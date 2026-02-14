#!/bin/bash

if [ -z "$WASM_URL" ] && [ -z "$GITHUB_URL" ]; then
  echo "WASM_URL or GITHUB_URL must be set. Exiting."
  exit 1
fi

if [[ ! -z "$WASM_URL" ]] && [[ "$WASM_URL" =~ ^https?://github\.com/ ]]; then
  GITHUB_URL="$WASM_URL"
  unset WASM_URL
fi

STAGING_DIR="/usercontent"
echo "ensure staging dir is empty"
rm -rf /usercontent/* /usercontent/.[!.]*

if [[ ! -z "$GITHUB_URL" ]]; then
  branch=""
  if [[ "$GITHUB_URL" == *"#"* ]]; then
    branch="${GITHUB_URL#*#}"
    branch="${branch%/}"
    GITHUB_URL="${GITHUB_URL%%#*}"
  fi

  path="/${GITHUB_URL#*://*/}" && [[ "/${GITHUB_URL}" == "${path}" ]] && path="/"

  if [[ ! -z "$GITHUB_TOKEN" ]]; then
    echo "cloning https://***@github.com${path}"
    git clone https://$GITHUB_TOKEN@github.com${path} /usercontent/
  else
    echo "cloning https://github.com${path}"
    git clone https://github.com${path} /usercontent/
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
