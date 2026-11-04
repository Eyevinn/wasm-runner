#!/usr/bin/env bash
# Hermetic test: .commit-info.json and main.wasm must not show in `git status`.
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
ENTRY="$ROOT/scripts/docker-entrypoint.sh"
FAILS=0
ok() { echo "PASS: $1"; }
bad() { echo "FAIL: $1"; FAILS=$((FAILS+1)); }
check() { if eval "$2"; then ok "$1"; else bad "$1"; fi; }

TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
FUNCS="$TMP/funcs.sh"
{ sed -n '/^exclude_from_git_status() {/,/^}/p' "$ENTRY"; sed -n '/^write_commit_info() {/,/^}/p' "$ENTRY"; } > "$FUNCS"
check "functions extracted" 'grep -q "^write_commit_info()" "$FUNCS" && grep -q "^exclude_from_git_status()" "$FUNCS"'

REPO="$TMP/repo"; CALLER="$TMP/caller"
mkdir -p "$REPO" "$CALLER"
git -C "$REPO" init -q
echo hi > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" -c user.email=t@example.com -c user.name=T commit -qm "init"
mkdir -p "$REPO/.git/info"
echo "user-rule.log" >> "$REPO/.git/info/exclude"
BEFORE="$(git -C "$REPO" rev-list --count HEAD)"

# Run in a subshell whose cwd is NOT the repo (the entrypoint runs from /runner).
run() { ( cd "$CALLER" && source "$FUNCS" && "$@" >/dev/null 2>&1 ); }

run write_commit_info "$REPO"
check ".commit-info.json exists with sha" 'grep -q "\"sha\"" "$REPO/.commit-info.json"'
check "git status clean" '[ -z "$(git -C "$REPO" status --porcelain)" ]'
run write_commit_info "$REPO"
check "exclude idempotent" '[ "$(grep -cxF .commit-info.json "$REPO/.git/info/exclude")" = 1 ]'
check "user exclude rule survives" 'grep -qxF user-rule.log "$REPO/.git/info/exclude"'
check "no commit created" '[ "$(git -C "$REPO" rev-list --count HEAD)" = "$BEFORE" ]'
check "no .gitignore created" '[ ! -e "$REPO/.gitignore" ]'
check "no staged/unstaged diff" 'git -C "$REPO" diff --quiet && git -C "$REPO" diff --cached --quiet'
check "caller cwd has no .git" '[ ! -e "$CALLER/.git" ]'

echo wasm > "$REPO/main.wasm"
run exclude_from_git_status "$REPO" main.wasm
check "main.wasm hidden" '[ -z "$(git -C "$REPO" status --porcelain)" ]'
check "entrypoint cp branch excludes main.wasm" \
  'grep -A2 "cp \"\$WASM_FILE\" /usercontent/main.wasm" "$ENTRY" | grep -q "exclude_from_git_status /usercontent main.wasm"'

if [ "$FAILS" = 0 ]; then echo "ALL PASSED"; else echo "$FAILS failed"; exit 1; fi
