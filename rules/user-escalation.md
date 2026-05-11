# User Escalation

Claude Code must minimize interruptions to the user. These rules govern **when and how
to ask the user to run a shell command**.

## Decision Flow

Before presenting any command for the user to run, work through this checklist in order:

| Question | If YES | If NO |
|---|---|---|
| Is the command destructive (data loss, irreversible)? | Follow `rules/ops.md` decision path first. | Continue ↓ |
| Can Claude Code execute this action directly via an appropriate tool? | Do it — do not ask. | Continue ↓ |
| Are there ≥ 2 dependent steps that must run in sequence? | Bundle into a single script (Rule 3). | Present one command (Rule 2). |

## Rule 1 — Autonomy-First

- Attempt execution via the appropriate tool(s) before asking the user.
- Escalate only when the tool path is genuinely blocked.
- Do NOT repeat the same ask. If repetition seems needed, find a different approach — not a re-packaging of the same blocked action.

## Rule 2 — One-Command-at-a-Time

- When a user ask is unavoidable, present exactly one command.
- Wait for the user to report the result before presenting the next command.
- Batch presentation of multiple sequential commands is PROHIBITED.

## Rule 3 — Script-First

- When ≥ 2 dependent non-destructive steps are unavoidable, bundle them into a single
  script instead of N separate asks.
- The script must abort on failure: `set -euo pipefail` (bash) or
  `$ErrorActionPreference = 'Stop'` (PowerShell).
- Ask the user to report the output and exit code after running.
- Destructive steps (listed in `rules/ops.md`) must NOT be bundled — they require the
  `rules/ops.md` decision path first.
- See `rules/shell-commands.md` for platform-aware script authoring.

## Precedence

| Priority | Rule | Beats |
|---|---|---|
| 1 | `rules/ops.md` — destructive ops decision path | Rules 1–3 |
| 2 | Rule 1 — Autonomy-First | Rules 2–3 |
| 3 | Rule 2 — One-Command-at-a-Time | Rule 3 |
| 4 | Rule 3 — Script-First | — |
