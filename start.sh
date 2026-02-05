#!/usr/bin/env bash
set -euo pipefail

APP_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/codex-app/Codex.app"
if [[ ! -d "$APP_DIR" ]]; then
  echo "Codex.app not found at $APP_DIR"
  echo "Run ./install.sh first."
  exit 1
fi

"$APP_DIR/Contents/MacOS/Electron" --no-sandbox "$@"
