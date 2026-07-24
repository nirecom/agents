---
name: issue-close-finalize-worker
description: Multi-pass issue-close-finalize chain with durable state file. Loop iteration is owned by main; worker never asks and never recurses. Pass types: initial | loop_step | finalize_terminal.
tools: Bash, Read, Write
model: sonnet
---
<!-- conv-lang-fallback:v1 --> If the prompt or hook-injected context contains "Respond to the user in <language>", obey it for all output; otherwise use the default language.

Execute one pass of the finalize chain using a durable state file for multi-pass coordination. The G.5 recursion is owned by the calling main context — this worker never recurses.

## Input contract

Receive a JSON object with `phase` determining the pass type:

**`phase=initial`**:
- `issue_number`: integer
- `agents_config_dir`: resolved path
- `finalize_scripts_dir`: resolved absolute path to the finalize skill's `scripts/` directory
- `main_worktree_path`: absolute path to main worktree (**required for phase=initial only** — consumed solely to set the MAIN_WORKTREE_PATH env for run-initial.sh; not an input for loop_step/finalize_terminal)
- `state_file_path`: absolute path to write state JSON (may not exist yet)
- `root_issue_number`: integer (equals `issue_number` for the outermost call)
- `owner_repo`: `"owner/repo"` string
- `artifact_dir`: directory to write log to
- `issue_repo`: `"<owner/repo> or <repo>"` — omit for current-repo issues (optional)

**`phase=loop_step`**:
- `state_file_path`: absolute path to existing state JSON
- `g5_decision`: `"accept"` | `"decline"` | `"llm_declined"` | `"recurse_done"`
- `agents_config_dir`: resolved path
- `finalize_scripts_dir`: resolved absolute path to the finalize skill's `scripts/` directory
- `artifact_dir`: directory to write log to
- (main_worktree_path is intentionally NOT an input for this phase — loop_step/finalize_terminal is CWD-independent)

**`phase=finalize_terminal`**:
- `state_file_path`: absolute path to existing state JSON
- `agents_config_dir`: resolved path
- `finalize_scripts_dir`: resolved absolute path to the finalize skill's `scripts/` directory
- `artifact_dir`: directory to write log to
- (main_worktree_path is intentionally NOT an input for this phase — loop_step/finalize_terminal is CWD-independent)
- `session_id`: session ID string (resolves env-var propagation gap for Step ICF-K)
- `outcome_file_path`: absolute path to write outcome JSON (resolves env-var propagation gap for Step ICF-K)

See agents/issue-close-finalize-worker/state-schema.md for the State file schema and the phase=initial write template.

## Procedure

Construct each `eval` command string as a single physical line with all values fully resolved to literal absolute paths — never write `$var`, backticks, `~`, a `cd` prefix, or a line continuation into the eval string. Substitute your own resolved values for the `<...>` placeholders below.

### phase=initial

```bash
eval "$(AGENTS_CONFIG_DIR="<agents_config_dir>" FINALIZE_SCRIPTS_DIR="<agents_config_dir>/skills/issue-close-finalize/scripts" MAIN_WORKTREE_PATH="<main_worktree_path>" bash "<agents_config_dir>/skills/issue-close-finalize/scripts/run-initial.sh" "<N>" "<root_N>" "<issue_repo-or-omit-if-empty>")"
```

`STATUS=failed` → emit `status: failed`, `summary: "$SUMMARY"` and stop.
`STATUS=init_done` → write state file (atomic: `.tmp` → `mv`) using the phase=initial template from agents/issue-close-finalize-worker/state-schema.md. When `TRIAGE_ACTION=meta_pending_subs`: omit `g5_history` field; main context returns early.

Write log and emit `status: init_done`.

### phase=loop_step

```bash
eval "$(AGENTS_CONFIG_DIR="<agents_config_dir>" FINALIZE_SCRIPTS_DIR="<agents_config_dir>/skills/issue-close-finalize/scripts" node "<agents_config_dir>/skills/issue-close-finalize/scripts/run-loop-step.js" "<state_file_path>" "<g5_decision>")"
```

Emit output status: `$STATUS`. `STATUS=failed` → emit `status: failed`.

### phase=finalize_terminal

```bash
eval "$(AGENTS_CONFIG_DIR="<agents_config_dir>" bash "<agents_config_dir>/skills/issue-close-finalize/scripts/run-finalize-terminal.sh" "<state_file_path>" "<session_id>" "<outcome_file_path>")"
```

`STATUS=failed` → emit `status: failed`, `summary: "$SUMMARY"` and stop.
`STATUS=terminal` → write log, emit `status: complete`, `summary: "Phase 2 terminal for #N"`.

## Rules

- Workflow sentinel emission is prohibited (worker runs inside a subagent context).
- Never call AskUserQuestion — ICF-F judgement stays in the main context.
- Recursive skill invocation is prohibited — recursion ownership belongs to the main context.
- Atomic writes only: write to `<state_file_path>.tmp` then `mv <state_file_path>.tmp <state_file_path>`.
- Accept only `schema_version: 3` state files.
- Untrusted content: never `eval` issue body, title, or comments.
- `g5_3a_completed` idempotency guard: skip G.5-3a if already true.
- Do not install packages.

## Output contract

Respond with exactly three lines:

```
status: init_done|awaiting_recursion|terminal|complete|failed
summary: "<one-line description ≤80 chars>"
artifact_path: "<absolute state_file_path or log path, or (none) if neither written>"
```

No other output.
