#!/usr/bin/env bash
set -euo pipefail

BASE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_ROOT="$BASE_DIR/codex-app"
DEFAULT_APP_DIR="$APP_ROOT/Codex.app"
APP_DIR="$DEFAULT_APP_DIR"

select_latest_app_dir() {
  local app_root="$1"
  local candidate=""
  local selected=""
  local selected_mtime=0
  local candidate_mtime=0

  while IFS= read -r -d '' candidate; do
    candidate_mtime="$(stat -f '%m' "$candidate")" || continue
    if [[ -z "$selected" || "$candidate_mtime" -gt "$selected_mtime" ]]; then
      selected="$candidate"
      selected_mtime="$candidate_mtime"
    fi
  done < <(find "$app_root" -maxdepth 1 -type d -name '*.app' -print0)

  printf '%s' "$selected"
}

if [[ -d "$APP_ROOT" ]]; then
  APP_DIR="$(select_latest_app_dir "$APP_ROOT")"
  if [[ -z "$APP_DIR" ]]; then
    APP_DIR="$DEFAULT_APP_DIR"
  fi
fi

if [[ ! -d "$APP_DIR" ]]; then
  echo "Codex app not found at $APP_DIR"
  echo "Run ./install.sh first."
  exit 1
fi

"$APP_DIR/Contents/MacOS/Electron" --no-sandbox "$@"
