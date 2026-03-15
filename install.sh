#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/work"
OUT="$ROOT/codex-app"
SYSTEM_APPS_DIR="/Applications"
ELECTRON_VERSION="40.0.0"
ELECTRON_ZIP="electron-v${ELECTRON_VERSION}-darwin-x64.zip"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/${ELECTRON_ZIP}"
WORK_APP_PATH=""
OUT_APP_PATH=""
SYSTEM_APP_PATH=""
APP_BUNDLE_NAME=""
APP_DISPLAY_NAME=""
APP_PLIST_NAME=""
APP_BUNDLE_IDENTIFIER=""
APP_VERSION=""
APP_BUILD_VERSION=""
NATIVE_REBUILD_VERBOSE="${NATIVE_REBUILD_VERBOSE:-0}"
SOURCE_INPUT=""
normalize_source_input_path() {
  local input_path="$1"

  if [[ "$input_path" =~ ^https?:// ]]; then
    printf '%s\n' "$input_path"
    return
  fi

  while [[ "$input_path" == */ && "$input_path" != "/" ]]; do
    input_path="${input_path%/}"
  done

  printf '%s\n' "$input_path"
}

usage() {
  cat <<EOF
Usage: $0 [-h|--help] [-v|--verbose] /path/to/Codex*.app
       $0 [-h|--help] [-v|--verbose] /path/to/Codex*.dmg
       $0 [-h|--help] [-v|--verbose] https://.../Codex*.dmg

Options:
  -h, --help      Show this help message and exit.
  -v, --verbose   Enable verbose native rebuild output.
                  (Alternatively, set NATIVE_REBUILD_VERBOSE=1.)
EOF
}

while [[ $# -gt 0 ]]; do
  case "$1" in
    -v|--verbose)
      NATIVE_REBUILD_VERBOSE=1
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --)
      shift
      break
      ;;
    -*)
      echo "Unknown option: $1"
      usage
      exit 1
      ;;
    *)
      if [[ -n "$SOURCE_INPUT" ]]; then
        echo "Error: multiple sources provided."
        usage
        exit 1
      fi
      SOURCE_INPUT="$1"
      shift
      ;;
  esac
done

if [[ -z "$SOURCE_INPUT" && $# -gt 0 ]]; then
  if [[ $# -gt 1 ]]; then
    echo "Error: multiple sources provided."
    usage
    exit 1
  fi
  SOURCE_INPUT="$1"
elif [[ -n "$SOURCE_INPUT" && $# -gt 0 ]]; then
  echo "Error: multiple sources provided."
  usage
  exit 1
fi

if [[ -z "$SOURCE_INPUT" ]]; then
  usage
  exit 1
fi

SOURCE_INPUT="$(normalize_source_input_path "$SOURCE_INPUT")"

mkdir -p "$WORK" "$OUT"
LOG_DIR="$WORK/logs"
mkdir -p "$LOG_DIR"

resolve_x64_codex_cli() {
  local codex_cmd="$1"
  local resolved=""
  # Resolve through npm shims/symlinks so we can inspect the real file on disk.
  if ! resolved="$(python3 - "$codex_cmd" <<'PY'
import os
import sys

print(os.path.realpath(sys.argv[1]))
PY
)"; then
    return 1
  fi

  local candidates=("$resolved")
  # npm launchers are often scripts/symlinks (not always *.js), so always
  # try the vendored x86_64 binary path when we can derive a package root.
  local package_root
  if package_root="$(cd "$(dirname "$resolved")/.." 2>/dev/null && pwd)"; then
    candidates+=("$package_root/vendor/x86_64-apple-darwin/codex/codex")
  fi

  local candidate
  for candidate in "${candidates[@]}"; do
    [[ -f "$candidate" ]] || continue
    # Ensure the bundled binary we copy is executable on Intel hosts.
    if file "$candidate" | grep -q "x86_64"; then
      echo "$candidate"
      return 0
    fi
  done

  return 1
}
SESSION_DIR="$(mktemp -d "$WORK/install.XXXXXX")"

read_plist_key() {
  local plist_path="$1"
  local key="$2"
  /usr/libexec/PlistBuddy -c "Print :$key" "$plist_path" 2>/dev/null || true
}

force_remove_path() {
  local target_path="$1"
  if [[ -e "$target_path" ]]; then
    chmod -R u+w "$target_path" 2>/dev/null || true
    rm -rf "$target_path" 2>/dev/null || return 1
  fi
}

install_to_system_applications() {
  if ! mkdir -p "$SYSTEM_APPS_DIR" 2>/dev/null; then
    echo "Warning: unable to create $SYSTEM_APPS_DIR; leaving app at $OUT_APP_PATH"
    return 1
  fi

  if [[ -e "$SYSTEM_APP_PATH" ]] && ! force_remove_path "$SYSTEM_APP_PATH"; then
    echo "Warning: unable to replace existing app at $SYSTEM_APP_PATH; leaving app at $OUT_APP_PATH"
    return 1
  fi

  if ! cp -R "$OUT_APP_PATH" "$SYSTEM_APP_PATH" 2>/dev/null; then
    force_remove_path "$SYSTEM_APP_PATH" || true
    echo "Warning: unable to copy app to $SYSTEM_APP_PATH; leaving app at $OUT_APP_PATH"
    return 1
  fi

  return 0
}

SOURCE_APP_PATH=""
if [[ "$SOURCE_INPUT" =~ ^https?:// ]]; then
  DMG_PATH="$SESSION_DIR/Codex.dmg"
  echo "Downloading DMG..."
  curl -fL "$SOURCE_INPUT" -o "$DMG_PATH"
elif [[ -d "$SOURCE_INPUT" && "$SOURCE_INPUT" == *.app ]]; then
  SOURCE_APP_PATH="$(cd "$(dirname "$SOURCE_INPUT")" && pwd)/$(basename "$SOURCE_INPUT")"
else
  DMG_PATH="$SESSION_DIR/Codex.dmg"
  cp "$SOURCE_INPUT" "$DMG_PATH"
fi

if [[ -z "$SOURCE_APP_PATH" ]]; then
  # Mount DMG
  ATTACH_PLIST="$SESSION_DIR/attach.plist"
  hdiutil attach "$DMG_PATH" -nobrowse -readonly -plist > "$ATTACH_PLIST"
  MOUNT_POINT="$(python3 - "$ATTACH_PLIST" <<'PY'
import plistlib
import sys

with open(sys.argv[1], "rb") as fh:
    data = plistlib.load(fh)

for entity in data.get("system-entities", []):
    mount_point = entity.get("mount-point")
    if mount_point:
        print(mount_point)
        break
else:
    raise SystemExit("unable to determine DMG mount point")
PY
)"

  SOURCE_APP_PATH="$(find "$MOUNT_POINT" -maxdepth 1 -type d -name '*.app' -print | sort | head -n 1)"
  if [[ -z "$SOURCE_APP_PATH" ]]; then
    hdiutil detach "$MOUNT_POINT" || true
    echo "Error: no .app bundle found at $MOUNT_POINT"
    exit 1
  fi
fi

APP_BUNDLE_NAME="$(basename "$SOURCE_APP_PATH")"
WORK_APP_PATH="$SESSION_DIR/$APP_BUNDLE_NAME"
OUT_APP_PATH="$OUT/$APP_BUNDLE_NAME"
SYSTEM_APP_PATH="$SYSTEM_APPS_DIR/$APP_BUNDLE_NAME"

force_remove_path "$WORK_APP_PATH"
cp -R "$SOURCE_APP_PATH" "$WORK_APP_PATH"
chmod -R u+w "$WORK_APP_PATH"
if [[ -n "${MOUNT_POINT:-}" ]]; then
  hdiutil detach "$MOUNT_POINT"
fi

SOURCE_INFO_PLIST="$WORK_APP_PATH/Contents/Info.plist"
APP_DISPLAY_NAME="$(read_plist_key "$SOURCE_INFO_PLIST" "CFBundleDisplayName")"
APP_PLIST_NAME="$(read_plist_key "$SOURCE_INFO_PLIST" "CFBundleName")"
APP_BUNDLE_IDENTIFIER="$(read_plist_key "$SOURCE_INFO_PLIST" "CFBundleIdentifier")"
APP_VERSION="$(read_plist_key "$SOURCE_INFO_PLIST" "CFBundleShortVersionString")"
APP_BUILD_VERSION="$(read_plist_key "$SOURCE_INFO_PLIST" "CFBundleVersion")"

if [[ -z "$APP_DISPLAY_NAME" ]]; then
  APP_DISPLAY_NAME="${APP_BUNDLE_NAME%.app}"
fi
if [[ -z "$APP_PLIST_NAME" ]]; then
  APP_PLIST_NAME="$APP_DISPLAY_NAME"
fi

# Extract app.asar
ASAR_EXTRACT="$SESSION_DIR/app-extract"
force_remove_path "$ASAR_EXTRACT"
mkdir -p "$ASAR_EXTRACT"

ASAR_CMD="asar"
if ! command -v asar >/dev/null 2>&1; then
  ASAR_TOOLS="$WORK/asar-tools"
  mkdir -p "$ASAR_TOOLS"
  if [[ ! -x "$ASAR_TOOLS/node_modules/.bin/asar" ]]; then
    (cd "$ASAR_TOOLS" && npm init -y >/dev/null && npm i --no-save asar)
  fi
  ASAR_CMD="$ASAR_TOOLS/node_modules/.bin/asar"
fi

"$ASAR_CMD" extract "$WORK_APP_PATH/Contents/Resources/app.asar" "$ASAR_EXTRACT"

# Patch main entry:
# 1) avoid accidental dev-server loading in packaged mode
# 2) guard markAppQuitting access
# 3) force low-power window effects for Intel Macs (opaque windows, no liquid-glass)
PATCH_LOG="$SESSION_DIR/patch-main.log"
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

def patch_dev_server_guard(src: str) -> str:
    fn = None
    m = re.search(r'function (\\w+)\\(\\)\\{return process\\.env\\.ELECTRON_RENDERER_URL\\|\\|\\w+\\}', src)
    if m:
        fn = m.group(1)
    patterns = []
    if fn:
        patterns.extend([fr'new URL\\({fn}\\(\\)\\)', fr'new URL\\({fn}\\)'])
    patterns.extend([r'new URL\\(_B\\(\\)\\)', r'new URL\\(_B\\)'])
    for pat in patterns:
        m2 = re.search(pat, src)
        if not m2:
            continue
        window_start = max(0, m2.start() - 400)
        window_end = min(len(src), m2.end() + 400)
        window = src[window_start:window_end]
        guard_matches = list(re.finditer(r'!([A-Za-z_$][\\w$]*)\\.app\\.isPackaged', window))
        if not guard_matches:
            continue
        mguard = guard_matches[-1]
        var = mguard.group(1)
        abs_idx = window_start + mguard.start()
        needle = f'!{var}.app.isPackaged'
        replacement = f'!{var}.app.isPackaged&&process.env.ELECTRON_RENDERER_URL'
        if src[abs_idx:abs_idx+len(replacement)] == replacement:
            return src
        return src[:abs_idx] + replacement + src[abs_idx+len(needle):]
    raise SystemExit("patch pattern1 not found in main entry")

text = patch_dev_server_guard(text)

pattern2a = r'if\\(yl\\)\\{([A-Za-z_$][\\w$]*)\\.markAppQuitting\\(\\);return\\}'
m2 = re.search(pattern2a, text)
if m2:
    var = m2.group(1)
    old = m2.group(0)
    new = f'if(yl){{typeof {var}==\"undefined\"||{var}.markAppQuitting();return}}'
    text = text.replace(old, new, 1)
else:
    print("patch pattern2a not found; skipping")

pattern2b = r'yl=!0,([A-Za-z_$][\\w$]*)\\.markAppQuitting\\(\\)'
m3 = re.search(pattern2b, text)
if m3:
    var = m3.group(1)
    old = m3.group(0)
    new = f'yl=!0,typeof {var}==\"undefined\"||{var}.markAppQuitting()'
    text = text.replace(old, new, 1)
else:
    print("patch pattern2b not found; skipping")

def patch_low_power_visual_effects(src: str) -> str:
    updated = src

    old_opaque = "isOpaqueWindowsEnabled(t){return this.options.getGlobalStateForHost(t).get(Wv.OPAQUE_WINDOWS)===!0}"
    new_opaque = "isOpaqueWindowsEnabled(t){return!0}"
    if old_opaque in updated:
        updated = updated.replace(old_opaque, new_opaque, 1)
    else:
        updated = re.sub(
            r"isOpaqueWindowsEnabled\([^)]*\)\{return[^}]+\}",
            "isOpaqueWindowsEnabled(t){return!0}",
            updated,
            count=1,
        )

    old_glass = (
        'async getLiquidGlassSupport(){if(this.liquidGlassSupport!=null)return this.liquidGlassSupport;'
        'if(process.platform!=="darwin")return this.liquidGlassSupport=!1,!1;try{const n='
        '(await import("electron-liquid-glass")).default.isGlassSupported?.()??!1;'
        'return this.liquidGlassSupport=n,this.liquidGlassSupport}catch{return this.liquidGlassSupport=!1,!1}}'
    )
    new_glass = "async getLiquidGlassSupport(){return this.liquidGlassSupport=!1,!1}"
    if old_glass in updated:
        updated = updated.replace(old_glass, new_glass, 1)
    else:
        updated = re.sub(
            r'async getLiquidGlassSupport\(\)\{if\(this\.liquidGlassSupport!=null\)return this\.liquidGlassSupport;'
            r'if\(process\.platform!=="darwin"\)return this\.liquidGlassSupport=!1,!1;try\{const [^}]+'
            r'return this\.liquidGlassSupport=n,this\.liquidGlassSupport\}catch\{return this\.liquidGlassSupport=!1,!1\}\}',
            new_glass,
            updated,
            count=1,
        )

    if updated == src:
        print("low-power patch patterns not found; skipping")
    return updated

text = patch_low_power_visual_effects(text)

def patch_app_server_analytics_default(src: str) -> str:
    updated, count = re.subn(
        r'args:\["app-server","--analytics-default-enabled"\]',
        'args:["app-server"]',
        src,
    )
    if count == 0:
        print("app-server analytics patch pattern not found; skipping")
    return updated

text = patch_app_server_analytics_default(text)

target.write_text(text)
print(f"patched {target}")

assets_dir = Path("$ASAR_EXTRACT/webview/assets")
index_candidates = sorted(assets_dir.glob("index-*.js"))
if not index_candidates:
    raise SystemExit(f"webview index bundle not found in {assets_dir}")

index_target = index_candidates[0]
renderer = index_target.read_text()
original_renderer = renderer

def patch_renderer_performance(src: str) -> str:
    out = src

    # Disable Shiki provider wrapper to reduce renderer CPU during streaming updates.
    marker_start = out.find("function W8n(t){")
    marker_end = out.find("function V8n()", marker_start)
    if marker_start != -1 and marker_end != -1:
        out = out[:marker_start] + "function W8n(t){const{children:e}=t;return e}" + out[marker_end:]

    # Disable renderer Sentry init and selected non-essential hooks.
    out = out.replace("I7n();", "", 1)
    for old in (
        "h.jsx(P7n,{})",  # telemetry user wiring
        "h.jsx(B8n,{})",  # app-open/app-close analytics event
        "h.jsx(d7n,{})",  # desktop notifications lifecycle
        "h.jsx(t7n,{})",  # badge count updates
        "h.jsx(b7n,{})",  # post-turn diff-comment extraction
    ):
        out = out.replace(old, "null", 1)

    return out

renderer = patch_renderer_performance(renderer)
if renderer == original_renderer:
    print("renderer performance patch patterns not found; skipping")
else:
    index_target.write_text(renderer)
    print(f"patched {index_target}")
PY
then
  echo "Error: automatic patching failed for this Codex build."
  if command -v codex >/dev/null 2>&1; then
    cat <<EOF
Fallback: use Codex CLI to adapt install.sh patch logic for this specific Codex build, then rerun.

Run:
codex exec -C "$ROOT" --sandbox workspace-write 'Update install.sh patch logic so it still patches the current .vite/build main entry from this DMG. Keep behavior the same except:
1) only attempt dev-server URL logic when process.env.ELECTRON_RENDERER_URL is set
2) guard any markAppQuitting() call with a typeof/object existence check.
3) force low-power visuals by making isOpaqueWindowsEnabled() return true and getLiquidGlassSupport() return false.
Do not change unrelated installer behavior.'

Then rerun:
./install.sh "$SOURCE_INPUT"
EOF
  else
    echo "Install Codex CLI for guided fallback patching: npm i -g @openai/codex"
  fi
  echo "Patch error details:"
  cat "$PATCH_LOG"
  exit 1
fi

# Rebuild native modules for Electron x64
REBUILD="$SESSION_DIR/rebuild"
force_remove_path "$REBUILD"
mkdir -p "$REBUILD"
cd "$REBUILD"
unset npm_config_runtime npm_config_target npm_config_arch npm_config_disturl
npm init -y >/dev/null
npm i --no-save better-sqlite3@12.4.6 node-pty@1.1.0 node-gyp@12.2.0
NODE_GYP="$REBUILD/node_modules/.bin/node-gyp"

# Set SDK flags when available; some setups need explicit SDK include paths.
if command -v xcrun >/dev/null 2>&1; then
  if SDK_PATH="$(xcrun --show-sdk-path 2>/dev/null)"; then
    if [[ -n "$SDK_PATH" && -d "$SDK_PATH" ]]; then
      export SDKROOT="$SDK_PATH"
      export CXXFLAGS="${CXXFLAGS:-} -isysroot \"$SDK_PATH\" -I\"$SDK_PATH\"/usr/include/c++/v1 -I\"$SDK_PATH\"/usr/include"
      export LDFLAGS="${LDFLAGS:-} -isysroot \"$SDK_PATH\""
    else
      echo "Warning: xcrun returned an empty or invalid SDK path ('$SDK_PATH'); continuing without explicit SDK flags."
    fi
  else
    echo "Warning: xcrun is installed but failed to resolve SDK path; continuing without explicit SDK flags."
  fi
else
  echo "Warning: xcrun not found; continuing without explicit SDK flags."
fi

run_native_rebuild() {
  local module="$1"
  local log_file="$LOG_DIR/rebuild-${module}.log"
  _run_node_gyp_rebuild() {
    (
      cd "$REBUILD/node_modules/$module"
      "$NODE_GYP" rebuild --release --runtime=electron --target="$ELECTRON_VERSION" --arch=x64 --dist-url=https://electronjs.org/headers
    )
  }

  echo "Rebuilding $module for Electron x64..."
  echo "Note: compiler warnings from upstream native modules are expected and non-fatal."
  if [[ "$NATIVE_REBUILD_VERBOSE" == "1" ]]; then
    echo "Verbose native rebuild enabled (-v/--verbose or NATIVE_REBUILD_VERBOSE=1)."
  else
    echo "Streaming disabled; full output is written to $log_file."
  fi

  local rebuild_rc=0
  if [[ "$NATIVE_REBUILD_VERBOSE" == "1" ]]; then
    _run_node_gyp_rebuild 2>&1 | tee "$log_file" || rebuild_rc=$?
  else
    _run_node_gyp_rebuild >"$log_file" 2>&1 || rebuild_rc=$?
  fi

  if [[ "$rebuild_rc" -ne 0 ]]; then
    echo "Error: rebuild failed for $module."
    echo "Full log: $log_file"
    echo "Tip: rerun with -v/--verbose (or NATIVE_REBUILD_VERBOSE=1) to stream build output live."
    exit 1
  fi

  local warning_count
  warning_count="$(grep -c ' warning:' "$log_file" || true)"
  if [[ "$warning_count" -gt 0 ]]; then
    echo "Rebuild OK: $module ($warning_count warning line(s)). Log: $log_file"
  else
    echo "Rebuild OK: $module (no compiler warnings). Log: $log_file"
  fi
}

run_native_rebuild "better-sqlite3"
run_native_rebuild "node-pty"

# Inject rebuilt modules into asar extract
mkdir -p "$ASAR_EXTRACT/node_modules/better-sqlite3/build/Release"
mkdir -p "$ASAR_EXTRACT/node_modules/node-pty/build/Release"
mkdir -p "$ASAR_EXTRACT/node_modules/node-pty/bin/darwin-x64-143"

cp "$REBUILD/node_modules/better-sqlite3/build/Release/better_sqlite3.node" \
   "$ASAR_EXTRACT/node_modules/better-sqlite3/build/Release/better_sqlite3.node"

cp "$REBUILD/node_modules/node-pty/build/Release/pty.node" \
   "$ASAR_EXTRACT/node_modules/node-pty/build/Release/pty.node"

cp "$REBUILD/node_modules/node-pty/build/Release/pty.node" \
   "$ASAR_EXTRACT/node_modules/node-pty/bin/darwin-x64-143/node-pty.node"

# Disable sparkle
truncate -s 0 "$ASAR_EXTRACT/native/sparkle.node" || true

# Pack asar (unpack native .node files)
cd "$ROOT"
"$ASAR_CMD" pack "$ASAR_EXTRACT" "$WORK_APP_PATH/Contents/Resources/app.asar" --unpack "**/*.node"

# Prepare Electron x64 bundle
ELECTRON_DIR="$SESSION_DIR/electron"
force_remove_path "$ELECTRON_DIR"
mkdir -p "$ELECTRON_DIR"
cd "$ELECTRON_DIR"
curl -fL "$ELECTRON_URL" -o electron.zip
unzip -q electron.zip

# Build final app
force_remove_path "$OUT_APP_PATH"
cp -R "$ELECTRON_DIR/Electron.app" "$OUT_APP_PATH"

# Replace resources
cp "$WORK_APP_PATH/Contents/Resources/app.asar" "$OUT_APP_PATH/Contents/Resources/app.asar"
cp -R "$WORK_APP_PATH/Contents/Resources/app.asar.unpacked" "$OUT_APP_PATH/Contents/Resources/"
cp -R "$WORK_APP_PATH/Contents/Resources/native" "$OUT_APP_PATH/Contents/Resources/"

# Copy Codex CLI (optional)
CODEX_CMD="$(type -P codex 2>/dev/null || true)"
if [[ -n "$CODEX_CMD" && -x "$CODEX_CMD" ]]; then
  # Resolve to a concrete x86_64 binary when PATH points to a launcher script.
  if CODEX_BIN="$(resolve_x64_codex_cli "$CODEX_CMD")"; then
    if ! install -m 755 "$CODEX_BIN" "$OUT_APP_PATH/Contents/Resources/codex"; then
      echo "Warning: failed to copy x86_64 Codex CLI into app bundle from $CODEX_BIN (continuing)."
    fi
  else
    echo "Warning: found codex at $CODEX_CMD but could not resolve an x86_64 binary; leaving bundled CLI unchanged."
  fi
else
  echo "Warning: codex not found in PATH; leaving bundled CLI unchanged."
fi

# Icon + Info.plist
cp "$WORK_APP_PATH/Contents/Resources/electron.icns" "$OUT_APP_PATH/Contents/Resources/electron.icns"
plutil -replace CFBundleDisplayName -string "$APP_DISPLAY_NAME" "$OUT_APP_PATH/Contents/Info.plist"
plutil -replace CFBundleName -string "$APP_PLIST_NAME" "$OUT_APP_PATH/Contents/Info.plist"
if [[ -n "$APP_BUNDLE_IDENTIFIER" ]]; then
  plutil -replace CFBundleIdentifier -string "$APP_BUNDLE_IDENTIFIER" "$OUT_APP_PATH/Contents/Info.plist"
fi
if [[ -n "$APP_VERSION" ]]; then
  plutil -replace CFBundleShortVersionString -string "$APP_VERSION" "$OUT_APP_PATH/Contents/Info.plist"
fi
if [[ -n "$APP_BUILD_VERSION" ]]; then
  plutil -replace CFBundleVersion -string "$APP_BUILD_VERSION" "$OUT_APP_PATH/Contents/Info.plist"
fi

# Install to /Applications when permitted.
if install_to_system_applications; then
  echo "Done: $SYSTEM_APP_PATH"
else
  echo "Done: $OUT_APP_PATH"
fi
