# How OpenCode Works, and How Lumen Adopts It

Reference for the OpenCode harness (`opencode/`), plus the implementation plan for
porting its prompt and tool architecture into Lumen (`new-codex/`, the native
macOS agent app). Paths under `opencode/` are relative to that repository;
paths under `Sources/` are relative to `new-codex/`.

OpenCode is MIT licensed (Copyright (c) 2025 opencode). Prompt text adopted from
it is adapted to Lumen's tool names and harness limits, and the adaptations are
called out wherever they change behavior.

---

## Part 1 — How OpenCode assembles a request

### 1.1 `system` is an ordered array, not one string

`packages/core/src/session/model-request.ts:100` (`baseTranscript`) builds:

```ts
system: [
  input.agent.system
    ? input.agent.system
    : SessionSystemPrompt.make(input.tools.definitions.map((tool) => tool.name)),
  input.initial,
].filter((part) => part.length > 0).map(SystemPart.make),
```

- `part[0]` is the **agent prompt**: a custom `agent.system` if the agent defines
  one, otherwise the **default base prompt**.
- `part[1]` is `initial`: the rendered **instruction baseline** (§1.4).
- A custom `agent.system` **replaces** the base prompt; it does not append.
- Session `context` hooks then mutate this array (identity block, provider
  override prompt, plan reminders) before the request is sent.

### 1.2 The default base prompt and tool guidance

Source: `packages/core/src/session/runner/prompt/system.txt`. It is a template
with a `${OPENCODE_TOOL_GUIDANCE}` placeholder. `session/system-prompt.ts`
`make(tools)` → `render(PROMPT, tools)` fills it, and guidance lines are added
**only when the matching tool is advertised for that request**:

| Tool present | Guidance added |
| --- | --- |
| `shell` | Prefer dedicated tools; do not chain shell commands with separators. |
| `write` | Use `write` to create or fully replace files; prefer `edit` for targeted changes. |
| `edit` | Replace exact `oldString` with `newString`; unique unless `replaceAll`. |

The placeholder is filled from `input.tools.definitions.map((tool) => tool.name)`
— the definitions actually advertised for that Step, after permission filtering
(§2.1). So the prompt is a function of the tool set, not a constant.

### 1.3 Provider override prompts

`packages/core/src/plugin/optimize.ts` registers a `context`/`compaction`/
`generate` hook per model family. It renders through the same
`SessionSystemPrompt.render(template, Object.keys(event.tools))`, then:

- **`gpt`** model ids → `plugin/system-prompt/gpt.txt` (`gpt-astra.txt` for
  `astra`), mode **override**: replaces `system[0]`.
- **`claude`** → `plugin/system-prompt/anthropic.txt`, mode **append**:
  `` `${system[0].text}\n\n${rendered}` ``.
- `kimi`, `trinity`, `muse` → override with their own files.

Two rules matter:

1. If the agent has a custom `system`, the override is **skipped** (`optimize.ts:81`).
2. `gpt.txt` adds commentary-channel rules, delegation limits, destructive-action
   rules, and autonomy rules; `anthropic.txt` is only a short "# Code comments"
   paragraph.

`plugin/tool-input-repair.ts` and the disabled `OpenAIToolsPlugin` /
`AnthropicToolsPlugin` are not part of the prompt path.

### 1.4 The instruction baseline (`initial`)

`packages/core/src/session/context.ts:150` composes independent, typed sources
with `Instructions.combine`, ordered **most to least shared** so the prompt-cache
prefix stays reusable:

```ts
instructions: Instructions.combine([
  CodeModeInstructions.make(loaded.tools.codeModeCatalog), // user-level, stable
  loaded.mcp,          // MCP server instructions
  loaded.references,   // project references
  loaded.skills,       // available skills
  loaded.discovery,    // AGENTS.md (global + ancestor walk)
  loaded.builtins,     // date + environment (varies by day and directory)
  loaded.entries,      // per-Session durable instruction state
])
```

Details:

- `instructions/index.ts` gives each source a key, hashes canonical JSON to
  detect change, and renders `initial` / `changed` / `removed` text. The
  `initial` render is the baseline; later changes are appended as durable System
  messages in history, so the baseline itself stays a stable prefix.
- **Discovery** (`instruction-discovery.ts`): each file renders as
  `Instructions from: <path>\n<content>`. Sources are the global config
  `AGENTS.md` and an ancestor walk to the project root. The `read` tool also
  injects nearby `AGENTS.md` files found by walking up from the read target
  (`tool/plugin/read.ts:87-107`) as durable synthetic instructions.
- **Built-ins** (`instructions/builtins.ts`): `core/date` → `Today's date: <date>`;
  `core/environment` → an `<env>` block with working directory, workspace root,
  whether the directory is a git repo, the platform, and a note preferring the
  harness temp directory over `/tmp`.

### 1.5 Plan mode, identity, and max steps

- **Plan mode** is not prompt text: `plugin/plan.ts` injects user-role
  `<system-reminder>` messages (enter/leave) reconciled on every `context` hook so
  compaction cannot strip them, and denies the `edit` action outside
  `~/.opencode/plan/*`.
- **Identity** (`plugin/identity.ts`) splices a `# Your Model` block
  (`Name`/`Provider ID`/`Model ID`) into `system[1]`.
- **Max steps** (`session/runner/max-steps.ts`): when the agent's step allowance
  is exhausted, the runner appends `MAX_STEPS_PROMPT` as an assistant message and
  sets `toolChoice: "none"` (`runner/llm.ts:237-241`). Tool definitions stay in
  the request to preserve the cached prefix, but execution refuses with
  "Tools are disabled after the maximum agent steps" (`runner/step.ts:96`).

### 1.6 Built-in agents

`packages/core/src/plugin/agent.ts` seeds `build` (primary, default base prompt),
`general` (subagent), `explore` (subagent, `PROMPT_EXPLORE`, read-only
permissions), and hidden `compaction`, `title` (`PROMPT_TITLE`), `summary`
(`PROMPT_SUMMARY`). `plugin/plan.ts` adds `plan`. Custom agents come from
`{agent,agents,mode,modes}/**/*.md` and config `agents.<id>`; their `system`
overrides the base prompt.

---

## Part 2 — How OpenCode exposes tools

### 2.1 Two exposure modes

Each tool declares `options.codemode`:

- `codemode: false` → advertised on the provider's **native tool list**.
- `codemode: true` (the default) → reachable only through the `execute` Code Mode
  tool, listed in the Code Mode catalog instructions.

`Tool.snapshot` (`tool.ts:225`) splits tools into `direct` (native) and
`codeModeTools`, builds `execute` from `CodeModeTool.create`, and returns
`definitions = [...sorted(direct), ...(execute ? [execute] : [])]`. A `deny`
permission rule on the tool's action with resource `*` removes a tool from the
catalog entirely (`tool.ts:292`).

### 2.2 Native built-in tools

| Name | Permission action | Purpose |
| --- | --- | --- |
| `shell` | `shell` | `command`, `workdir`, `timeout` (default 120000 ms), `background`. |
| `read` | `read` | File/dir, text/images/PDF, `offset`/`limit`; injects nearby `AGENTS.md`. |
| `write` | `edit` | Create or fully replace a file; creates parent dirs. |
| `edit` | `edit` | Exact `oldString` → `newString`, `replaceAll`. |
| `patch` | `edit` | Apply-Patch format (add/delete/update/move). |
| `glob` / `grep` | `glob` / `grep` | Pattern and ripgrep search. |
| `question` | `question` | Ask the user structured questions. |
| `skill` | `skill` | Load an available skill's instructions/resources. |
| `subagent` | `subagent` | Spawn a child session. |
| `webfetch` / `websearch` | `webfetch` / `websearch` | Network read tools. |
| `execute` | `execute` | Run JS in a confined Code Mode runtime with `tools` + `fetch`. |

`tool/plugin/patch.ts:296-306` removes `edit` + `write` in favor of `patch` for
GPT models, so a given request advertises `patch` **or** `edit`+`write`.

### 2.3 Execution lifecycle

- Input is validated at the registration boundary (`tool/runtime.ts`); invalid
  input returns a `Tool.Error` telling the model to re-call.
- Results carry `output` (machine), `content` (model-visible), and `metadata`
  (UI/progress); oversized output is bounded by the Session runner.
- Parallel tool calls run on per-call fibers (`runner/step.ts:127-138`); a local
  call starts only after `Tool.Called` is published, and interruption aborts
  outstanding tool fibers.
- Leaves own path resolution, permission assertions, and side-effect ordering.
  `edit`, `write`, and `patch` share the `edit` action.

---

## Part 3 — What Lumen already does

Lumen is a single-agent, approval-gated macOS app. Its current design:

| Concern | OpenCode | Lumen before this change |
| --- | --- | --- |
| System prompt | `[agent prompt or base, initial]` array | one configurable string + an ad-hoc `baseContext` blob appended per turn |
| Tool guidance | rendered from the advertised tool names | baked into the prompt text, unconditional |
| Instruction baseline | type/date/env/AGENTS.md/skills/MCP sources | date and environment absent; no project instruction files |
| Provider prompts | per-family override/append | none |
| Agents | build/plan/explore/title/summary | one implicit agent |
| Max steps | `MAX_STEPS_PROMPT`, tools disabled | throws `AgentError.iterationLimit` |
| Tools | 13 native + Code Mode + MCP | `list_files`, `read_file`, `search_files`, `edit_file`, `run_command` + MCP |

Lumen's tool layer keeps OpenCode's most important safety properties: every path
is resolved and confined to the workspace (`WorkspaceService`), commands are a
program name plus an argument array with a denylist and a process group, and
`edit_file`/`run_command` always pass through `ApprovalGate`.

---

## Part 4 — The plan, and what was implemented

### 4.1 Prompt layering (`Sources/LumenCore/Agent/SystemPrompt.swift`)

Adopts `system = [agent prompt or base, instruction baseline]`:

1. **Part 0** is `systemPrompt` when the user has set a custom prompt; otherwise
   the built-in base prompt (`SystemPrompt.base`). A custom prompt replaces the
   base, exactly like OpenCode's `agent.system`.
2. **Part 1** is the instruction baseline (§4.2).
3. The parts are joined with a blank line into one system message, because
   Lumen's providers accept a single system message (Anthropic already
   concatenates several with `\n\n`).

Tool guidance follows `session/system-prompt.ts`: `SystemPrompt.render(template:
tools:)` replaces `${LUMEN_TOOL_GUIDANCE}` with lines that apply only to the
advertised tools. Guidance text is adapted to Lumen's real tools — notably
`edit_file` has no `replaceAll`, so the guidance does not mention one.

Provider overrides follow `plugin/optimize.ts`:

| Model id contains | Mode | Text |
| --- | --- | --- |
| `gpt` | replace | `SystemPrompt.gpt`, adapted from `gpt.txt` |
| `claude` | append | `SystemPrompt.anthropicAppendix`, ported from `anthropic.txt` |

Deviations, deliberate and called out:

- **Commentary channel**: `gpt.txt` describes a commentary channel Lumen does not
  have. The adapted text keeps the final-answer rules and drops the channel.
- **Delegation**: OpenCode's delegation section exists because it has a
  `subagent` tool. Lumen has none, so the section is omitted.
- **`oss`/`gpt-4` exclusions**: only used by OpenCode's `patch` selection, which
  has no Lumen equivalent, so the `gpt` match is a plain substring test.

### 4.2 Instruction baseline (`Sources/LumenCore/Agent/Instructions.swift`)

`Instructions.parts` returns ordered `InstructionSource` values, most to least
shared, mirroring `SessionContext.select`:

| Key | Source | Render |
| --- | --- | --- |
| `core/instructions` | global `~/.lumen/AGENTS.md`, then the workspace `AGENTS.md` | `Instructions from: <path>\n<content>` |
| `core/date` | current date | `Today's date: <yyyy-MM-dd>` |
| `core/environment` | workspace root, git presence, platform | `Here is some useful information about the environment you are running in:` + `<env>` block |
| `core/no-project` | no workspace is open | says no file or command tools are available |

Deviations:

- **No ancestor walk above the project root.** OpenCode walks up to the project
  root; in Lumen the workspace root *is* the project root, so the walk collapses
  to that one file, and Lumen's rule that no path may leave the workspace root is
  preserved.
- **No per-source change tracking.** OpenCode hashes each source and appends
  `changed` renders as durable System messages. Lumen re-renders the baseline on
  every turn, so a changed `AGENTS.md` is picked up naturally. There is no
  `initial`/`changed`/`removed` split.
- **Global instructions are app-owned.** `~/.lumen/AGENTS.md` is read through
  `WorkspaceService.loadAppFile`, not as a model-supplied path.
- **Nested `AGENTS.md` discovery on `read`** (OpenCode's `tool/plugin/read.ts:87`)
  is deferred: it needs durable per-Session synthetic instructions.

### 4.3 Max steps (`Sources/LumenCore/Agent/AgentSession.swift`)

The final permitted iteration adds `SystemPrompt.maxSteps` as an assistant
message and advertises **no tools**, so the model must answer with text. If a
provider still returns a tool call, it is answered with an error result instead
of being executed. The turn ends normally with a summary instead of throwing
`AgentError.iterationLimit`.

Deviation: OpenCode keeps tool definitions and sets `toolChoice: "none"` to
preserve the cached prefix. Lumen's provider protocol has no `toolChoice`, and
an empty tool list is rejected by no known endpoint, so tools are simply not
advertised on the last step. The prefix cache is lost for that one request.

### 4.4 Tool surface

`ToolRegistry` is unchanged in behavior but now exposes the definitions Lumen
would advertise for a given approval gate, so prompt guidance and the request
use the same list. Native tools remain five, plus MCP as
`mcp__<server>__<tool>`. Code Mode, `subagent`, `patch`, `question`, `skill`,
`webfetch`, and `websearch` are **not** ported; they need runtime pieces Lumen
does not have (a JS sandbox, child sessions, an Apply-Patch parser, structured
question UI).

### 4.5 Configuration and UI

- `AppConfiguration.defaultSystemPrompt` is now the base template with the
  `${LUMEN_TOOL_GUIDANCE}` placeholder. The previous Lumen default and the older
  "helpful coding agent" string are recognized as legacy defaults and upgraded
  once; a prompt the user actually edited is never overwritten.
- Settings gains a short explanation of the placeholder and a **Use Default
  Prompt** action, so the built-in prompt is discoverable and restorable.

### 4.6 Verification

Tests in `Tests/LumenCoreTests/SystemPromptTests.swift` and
`Tests/LumenCoreTests/InstructionTests.swift`, plus new cases in
`AgentTests.swift` and `ConfigurationTests.swift`, cover: placeholder
substitution, guidance appearing only for advertised tools, provider
override/append selection, custom-prompt precedence, baseline ordering and
content, `AGENTS.md` inclusion and absence, no-project rendering, legacy default
upgrade versus preserved custom prompts, and the max-steps turn.

### 4.7 Deliberately deferred

- Named agents with their own prompts, permissions, models, and a picker UI.
- Plan mode (user-role `<system-reminder>` reminders plus `edit` denial).
- Code Mode (`execute` + catalog instructions) and the remaining native tools.
- Instruction change tracking (`changed`/`removed` renders) and nested
  `AGENTS.md` injection.
- Per-model identity block (`# Your Model`).
