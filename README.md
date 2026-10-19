# 🚨 DISCLAIMER

> [!CAUTION]
> This is straight up ai slop made with deepseek v4.1 flash and gpt6 astra. Not a single line of code was checked by me or any human in this instance. Use at your own risk. 
> Only this disclaimer was added by me, everything else is done by an LLM.

# Lumen

A native macOS 14+ coding agent built with Swift 6 and SwiftUI. Provider credentials stay in Keychain; the app uses your own provider accounts or a local OpenAI-compatible server.

## Build

Install full Xcode and its command-line components, plus [XcodeGen](https://github.com/yonaskolb/XcodeGen):

```sh
brew install xcodegen
swift test
./scripts/build.sh
open build/Build/Products/Debug/Lumen.app
```

The build script uses `/Applications/Xcode.app` when `DEVELOPER_DIR` is not set. Set that environment variable to use another Xcode installation. `project.yml` is the source of truth; the generated Xcode project is ignored by Git.

`LumenCore` contains the testable logic. `LumenApp` contains the native UI. Tests run offline. There are no runtime package dependencies.

## Providers

Open **Lumen → Settings → Providers**, add a profile, enter its API base URL and default model, and save its credentials. Custom headers are also stored in Keychain. Use **Test Connection** to fetch the model list. Local endpoints may use an empty key. OpenAI-compatible endpoints normally use a URL ending in `/v1`.

The **Add provider** menu includes presets for OpenAI, **Anthropic** (Messages API), **OpenRouter**, **OpenCode Console**, the legacy **OpenCode Zen** gateway, and a local OpenAI-compatible server; each routes through the matching streaming client. Anthropic uses `x-api-key` and `anthropic-version`. OpenCode Console reads your workspace config (`GET /api/v2/config`) and sends each model to the API family it names (Chat Completions, Responses, or Messages); OpenRouter and Zen are OpenAI-compatible gateways.

Choose a provider and model in the chat composer. Use the model menu's **Enter model ID…** action when the server does not support model listing. Switching either selection affects the next turn. Optional per-million-token prices apply only to the profile's default model; costs are estimates, not billing statements. The composer footer reports the last response's input and output tokens, its measured output tokens per second, and that estimate.

### ChatGPT account sign-in (no API key)

In **Settings → Providers → Add Provider → ChatGPT Account**, choose **Continue with ChatGPT** and approve access in your browser. Select that account in the chat composer; Lumen fetches its available models and uses your ChatGPT plan through the public Responses API. Account availability, credits, and limits are controlled by OpenAI; use **Manage usage** to review them.

This implements OpenAI's [direct, open-source app OAuth flow](https://developers.openai.com/siwc/token-sharing-open-source/sign-in): dynamic registration with Lumen's own issued client ID, loopback callback, PKCE, state/nonce validation, and RSA-signed ID-token validation against OpenAI's JWKS. No Codex client ID, private ChatGPT endpoint, API key, client secret, external CLI, or provider SDK is used. Registration and tokens live only in Keychain; token refresh is serialized and rotating tokens are replaced together. Sign Out clears local tokens and attempts remote revocation while keeping the registration for later sign-in. Account registrations survive app restarts. Switching providers starts a fresh conversation on the next send.

OpenAI documents this as a preview for open-source apps. Commercial distribution may require OpenAI approval; confirm eligibility before releasing. ChatGPT plan requests use `store: false`, `stream: true`, complete conversation input, namespaced local tools, and encrypted reasoning continuation. Live browser authorization and plan access must be verified with your own eligible account; automated tests remain offline.

Send with **⌘Return**; **Esc** stops an active response. **⌘N** starts a new conversation and **⌘,** opens Settings.

## Project inspection

Use **Open Project** (**⌘O**) to choose a folder. The left sidebar separates remembered **Projects** from project-free **Chats**; switching preserves conversations and drafts during the app session. The agent can list files, read numbered UTF-8 text, and search for literal text, then use the results in subsequent model turns.

Chat shows the conversation, not tool payloads. The right-hand workspace panel has **Activity**, **Changes**, and **Files** tabs. Activity shows readable action names and progress; expand an action or command to inspect its output. Changes contains pending edit approvals, numbered red/green diffs, a **Changes only** filter, expanded diff review, and guarded Undo. Command approvals also appear in the panel, with explicit arguments and security warnings. Toggle the panel with **⌘⌥I**; pending approvals automatically reveal it.

Paths are checked against the project root, including symlinks; descriptor-based access prevents symlink swaps from escaping it. Reads are limited to 1 MB per file and 24,000 output characters. Listing/search skips hidden files, symlinks and build/vendor folders, scans at most 10,000 entries (64 directory levels), and search stops after 32 MB of text or 100 matches. Narrow the path for larger repositories. The lazy file tree includes dotfiles, skips Git/recovery/build folders and symlinks, and limits each directory to 500 visible entries. Click a file for a read-only preview; use Refresh for external changes.

## Approved edits and visual diffs

The agent's `edit_file` tool replaces one exact, unique text block. Empty `old_text` creates a new file only when it does not exist and its parent folder already exists. Every edit pauses for a numbered, red/green visual diff: **Approve & Apply** commits it; **Reject** changes nothing. Stop also cancels pending approval. Git internals and `.lumen` recovery files cannot be edited by the agent. Files are limited to 1 MB; large diffs (over 4,000 combined lines) show complete before/after replacement rather than an expensive minimal diff.

The workspace rechecks the file and parent folder before commit, writes a temporary file, and atomically installs it. Existing files are swapped and checked again rather than blindly overwritten. Permissions, ACLs and extended attributes are preserved; modification timestamps advance for build tools. Recovery JSON (including path, before and after) and displaced original files stay in `.lumen/backups`; if archival fails, a hidden `.lumen-edit-*` recovery file is retained beside the edited file. Add `.lumen/` to your project's `.gitignore` if you do not want recovery snapshots tracked. **Changes** opens applied diffs and supports guarded Undo during the current workspace session: it refuses to overwrite subsequent manual edits. Recovery snapshots survive restarts, and conversations (messages and drafts) are restored across launches from `conversations.json`; per-conversation change lists are still session-only. Anthropic and OpenAI-compatible execution are both supported, and shell commands run with approval or under the Full Auto policy.

## Approvals, Git review, and attachments

**Settings → Agent → Approvals** chooses how much runs without prompting. *Review everything* (default) asks before each edit and command; *Auto-approve edits* applies file edits immediately; *Full Auto* also runs commands without prompting. A built-in command denylist blocks dangerous programs and options in every mode, and approval can never override it.

The workspace panel's **Git** tab reviews the working tree against `HEAD` for the open project: changed and untracked files, the tracked diff, and a **Commit all** action. Destructive Git operations are intentionally not offered; use per-change **Undo** in **Changes** to restore the agent's edits from recovery snapshots.

Open a file in the **Files** tab and choose **Attach to prompt** to fold its contents into the next turn. Attached files appear as chips above the composer and are cleared after sending.

## MCP servers

**Settings → Agent → MCP Servers** adds [Model Context Protocol](https://modelcontextprotocol.io) servers launched over stdio (a command plus space-separated arguments). Their tools are exposed to the agent as `mcp__<server>__<tool>` and run with the server's own permissions without a separate in-app approval prompt, so only add servers you trust. Servers inherit the same scrubbed environment as agent commands.

## Releasing

`./scripts/release.sh` archives a Release build, signs it with your Developer ID under Hardened Runtime, notarizes and staples the DMG, and verifies it with `spctl` and `stapler`. It requires `NOTARY_PROFILE` (from `xcrun notarytool store-credentials`) and `DEVELOPER_ID_APPLICATION`.

## Saved configuration and reasoning

Provider metadata, selected account/provider, model choices, reasoning effort, system prompt, iteration limit and last project are saved atomically to `~/.lumen/config.json`. API keys, custom headers and OAuth credentials stay only in Keychain. Existing ChatGPT registrations are merged without overwriting saved names or model selections. A damaged configuration file is reported and is not silently replaced with defaults. On first launch after upgrading, a configuration at the old `~/Library/Application Support/Lumen/settings.json` path is read once as a fallback.

Set **Reasoning** near the composer or in **Settings → Agent**. **Default** omits an override; other choices send `reasoning.effort` to Responses or `reasoning_effort` to OpenAI-compatible Chat Completions. Available efforts depend on the selected model/provider; an unsupported override may reject the request. Changes apply to the next turn.

The chat shows a collapsed **Reasoning** section when the provider exposes reasoning. For known summary-capable Responses models (GPT-5/6, o3/o4 and Codex), Lumen requests `reasoning.summary: auto` and streams the public summary. Compatible endpoints can supply `reasoning_content` or `reasoning` text. Expand the section to read it; the answer remains separate. Some models/accounts provide no readable summary. OpenAI's private internal reasoning and encrypted continuation data are not displayed, decrypted, or invented.

## Long conversations

The composer footer shows the estimated request size against the selected model's context window. When a request would pass about three quarters of that window, Lumen asks the same provider to summarize the older half of the conversation and sends that summary in place of those turns. No tools are offered to the summarizer, and a failed summary falls back to the full history.

The transcript and the saved conversation keep every message; only the request is compacted. Each conversation's summary and the number of turns it covers are stored with it, so a relaunch neither re-summarizes nor re-sends what was already compressed. Window sizes come from a built-in table — Codex/GPT-5/6 272,000 tokens, GPT-4.1 and Gemini 1,048,576, Claude and o3/o4 200,000, anything else 128,000 — so an unknown local model compacts early rather than overflowing. Stop cancels a summary in progress like any other request.

## Contributing

Run `swift test` before opening a pull request; CI runs the same tests plus a full app build on macOS. Keep `LumenCore` free of UI code and provider credentials out of anything but Keychain.

## License

MIT — see [LICENSE](LICENSE). The system prompt and prompt-assembly text are adapted from OpenCode; see [THIRD_PARTY_NOTICES.md](THIRD_PARTY_NOTICES.md).
