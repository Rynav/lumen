# Roadmap

Working notes for what comes after v1. Ordering is by what hurts a real session first, not by size.

## Done

- **Custom slash commands.** Markdown files in `~/.lumen/commands` appear in the composer's `/` menu. Picking one inserts its prompt; typing `/name` and sending expands it, with any following text appended as arguments.
- **Plan mode + todo tool.** The composer's Plan toggle makes a run read-only: Lumen inspects the project and writes a checklist with `update_todos`. The Plan inspector tab shows progress, and Start Building leaves plan mode and executes the checklist. Both survive restarts with the chat.
- **Open in the default app and Reveal in Finder.** Right-click a file or folder in the explorer to hand it to the editor macOS associates with it, or to show it in Finder.
- **Durable changes.** Applied change lists and guarded Undo now survive a restart, saved with the chat. Chats can also be searched by name or message text and renamed from the sidebar.
- **Patch-style multi-file edits.** `apply_patch` reviews one `*** Begin Patch` block as a single approval card, with per-file apply/reject and the existing recovery-snapshot and Undo path.
- **Ask the user a question.** `ask_user` blocks the run until the user picks one of two suggested answers or types their own, instead of guessing or stalling. No policy auto-answers it; Stop leaves an unanswered tool error.

## Next

1. **Parallel read-only tools.** Reads are independent and can run together; edits stay serial behind approvals.

## Workflow

- **Session state restore.** Reopen to the same project, conversation, inspector tab, and scroll position.

## Release and trust

- **Sparkle auto-update** (deferred from v1 in AGENTS.md) with a signed appcast wired into `release.sh`.
- **Performance guardrails in CI** for the idle-memory and cold-launch targets.
- **Hardening pass.** Fuzz the path validator, test command-denylist bypasses, audit Keychain and logging.

## Deliberately later

- Guarded Git write actions (branch, commit, push, PR) — skipped for now.
- Multiple windows/projects at once (today `ChatModel` is a single app-wide state object; this is an architecture change).
- Per-hunk approval granularity.
- Crash reporting.
