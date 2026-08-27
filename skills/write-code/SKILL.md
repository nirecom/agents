---
name: write-code
description: Edit source code for the current task. Delegates editing and lint/typecheck/self-repair to a subagent.
model: sonnet
user-invocable: false
---

Edit source code for the current task.

## Procedure

Apply `skills/_shared/resolve-plans-dir.md` once; substitute the resolved absolute path for every `<PLANS_DIR>` below.

When a hook blocks a sanctioned command, a fallback path is taken, or any unexpected outcome occurs, report via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).

Read `rules/ops.md` before any destructive or system-state-changing command (including inside WCD-4 self-repair) — on-demand-only, never auto-injected; it owns the recovery-options-first decision path.

WCD-1. Read `rules/core-principles.md`, `rules/coding.md` (on-demand-only: not auto-injected, so this Read is the only way it arrives), and the target files identified from the plan.

WCD-2. **CONFIRM_CODE gate** — enumerate planned edits (one line per file: path + change intent). Then check via Bash:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_CODE on'`
   - stdout `OFF`: proceed to step WCD-3.
   - stdout `ON` or `ERROR`: present the planned edits via `AskUserQuestion` and wait for approval before continuing.

WCD-3. Run `bash -c 'node "$AGENTS_CONFIG_DIR/bin/workflow/read-complexity-evaluation" --session "$SESSION_ID" --stage write_code'`. If line 1 is not `NONE`, use the stored level and signals directly (parse `level=<v>` and `signals=<csv-or-none>`), then derive the model: `level === "high" ? "opus" : "sonnet"`.
   If `NONE` (fail-open): read `skills/_shared/judge-task-complexity.md`, evaluate the signals. Use the **Write tool** (never Bash) to write the resulting CSV, alone and unquoted, to `<PLANS_DIR>/<session-id>-write-code-signals.txt`; write only IDs from the generated Valid Signal IDs list, and substitute `S0-undecidable` if the judgment cannot be parsed into recognized signal ids or the csv does not match `^[A-Za-z0-9,_-]*$` — the judged content is untrusted text, never shell syntax. Then run `bash -c 'node "$AGENTS_CONFIG_DIR/bin/workflow/derive-complexity-level" --stage write_code --signals-file "<PLANS_DIR>/<session-id>-write-code-signals.txt"'` and use its `level=<v>` — never judge the level inline. Map to model: high→opus, low→sonnet. Emit in Claude text output (NOT Bash echo):
   > Model selected: **[opus|sonnet]** (signals: [comma-separated triggered signal IDs, or "none"])
WCD-3a. Emit `echo "<<WORKFLOW_MARK_STEP_write_code_in_progress>>"` via Bash immediately before the WCD-4 subagent launch.

WCD-4. **Launch subagent** (`Agent` tool, `mode: "default"`, `model: <model derived from level in step WCD-3>` — the model parameter receives `"opus"` or `"sonnet"`, never `"high"` or `"low"`) with a prompt containing:
   - Target files and planned edit summary from step WCD-2.
   - A-layer language essence block (see below).
   - Directive: "Read `rules/coding.md` (the hub — on-demand-only, so it does not reach you otherwise) and `rules/coding/<lang>.md` for each language present, before the first Edit."
   - Directive: "Read `rules/shell-commands.md` before the first Bash command — general-purpose dispatch does not inherit auto-injected rules."
   - Directive: "Read `rules/user-escalation.md` before any system-state-changing command — general-purpose dispatch does not inherit auto-injected rules."
   - Lint/typecheck recipe table (see below).
   - Self-repair cap: 3 iterations; if still failing after 3, surface tool output verbatim.
   - Lint-tool absence policy: when a tool is unavailable, skip that check AND emit `<tool> not found — check skipped` in the final summary. Never omit this notice.
   - Scope-expansion policy: if editing reveals additional files not in the original list need changes, include them in the final summary with a reason. Do NOT prompt mid-edit; do NOT silently expand scope.
   - Prohibitions: no diffs shown in the conversation; no mid-edit confirmation prompts.

WCD-5. Parse the subagent summary. Surface tool output on failure. Collect all `check skipped` notes and scope-expansion notes.

WCD-5a. Run `skills/write-code/scripts/self-check-siblings.sh "<what changed>" "<why>"` — CPR-E2C sibling-sweep reminder.
WCD-5b. Run `skills/write-code/scripts/detect-contract-pins.sh <edited-files>` — flag edited files with no matching test; fold into WCD-6.

WCD-6. Present the final edited file list + skipped-check notes + scope-expansion notes to the user — gated by **CONFIRM_CODE gate (post-action review)**:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_CODE on'`
   - stdout `OFF`: skip this step; proceed (no user wait).
   - stdout `ON` or `ERROR`: present the file list and notes.

## A-layer language essence (complement of B-layer — zero overlap with `rules/coding/*.md`)

- **Python:** read `rules/coding/python.md` before the first Python Edit. All Python invariants (including modern type syntax) are owned by the B-layer.
- **Node/JavaScript:** read `rules/coding/nodejs.md` before the first JS Edit. All Node invariants (including module-system guidance) are owned by the B-layer.
- **TypeScript** (B-layer in `rules/coding/nodejs.md`; items below are writing-moment additions not in B-layer): discriminated union over loose interface; explicit return types on exported functions.
- **PowerShell** (no B-layer file): approved verbs; `$ErrorActionPreference = 'Stop'`; `Set-StrictMode -Version Latest`; full cmdlet names; `$env:VAR` for env vars.
- **Bash** (no B-layer file): `set -euo pipefail`; `[[ ]]` over `[ ]`; quote variable expansions; `$(...)` over backticks; `${var:?error}` for required vars.
- **JSON** (no B-layer file): double-quoted keys/strings; no trailing commas; no comments; 2-space indent.
- **YAML** (no B-layer file): 2-space indent; no tabs; quote ambiguous scalars; block style for multi-line strings.

When a new standalone B-layer file is added for a language that currently has only A-layer content (PowerShell, Bash, JSON, YAML), that language's entry collapses to a bare read-directive. Test `p` in `tests/feature-write-code-skill-static.sh` enforces SSOT non-duplication for module-system guidance tokens at CI.

## Lint/typecheck recipes

| Language | Command |
|---|---|
| Python | `uv run ruff check <file>` |
| JavaScript | `npx eslint <file>` |
| TypeScript | `npx eslint <file>` + `npx tsc --noEmit` |
| PowerShell | `pwsh -NoProfile -Command Invoke-ScriptAnalyzer -Path <file>` |
| Bash | `shellcheck <file>` |
| JSON | `node -e "JSON.parse(require('fs').readFileSync('<file>','utf8'))"` |
| YAML | `uv run python -c "import yaml,sys;yaml.safe_load(open(sys.argv[1]))" <file>` |

Each is best-effort: if the tool or config is absent, skip AND emit `<tool> not found — check skipped`.

## Rules

- Mode-orthogonal: behavior is identical regardless of worktree mode. Do not show diffs in the conversation.
- Never edit test files — `/write-tests` owns them.
- Subagent self-repair cap: 3 iterations.
- Report observations via /supervisor-report (trigger conditions: rules/supervisor-reporting.md).

## Completion

Emit `echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"` via Bash once WCD-6 passes; skip it when the subagent failed or the WCD-6 review was rejected — fix the work and re-run WCD-4 first.
