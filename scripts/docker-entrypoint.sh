#!/bin/bash

if [ -z "$WASM_URL" ]; then
  echo "WASM_URL is not set. Exiting."
  exit 1
fi

STAGING_DIR="/usercontent"
echo "ensure staging dir is empty"
rm -rf /usercontent/*
echo "Downloading WASM file from $WASM_URL"
curl -sSL "$WASM_URL" -o /usercontent/main.wasm

chown runner:runner -R /usercontent
cd /usercontent

if [[ ! -z "$OSC_ACCESS_TOKEN" ]] && [[ ! -z "$CONFIG_SVC" ]]; then
  echo "Loading environment variables from application config service '$CONFIG_SVC'"
  eval `npx -y @osaas/cli@latest web config-to-env $CONFIG_SVC`
fi

exec runuser -u runner "$@"