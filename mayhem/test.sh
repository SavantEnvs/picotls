#!/usr/bin/env bash
#
# mayhem/test.sh — RUN picotls' own picotest suites (test-minicrypto.t, test-openssl.t; built by
# mayhem/build.sh with normal flags). They are known-answer tests (cipher/hash/KDF vectors, full TLS 1.3
# handshakes asserting negotiated results). Counts come from the top-level TAP lines; a runner that
# prints no plan, or whose passed count differs from its plan, fails — so a neutered binary cannot pass.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ]
}

export BINARY_DIR="$SRC/build/test"
passed=0; failed=0; skipped=0
for exe in test-minicrypto.t test-openssl.t; do
  bin="$BINARY_DIR/$exe"
  if [ ! -x "$bin" ]; then echo "FATAL: $bin missing (mayhem/build.sh should have built it)" >&2; failed=$((failed+1)); continue; fi
  out=$("$bin" 2>&1); rc=$?
  printf '%s\n' "$out" | grep -E '^(ok|not ok|1\.\.|# SKIP)' || true
  p=$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+' || true)
  s=$(printf '%s\n' "$out" | grep -cE '^ok [0-9]+.*# [Ss][Kk][Ii][Pp]' || true)
  f=$(printf '%s\n' "$out" | grep -cE '^not ok' || true)
  plan=$(printf '%s\n' "$out" | sed -n 's/^1\.\.\([0-9][0-9]*\)$/\1/p' | tail -1)
  if [ -z "$plan" ] || [ "$rc" -ne 0 ] || [ $((p + f)) -ne "$plan" ]; then
    echo "FAIL $exe: rc=$rc plan='${plan:-none}' ok=$p not_ok=$f" >&2
    f=$((f + 1))
  fi
  passed=$((passed + p - s)); skipped=$((skipped + s)); failed=$((failed + f))
done
emit_ctrf "picotest" "$passed" "$failed" "$skipped"
