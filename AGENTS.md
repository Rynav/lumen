# Lumen: native macOS coding agent app

## What this is
A lightweight, native macOS app (Swift 6, SwiftUI) that works like ChatGPT Codex / Claude Code: a chat UI where an LLM agent can read, search, and edit files in a chosen project folder and run shell commands, with user approval for risky actions. It connects to multiple providers using the user's own API keys.

Lightweight is a hard requirement: no Electron, no web views for core UI, minimal dependencies. Targets: idle memory under 150 MB, cold launch under 1 second.

## Platform and distribution
- macOS 14+ only. Use AppKit where SwiftUI falls short (text views, terminal-style output). No iOS/Catalyst considerations.
- Distributed as a notarized direct download (Developer ID, DMG). NOT sandboxed (shell execution requires it), but Hardened Runtime must be enabled with no unnecessary entitlement exceptions.
- All file and shell access goes through a single `WorkspaceService` so a sandboxed build remains possible later.

## Project structure (terminal-buildable; do not hand-edit .xcodeproj)
- `Package.swift` defines a `LumenCore` library (providers, agent, tools, workspace, persistence) plus its test target. All logic and tests live here, so `swift test` works without Xcode UI.
- The app target is a thin SwiftUI shell generated from `project.yml` via XcodeGen (dev-time tool only, not a runtime dependency). Commit `project.yml`; gitignore the generated `.xcodeproj`.
- `scripts/` contains: `build.sh` (xcodegen + xcodebuild), `test.sh` (`swift test`), `release.sh` (archive, Developer ID sign, notarize, staple, make DMG).

```
Lumen/
  Sources/LumenCore/
    Providers/    LLMProvider protocol (Types), OpenAI, Anthropic, ChatGPT-account and
                  MCP clients, HTTPTransport + SSEParser
    Agent/        AgentSession (actor), ChatModel, ToolRegistry, ApprovalGate,
                  SystemPrompt, Instructions, Activity
    Workspace/    WorkspaceService (path validation, file ops, edits), CommandProcess, GitService
    Persistence/  AppConfiguration, ConversationStore, KeychainStore
  Sources/LumenApp/   SwiftUI views, scenes, menu commands (no networking or file logic here)
  Tests/LumenCoreTests/
  project.yml
  scripts/
```

## Commands (run these; do not guess)
- Test: `swift test`
- Build app: `./scripts/build.sh`
- Release: `./scripts/release.sh` (requires env var `NOTARY_PROFILE`, a keychain profile created with `xcrun notarytool store-credentials`; never hardcode credentials)

## Tech rules
- Swift 6 language mode, zero warnings. Swift Concurrency (async/await, actors, `AsyncThrowingStream`). Observation framework (`@Observable`) for UI state. No Combine unless unavoidable.
- Networking: `URLSession` only. Implement SSE streaming by hand with `URLSession.bytes(for:)`. No third-party provider SDKs.
- Runtime dependencies: aim for zero. Only a Markdown renderer and a diff view are acceptable candidates; justify any in the README. Sparkle (auto-update) is deferred to post-v1.
- Persistence: JSON files in Application Support (or SwiftData). Keep it simple.
- No force-unwraps in production code. Logging via `os.Logger` only; never log API keys or full file contents.
- Tests must run offline and deterministically: use recorded fixtures and a `MockProvider` that replays scripted tool calls. No real network calls in tests.

## Security rules (non-negotiable)
- API keys live only in the macOS Keychain. Never in UserDefaults, files, logs, or crash output.
- When spawning child processes, scrub the environment: never pass API keys or Lumen's own secrets to commands the agent runs.
- Every file path from the model is resolved (symlinks included) and must stay inside the workspace root. Reject `..` escapes and absolute paths outside the root.
- `run_command` uses a process group so Stop kills the whole tree; enforce timeouts and truncate output with a head/tail summary.
- Command denylist (e.g. `sudo`, `rm -rf /`) is enforced in code even in Full Auto mode.

## Definition of done (v1)
- Clean build and passing tests with zero warnings.
- User adds an OpenAI key, opens a project folder, asks "add a unit test for X", watches the agent read files, propose a diff, wait for approval, apply it, and run the tests, all streaming live.
- Same flow works with Anthropic and with a local OpenAI-compatible endpoint (e.g. Ollama).
- Stop reliably cancels both the network stream and any running process.
- `release.sh` produces a signed, notarized, stapled DMG that passes `spctl --assess` and `stapler validate`.
