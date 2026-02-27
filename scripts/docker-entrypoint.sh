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
    git clone "https://token:${TOKEN}@${GIT_HOST}${path}" /usercontent/
  else
    echo "cloning https://${GIT_HOST}${path}"
    git clone "https://${GIT_HOST}${path}" /usercontent/
  fi

  git config --global --add safe.directory /usercontent
  if [[ ! -z "$branch" ]]; then
    echo "checking out branch: $branch"
    git -C /usercontent/ checkout "$branch"
  fi

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
