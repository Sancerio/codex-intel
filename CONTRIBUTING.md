# Contributing

Thanks for helping improve the Intel macOS port!

## Scope

This repo provides a **local installer** that converts the official Codex DMG into an Intel‑compatible Electron bundle. We do **not** distribute OpenAI binaries.

## Good issues/PRs

- Installer reliability improvements
- Better logging and error messages
- Safer cleanup
- Documentation fixes
- Compatibility notes for different macOS versions

## Development

- Run `./install.sh /path/to/Codex.dmg` on an Intel Mac
- Test by launching `./codex-app/Codex.app/Contents/MacOS/Electron --no-sandbox`

## Legal

Do not commit or upload the DMG or built `Codex.app` into this repository.
