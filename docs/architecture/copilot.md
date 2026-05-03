# GitHub Copilot Support

This document describes the design decisions behind extending the agents framework to
GitHub Copilot (VS Code). Claude Code remains the primary target; Copilot is the first
secondary target, with Codex CLI and Gemini CLI planned for later.

---

## 1. Key Findings from Research

Before implementation, VS Code Copilot documentation was fetched to understand the
current (2026) customization surface. Several findings changed the initial design
assumptions significantly.

### 1.1 Copilot reads CLAUDE.md and `.claude/rules/` natively

When `chat.useClaudeMdFile: true` is set in VS Code user settings, Copilot automatically
picks up:

- `CLAUDE.md` at the workspace root
- `.claude/CLAUDE.md` within the workspace
- `~/CLAUDE.md` (user home)
- `~/.claude/rules/` (the entire rules directory, recursively)

This means the existing CLAUDE.md and rules/ symlinks installed by `dotfileslink` are
already usable by Copilot with a single settings toggle — no conversion, no wrapping,
no symlink into `~/.copilot/`.

**Design consequence**: instructions porting is a zero-code change. Only VS Code settings
need to be written.

### 1.2 Copilot has a Claude Code-compatible hooks API

VS Code Copilot supports the same lifecycle hooks as Claude Code:

| Hook | Trigger |
|---|---|
| `SessionStart` | New chat session begins |
| `UserPromptSubmit` | User submits a message |
| `PreToolUse` | Before any tool invocation |
| `PostToolUse` | After a tool completes |
| `PreCompact` | Before context compaction |
| `SubagentStart` / `SubagentStop` | Subagent spawned / completed |
| `Stop` | Session ends |

The hook file format and stdin/stdout JSON protocol are identical to Claude Code.
Critically, **Copilot reads `~/.claude/settings.json` as a hook source** — the same
file that the `dotfileslink` installer already symlinks from this repo's `settings.json`.

Hook configuration path (searched in priority order):

1. `.github/hooks/*.json` (workspace)
2. `.claude/settings.json` / `.claude/settings.local.json` (workspace)
3. `~/.claude/settings.json` (user-global) ← our existing symlink
4. `~/.copilot/hooks/` (Copilot-specific user dir)

**Design consequence**: hooks are shared without any new files. The only required change
is extending the `matcher` patterns in `settings.json` to include Copilot tool names
alongside Claude Code tool names.

### 1.3 Skills: two distinct Copilot mechanisms

Copilot supports two separate systems for skill invocation:

**Prompt Files** (`.prompt.md`) — manually triggered slash commands (`/promptname`).
Frontmatter fields: `name`, `description`, `agent`, `model`, `tools`, `argument-hint`.
VS Code searches `.github/prompts/` and directories listed in `chat.promptFilesLocations`.

**Agent Skills** (`SKILL.md`) — automatically detected and loaded by Copilot based on
`description` matching against the user's prompt. Launched 2025-12-18 (VS Code 1.108+).
Uses the **same `SKILL.md` format as Claude Code** — an open standard shared across
agents (Copilot, Claude Code, Cursor, Windsurf, and others).

Agent Skills search paths (user-global):

```
~/.claude/skills/<name>/SKILL.md   ← covered by existing symlink
~/.copilot/skills/<name>/SKILL.md
~/.agents/skills/<name>/SKILL.md
```

Additional paths are configurable via `chat.agentSkillsLocations`.

**Design consequence**: the `~/.claude/skills → agents/skills` symlink installed by
`dotfileslink` makes all skills available to Copilot automatically — no `copilot/prompts/`
port is needed for routing. `copilot/prompts/` retains value only for skills that require
Copilot-specific rewrites (see §4).

### 1.4 Subagent delegation does not exist in Copilot

Claude Code has an `Agent` tool that spawns subagents (planner, reviewer, explore, etc.)
with isolated tool access and separate context windows. Copilot has no equivalent:

- **Chat modes** (`.chatmode.md`) define a system prompt and tool set, but the user must
  select them manually — they cannot be triggered programmatically by another agent.
- There is no API for one Copilot session to delegate work to another session.

**Design consequence**: skills that depend on `Agent` tool delegation (primarily
`/make-outline-plan` and `/make-detail-plan` with their subagent loops) must be rewritten
as single-pass prompts with self-critique. The quality ceiling is lower than the Claude
Code version. The three-stage planning pipeline (`/clarify-intent` → `/make-outline-plan`
→ `/make-detail-plan`) is Claude Code-only; Copilot falls back to the legacy
`/make-plan` single-pass prompt.

---

## 2. What Is Shared (SSOT approach)

The goal is to keep `CLAUDE.md`, `rules/`, `settings.json` (hooks), and the core skill
logic as a single source of truth. Per-tool artifacts are generated or referenced by the
install scripts; they are not hand-maintained duplicates.

| Artifact | Claude Code | Copilot | How shared |
|---|---|---|---|
| `CLAUDE.md` | `~/.claude/CLAUDE.md` symlink | `chat.useClaudeMdFile: true` reads the same file | Settings toggle only |
| `rules/*.md` | `~/.claude/rules/` symlink | Same dir read natively by Copilot | Settings toggle only |
| `settings.json` hooks | Read from `~/.claude/settings.json` | Same file read by Copilot | Matcher OR-extension |
| Skills | `~/.claude/skills/` symlink, invoked via `/skill` | Same `~/.claude/skills/` symlink, auto-detected as Agent Skills (VS Code 1.108+) | Shared via symlink — no port needed |
| `agents/` (planner, reviewer) | Subagent definitions | **Not ported** — no equivalent | N/A |

---

## 3. Hooks Matcher Extension

Claude Code and Copilot use different tool names for the same operation:

| Operation | Claude Code tool name | Copilot tool name |
|---|---|---|
| Run shell command | `Bash` | `runInTerminal`, `runCommands` |
| Edit a file | `Edit`, `Write`, `MultiEdit` | `editFiles` |
| Read a file | `Read` | (varies — not extended) |

The `settings.json` hook matchers were extended with OR patterns so the same hook fires
in both environments:

```json
"matcher": "Bash|runInTerminal|runCommands"
"matcher": "Write|Edit|MultiEdit|editFiles"
"matcher": "Bash|Read|Grep|Glob|Edit|Write|MultiEdit|editFiles|runInTerminal|runCommands"
```

**Note**: The exact Copilot tool names for read/search operations (`codebase`,
`readFile`, etc.) have not been confirmed against a live session. The hooks that cover
`Read|Grep|Glob` (currently only `block-dotenv`) may not fire for Copilot's equivalent
read tools. Verification against live Copilot hook input JSON is required — see
[Section 6: Verification](#6-verification).

If a hook mismatch is found, capture the `tool_name` field from the hook's stdin JSON
and add it to the appropriate matcher. Document the confirmed names in a follow-up
update to this file.

---

## 4. Skills Port

### Current state: Agent Skills supersedes manual porting

The original design (written before Agent Skills shipped) ported 8 skills manually to
`copilot/prompts/*.prompt.md`. Since VS Code 1.108 (2025-12-18), Copilot auto-detects
all `SKILL.md` files under `~/.claude/skills/` as Agent Skills — including skills that
were previously excluded (`save-research`, `update-infrastructure`, `review-tests`).

**`copilot/prompts/` has been removed** (2026-04-26). All skills are served via the
`~/.claude/skills` symlink and the Agent Skills mechanism.

### Skills requiring Copilot-specific rewrites

Three skills have structural differences between Claude Code and Copilot that reduce
fidelity when using the shared `SKILL.md` directly:

| Skill | Issue | Impact |
|---|---|---|
| `clarify-intent` / `make-outline-plan` / `make-detail-plan` | 3-stage pipeline relies on `Agent` tool and `AskUserQuestion` | Claude Code-only; Copilot falls back to legacy `/make-plan` single-pass prompt |
| `make-plan` (legacy, Copilot fallback) | Relies on `Agent` tool for planner/reviewer loop | Single-pass self-critique only; lower quality ceiling |
| `write-tests` | Uses subagent isolation (`mode: agent` + tool restriction) | O(N) confirmation prompts not avoided |
| `deep-research` | References `#fetch` tool; behavior varies by Copilot version | May require agent mode enabled |

If higher fidelity is needed for these three, adding a `## Copilot Notes` section
to the relevant `SKILL.md` is the preferred approach — it keeps SKILL.md as the
single source of truth rather than maintaining a parallel file.

---

## 5. VS Code Settings Auto-Configuration

The install scripts (`install.ps1` / `install.sh`) call new subscripts
(`install/win/vscode-settings.ps1` / `install/linux/vscode-settings.sh`) that merge
the required keys into VS Code user `settings.json` non-destructively.

### Settings file locations

| Platform | Path |
|---|---|
| Windows | `%APPDATA%\Code\User\settings.json` |
| macOS | `~/Library/Application Support/Code/User/settings.json` |
| Linux | `~/.config/Code/User/settings.json` |
| WSL with Windows VS Code | Windows path (not handled — run `install.ps1` from Windows side) |

Override for testing: set `VSCODE_USER_SETTINGS_DIR` env var.

### Keys written and their purpose

| Key | Value | Purpose |
|---|---|---|
| `chat.useClaudeMdFile` | `true` | **Critical.** Enables Copilot to read `CLAUDE.md` and `~/.claude/rules/`. Without this, the port does not work. |
| `chat.useAgentsMdFile` | `true` | Enables workspace `AGENTS.md` support. Not used today; enables Codex support in a future pass with no reinstall. |
| `chat.useNestedAgentsMdFiles` | `false` | Disables recursive `AGENTS.md` scanning (experimental feature with accidental-pickup risk). |
| `github.copilot.chat.codeGeneration.useInstructionFiles` | `true` | Enables `.github/copilot-instructions.md` and `.github/instructions/*.instructions.md` loading. |
| `chat.includeApplyingInstructions` | `true` | Activates `applyTo` glob matching for path-scoped instructions. |
| `chat.promptFiles` | `true` | Enables `.prompt.md` files as `/promptname` slash commands. |
| `chat.promptFilesLocations` | `{}` | No custom prompt directories needed; Agent Skills covers all skills via `~/.claude/skills`. |
| `chat.hookFilesLocations` | `{ "$HOME/.claude": true }` | Adds `~/.claude/` to hook search paths. Copilot is expected to scan this by default; explicit registration is a version-drift safety net. |

### Merge behavior

- Existing settings are preserved; only the above keys are overwritten.
- A `.bak` copy of the original `settings.json` is written before modification.
- If `settings.json` is missing, it is created from scratch.
- If `settings.json` is invalid JSON (e.g., JSONC with comments), the script skips
  with a warning rather than corrupting the file. Re-run after removing comments.
- Path values in `chat.promptFilesLocations` and `chat.hookFilesLocations` are absolute
  paths computed at install time.
- Idempotent: running install twice produces the same result.

### Limitation: JSONC comments are lost

VS Code `settings.json` files often contain comments (`// ...`, `/* ... */`).
PowerShell's `ConvertFrom-Json` and bash's `jq` both reject JSONC. If your
`settings.json` has comments, the scripts will warn and skip. To fix: strip comments
manually or with a JSONC-aware tool before running install.

---

## 6. Verification

These steps are required after installation to confirm the integration is working.
Automated tests cover install script behavior; live Copilot behavior must be checked
manually.

### 6.1 VS Code settings merge

```powershell
# Run install; confirm keys are present
.\install.ps1
code $env:APPDATA\Code\User\settings.json
```

Expect: all 8 keys present, pre-existing keys untouched, `.bak` file created.

### 6.2 Instructions loading

Open any workspace in VS Code with GitHub Copilot active. In Copilot Chat, ask:

> "List the custom instructions currently applied to you."

Expect: content from `CLAUDE.md` (language policy, workflow steps, etc.) and
`~/.claude/rules/*.md` (coding conventions, test categories, etc.) to be reflected
in the response. If Copilot reports no custom instructions, check that
`chat.useClaudeMdFile` is `true` and that `~/.claude/CLAUDE.md` is not empty.

### 6.3 Skills (Agent Skills + Prompt Files)

**Agent Skills (primary):** In Copilot Chat, type `/` and confirm that skills not present
in `copilot/prompts/` appear — e.g., `/save-research`, `/review-tests`, `/update-infrastructure`.
These are served from `~/.claude/skills/` via the Agent Skills mechanism.

**Prompt Files (legacy):** The 8 ported skills (`commit-push`, `update-docs`,
`review-code-security`, `review-plan-security`, `survey-code`, `write-tests`,
`make-plan`, `deep-research`) should also appear. Selecting `/commit-push` loads and
executes the prompt correctly. `/make-plan` produces a usable plan (self-critique version).

If Agent Skills do not appear, verify that `~/.claude/skills` symlink points to `agents/skills/`.
If Prompt Files do not appear, check `chat.promptFiles: true` and verify
`chat.promptFilesLocations` points to the correct absolute path.

### 6.4 Hooks firing

To confirm hooks fire in Copilot, add a diagnostic tee to one hook temporarily:

```json
{
  "type": "command",
  "command": "node \"$AGENTS_CONFIG_DIR/hooks/scan-outbound.js\" | tee /tmp/hook-input.log"
}
```

Trigger a tool call in Copilot Chat (e.g., ask it to edit a file). Check
`/tmp/hook-input.log` for the hook's stdin JSON. Verify:

- `tool_name` field value — confirm it matches the OR-extended matcher patterns.
- `hookEventName` is `PreToolUse`.
- The hook script runs and produces valid JSON output.

If `tool_name` values differ from the assumed Copilot names (`runInTerminal`,
`runCommands`, `editFiles`), update the matchers in `settings.json` accordingly
and document the confirmed names here.

### 6.5 Non-regression

Run the existing test suite to confirm Claude Code hooks are unaffected by the
matcher extension:

```bash
timeout 120 bash tests/main-workflow-gate-regex.sh
timeout 120 bash tests/main-check-cross-platform.sh
```

---

## 7. Out of Scope (This Phase)

The following were explicitly excluded from the initial Copilot port:

| Item | Reason |
|---|---|
| `agents/planner.md`, `agents/reviewer.md` | Copilot has no Agent tool; subagent delegation cannot be replicated in config files |
| `/loop`, `/schedule` harness skills | Claude Code-specific; no Copilot equivalent |
| `AGENTS.md` creation | Deferred to Codex support pass; today only the settings key is enabled |
| Codex CLI support | Next after Copilot pilot |
| Gemini CLI support | Next after Codex |
| VS Code extension hooks | Copilot hook system covers config-based hooks; a VS Code extension would be needed for deeper integration (e.g., workflow gate UI) |

---

## 8. Future: Codex and Gemini

The directory layout is designed to accept siblings:

```
agents/
├── copilot/
│   └── prompts/       ← Copilot-specific skill rewrites (make-plan, write-tests, deep-research)
├── codex/             ← future: AGENTS.md body + ~/.codex/prompts/ symlinks
└── gemini/            ← future: GEMINI.md body + ~/.gemini/ hooks
```

Skills shared without modification live under `skills/` and are served to all agents via
the `~/.claude/skills/` symlink and the Agent Skills open standard.

Gemini CLI's hook system is also Claude Code-compatible (same JSON protocol, similar
hook event names). The `settings.json` matcher extension pattern used for Copilot
should apply directly. Codex CLI does not have a hooks API as of early 2026; coverage
will be limited to instructions and custom prompts.
