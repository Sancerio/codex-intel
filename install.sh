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

# Fetch DMG
DMG_PATH="$WORK/Codex.dmg"
if [[ "$DMG_SRC" =~ ^https?:// ]]; then
  echo "Downloading DMG..."
  curl -L "$DMG_SRC" -o "$DMG_PATH"
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
hdiutil detach "$MOUNT_POINT"

# Extract app.asar
ASAR_EXTRACT="$WORK/app-extract"
rm -rf "$ASAR_EXTRACT"
mkdir -p "$ASAR_EXTRACT"

if ! command -v asar >/dev/null 2>&1; then
  npm i -g asar
fi

asar extract "$WORK/Codex.app/Contents/Resources/app.asar" "$ASAR_EXTRACT"

# Patch main.js (avoid dev server + zt init guard)
python3 - <<PY
from pathlib import Path
path = Path("$ASAR_EXTRACT/.vite/build/main.js")
if not path.exists():
    raise SystemExit(f"main.js not found at {path}")
text = path.read_text()
text = text.replace('!F.app.isPackaged){const G=new URL(dB());', '!F.app.isPackaged&&process.env.ELECTRON_RENDERER_URL){const G=new URL(dB());', 1)
text = text.replace('El=!0,zt.markAppQuitting()});', 'El=!0,typeof zt==\"undefined\"||zt.markAppQuitting()});', 1)
path.write_text(text)
print("patched main.js")
PY

# Rebuild native modules for Electron x64
REBUILD="$WORK/rebuild"
rm -rf "$REBUILD"
mkdir -p "$REBUILD"
cd "$REBUILD"
npm init -y >/dev/null
npm i --no-save better-sqlite3@12.4.6 node-pty@1.1.0

# better-sqlite3 (Electron)
export npm_config_runtime=electron
export npm_config_target="$ELECTRON_VERSION"
export npm_config_arch=x64
export npm_config_disturl=https://electronjs.org/headers
npm rebuild better-sqlite3 || true

# node-pty (Electron)
cd "$REBUILD/node_modules/node-pty"
npx node-gyp rebuild --release --runtime=electron --target="$ELECTRON_VERSION" --arch=x64 --dist-url=https://electronjs.org/headers

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
asar pack "$ASAR_EXTRACT" "$WORK/Codex.app/Contents/Resources/app.asar" --unpack "**/*.node"

# Prepare Electron x64 bundle
ELECTRON_DIR="$WORK/electron"
rm -rf "$ELECTRON_DIR"
mkdir -p "$ELECTRON_DIR"
cd "$ELECTRON_DIR"
curl -L "$ELECTRON_URL" -o electron.zip
unzip -q electron.zip

# Build final app
rm -rf "$OUT/Codex.app"
cp -R "$ELECTRON_DIR/Electron.app" "$OUT/Codex.app"

# Replace resources
cp "$WORK/Codex.app/Contents/Resources/app.asar" "$OUT/Codex.app/Contents/Resources/app.asar"
cp -R "$WORK/Codex.app/Contents/Resources/app.asar.unpacked" "$OUT/Codex.app/Contents/Resources/"
cp -R "$WORK/Codex.app/Contents/Resources/native" "$OUT/Codex.app/Contents/Resources/"

# Copy Codex CLI (optional)
if command -v codex >/dev/null 2>&1; then
  cp "$(command -v codex)" "$OUT/Codex.app/Contents/Resources/codex"
fi

# Icon + Info.plist
cp "$WORK/Codex.app/Contents/Resources/electron.icns" "$OUT/Codex.app/Contents/Resources/electron.icns"
/usr/libexec/PlistBuddy -c "Set :CFBundleDisplayName Codex" -c "Set :CFBundleName Codex" "$OUT/Codex.app/Contents/Info.plist"

echo "Done: $OUT/Codex.app"
