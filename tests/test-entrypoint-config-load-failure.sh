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
  echo 'echo "AFTER_ACCESS=${OSC_ACCESS_TOKEN:-unset}"'
  echo 'echo "AFTER_REFRESH=${OSC_REFRESH_TOKEN:-unset}"'
} > "$WORK/run.sh"

# Stub curl (token refresh fails softly, as in the real block) and timeout
# (passes through the real command after dropping the duration argument).
# The curl stub emulates the token exchange: it honours -o/--data, records the
# request body, prints CURL_STATUS and writes CURL_BODY; it exits with
# CURL_EXIT (default 22, i.e. the exchange fails softly as before).
cat > "$WORK/bin/curl" <<'STUB'
#!/bin/bash
out=""
data=""
while [ $# -gt 0 ]; do
  case "$1" in
    -o) out="$2"; shift ;;
    --data) data="${2#@}"; shift ;;
  esac
  shift
done
[ -n "$data" ] && cat "$data" > "$CURL_BODY_LOG"
[ -n "$out" ] && printf '%s' "${CURL_BODY:-}" > "$out"
printf '%s' "${CURL_STATUS:-000}"
exit "${CURL_EXIT:-22}"
STUB
# jq is absent from the real image: a stub that exits 127 stops a developer
# machine that has jq from masking a regression back to jq.
printf '#!/bin/bash\nexit 127\n' > "$WORK/bin/jq"
chmod +x "$WORK/bin/jq"
printf '#!/bin/bash\nshift\nexec "$@"\n' > "$WORK/bin/timeout"
chmod +x "$WORK/bin/curl" "$WORK/bin/timeout"

# usage: run_case <stub-body> [env assignments...]; sets OUT, RC
run_case() {
  local body="$1"
  shift
  printf '#!/bin/bash\n%s\n' "$body" > "$WORK/bin/npx"
  chmod +x "$WORK/bin/npx"
  OUT=$(env -i PATH="$WORK/bin:/usr/bin:/bin:$NODE_DIR" OSAAS_CLI_VERSION=0.0.0 CURL_BODY_LOG="$WORK/curl-body.log" "$@" bash "$WORK/run.sh" 2>&1)
  RC=$?
}

NODE_DIR=$(dirname "$(command -v node)")
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
run_case 'echo "export FOO=bar"; echo "export BAZ=qux"' "${CFG[@]}"
if [ $RC -eq 0 ] && echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'FOO=bar' \
  && echo "$OUT" | grep -q 'Loaded 2 environment variable(s)' && ! echo "$OUT" | grep -q 'qux'; then
  pass "valid exports are loaded, run phase reached, values not logged"
else
  fail "valid exports (rc=$RC): $OUT"
fi

# 5a. Failure with a secret on stdout: not logged, hint still driven by stderr
run_case "echo \"export DB_PASS='S3CR3T-canary'\"; echo 'boom 401 unauthorized' >&2; exit 2" "${CFG[@]}"
if [ $RC -eq 2 ] && echo "$OUT" | grep -q 'Failed to load config (exit 2)' && echo "$OUT" | grep -q 'refresh-app-config' \
  && ! echo "$OUT" | grep -q 'S3CR3T-canary'; then
  pass "failure with secret on stdout does not log it"
else
  fail "leak on failure (rc=$RC): $OUT"
fi

# 5b. Timeout after partial stdout: not logged
run_case "echo \"export DB_PASS='S3CR3T-canary'\"; exit 124" "${CFG[@]}"
if [ $RC -eq 124 ] && echo "$OUT" | grep -q 'Timed out' && ! echo "$OUT" | grep -q 'S3CR3T-canary'; then
  pass "timeout with secret on stdout does not log it"
else
  fail "leak on timeout (rc=$RC): $OUT"
fi

# 5c. Invalid key name: name logged, value not
run_case "echo \"export MY-KEY='S3CR3T-canary'\"" "${CFG[@]}"
if [ $RC -ne 0 ] && ! echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'no valid environment variables' \
  && echo "$OUT" | grep -q 'MY-KEY' && ! echo "$OUT" | grep -q 'S3CR3T-canary'; then
  pass "invalid key name logged without its value"
else
  fail "leak on invalid key (rc=$RC): $OUT"
fi

# 5d. Tokens in stderr are redacted (literal token and well-known shapes)
run_case 'echo "auth failed for ${OSC_ACCESS_TOKEN} with ghp_abcdefghijklmnopqrstuvwxyz0123456789 and eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxMjM0In0.c2lnbmF0dXJl" >&2; exit 2' OSC_ACCESS_TOKEN=osc-literal-token-9f3a CONFIG_SVC=mystore
if [ $RC -eq 2 ] && echo "$OUT" | grep -q '\[REDACTED\]' \
  && ! echo "$OUT" | grep -qE 'osc-literal-token-9f3a|ghp_abcdefghijklmnopqrstuvwxyz0123456789|eyJhbGciOiJIUzI1NiJ9'; then
  pass "tokens in stderr are redacted"
else
  fail "token redaction (rc=$RC): $OUT"
fi

# 5e. The exchanged (fresh) token is redacted too
run_case 'echo "bad token $OSC_ACCESS_TOKEN" >&2; exit 2' OSC_ACCESS_TOKEN=osc-literal-token-9f3a CONFIG_SVC=mystore CURL_EXIT=0 CURL_STATUS=200 'CURL_BODY={"token":"fresh-literal-token-77aa","expiresIn":3600}'
if [ $RC -eq 2 ] && echo "$OUT" | grep -q '\[REDACTED\]' && ! echo "$OUT" | grep -q 'fresh-literal-token-77aa'; then
  pass "fresh exchanged token is redacted"
else
  fail "fresh token redaction (rc=$RC): $OUT"
fi

# 5f. Stdout must not drive the refresh hint
run_case "echo \"export X='expired 401'\"; echo boom >&2; exit 2" "${CFG[@]}"
if [ $RC -eq 2 ] && ! echo "$OUT" | grep -q refresh-app-config && ! echo "$OUT" | grep -q 'expired 401'; then
  pass "stdout no longer drives the refresh hint"
else
  fail "hint from stdout (rc=$RC): $OUT"
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

# 9. Exchange succeeds: config-to-env uses the fresh token, the app keeps the
# original token, OSC_REFRESH_TOKEN is the original, the body is {"token":...}
rm -f "$WORK/curl-body.log"
run_case 'echo "export FOO=$OSC_ACCESS_TOKEN"' "${CFG[@]}" CURL_EXIT=0 CURL_STATUS=200 'CURL_BODY={"token":"fresh","expiresIn":3600}'
if [ $RC -eq 0 ] && echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'FOO=fresh' \
  && echo "$OUT" | grep -q 'AFTER_ACCESS=tok' && echo "$OUT" | grep -q 'AFTER_REFRESH=tok' \
  && ! echo "$OUT" | grep -q 'WARNING' && [ "$(cat "$WORK/curl-body.log")" = '{"token":"tok"}' ]; then
  pass "successful exchange: config load uses fresh token, app keeps original"
else
  fail "successful exchange (rc=$RC): $OUT body=$(cat "$WORK/curl-body.log" 2>/dev/null)"
fi

# 10. Exchange failures warn (status/code only), keep the original token and
# still reach the config command.
exchange_failure_case() {
  local label="$1" want="$2"
  shift 2
  run_case 'echo "export FOO=$OSC_ACCESS_TOKEN"' "${CFG[@]}" "$@"
  if [ $RC -eq 0 ] && echo "$OUT" | grep -q REACHED_RUN && echo "$OUT" | grep -q 'FOO=tok' \
    && echo "$OUT" | grep -qF "[CONFIG] WARNING: runner token exchange failed ($want); using the original token" \
    && ! echo "$OUT" | grep -q 'FOO=fresh' && echo "$OUT" | grep -q 'AFTER_ACCESS=tok'; then
    pass "exchange failure ($label) warns and keeps original token"
  else
    fail "exchange failure $label (rc=$RC): $OUT"
  fi
}
exchange_failure_case "401 expired" "HTTP 401, code=refresh_token_expired" CURL_EXIT=0 CURL_STATUS=401 'CURL_BODY={"code":"refresh_token_expired","token":"fresh"}'
exchange_failure_case "401 invalid" "HTTP 401, code=refresh_token_invalid" CURL_EXIT=0 CURL_STATUS=401 'CURL_BODY={"code":"refresh_token_invalid"}'
exchange_failure_case "500" "HTTP 500, code=none" CURL_EXIT=0 CURL_STATUS=500 'CURL_BODY=oops'
exchange_failure_case "curl exit 22" "curl exit 22, code=none" CURL_EXIT=22
exchange_failure_case "curl timeout 28" "curl exit 28, code=none" CURL_EXIT=28
# A 200 without a usable token is a failure, never an empty token
exchange_failure_case "200 without token" "HTTP 200, code=none" CURL_EXIT=0 CURL_STATUS=200 'CURL_BODY={"expiresIn":3600}'
exchange_failure_case "200 with non-JSON" "HTTP 200, code=none" CURL_EXIT=0 CURL_STATUS=200 'CURL_BODY=not json'

if [ $FAILURES -ne 0 ]; then
  echo "$FAILURES test(s) failed"
  exit 1
fi
echo "All tests passed"
