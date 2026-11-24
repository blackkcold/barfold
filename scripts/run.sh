#!/bin/bash
set -euo pipefail

PROJECT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
cd "$PROJECT_DIR"

CONFIG="${1:-debug}"
if [ "$CONFIG" = "release" ]; then
    scripts/build.sh --adhoc
else
    scripts/build.sh --debug --adhoc
fi

VERSION="$(tr -d '[:space:]' < version.txt)"
APP="${PROJECT_DIR}/release/${VERSION}/BarFold.app"

echo "🚀 Launching ${APP}"
open -n "$APP"
sleep 1
echo "   Status file: ${HOME}/Library/Application Support/BarFold/state.json"
echo "   Log:         ${HOME}/Library/Application Support/BarFold/events.ndjson"
