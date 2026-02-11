#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK="$ROOT/work"
OUT="$ROOT/codex-app"
ELECTRON_VERSION="40.0.0"
ELECTRON_ZIP="electron-v${ELECTRON_VERSION}-darwin-x64.zip"
ELECTRON_URL="https://github.com/electron/electron/releases/download/v${ELECTRON_VERSION}/${ELECTRON_ZIP}"

DMG_SRC="${1:-}"
if [[ -z "$DMG_SRC" ]]; then
  echo "Usage: $0 /path/to/Codex.dmg OR $0 https://.../Codex.dmg"
  exit 1
fi

mkdir -p "$WORK" "$OUT"

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

# Fetch DMG
DMG_PATH="$WORK/Codex.dmg"
if [[ "$DMG_SRC" =~ ^https?:// ]]; then
  echo "Downloading DMG..."
  curl -fL "$DMG_SRC" -o "$DMG_PATH"
else
  cp "$DMG_SRC" "$DMG_PATH"
fi

# Mount DMG
MOUNT_POINT="/Volumes/Codex Installer"
if mount | grep -q "${MOUNT_POINT}"; then
  hdiutil detach "$MOUNT_POINT" || true
fi
hdiutil attach "$DMG_PATH" -nobrowse -readonly

# Copy app bundle
cp -R "$MOUNT_POINT/Codex.app" "$WORK/Codex.app"
chmod -R u+w "$WORK/Codex.app"
hdiutil detach "$MOUNT_POINT"

# Extract app.asar
ASAR_EXTRACT="$WORK/app-extract"
rm -rf "$ASAR_EXTRACT"
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

"$ASAR_CMD" extract "$WORK/Codex.app/Contents/Resources/app.asar" "$ASAR_EXTRACT"

# Patch main entry (avoid dev server; guard markAppQuitting)
PATCH_LOG="$WORK/patch-main.log"
if ! python3 - <<PY 2>"$PATCH_LOG"
from pathlib import Path
import re

build_dir = Path("$ASAR_EXTRACT/.vite/build")
main_stub = build_dir / "main.js"
if not main_stub.exists():
    raise SystemExit(f"main.js not found at {main_stub}")

target = main_stub
stub_text = main_stub.read_text()
match = re.search(r'require\(["\']\./(main-[^"\']+\.js)["\']\)', stub_text)
if match:
    candidate = build_dir / match.group(1)
    if not candidate.exists():
        raise SystemExit(f"referenced main entry not found: {candidate}")
    target = candidate

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

target.write_text(text)
print(f"patched {target}")
PY
then
  echo "Error: automatic patching failed for this Codex build."
  if command -v codex >/dev/null 2>&1; then
    cat <<EOF
Fallback: use Codex CLI to adapt install.sh patch logic for this specific DMG build, then rerun.

Run:
codex exec -C "$ROOT" --sandbox workspace-write 'Update install.sh patch logic so it still patches the current .vite/build main entry from this DMG. Keep behavior the same except:
1) only attempt dev-server URL logic when process.env.ELECTRON_RENDERER_URL is set
2) guard any markAppQuitting() call with a typeof/object existence check.
Do not change unrelated installer behavior.'

Then rerun:
./install.sh "$DMG_SRC"
EOF
  else
    echo "Install Codex CLI for guided fallback patching: npm i -g @openai/codex"
  fi
  echo "Patch error details:"
  cat "$PATCH_LOG"
  exit 1
fi

# Rebuild native modules for Electron x64
REBUILD="$WORK/rebuild"
rm -rf "$REBUILD"
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

# better-sqlite3 (Electron)
cd "$REBUILD/node_modules/better-sqlite3"
"$NODE_GYP" rebuild --release --runtime=electron --target="$ELECTRON_VERSION" --arch=x64 --dist-url=https://electronjs.org/headers

# node-pty (Electron)
cd "$REBUILD/node_modules/node-pty"
"$NODE_GYP" rebuild --release --runtime=electron --target="$ELECTRON_VERSION" --arch=x64 --dist-url=https://electronjs.org/headers

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
"$ASAR_CMD" pack "$ASAR_EXTRACT" "$WORK/Codex.app/Contents/Resources/app.asar" --unpack "**/*.node"

# Prepare Electron x64 bundle
ELECTRON_DIR="$WORK/electron"
rm -rf "$ELECTRON_DIR"
mkdir -p "$ELECTRON_DIR"
cd "$ELECTRON_DIR"
curl -fL "$ELECTRON_URL" -o electron.zip
unzip -q electron.zip

# Build final app
rm -rf "$OUT/Codex.app"
cp -R "$ELECTRON_DIR/Electron.app" "$OUT/Codex.app"

# Replace resources
cp "$WORK/Codex.app/Contents/Resources/app.asar" "$OUT/Codex.app/Contents/Resources/app.asar"
cp -R "$WORK/Codex.app/Contents/Resources/app.asar.unpacked" "$OUT/Codex.app/Contents/Resources/"
cp -R "$WORK/Codex.app/Contents/Resources/native" "$OUT/Codex.app/Contents/Resources/"

# Copy Codex CLI (optional)
CODEX_CMD="$(type -P codex 2>/dev/null || true)"
if [[ -n "$CODEX_CMD" && -x "$CODEX_CMD" ]]; then
  # Resolve to a concrete x86_64 binary when PATH points to a launcher script.
  if CODEX_BIN="$(resolve_x64_codex_cli "$CODEX_CMD")"; then
    if ! install -m 755 "$CODEX_BIN" "$OUT/Codex.app/Contents/Resources/codex"; then
      echo "Warning: failed to copy x86_64 Codex CLI into app bundle from $CODEX_BIN (continuing)."
    fi
  else
    echo "Warning: found codex at $CODEX_CMD but could not resolve an x86_64 binary; leaving bundled CLI unchanged."
  fi
else
  echo "Warning: codex not found in PATH; leaving bundled CLI unchanged."
fi

# Icon + Info.plist
cp "$WORK/Codex.app/Contents/Resources/electron.icns" "$OUT/Codex.app/Contents/Resources/electron.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Codex" -c "Set :CFBundleName Codex" "$OUT/Codex.app/Contents/Info.plist"

echo "Done: $OUT/Codex.app"
