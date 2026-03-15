#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
APP_DIR="$ROOT/codex-app"
DEFAULT_APP_PATH="$APP_DIR/Codex.app"
APP_PATH="${1:-$DEFAULT_APP_PATH}"
OPTIMIZED_APP_PATH=""
ASAR_PATH=""
WORK="$ROOT/work/power-optimize"
ASAR_EXTRACT="$WORK/app-extract"
PATCH_LOG="$WORK/patch-power.log"

select_latest_app_path() {
  local app_root="$1"
  local exclude_pattern="${2:-}"
  local candidate=""
  local selected=""
  local selected_mtime=0
  local candidate_mtime=0

  while IFS= read -r -d '' candidate; do
    if [[ -n "$exclude_pattern" && "$candidate" == $exclude_pattern ]]; then
      continue
    fi
    candidate_mtime="$(stat -f '%m' "$candidate")" || continue
    if [[ -z "$selected" || "$candidate_mtime" -gt "$selected_mtime" ]]; then
      selected="$candidate"
      selected_mtime="$candidate_mtime"
    fi
  done < <(find "$app_root" -maxdepth 1 -type d -name '*.app' -print0)

  printf '%s' "$selected"
}

if [[ -z "${1:-}" && -d "$APP_DIR" && ! -d "$APP_PATH" ]]; then
  APP_PATH="$(select_latest_app_path "$APP_DIR" '*-optimized.app')"
fi

if [[ ! -d "$APP_PATH" ]]; then
  echo "App bundle not found at: ${APP_PATH:-$DEFAULT_APP_PATH}"
  echo "Usage: $0 [/path/to/Codex*.app]"
  exit 1
fi

OPTIMIZED_APP_PATH="${APP_PATH%.app}-optimized.app"

resolve_asar_path() {
  ASAR_PATH="$APP_PATH/Contents/Resources/app.asar"
  if [[ ! -f "$ASAR_PATH" ]]; then
    echo "app.asar not found at: $ASAR_PATH"
    exit 1
  fi
}

resolve_asar_path

if [[ ! -w "$ASAR_PATH" ]]; then
  if [[ -z "${1:-}" ]]; then
    rm -rf "$OPTIMIZED_APP_PATH"
    cp -R "$APP_PATH" "$OPTIMIZED_APP_PATH"
    chmod -R u+w "$OPTIMIZED_APP_PATH"
    APP_PATH="$OPTIMIZED_APP_PATH"
    resolve_asar_path
    echo "Created writable copy at: $APP_PATH"
  else
    echo "app.asar is not writable: $ASAR_PATH"
    echo "Fix permissions or run without an argument to auto-create ${OPTIMIZED_APP_PATH##*/}."
    exit 1
  fi
fi

mkdir -p "$WORK"
rm -rf "$ASAR_EXTRACT"
mkdir -p "$ASAR_EXTRACT"

ASAR_CMD="asar"
if ! command -v asar >/dev/null 2>&1; then
  ASAR_TOOLS="$ROOT/work/asar-tools"
  mkdir -p "$ASAR_TOOLS"
  if [[ ! -x "$ASAR_TOOLS/node_modules/.bin/asar" ]]; then
    (cd "$ASAR_TOOLS" && npm init -y >/dev/null && npm i --no-save asar)
  fi
  ASAR_CMD="$ASAR_TOOLS/node_modules/.bin/asar"
fi

"$ASAR_CMD" extract "$ASAR_PATH" "$ASAR_EXTRACT"

if ! python3 - <<PY 2>"$PATCH_LOG"
from pathlib import Path
import re

build_dir = Path("$ASAR_EXTRACT/.vite/build")
def resolve_main_entry(build_path: Path) -> Path:
    markers = (
        "ELECTRON_RENDERER_URL",
        "markAppQuitting",
        "isOpaqueWindowsEnabled",
        "getLiquidGlassSupport",
        "electron-liquid-glass",
    )
    marker_candidates = [
        *sorted(build_path.glob("main-*.js")),
        *sorted(build_path.glob("bootstrap-*.js")),
        *[candidate for candidate in (build_path / "main.js", build_path / "bootstrap.js") if candidate.exists()],
    ]
    for candidate in marker_candidates:
        candidate_text = candidate.read_text()
        if any(marker in candidate_text for marker in markers):
            return candidate

    target = None
    for stub_name in ("main.js", "bootstrap.js"):
        stub = build_path / stub_name
        if stub.exists():
            target = stub
            break
    if target is None:
        raise SystemExit(f"main entry stub not found in {build_path}")

    seen = set()
    while True:
        target_key = str(target)
        if target_key in seen:
            return target
        seen.add(target_key)

        stub_text = target.read_text()
        match = re.search(r'require\(["\']\./((?:main|bootstrap)-[^"\']+\.js)["\']\)', stub_text)
        if not match:
            return target

        candidate = build_path / match.group(1)
        if not candidate.exists():
            raise SystemExit(f"referenced main entry not found: {candidate}")
        target = candidate

target = resolve_main_entry(build_dir)

text = target.read_text()

old_opaque = "isOpaqueWindowsEnabled(t){return this.options.getGlobalStateForHost(t).get(Wv.OPAQUE_WINDOWS)===!0}"
new_opaque = "isOpaqueWindowsEnabled(t){return!0}"
if old_opaque in text:
    text = text.replace(old_opaque, new_opaque, 1)
else:
    text, count = re.subn(
        r"isOpaqueWindowsEnabled\([^)]*\)\{return[^}]+\}",
        "isOpaqueWindowsEnabled(t){return!0}",
        text,
        count=1,
    )
    if count == 0:
        raise SystemExit("unable to patch isOpaqueWindowsEnabled in main bundle")

old_glass = (
    'async getLiquidGlassSupport(){if(this.liquidGlassSupport!=null)return this.liquidGlassSupport;'
    'if(process.platform!=="darwin")return this.liquidGlassSupport=!1,!1;try{const n='
    '(await import("electron-liquid-glass")).default.isGlassSupported?.()??!1;'
    'return this.liquidGlassSupport=n,this.liquidGlassSupport}catch{return this.liquidGlassSupport=!1,!1}}'
)
new_glass = "async getLiquidGlassSupport(){return this.liquidGlassSupport=!1,!1}"
if old_glass in text:
    text = text.replace(old_glass, new_glass, 1)
else:
    text, count = re.subn(
        r'async getLiquidGlassSupport\(\)\{if\(this\.liquidGlassSupport!=null\)return this\.liquidGlassSupport;'
        r'if\(process\.platform!=="darwin"\)return this\.liquidGlassSupport=!1,!1;try\{const [^}]+'
        r'return this\.liquidGlassSupport=n,this\.liquidGlassSupport\}catch\{return this\.liquidGlassSupport=!1,!1\}\}',
        new_glass,
        text,
        count=1,
    )
    if count == 0:
        raise SystemExit("unable to patch getLiquidGlassSupport in main bundle")

text, analytics_count = re.subn(
    r'args:\["app-server","--analytics-default-enabled"\]',
    'args:["app-server"]',
    text,
)
if analytics_count == 0:
    print("app-server analytics patch pattern not found; skipping")

target.write_text(text)
print(f"patched {target}")

assets_dir = Path("$ASAR_EXTRACT/webview/assets")
index_candidates = sorted(assets_dir.glob("index-*.js"))
if not index_candidates:
    raise SystemExit(f"webview index bundle not found in {assets_dir}")

index_target = index_candidates[0]
renderer = index_target.read_text()
original_renderer = renderer

# Disable Shiki provider wrapper to reduce renderer CPU during streaming updates.
marker_start = renderer.find("function W8n(t){")
marker_end = renderer.find("function V8n()", marker_start)
if marker_start != -1 and marker_end != -1:
    renderer = (
        renderer[:marker_start]
        + "function W8n(t){const{children:e}=t;return e}"
        + renderer[marker_end:]
    )

# Disable renderer Sentry init and selected non-essential hooks.
renderer = renderer.replace("I7n();", "", 1)
for old in (
    "h.jsx(P7n,{})",  # telemetry user wiring
    "h.jsx(B8n,{})",  # app-open/app-close analytics event
    "h.jsx(d7n,{})",  # desktop notifications lifecycle
    "h.jsx(t7n,{})",  # badge count updates
    "h.jsx(b7n,{})",  # post-turn diff-comment extraction
):
    renderer = renderer.replace(old, "null", 1)

if renderer == original_renderer:
    print("renderer performance patch patterns not found; skipping")
else:
    index_target.write_text(renderer)
    print(f"patched {index_target}")
PY
then
  echo "Error: power optimization patch failed."
  cat "$PATCH_LOG"
  exit 1
fi

PATCHED_ASAR="$WORK/app.patched.asar"
"$ASAR_CMD" pack "$ASAR_EXTRACT" "$PATCHED_ASAR" --unpack "**/*.node"

BACKUP_PATH="$ASAR_PATH.bak.$(date +%Y%m%d%H%M%S)"
cp "$ASAR_PATH" "$BACKUP_PATH"
cp "$PATCHED_ASAR" "$ASAR_PATH"

echo "Patched low-power visuals in:"
echo "  $APP_PATH"
echo "Backup saved at:"
echo "  $BACKUP_PATH"
