#!/bin/bash
# Behavioural test for the CONFIG_SVC block of scripts/docker-entrypoint.sh.
# Extracts the real block (between BEGIN/END CONFIG LOAD markers) and runs it
# with stub npx/curl on PATH. See Eyevinn/wasm-runner#27.

set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
ENTRYPOINT="$REPO_ROOT/scripts/docker-entrypoint.sh"

FAILURES=0
pass() { echo "PASS: $1"; }
fail() {
  echo "FAIL: $1"
  FAILURES=$((FAILURES + 1))
}

WORK=$(mktemp -d)
trap 'rm -rf "$WORK"' EXIT
mkdir -p "$WORK/bin"

# Extract the real config block and append a marker for "reached the run phase"
sed -n '/^# BEGIN CONFIG LOAD$/,/^# END CONFIG LOAD$/p' "$ENTRYPOINT" > "$WORK/block.sh"
if [ ! -s "$WORK/block.sh" ]; then
  fail "BEGIN/END CONFIG LOAD markers not found in $ENTRYPOINT"
  exit 1
fi
{
  echo '#!/bin/bash'
  cat "$WORK/block.sh"
  echo 'echo REACHED_RUN'
  echo 'echo "FOO=${FOO:-unset}"'
} > "$WORK/run.sh"

# Stub curl (token refresh fails softly, as in the real block) and timeout
# (passes through the real command after dropping the duration argument).
printf '#!/bin/bash\nexit 22\n' > "$WORK/bin/curl"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$WORK/bin/timeout"
chmod +x "$WORK/bin/curl" "$WORK/bin/timeout"

# usage: run_case <stub-body> [env assignments...]; sets OUT, RC
run_case() {
  local body="$1"
  shift
  printf '#!/bin/bash\n%s\n' "$body" > "$WORK/bin/npx"
  chmod +x "$WORK/bin/npx"
  OUT=$(env -i PATH="$WORK/bin:/usr/bin:/bin" OSAAS_CLI_VERSION=0.0.0 "$@" bash "$WORK/run.sh" 2>&1)
  RC=$?
}

CFG=(OSC_ACCESS_TOKEN=tok CONFIG_SVC=mystore)

# 1. Non-zero exit fails the app
run_case 'echo "boom" >&2; exit 1' "${CFG[@]}"
if [ $RC -eq 1 ] && ! echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q '\[CONFIG\] ERROR: Failed to load config (exit 1)'; then
  pass "non-zero exit fails and does not reach run phase"
else
  fail "non-zero exit (rc=$RC): $OUT"
fi

# 2. Timeout (exit 124) fails the app
run_case 'exit 124' "${CFG[@]}"
if [ $RC -eq 124 ] && ! echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'Timed out'; then
  pass "timeout (124) fails and does not reach run phase"
else
  fail "timeout (rc=$RC): $OUT"
fi

# 3. Exit 0 with non-empty output but no valid exports fails
run_case 'echo "garbled output"' "${CFG[@]}"
if [ $RC -ne 0 ] && ! echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'no valid environment variables'; then
  pass "exit 0 with no valid exports fails"
else
  fail "no valid exports (rc=$RC): $OUT"
fi

# 4. Expired token prints the refresh-app-config hint
run_case 'echo "401 Unauthorized: token expired" >&2; exit 1' "${CFG[@]}"
if [ $RC -ne 0 ] && echo "$OUT" | grep -q "refresh-app-config"; then
  pass "expired token prints refresh-app-config hint"
else
  fail "expired token hint (rc=$RC): $OUT"
fi

# 5. Valid exports are loaded and the run phase is reached
run_case 'echo "export FOO=bar"' "${CFG[@]}"
if [ $RC -eq 0 ] && echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'FOO=bar'; then
  pass "valid exports are loaded and run phase reached"
else
  fail "valid exports (rc=$RC): $OUT"
fi

# 6. Empty store (exit 0, empty stdout, stderr noise) continues
run_case 'echo "npm notice" >&2; exit 0' "${CFG[@]}"
if [ $RC -eq 0 ] && echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'has no parameters'; then
  pass "empty store continues with no-parameters log"
else
  fail "empty store (rc=$RC): $OUT"
fi

# 7. No CONFIG_SVC: block skipped, npx never called
run_case 'echo "npx called"; exit 1' OSC_ACCESS_TOKEN=tok
if [ $RC -eq 0 ] && echo "$OUT" | grep -q REACHED_RUN && ! echo "$OUT" | grep -q 'npx called'; then
  pass "no CONFIG_SVC is unaffected"
else
  fail "no CONFIG_SVC (rc=$RC): $OUT"
fi

# 8. CONFIG_SVC without OSC_ACCESS_TOKEN: unchanged (skipped)
run_case 'echo "npx called"; exit 1' CONFIG_SVC=mystore
if [ $RC -eq 0 ] && echo "$OUT" | grep -q REACHED_RUN && ! echo "$OUT" | grep -q 'npx called'; then
  pass "CONFIG_SVC without token is unaffected"
else
  fail "CONFIG_SVC without token (rc=$RC): $OUT"
fi

if [ $FAILURES -ne 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All tests passed"
