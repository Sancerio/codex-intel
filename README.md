# Codex Desktop (Intel macOS)

![GitHub repo size](https://img.shields.io/github/repo-size/Sancerio/codex-intel)
![GitHub stars](https://img.shields.io/github/stars/Sancerio/codex-intel?style=flat)
![GitHub license](https://img.shields.io/github/license/Sancerio/codex-intel)

Run OpenAI Codex Desktop on Intel macOS by converting the official macOS app bundle or DMG into an x86_64 Electron app bundle. Stable and Beta builds are both supported.

> This is an unofficial community project. Codex Desktop is a product of OpenAI.

Learn more about Codex: https://openai.com/codex/

## What this does

The installer:

1. Takes a local `.app` bundle or extracts the macOS `.dmg`
2. Pulls out `app.asar` (the Electron app)
3. Rebuilds native modules (`node-pty`, `better-sqlite3`) for Electron x64
4. Disables macOS‑only Sparkle auto‑update
5. Downloads Electron v40 for darwin‑x64
6. Repackages everything into a runnable app bundle with the same name as the original DMG app, such as `Codex.app` or `Codex (Beta).app`
7. Applies a small patch so it doesn’t try to connect to a Vite dev server

## Prerequisites

- Intel Mac (x86_64)
- Node.js 20+ and npm
- Python 3
- Xcode Command Line Tools (`xcode-select --install`)
- Homebrew (for `p7zip` and `curl`)

Install dependencies:

```bash
brew install p7zip curl
```

You also need the Codex CLI installed:

```bash
npm i -g @openai/codex
```

## Installation

### Option A: Provide your own app bundle or DMG

```bash
git clone https://github.com/<your-user>/codex-intel.git
cd codex-intel
chmod +x install.sh
./install.sh /path/to/Codex*.app
```

Or:

```bash
./install.sh /path/to/Codex*.dmg
```

Verbose native rebuild output:

```bash
./install.sh -v /path/to/Codex.dmg
```

### Option B: Auto‑download DMG

If you have the DMG URL, you can pass it directly:

```bash
./install.sh https://example.com/Codex*.dmg
```

### Option C: Use the current Beta app bundle zip

The current Beta desktop build is available here:

[Codex (Beta) darwin-arm64 26.311.30926](https://persistent.oaistatic.com/codex-app-beta/Codex%20(Beta)-darwin-arm64-26.311.30926.zip)

Because this download is a `.zip` containing `Codex (Beta).app`, unzip it first, then point `install.sh` at the extracted app bundle:

```bash
unzip 'Codex (Beta)-darwin-arm64-26.311.30926.zip'
./install.sh './Codex (Beta).app'
```

## Usage

The installer creates:

```
./codex-app/<original app name>.app
```

Launch it from Finder or:

```bash
./codex-app/Codex.app/Contents/MacOS/Electron --no-sandbox
```

For Beta builds, that path is typically:

```bash
./codex-app/Codex\ \(Beta\).app/Contents/MacOS/Electron --no-sandbox
```

Or use the helper script:

```bash
./start.sh
```

## Performance (Intel Fan Noise / Idle Heat)

This repo now applies a low-power window patch during `install.sh`:

- forces opaque windows
- disables liquid-glass effects
- applies an aggressive renderer performance patch:
  - disables renderer Sentry init
  - bypasses Shiki highlight provider wrapper
  - disables non-essential telemetry/notification hooks

This reduces idle GPU load on many Intel Macs.

Tradeoffs in aggressive mode:

- desktop notifications/badge updates may be reduced
- some telemetry diagnostics are disabled
- code highlighting behavior may be simpler in chat output

If you already built an app in `codex-app/`, patch it in place without reinstalling:

```bash
./optimize-power.sh
```

Optional custom app path:

```bash
./optimize-power.sh /path/to/Codex*.app
```

`./start.sh` launches the newest app bundle under `codex-app/`, so a fresh Beta install will be picked automatically even if older stable bundles are still present.

## Notes

- Auto‑update is disabled (Sparkle is macOS‑only and removed).
- The app may show warnings about `url.parse` deprecation — safe to ignore.
- The app expects the Codex CLI on your PATH. If you installed it globally, that’s already done.
- During native rebuild, upstream modules can emit compiler warnings; this is expected as long as rebuild finishes with `Rebuild OK`.
- Native rebuild output is saved under `work/logs/` by default (for example `work/logs/rebuild-better-sqlite3.log`).
- To stream full native rebuild output live, run with `./install.sh -v ...` (or set `NATIVE_REBUILD_VERBOSE=1`).

## Troubleshooting

**App opens a blank window**
- Make sure the patch applied (installer output should say “patched main.js”).
- If patching fails with a pattern error, use the Codex CLI fallback shown by `install.sh` to update patch logic in `install.sh`, then rerun the installer.

**Native module load error**
- Delete `codex-app/` and rerun `install.sh`.

**Compiler warnings during install**
- Warnings from `better-sqlite3` and `node-pty` can be normal with newer toolchains.
- Treat the run as successful if installer output shows `Rebuild OK: better-sqlite3` and `Rebuild OK: node-pty`.
- If rebuild fails, inspect `work/logs/rebuild-*.log`.

**Gatekeeper warning**
- Right‑click the app → Open (once) to allow it.

## Disclaimer

This project does not distribute OpenAI software. It automates the same conversion steps a user would perform locally using their own DMG.

## License

MIT
