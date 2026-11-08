#!/bin/bash

if [ -z "$WASM_URL" ] && [ -z "$GITHUB_URL" ] && [ -z "$GIT_URL" ]; then
  echo "WASM_URL, GIT_URL, or GITHUB_URL must be set. Exiting."
  exit 1
fi

if [[ ! -z "$WASM_URL" ]] && [[ "$WASM_URL" =~ ^https?://.+/.+ ]]; then
  GIT_URL="$WASM_URL"
  unset WASM_URL
fi

# Backward compatibility: convert GITHUB_URL to GIT_URL
if [[ -z "$GIT_URL" ]] && [[ ! -z "$GITHUB_URL" ]]; then
  GIT_URL="$GITHUB_URL"
fi

# Run a git command while scrubbing any leaked credentials from its stderr.
# Uses process substitution (not a pipe) so $? still reflects the git command.
git_scrub_stderr() {
  "$@" 2> >(sed -r 's/gh[pso]_[A-Za-z0-9]{20,}/[REDACTED]/g; s/([Bb]asic )[A-Za-z0-9+\/=]{8,}/\1[REDACTED]/g' >&2)
}

# Hide a platform-written file from `git status` without touching tracked files.
exclude_from_git_status() {
  local repo_dir="$1" name="$2" excl
  excl="$(git -C "$repo_dir" rev-parse --git-path info/exclude 2>/dev/null)" || return 0
  [ -n "$excl" ] || return 0
  # git prints this path relative to the -C directory, not to this script's cwd (/runner)
  case "$excl" in /*) ;; *) excl="$repo_dir/$excl" ;; esac
  mkdir -p "$(dirname "$excl")" 2>/dev/null || return 0
  grep -qxF "$name" "$excl" 2>/dev/null || echo "$name" >> "$excl" 2>/dev/null || true
}

# Write commit metadata to a well-known file for platform visibility
write_commit_info() {
  local repo_dir="$1"
  if ! git -C "$repo_dir" rev-parse HEAD >/dev/null 2>&1; then return 0; fi
  local sha shortSha msg author date
  sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null) || return 0
  shortSha=$(git -C "$repo_dir" rev-parse --short HEAD 2>/dev/null) || return 0
  msg=$(git -C "$repo_dir" log -1 --format='%s' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g') || return 0
  author=$(git -C "$repo_dir" log -1 --format='%an' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g') || return 0
  date=$(git -C "$repo_dir" log -1 --format='%aI' 2>/dev/null) || return 0

  local recent="["
  local first=true
  while read -r c_sha; do
    [ -z "$c_sha" ] && continue
    local c_short c_msg c_author c_date
    c_short=$(git -C "$repo_dir" rev-parse --short "$c_sha" 2>/dev/null)
    c_msg=$(git -C "$repo_dir" log -1 --format='%s' "$c_sha" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
    c_author=$(git -C "$repo_dir" log -1 --format='%an' "$c_sha" 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
    c_date=$(git -C "$repo_dir" log -1 --format='%aI' "$c_sha" 2>/dev/null)
    if [ "$first" = true ]; then first=false; else recent="$recent,"; fi
    recent="$recent{\"sha\":\"$c_sha\",\"shortSha\":\"$c_short\",\"message\":\"$c_msg\",\"author\":\"$c_author\",\"date\":\"$c_date\"}"
  done <<< "$(git -C "$repo_dir" log -5 --format='%H' 2>/dev/null)"
  recent="$recent]"

  printf '{"sha":"%s","shortSha":"%s","message":"%s","author":"%s","date":"%s","recentCommits":%s}\n' \
    "$sha" "$shortSha" "$msg" "$author" "$date" "$recent" \
    > "$repo_dir/.commit-info.json" 2>/dev/null || true
  exclude_from_git_status "$repo_dir" .commit-info.json
  echo "Commit info: $shortSha - $msg"
}

STAGING_DIR="/usercontent"
echo "ensure staging dir is empty"
rm -rf /usercontent/* /usercontent/.[!.]*

if [[ ! -z "$GIT_URL" ]]; then
  branch=""
  if [[ "$GIT_URL" == *"#"* ]]; then
    branch="${GIT_URL#*#}"
    branch="${branch%/}"
    GIT_URL="${GIT_URL%%#*}"
  fi

  GIT_HOST=$(echo "$GIT_URL" | sed -E 's|^https?://([^/]+).*|\1|')
  path="/${GIT_URL#*://*/}" && [[ "/${GIT_URL}" == "${path}" ]] && path="/"

  TOKEN="${GIT_TOKEN:-$GITHUB_TOKEN}"
  GIT_AUTH_ARGS=()
  if [[ ! -z "$TOKEN" ]]; then
    AUTH_B64=$(printf '%s' "x-access-token:${TOKEN}" | base64 | tr -d '\n')
    GIT_AUTH_ARGS=(-c "http.https://${GIT_HOST}/.extraheader=AUTHORIZATION: basic ${AUTH_B64}")
  fi

  echo "cloning https://${GIT_HOST}${path}"
  git_scrub_stderr git "${GIT_AUTH_ARGS[@]}" clone "https://${GIT_HOST}${path}" /usercontent/

  git config --global --add safe.directory /usercontent
  if [[ ! -z "$branch" ]]; then
    echo "checking out branch: $branch"
    git -C /usercontent/ checkout "$branch"
  fi

  write_commit_info /usercontent

  # Find .wasm file in repo (WASI _start entry point is called by wasmedge by default)
  WASM_FILE=$(find /usercontent -name "*.wasm" -type f ! -path "/usercontent/.git/*" | head -1)
  if [ -z "$WASM_FILE" ]; then
    echo "No .wasm file found in repository. Exiting."
    exit 1
  fi
  echo "Found WASM file: $WASM_FILE"
  if [ "$WASM_FILE" != "/usercontent/main.wasm" ]; then
    cp "$WASM_FILE" /usercontent/main.wasm
    exclude_from_git_status /usercontent main.wasm
  fi
elif [[ ! -z "$WASM_URL" ]]; then
  echo "Downloading WASM file from $WASM_URL"
  curl -sSL "$WASM_URL" -o /usercontent/main.wasm
fi

chown runner:runner -R /usercontent
cd /usercontent

# BEGIN CONFIG LOAD
if [[ -n "${OSC_ACCESS_TOKEN:-}" && -n "${CONFIG_SVC:-}" ]]; then
  # Derive OSC environment from OSC_MCP_URL if OSC_ENV is not set explicitly
  if [[ -z "${OSC_ENV:-}" && -n "${OSC_MCP_URL:-}" ]]; then
    _extracted=$(echo "$OSC_MCP_URL" | sed -n 's|.*\.svc\.\([a-z]*\)\.osaas\.io.*|\1|p')
    OSC_ENV=${_extracted:-prod}
  fi
  # Token refresh: exchange the runner-refresh token for a short-lived PAT.
  # The PAT is used for the config load only. OSC_ACCESS_TOKEN is left as is
  # (the WASM module cannot observe it) and the original token is also exposed
  # as OSC_REFRESH_TOKEN. Any failure keeps the original token. There is no jq
  # in this image: the JSON body and the response are handled with node.
  export OSC_REFRESH_TOKEN="${OSC_REFRESH_TOKEN:-$OSC_ACCESS_TOKEN}"
  fresh_token=""
  refresh_body_file=$(umask 077; mktemp)
  refresh_resp_file=$(umask 077; mktemp)
  node -e 'process.stdout.write(JSON.stringify({token: process.env.OSC_REFRESH_TOKEN}))' >"$refresh_body_file" 2>/dev/null
  refresh_status=$(curl -s -o "$refresh_resp_file" -w '%{http_code}' --max-time 10 -X POST \
    -H 'Content-Type: application/json' --data @"$refresh_body_file" \
    "https://token.svc.${OSC_ENV:-prod}.osaas.io/runner-token/refresh" 2>/dev/null)
  refresh_curl_exit=$?
  refresh_code=""
  if [ $refresh_curl_exit -eq 0 ] && [ "$refresh_status" = "200" ]; then
    fresh_token=$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(typeof j.token==="string"?j.token:"")}catch(e){}' "$refresh_resp_file" 2>/dev/null)
  elif [ $refresh_curl_exit -eq 0 ]; then
    refresh_code=$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(typeof j.code==="string"?j.code:"")}catch(e){}' "$refresh_resp_file" 2>/dev/null)
  fi
  rm -f "$refresh_body_file" "$refresh_resp_file"
  if [ -z "$fresh_token" ]; then
    if [ $refresh_curl_exit -ne 0 ]; then
      refresh_status="curl exit $refresh_curl_exit"
    fi
    echo "[CONFIG] WARNING: runner token exchange failed (HTTP ${refresh_status:-none}, code=${refresh_code:-none}); using the original token"
  fi
  echo "[CONFIG] Loading environment variables from config service '$CONFIG_SVC'"
  # Read the exit status on the very next line. This script has no `set -e`
  # (keep it that way): under `set -e` a failing `x=$(cmd)` would kill the
  # script before config_exit is read, skipping the [CONFIG] error reporting.
  config_err_file=$(mktemp)
  config_env_output=$(OSC_ACCESS_TOKEN="${fresh_token:-$OSC_ACCESS_TOKEN}" timeout 60s npx -y "@osaas/cli@${OSAAS_CLI_VERSION:?OSAAS_CLI_VERSION must be set (pinned in the Dockerfile)}" web config-to-env ${OSC_ENV:+--env "$OSC_ENV"} "$CONFIG_SVC" 2>"$config_err_file")
  config_exit=$?
  config_err_output=$(cat "$config_err_file" 2>/dev/null)
  rm -f "$config_err_file"
  if [ $config_exit -eq 0 ]; then
    valid_exports=$(echo "$config_env_output" | grep "^export [A-Za-z_][A-Za-z0-9_]*=")
    if [ -n "$valid_exports" ]; then
      eval "$valid_exports"
      var_count=$(echo "$valid_exports" | wc -l | tr -d ' ')
      echo "[CONFIG] Loaded $var_count environment variable(s)"
    elif [ -n "$config_env_output" ]; then
      echo "[CONFIG] ERROR: Config service '$CONFIG_SVC' returned output with no valid environment variables: $config_env_output" >&2
      exit 1
    else
      echo "[CONFIG] Config service '$CONFIG_SVC' has no parameters"
    fi
  else
    if [ $config_exit -eq 124 ]; then
      echo "[CONFIG] ERROR: Timed out loading config from '$CONFIG_SVC' (exit 124): $config_err_output $config_env_output" >&2
    else
      echo "[CONFIG] ERROR: Failed to load config (exit $config_exit): $config_err_output $config_env_output" >&2
    fi
    if echo "$config_err_output $config_env_output" | grep -qiE 'expired|unauthorized|401'; then
      echo "[CONFIG] Use the 'refresh-app-config' MCP tool to issue a fresh token." >&2
    fi
    exit "$config_exit"
  fi
fi
# END CONFIG LOAD

exec runuser -u runner "$@"
