#!/bin/bash
# Verifies scripts/docker-entrypoint.sh keeps git clone credentials out of the
# URL argument and instead uses a scoped http.extraheader, plus scrubs stderr.
# See Eyevinn/wasm-runner#21.

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

# 1. bash -n syntax check
if bash -n "$ENTRYPOINT"; then
  pass "bash -n scripts/docker-entrypoint.sh"
else
  fail "bash -n scripts/docker-entrypoint.sh"
fi

# 2. The git clone line must not embed ${TOKEN} in the URL
CLONE_LINE=$(grep -n 'git.*clone' "$ENTRYPOINT" | grep -v '^\s*#')
if [ -z "$CLONE_LINE" ]; then
  fail "could not find a git clone invocation in $ENTRYPOINT"
elif echo "$CLONE_LINE" | grep -q '\${TOKEN}@'; then
  fail "git clone line still embeds \${TOKEN} in the URL: $CLONE_LINE"
else
  pass "git clone line does not embed \${TOKEN} in the URL"
fi

# 3. The clone line must reference GIT_AUTH_ARGS
if echo "$CLONE_LINE" | grep -q 'GIT_AUTH_ARGS\[@\]'; then
  pass "git clone line uses \${GIT_AUTH_ARGS[@]}"
else
  fail "git clone line does not use \${GIT_AUTH_ARGS[@]}: $CLONE_LINE"
fi

# 4. GIT_AUTH_ARGS must be built with the scoped http.https://<host>/.extraheader form
if grep -q 'http\.https://\${GIT_HOST}/\.extraheader=' "$ENTRYPOINT"; then
  pass "GIT_AUTH_ARGS uses scoped http.https://\${GIT_HOST}/.extraheader= key"
else
  fail "GIT_AUTH_ARGS does not use the scoped http.https://\${GIT_HOST}/.extraheader= key"
fi

if grep -Eq '(^|[^.])http\.extraheader=' "$ENTRYPOINT"; then
  fail "found a bare (unscoped) http.extraheader= usage"
else
  pass "no bare (unscoped) http.extraheader= usage found"
fi

# 5. git_scrub_stderr must wrap the clone call
if echo "$CLONE_LINE" | grep -q 'git_scrub_stderr'; then
  pass "clone call is wrapped by git_scrub_stderr"
else
  fail "clone call is not wrapped by git_scrub_stderr: $CLONE_LINE"
fi

if grep -q 'git_scrub_stderr()' "$ENTRYPOINT"; then
  pass "git_scrub_stderr helper is defined"
else
  fail "git_scrub_stderr helper is not defined"
fi

# 6. Sandboxed check: building GIT_AUTH_ARGS with a fake token must never leak
#    the raw token string, only its base64 form.
FAKE_TOKEN="faketoken1234567890123456789012"
GIT_HOST="github.com"

# Extract the GIT_AUTH_ARGS construction block from the script and eval it in
# isolation with our own TOKEN/GIT_HOST, rather than sourcing the whole
# script (which would attempt a real clone).
BLOCK=$(awk '/^  TOKEN="\$\{GIT_TOKEN:-\$GITHUB_TOKEN\}"/,/^  fi$/' "$ENTRYPOINT")
if [ -z "$BLOCK" ]; then
  fail "could not extract GIT_AUTH_ARGS construction block from $ENTRYPOINT"
else
  TOKEN="$FAKE_TOKEN"
  eval "$BLOCK"

  ARGS_STR="${GIT_AUTH_ARGS[*]:-}"
  if echo "$ARGS_STR" | grep -q "$FAKE_TOKEN"; then
    fail "GIT_AUTH_ARGS contains the raw fake token string"
  else
    pass "GIT_AUTH_ARGS does not contain the raw fake token string"
  fi

  # Extract the base64 chunk after "basic " and decode it, rather than
  # string-comparing to an independently-computed base64 value: this keeps
  # the assertion structural (decodes to "x-access-token:<non-empty>") so it
  # is not sensitive to how the token value itself is represented.
  B64_CHUNK=$(echo "$ARGS_STR" | sed -n 's/.*basic \([A-Za-z0-9+\/=]*\).*/\1/p')
  if [ -z "$B64_CHUNK" ]; then
    fail "could not extract a base64 chunk from GIT_AUTH_ARGS: $ARGS_STR"
  else
    DECODED=$(printf '%s' "$B64_CHUNK" | base64 -d 2>/dev/null)
    if echo "$DECODED" | grep -q '^x-access-token:.\+$'; then
      pass "GIT_AUTH_ARGS header decodes to x-access-token:<value>"
    else
      fail "GIT_AUTH_ARGS header does not decode to x-access-token:<value>: $DECODED"
    fi
  fi
fi

if [ "$FAILURES" -eq 0 ]; then
  echo "All checks passed."
  exit 0
else
  echo "$FAILURES check(s) failed."
  exit 1
fi
