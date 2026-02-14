# Contributing

Thanks for helping improve `codex-intel` - the Intel macOS port of [Codex App](https://openai.com/codex/).

## Scope

This repo provides a local installer that converts an official Codex DMG into an Intel-compatible Electron app bundle.  
We do not distribute OpenAI DMGs or app binaries in this repository.

## What To Contribute

- Installer reliability improvements
- Better diagnostics and failure messages
- Safer patching/fallback behavior
- Documentation and troubleshooting updates
- Compatibility notes for macOS/Intel toolchains

## Development

- Run `./install.sh /path/to/Codex.dmg` on Intel macOS.
- Validate by launching `./codex-app/Codex.app/Contents/MacOS/Electron --no-sandbox`.
- Keep changes focused and easy to review.

## Issue Labels And Triage

Core issue labels used by maintainers:

- `needs-triage`: Issue needs maintainer classification.
- `bug`: Confirmed malfunction report.
- `question`: Clarification/support request.
- `help wanted`: Maintainer welcomes external help.
- `good first issue`: Good starter task for new contributors.
- `awaiting-reply`: Waiting on reporter follow-up.
- `stale`: No follow-up activity after waiting period.
- `confirmed-bug`: Reproduced/confirmed by maintainer.
- `security`: Security-sensitive issue.
- `pinned`: Maintainer-pinned priority/context issue.

`bug`, `question`, `help wanted`, and `good first issue` are GitHub defaults; the label bootstrap workflow also ensures they exist for repos/forks where defaults were renamed or removed.

## Stale Policy

- Issues labeled `awaiting-reply` are marked `stale` after 7 days with no update.
- `stale` issues are closed after 14 additional days with no update.
- A reporter can comment to continue discussion; maintainers can reopen as needed.

## Automation

Repository workflows implement this policy:

- `.github/workflows/stale-issues.yml`:
  - Applies stale/close policy for `awaiting-reply` issues.
- `.github/workflows/issue-comment-triage.yml`:
  - On non-maintainer issue comments, removes `awaiting-reply`/`stale`.
  - Adds `needs-triage` only if the issue has no existing non-transient triage label.
- `.github/workflows/ensure-issue-labels.yml`:
  - Manual (`workflow_dispatch`) label bootstrap for forks/new repos.

## PR Expectations

- Explain why the change is needed and what behavior changed.
- Include validation steps/output when possible.
- Keep commits and PR scope tight.
- Use Conventional Commits style for commit messages (for example: `fix(installer): guard SDK path detection`).
- Do not include built artifacts, DMGs, or `Codex.app` outputs.
