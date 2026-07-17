---
name: workflow-init
description: Routing entry point for the Claude Code workflow. Inspects #N and the intent:clarified label: Path A (skip interview), Path B (pre-fill interview), Path C (full interview + auto-create).
model: sonnet
---

IMPORTANT: Interactive session required. Hard-fail in non-interactive contexts (`claude -p`, `/loop`, subagents).

## Purpose

First step of every workflow session. Routes on GH issue context: Path A (`#N` + `intent:clarified`) skips interview; Path B (`#N`, no label) pre-fills interview; Path C (no `#N`) runs full interview and auto-creates a tracking issue.

## Procedure

### Step WI-1 — Resolve <PLANS_DIR>

Canonical: `skills/_shared/resolve-plans-dir.md`. Substitute the resolved absolute path for every `<PLANS_DIR>` placeholder below. Subagent prompts must receive literals — they cannot expand `$VAR`.

### Step WI-2 — Driver loop

The driver (`bin/workflow/workflow-init-driver`) handles WI-3..WI-9: token detection, `gh issue view` fetch for each N in `ISSUES`, Aggregate WIP check (all N: all_same / all_none / any_other), CLOSED detection, label extraction, route decision, and context.md write. The driver writes the checkpoint and `<SID>-context.md` directly under PLANS_DIR (outside git repos → ENFORCE_WORKTREE does not apply).

Invocation: `node "$AGENTS_CONFIG_DIR/bin/workflow/workflow-init-driver" <raw-tokens> 2>/dev/null`
(`<raw-tokens>` = issue number tokens like `#15` or `#15 #22` — not the full user prompt)

On resume (after `ask_user`): `node "$AGENTS_CONFIG_DIR/bin/workflow/workflow-init-driver" --resume <CHECKPOINT> --answer '<token>'`

Read all `KEY=VALUE` output lines. Dispatch on `ACTION=`:

| ACTION | Meaning | What to do |
|---|---|---|
| `invoke` | Next skill ready | Run `NEXT_SKILL` via Skill tool |
| `done` | Driver complete | Proceed to WI-10; follow `PATH_DECISION=` at WI-12 (Path C still runs WI-10 onward — no jump) |
| `blocked` | Unrecoverable | Show `REASON=` + `NEXT_HINT=` and stop |
| `ask_user` | User decision needed | Percent-decode `OPTIONS_DISPLAY=` (encoded like `QUESTION=`), present via `AskUserQuestion`; re-invoke with `--resume <CHECKPOINT> --answer '<token>'` |
| `emit_sentinel` | Driver requests sentinel | Emit `SENTINEL=` via separate Bash call |

`ask_user` interruptions and their options:

- `ASK_ID=wip_conflict`: Issue(s) #<CONFLICTED> are in progress in another session. Driver answers: Continue (recommended) / Abort. On Continue: for each N in `ISSUES`, driver runs `wip-state set <N>` (override for `other`; claim for `none`; idempotent for `same`). On Abort: `ACTION=blocked REASON=user_aborted`.
- `ASK_ID=wip_rc2`: wip-state set rc=2 for #N. Driver answers: Continue (acknowledge risk — driver treats as none, proceeds) / Abort.
- `ASK_ID=wip_error`: wip-state check failed (transient auth / session-id resolution failure — check `$CLAUDE_ENV_FILE` or `$CLAUDE_SESSION_ID`, rc=non-zero). Driver answers: Continue (treat as none, proceed) / Abort. Advisory: driver logs `[wip-state check failed for #N — proceeding as 'none']`.
- `ASK_ID=closed_reopen_<N>`: Issue #N is CLOSED. Driver answers: `reopen` / `remove` / `abort`. Remove is only offered when `len(closes_issues) >= 2`.
- `ASK_ID=meta_select`: meta issue has open sub-issues. Driver answers: `#<M>` (select sub-issue) / `abort`.
- `ASK_ID=fetch_failed_path_c`: `gh issue view` fetch failed. Driver answers: `continue` (Path C) / `abort`.

`PATH_DECISION=` values on `ACTION=done`:

- `A` — all N carry `intent:clarified` (and `FORCE_PATH_B` is not set from a fresh WIP claim).
- `B` — any N lacks `intent:clarified` OR WIP was freshly claimed for all N (`FORCE_PATH_B=true`). ALL_NONE path: `none` + for each N in `ISSUES`, `wip-state set <N>` (from fresh claim), then set `FORCE_PATH_B=1` — even when `intent:clarified` is present, FORCE_PATH_B routes to B. ISSUES[0] becomes closes_issues[0]; all entries become closes_issues in insertion order. ISSUES[@] are processed symmetrically.
- `C` — zero issues (`ISSUES=()`) OR `NON_GITHUB=1`.
- `META` — all issues carry `meta` label and have no open sub-issues.

### Step WI-10 — Parallel survey launch (all Paths)

In a **single assistant message**, invoke BOTH as parallel Agent tool calls (`run_in_background: false`). For each of `survey-code` / `survey-history`: prompt `session-id=<resolved>`, `context_path=<PLANS_DIR>/<session-id>-context.md`, `artifact_path=<PLANS_DIR>/<session-id>-survey-{code|history}.md`, instruct to read context_path + follow `skills/<survey-code|survey-history>/SKILL.md` Procedure, write to artifact_path, do NOT invoke make-outline-plan. Inject all paths as resolved strings (orchestrator substitutes `<PLANS_DIR>` for the absolute path from WI-1) — Agent subagents cannot expand `$VAR`.

### Step WI-11 — Post-check

Apply `skills/_shared/survey-artifact-valid.md` to each artifact. On invalid: emit `<<WORKFLOW_SURVEY_AGENT_FAILED: survey-code>>` or `<<WORKFLOW_SURVEY_AGENT_FAILED: survey-history>>`. Fall through to WI-12 on failure — do NOT abort. `clarify-intent` handles missing-or-invalid artifacts.

### Step WI-12 — Path-specific steps

#### Path META — meta label issue
WI-8 open sub-issue guard ensures all `ISSUES[@]` have no open sub-issues before reaching this path.
- PM1. `bin/workflow/set-workflow-type "$SESSION_ID" "wf-meta"` (separate Bash call, before any sentinel).
- PM2. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).
- PM3. `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: meta issue — WF-META type; intent confirmed from issue body>>"`.
- PM4. Use `/issue-create --skip-survey` with `--verdict bulk-sub-of --parent <meta-N> --manifest <file>` to create all planned sub-issues under the meta parent in a single bulk pass.
- PM5. Invoke `make-outline-plan`. (next-step auto-skips `detail` and 8 other non-applicable WF-CODE steps after outline completes — `make-detail-plan` is never invoked in WF-META.)

#### Path A — intent:clarified
- A1. Write `<PLANS_DIR>/<session-id>-intent.md` (strip sentinels from body): `# Agreed Requirements — <session-id>`, `## Issues` (one `- #<N>: <title>` line per entry in `ISSUES[@]`, in insertion order, no annotations), `## Background / Motivation`, `## Scope / Constraints`, `## Accepted Tradeoffs (none — capture at outline stage)`. Title for each N from WI-4's `gh issue view`; fetch failure → `- #<N>: (title unavailable)`. **Never omit `## Issues`** or **`## Accepted Tradeoffs`** — latter is `detail-planner.md` Approved Scope gate. `## Issues` is SSOT for `closes_issues` (canonical parser: `hooks/lib/parse-closes-issues.js`). `ISSUES[0]` is the first entry; it becomes `closes_issues[0]`; this entry becomes `closes_issues[0]`.
- A1a. Set session title: `node "$AGENTS_CONFIG_DIR/bin/cc-session-title" set-issue "$(pwd)" "<PLANS_DIR>"`
- A2. **Label + board-card parity for all N.** Invoke `skills/workflow-init/scripts/path-a-label-and-board.sh` with `"${REPO_MAP_ARGS[@]}"` followed by all entries of `ISSUES[@]` as positional args; export `PLANS_DIR`, `SESSION_ID`, `AGENTS_CONFIG_DIR`. Adds `intent:clarified` (`--add-label "intent:clarified"`) to each related entry (fail-closed — on failure writes ABORT marker `<PLANS_DIR>/<session-id>-workflow-init-aborted-pathA-multiN-label-failure.md` + exit 1). For every issue it runs `ensure-board-card.sh` (best-effort, warn-and-continue). Both idempotent.
- A3. Emit (separate Bash calls): `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` then `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: issue #{N} has intent:clarified label>>"`.
- A3a. **Complexity evaluation**: Read `skills/_shared/judge-task-complexity.md`; evaluate all S1–S6 signals against the confirmed intent.md (S6 approximated from intent.md line count only — outline.md does not exist yet). Then run as a separate Bash call: `SKIP_MODE=$(bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --verdict <high|low> --signals <csv-or-empty> --target outline)`. `$SKIP_MODE` is `auto` or `judgment`.
- A3b. **Outline skip — sentinel dispatch** (same logic as CI-C1c): `SKIP_MODE=auto` → proceed to the sentinel block. `SKIP_MODE=judgment` → evaluate so_c1/so_c2. Not both true → skip (go to A4). Both true → run `node "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" --session "$SESSION_ID" --target outline --c1 true --c2 true` as a separate Bash call, then proceed to the sentinel block. **Sentinel block** (separate Bash calls): `echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>"` → Agent tool (run_in_background: true): subagent_type=skip-verifier, session_id=`$SESSION_ID`, target=`outline`, intent_path=`<PLANS_DIR>/$SESSION_ID-intent.md`.
- A4. TodoWrite: mark `workflow_init` + `clarify_intent` complete; remaining 8 steps pending.
- A5. Invoke `make-outline-plan` (surveys already complete via WI-9).

#### Path B — issue exists, no intent:clarified
- B1. Write `<PLANS_DIR>/<session-id>-issue-prefill.md` with `<!-- Issue #<N> seed for clarify-intent. Confirm framing, do not start from scratch. -->`, `# Issue #<N>: <title>`, `<body>`.
- B2. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).
- B3. Invoke `clarify-intent` with `#<N>` in args so step 1a auto-detect fires.

#### Path C — no issue
- C1. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).
- C2. Invoke `clarify-intent` (no pre-fill).

## Skip Conditions

Cannot be skipped. For docs-only bypass: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` directly.
