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

# Write commit metadata to a well-known file for platform visibility
write_commit_info() {
  local repo_dir="$1"
  if [ -d "$repo_dir/.git" ]; then
    local sha=$(git -C "$repo_dir" rev-parse HEAD 2>/dev/null || echo "")
    if [ -n "$sha" ]; then
      local short_sha=$(echo "$sha" | cut -c1-7)
      local message=$(git -C "$repo_dir" log -1 --format='%s' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
      local author=$(git -C "$repo_dir" log -1 --format='%an' 2>/dev/null | sed 's/\\/\\\\/g; s/"/\\"/g')
      local date=$(git -C "$repo_dir" log -1 --format='%aI' 2>/dev/null)

      local recent="["
      local first=true
      while IFS='|' read -r c_sha c_msg c_author c_date; do
        [ -z "$c_sha" ] && continue
        local c_short=$(echo "$c_sha" | cut -c1-7)
        c_msg=$(echo "$c_msg" | sed 's/\\/\\\\/g; s/"/\\"/g')
        c_author=$(echo "$c_author" | sed 's/\\/\\\\/g; s/"/\\"/g')
        if [ "$first" = true ]; then first=false; else recent="$recent,"; fi
        recent="$recent{\"sha\":\"$c_sha\",\"shortSha\":\"$c_short\",\"message\":\"$c_msg\",\"author\":\"$c_author\",\"date\":\"$c_date\"}"
      done <<< "$(git -C "$repo_dir" log -5 --format='%H|%s|%an|%aI' 2>/dev/null)"
      recent="$recent]"

      cat > "$repo_dir/.commit-info.json" << COMMITEOF
{"sha":"$sha","shortSha":"$short_sha","message":"$message","author":"$author","date":"$date","recentCommits":$recent}
COMMITEOF
      echo "Commit info: $short_sha - $message"
    fi
  fi
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
  if [[ ! -z "$TOKEN" ]]; then
    echo "cloning https://***@${GIT_HOST}${path}"
    git clone "https://${TOKEN}@${GIT_HOST}${path}" /usercontent/
  else
    echo "cloning https://${GIT_HOST}${path}"
    git clone "https://${GIT_HOST}${path}" /usercontent/
  fi

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
  fi
elif [[ ! -z "$WASM_URL" ]]; then
  echo "Downloading WASM file from $WASM_URL"
  curl -sSL "$WASM_URL" -o /usercontent/main.wasm
fi

chown runner:runner -R /usercontent
cd /usercontent

if [[ ! -z "$OSC_ACCESS_TOKEN" ]] && [[ ! -z "$CONFIG_SVC" ]]; then
  echo "Loading environment variables from application config service '$CONFIG_SVC'"
  eval `npx -y @osaas/cli@latest web config-to-env $CONFIG_SVC`
fi

exec runuser -u runner "$@"
