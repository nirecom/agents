# agents

Personal Claude Code configuration — CLAUDE.md, skills, hooks, agents, and workflow
enforcement. Designed to extend to other agent frameworks (Codex, Cursor, Gemini CLI)
in the future.

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

## Directory Structure

```
CLAUDE.md          — global instructions loaded by Claude Code
settings.json      — hooks, permissions, model, and effort-level configuration
rules/             — coding, testing, docs, git, and security conventions
skills/            — slash commands (/make-plan, /write-tests, /review-code-security, …)
hooks/             — git and Claude Code hook scripts
agents/            — agent definition files (planner, reviewer)
bin/               — doc-append, doc-rotate, session-sync, scan-outbound, and other tools
install.sh         — Linux/macOS installer
install.ps1        — Windows installer
docs/              — architecture decisions, history, and operational docs
tests/             — test suite for hooks, skills, and framework behaviors
```

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
