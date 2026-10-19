# Roadmap

Working notes for what comes after v1. Ordering is by what hurts a real session first, not by size.

## Done

- **Patch-style multi-file edits.** `apply_patch` reviews one `*** Begin Patch` block as a single approval card, with per-file apply/reject and the existing recovery-snapshot and Undo path.

## Next

1. **Durable changes.** Per-conversation change lists and Undo are session-only; persist them so quitting the app does not lose recovery. Add conversation search and rename.
2. **Open in external editor / Reveal in Finder** from the file tree. Cheapest quality-of-life win in the app.

## Workflow

- **Plan mode + todo tool.** Read-only first pass, then execute against a checklist shown in the inspector. Pairs with context management.
- **Guarded Git write actions.** Branch, commit, push, and open a PR via `gh` when present; never force-push.
- **Custom commands.** Markdown files in `~/.lumen/commands` exposed as slash commands, reusing the instructions loader.
- **Parallel read-only tools.** Reads are independent and can run together; edits stay serial behind approvals.
- **Session state restore.** Reopen to the same project, conversation, inspector tab, and scroll position.

## Release and trust

- **Sparkle auto-update** (deferred from v1 in AGENTS.md) with a signed appcast wired into `release.sh`.
- **Performance guardrails in CI** for the idle-memory and cold-launch targets.
- **Hardening pass.** Fuzz the path validator, test command-denylist bypasses, audit Keychain and logging.

## Deliberately later

- Multiple windows/projects at once (today `ChatModel` is a single app-wide state object; this is an architecture change).
- Per-hunk approval granularity.
- Crash reporting.
