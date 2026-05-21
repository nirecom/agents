---
name: write-code
description: Edit source code for the current task. Delegates editing and lint/typecheck/self-repair to a subagent.
model: sonnet
---

Edit source code for the current task.

## Procedure

1. Read `rules/core-principles.md` and the target files identified from the plan.

2. **CONFIRM_CODE gate** — enumerate planned edits (one line per file: path + change intent). Then check via Bash:
   `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_CODE on && echo OFF || echo ON'`
   - `OFF`: proceed to step 3.
   - `ON`: present the planned edits via `AskUserQuestion` and wait for approval before continuing.

3. Read `skills/judge-task-complexity/SKILL.md`. Emit in Claude text output (NOT Bash echo):
   > Model selected: **[opus|sonnet]** (signals: [comma-separated triggered signal IDs, or "none"])

4. **Launch subagent** (`Agent` tool, `mode: "default"`, model = verdict from step 3) with a prompt containing:
   - Target files and planned edit summary from step 2.
   - A-layer language essence block (see below).
   - Directive: "Read `rules/coding/<lang>.md` before the first Edit for each language present."
   - Lint/typecheck recipe table (see below).
   - Self-repair cap: 3 iterations; if still failing after 3, surface tool output verbatim.
   - Lint-tool absence policy: when a tool is unavailable, skip that check AND emit `<tool> not found — check skipped` in the final summary. Never omit this notice.
   - Scope-expansion policy: if editing reveals additional files not in the original list need changes, include them in the final summary with a reason. Do NOT prompt mid-edit; do NOT silently expand scope.
   - Prohibitions: no diffs shown in the conversation; no mid-edit confirmation prompts.

5. Parse the subagent summary. Surface tool output on failure. Collect all `check skipped` notes and scope-expansion notes.

6. Present the final edited file list + skipped-check notes + scope-expansion notes to the user.

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

## Completion

None.
