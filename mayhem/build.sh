#!/usr/bin/env bash
#
# mayhem/build.sh — build picotls' three upstream libFuzzer harnesses (fuzz/fuzz-*.c, the same set
# OSS-Fuzz builds) with ASan+UBSan, plus the project's own picotest suites with NORMAL flags.
# Runs in the commit image as `mayhem` in /mayhem; re-runnable and offline (no fetches).
set -euo pipefail

[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
FUZZ_BUILD="$SRC/build/fuzz"
TEST_BUILD="$SRC/build/test"

# 1) The sanitized libraries. PTLS_FUZZ_HANDSHAKE=1 is what upstream's BUILD_FUZZER cmake path defines
#    (it relaxes handshake signature/finished checks so inputs reach the message parsers).
#    -fsanitize=fuzzer-no-link gives the library SanitizerCoverage (the harness TU alone is not enough);
#    it is added unconditionally, even when SANITIZER_FLAGS is empty.
cmake -S . -B "$FUZZ_BUILD" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="-DPTLS_FUZZ_HANDSHAKE=1 $SANITIZER_FLAGS -fsanitize=fuzzer-no-link $DEBUG_FLAGS"
cmake --build "$FUZZ_BUILD" -j"$MAYHEM_JOBS" --target picotls-core picotls-openssl picotls-minicrypto

# 2) Each harness twice: libFuzzer binary + a run-once -standalone reproducer. LeakSanitizer is switched
#    off at build time via mayhem/lsan_off.cc (ASan and UBSan stay active).
# shellcheck disable=SC2086
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$FUZZ_BUILD/lsan_off.o"
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$FUZZ_BUILD/standalone_main.o"

INC=(-I"$SRC/include" -I"$SRC/t" -I"$SRC/deps/cifra/src" -I"$SRC/deps/cifra/src/ext" -I"$SRC/deps/micro-ecc")
LIBS=("$FUZZ_BUILD/libpicotls-minicrypto.a" "$FUZZ_BUILD/libpicotls-openssl.a" "$FUZZ_BUILD/libpicotls-core.a" -lcrypto -ldl -lpthread)

for h in fuzz-asn1 fuzz-client-hello fuzz-server-hello; do
    # shellcheck disable=SC2086
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -D_GNU_SOURCE -DPTLS_FUZZ_HANDSHAKE=1 "${INC[@]}" $LIB_FUZZING_ENGINE \
        "$SRC/fuzz/$h.c" "$FUZZ_BUILD/lsan_off.o" "${LIBS[@]}" -o "$SRC/$h"
    # shellcheck disable=SC2086
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -O1 -D_GNU_SOURCE -DPTLS_FUZZ_HANDSHAKE=1 "${INC[@]}" \
        "$SRC/fuzz/$h.c" "$FUZZ_BUILD/standalone_main.o" "$FUZZ_BUILD/lsan_off.o" "${LIBS[@]}" -o "$SRC/$h-standalone"
done

# 3) The project's own picotest suites (test-minicrypto.t, test-openssl.t), NORMAL flags, no sanitizers.
cmake -S . -B "$TEST_BUILD" -DCMAKE_C_COMPILER="$CC" -DCMAKE_CXX_COMPILER="$CXX" \
    -DCMAKE_C_FLAGS="$COVERAGE_FLAGS" -DCMAKE_EXE_LINKER_FLAGS="$COVERAGE_FLAGS"
cmake --build "$TEST_BUILD" -j"$MAYHEM_JOBS" --target test-minicrypto.t test-openssl.t
