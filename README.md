# agents

Personal AI coding agent configuration for **Claude Code** and **GitHub Copilot** (VS Code).
Shared CLAUDE.md, rules, hooks, and skills — single source of truth across both tools.
Codex CLI and Gemini CLI planned next.

## What's Inside

### Hook-enforced end-to-end workflow

Most agent frameworks rely on the model to remember process steps. This framework encodes
the dev workflow — research → plan → write-tests → code → run-tests → security-review →
docs → user-verification — as a per-session state machine. A PreToolUse hook physically
blocks `git commit` until every required step completes or is explicitly skipped with a reason.

- **Evidence-based completion**: staging `tests/` and `docs/*.md` files automatically
  satisfies the corresponding steps — no manual marker required.
- **State inheritance**: after context compaction or a fresh session on the same cwd+branch,
  prior workflow state is inherited so progress is not lost.
- **Docs-only short-circuit**: commits that only touch human-facing documentation bypass
  steps 1–6 automatically.

### Private information scanning

Two checkpoints prevent private data from reaching public repositories: a `git pre-commit`
hook and a Claude Code PreToolUse hook. Both detect RFC 1918 addresses, email addresses,
MAC addresses, absolute local paths, hard-coded secrets (AWS, Anthropic, OpenAI, GitHub,
Slack, and others), PEM private keys, and Trojan Source hidden Unicode characters.
Repositories identified as private via `gh api` are skipped automatically.
See [docs/scan-outbound.md](docs/scan-outbound.md) for details.

### Cross-machine session continuity

Normalizes Claude Code project paths to drive-root form (`C:\git\`, `/git/`) and syncs
`~/.claude/projects/` through a private GitHub repo — conversations started on Windows can
be resumed on macOS/Linux, and vice versa.

### Standards-backed testing and security

Concrete test categories — Normal, Error, Edge, Idempotency, and Security — with citations:
OWASP ASVS V8, OWASP WSTG, CWE Top 25, OWASP LLM Top 10, MCP Top 10. Test layer selection
follows Martin Fowler's narrow/broad integration distinction and Kent C. Dodds' Testing
Trophy. Security skills apply the same references at design time (`/review-plan-security`)
and implementation time (`/review-code-security`).

### TDD via subagent isolation

Test writing runs in a `mode: "auto"` subagent restricted to test files only, reducing
user confirmations from O(N) per-edit approvals to exactly two: test plan approval and
final review.

### GitHub Copilot support

`CLAUDE.md` and `rules/` are read natively by Copilot when `chat.useClaudeMdFile: true`
is set — no duplication needed. The existing `settings.json` hooks fire in Copilot too
(same JSON protocol; matchers extended with Copilot tool names). All `skills/` are
available to Copilot via Agent Skills — the `~/.claude/skills` symlink is auto-detected
by Copilot (VS Code 1.108+, 2025-12-18), so no separate prompt files are needed.
The installer configures all required VS Code settings automatically.

See [docs/architecture/copilot.md](docs/architecture/copilot.md) for the full design.

## Directory Structure

```
CLAUDE.md          — global instructions (Claude Code + Copilot)
settings.json      — hooks, permissions, model, and effort-level configuration
rules/             — coding, testing, docs, git, and security conventions
skills/            — slash commands (/make-plan, /write-tests, …) for Claude Code and Copilot
copilot/           — Copilot-specific configuration (VS Code settings scripts)
hooks/             — git and Claude Code/Copilot hook scripts
agents/            — agent definition files (planner, reviewer) — Claude Code only
bin/               — doc-append, doc-rotate, session-sync, scan-outbound, and other tools
install/
  win/             — Windows-specific install subscripts
  linux/           — Linux/macOS install subscripts
install.sh         — Linux/macOS installer
install.ps1        — Windows installer
docs/              — architecture decisions, history, and operational docs
tests/             — test suite for hooks, skills, and framework behaviors
```

## Requirements

### Required

| Tool | Purpose |
|------|---------|
| `git` | Repo clone; `core.hooksPath` is set to the repo's `hooks/` directory |
| `bash` | All shell hooks (`pre-commit`, `commit-msg`) and `bin/` scripts |
| Node.js | All Claude Code hooks in `settings.json` run via `node hooks/*.js` |
| PowerShell 5+ (Windows) | `install.ps1`, symlink creation, session-sync wrapper |
| [Claude Code CLI](https://docs.anthropic.com/en/docs/claude-code) | The framework targets Claude Code; without it, hooks/skills have no host |

> Windows: symlink creation requires Developer Mode (Settings → System → For developers) or Administrator privileges.

### Optional

| Tool | Used by |
|------|---------|
| [uv](https://github.com/astral-sh/uv) + Python 3 | `doc-append`, `doc-rotate.py`, `sort-history.py`, `convert-history-table.py` |
| [GitHub CLI (`gh`)](https://cli.github.com/) | Private-repo detection in `hooks/pre-commit` (without it, all repos are scanned conservatively) |
| `osascript` (macOS) / `notify-send` (Linux) | Toast notifications from `bin/session-sync.sh` |
| `jq` | `install/linux/vscode-settings.sh` — merging VS Code user settings on Linux/macOS |

### GitHub Copilot

GitHub Copilot for VS Code is required for Copilot integration. The installer
(`install.ps1` / `install.sh`) writes the required VS Code user settings automatically.

> **Note**: `settings.json` is standard JSON. If your VS Code `settings.json` contains
> comments (JSONC), the installer will warn and skip the merge — remove comments first.

## Install

### Linux / macOS

```bash
git clone https://github.com/nirecom/agents ~/git/agents
cd ~/git/agents && ./install.sh
```

Then add to `~/.bash_profile` or `~/.zshrc`:

```bash
source ~/.agents_profile
```

### Windows (PowerShell)

```powershell
git clone https://github.com/nirecom/agents $HOME\git\agents
Set-Location $HOME\git\agents
.\install.ps1
```

Then add to your PowerShell profile:

```powershell
. "$HOME\.agents_profile.ps1"
```

### Standalone (no dotfiles)

The framework works without the [dotfiles](https://github.com/nirecom/dotfiles) repo.
`$DOTFILES_PRIVATE_DIR` is optional — if unset, `scan-outbound.sh` runs with an empty
private-info allowlist (warning only).

## Configuration

Key environment variables set by `dotfileslink`:

| Variable | Value | Purpose |
|----------|-------|---------|
| `AGENTS_CONFIG_DIR` | path to this repo | Resolves hook paths in `settings.json` |
| `AGENTS_DIR` | path to this repo | Resolves `session-sync.sh` path in shell profile |

## Contributing

This is a personal configuration repo. Issues and discussions are welcome; PRs are accepted
for bug fixes and portable improvements. Feature additions that are personal-workflow-specific
are generally out of scope.

## License

MIT
