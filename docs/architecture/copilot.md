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

### 1.3 Prompt files are slash commands

`.prompt.md` files with YAML frontmatter are invoked as `/promptname` in Copilot Chat.
Frontmatter fields: `name`, `description`, `agent`, `model`, `tools`, `argument-hint`.

VS Code searches for prompts in `.github/prompts/` (workspace) and in any directory
listed in `chat.promptFilesLocations` (user settings). This allows pointing directly at
the repo's `copilot/prompts/` without creating symlinks.

### 1.4 Subagent delegation does not exist in Copilot

Claude Code has an `Agent` tool that spawns subagents (planner, reviewer, explore, etc.)
with isolated tool access and separate context windows. Copilot has no equivalent:

- **Chat modes** (`.chatmode.md`) define a system prompt and tool set, but the user must
  select them manually — they cannot be triggered programmatically by another agent.
- There is no API for one Copilot session to delegate work to another session.

**Design consequence**: skills that depend on `Agent` tool delegation (primarily
`/make-plan` with its planner/reviewer loop) must be rewritten as single-pass prompts
with self-critique. The quality ceiling is lower than the Claude Code version.

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
| Skills | `~/.claude/skills/` symlink, invoked via `/skill` | `copilot/prompts/*.prompt.md`, invoked via `/skill` | Manual port to `.prompt.md` |
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

### Strategy

Skills were ported manually to `copilot/prompts/`. The Claude Code skill format
(`skills/<name>/SKILL.md`) and the Copilot prompt format (`copilot/prompts/<name>.prompt.md`)
differ mainly in frontmatter field names and the absence of Claude-specific tool
references in the body.

**Not automated**: a `bin/convert-skill-to-prompt.py` script was considered but rejected.
With only 8 core skills and non-trivial body rewrites needed (subagent delegation
removal, tool reference cleanup), manual porting gives better control. If the skill
count grows significantly, revisit.

### Skill-by-skill notes

| Skill | Copilot fidelity | Notes |
|---|---|---|
| `commit-push` | Full | Pure procedural instructions; maps 1:1 |
| `update-docs` | Full | Same; `doc-append` CLI call preserved as text instruction |
| `review-code-security` | Full | Pattern tables preserved verbatim |
| `review-plan-security` | Full | Checklist preserved; `TodoWrite` reference removed |
| `survey-code` | Full | `Explore subagent` reference replaced with direct grep/read instructions |
| `write-tests` | Partial | `mode: agent` + tools restriction replaces subagent isolation; O(N) confirmations not avoided |
| `make-plan` | Partial | planner/reviewer loop replaced with draft → self-critique → revise; one pass, no iteration |
| `deep-research` | Partial | `#fetch` tool dependency; may require agent mode enabled; behavior varies by Copilot version |

**Excluded from core port**: `save-research`, `update-instruction`, `review-tests`.
These are workflow-support skills with Claude Code-specific integrations that do not
have natural equivalents in the Copilot prompt system.

### Prompt file location

Prompts live under `copilot/prompts/` in the repo. VS Code user settings
(`chat.promptFilesLocations`) point directly to this directory — no symlink is created
under `~/.copilot/prompts/`. This is **Option A (direct reference)**: the install
script writes the absolute repo path into VS Code user settings, so the prompts are
always served from the single repo copy.

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
| `chat.promptFiles` | `true` | Enables `.prompt.md` files as `/promptname` slash commands. Without this, `copilot/prompts/` is inert. |
| `chat.promptFilesLocations` | `{ "<repo>/copilot/prompts": true }` | Adds `copilot/prompts/` to the user-level prompt search path (Option A direct reference). |
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

### 6.3 Prompt files

In Copilot Chat, type `/` and confirm:

- All 8 prompts appear in the suggestion list (`commit-push`, `update-docs`,
  `review-code-security`, `review-plan-security`, `survey-code`, `write-tests`,
  `make-plan`, `deep-research`).
- Selecting `/commit-push` loads and executes the prompt correctly.
- `/make-plan` produces a usable plan without the planner/reviewer loop
  (self-critique version).

If prompts do not appear, check `chat.promptFiles: true` and verify
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

The directory layout (`copilot/prompts/`) is designed to accept siblings:

```
agents/
├── copilot/
│   └── prompts/       ← this port
├── codex/             ← future: AGENTS.md body + ~/.codex/prompts/ symlinks
└── gemini/            ← future: GEMINI.md body + ~/.gemini/ hooks
```

Gemini CLI's hook system is also Claude Code-compatible (same JSON protocol, similar
hook event names). The `settings.json` matcher extension pattern used for Copilot
should apply directly. Codex CLI does not have a hooks API as of early 2026; coverage
will be limited to instructions and custom prompts.
