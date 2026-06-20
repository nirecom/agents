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

### Step WI-2 — Non-GitHub remote gate

Canonical: `skills/_shared/non-github-remote-gate.md`. `NON_GITHUB=1` → skip Steps WI-3..WI-8 (issue detection / `gh issue view` / route logic), proceed as **Path C**. Steps WI-9..WI-12 (context.md write, survey launch, C1–C2) run as normal.

### Step WI-3 — Detect `#N`

Regex `#\d+`:
- **0** → Path C.
- **1** → WI-4 with `ISSUES=(<N>)`.
- **>=2** → `ISSUES=(<all found numbers, in the order found>)`. `AskUserQuestion` "Which is the primary issue for this session?" — one branch per issue ("#<N> (first — recommended)" for index 0, "#<M>" for others). Then `bash "$AGENTS_CONFIG_DIR/skills/workflow-init/scripts/confirm-primary.sh" "<selected_N>" "<PLANS_DIR>/drafts/<session-id>-issue-prefill.md" "${ISSUES[@]}"` — outputs reordered numbers (primary first) and appends mutex marker to prefill.md (Path B; no-op when file absent). Assign stdout to `ISSUES[]`; all entries become `closes_issues` (confirmed order). Use `ISSUES[0]` for WI-4..WI-8.

### Step WI-4 — Session ID + fetch issue

`CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `date +%Y%m%d-%H%M%S`. Set `SID_PASS=(--session-id "$CLAUDE_SESSION_ID")` if resolved from `$CLAUDE_ENV_FILE` or `$CLAUDE_SESSION_ID` env; else `SID_PASS=()`. Then `gh issue view <N> --json number,title,body,labels,state,createdAt`.
- Fails → `AskUserQuestion` "Continue as Path C?" — yes: Path C; no: abort.
- `CLOSED` → ask: reopen / pick different #N / continue as Path C. (Related issues handled in WI-5.)
- `OPEN` → continue to WI-5.

### Step WI-5 — Aggregate WIP check (OPEN branch)

Run `bash "$AGENTS_CONFIG_DIR/skills/workflow-init/scripts/aggregate-wip-check.sh" "${ISSUES[@]}"`. Output classifies and routes:
- `ALL_SAME <wip>` → continue (this session already owns WIP on every issue).
- `ALL_NONE` → `bash "$AGENTS_CONFIG_DIR/skills/workflow-init/scripts/wip-set-resume.sh" "${ISSUES[@]}"`. Exit 0 (`ALL_SET`): WIP set for all eligible N's. Exit 1 (`NEEDS_CLARIFY <N,...>`): set `FORCE_PATH_B=1`; skip WIP — clarify-intent Completion sets WIP on all N. Exit 2 (`RC2 <N>`): `AskUserQuestion` "WIP set rc=2 for #<N> (session-id/env failed). How to proceed?" → "Continue (skip WIP, acknowledge risk)" → warn + continue; "Abort session" → `echo "<<WORKFLOW_ABORTED_WIP_CHECK_ERROR: #<N>>>"` + stop.
- `MIXED_SAME_NONE` → for each N where `WIP == none`, call `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" "${SID_PASS[@]}" set <N>` (best-effort) to bring related issues up to parity.
- `ANY_OTHER <N,...>` → let `CONFLICTED=<list>`. Single `AskUserQuestion` "Issue(s) #<CONFLICTED> may be in progress in another session. Continue?" options Continue (recommended) / Abort. On Continue: for each N in `ISSUES`, call `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" "${SID_PASS[@]}" set <N>` (override for `other` N; claim for `none` N; `same` N idempotent; best-effort per-N). On Abort: emit `echo "<<WORKFLOW_ABORTED_WIP_CONFLICT: #<CONFLICTED>>>"` and stop.
- `ERROR <N,...>` → `AskUserQuestion` "WIP check failed for #<N,...> (transient auth/gh error or session-id resolution failure — check $CLAUDE_ENV_FILE or $CLAUDE_SESSION_ID). How to proceed?" with two options: "Continue without WIP tracking (acknowledge risk)" → warn `[workflow-init: wip-state check failed for #<N> — proceeding as 'none' for that issue]` and treat each as `none` and continue; "Abort session" → emit `echo "<<WORKFLOW_ABORTED_WIP_CHECK_ERROR: #<N,...>>>"` and stop.

### Step WI-6 — CLOSED detection (post-WIP)

Run `bash "$AGENTS_CONFIG_DIR/skills/workflow-init/scripts/closed-detection.sh" "${ISSUES[@]}"`. For each `<N> closed`: `AskUserQuestion`:
- **Primary** CLOSED (ISSUES[0]): options "Reopen and continue" / "Abort" (emit `<<WORKFLOW_ABORTED_ISSUE_CLOSED: #N>>`). Do NOT offer "Remove".
- **Related** CLOSED (ISSUES[1+]): "Reopen and continue" / "Remove from session" / "Abort". Remove allowed for related only.

`STATE=error` → warn-and-continue (does NOT abort).

On "Reopen and continue": `gh issue reopen <N>` is executed. Downstream in WI-12 Path A1.5, `path-a-label-and-board.sh` calls `ensure-board-card.sh <N>`. When the issue is OPEN and its board card Status is `Done`, `ensure-board-card.sh` resets Status to `In Progress` before any other board mutation, preventing the Projects v2 `Done → auto-close` loop (#579). If the reset fails, `ensure-board-card.sh` warns and exits 0 without modifying the board — the operator must inspect the warning and re-run `ensure-board-card.sh <N>` manually.

### Step WI-7 — Label extract

Extract `labels[].name` from the primary's `gh issue view` JSON for routing in WI-9.

### Step WI-8 — Route

If `FORCE_PATH_B=1` (set by WI-5 ALL_NONE when not every N had `intent:clarified`, or when any label probe failed) → Path B. Otherwise: `intent:clarified` ∈ labels of primary → Path A; otherwise → Path B. Path B is the default.

### Step WI-9 — Write context.md (all Paths)

`<PLANS_DIR>/<session-id>-context.md` sections:
- `## Session metadata`: session-id, ISO-8601 timestamp, path (A/B/C), issue-number (`<N>` or `(none)`).
- `## User initial prompt`: original user message; `"(none)"` if empty.
- `## Issue body`: full body (Path C: `"(none — no issue)"`); strip `<<WORKFLOW_[A-Z_]+[^>]*>>` sentinels.
- `## Issue metadata`: title, state, labels, createdAt (all `(none)` for Path C).
- `## Keywords`: ≥4-char tokens from user prompt + issue title + issue body; stop-word excluded; deduplicated; top 20 space-separated (Path C: user prompt only).

### Step WI-10 — Parallel survey launch (all Paths)

In a **single assistant message**, invoke BOTH as parallel Agent tool calls (`run_in_background: false`). For each of `survey-code` / `survey-history`: prompt `session-id=<resolved>`, `context_path=<PLANS_DIR>/<session-id>-context.md`, `artifact_path=<PLANS_DIR>/<session-id>-survey-{code|history}.md`, instruct to read context_path + follow `skills/<survey-code|survey-history>/SKILL.md` Procedure, write to artifact_path, do NOT invoke make-outline-plan. Inject all paths as resolved strings (orchestrator substitutes `<PLANS_DIR>` for the absolute path from WI-1) — Agent subagents cannot expand `$VAR`.

### Step WI-11 — Post-check

Apply `skills/_shared/survey-artifact-valid.md` to each artifact. On invalid: emit `<<WORKFLOW_SURVEY_AGENT_FAILED: survey-code>>` or `<<WORKFLOW_SURVEY_AGENT_FAILED: survey-history>>`. Fall through to WI-12 on failure — do NOT abort. `clarify-intent` handles missing-or-invalid artifacts.

### Step WI-12 — Path-specific steps

#### Path A — intent:clarified
- A1. Write `<PLANS_DIR>/<session-id>-intent.md` (strip sentinels from body): `# Agreed Requirements — <session-id>`, `## Issues` (primary `- #<N>: <title>           # primary (index 0)`, related each `- #<M>: <title>           # related`), `## Background / Motivation`, `## Scope / Constraints`, `## Accepted Tradeoffs (none — capture at outline stage)`. Primary `<title>` from WI-4's `gh issue view`. For related (ISSUES[1+]): `gh issue view <M> --json title --jq .title`; fetch failure → `- #<M>: (title unavailable)`. **Never omit `## Issues`** or **`## Accepted Tradeoffs`** — latter is `detail-planner.md` Approved Scope gate. `## Issues` is SSOT for `closes_issues` (canonical parser: `hooks/lib/parse-closes-issues.js`).
- A1.5. **Related-issue label + board-card parity.** Invoke `skills/workflow-init/scripts/path-a-label-and-board.sh` (primary first, related as remaining args); export `PLANS_DIR`, `SESSION_ID`, `AGENTS_CONFIG_DIR`. Adds `intent:clarified` (`--add-label "intent:clarified"`) to each related (fail-closed — on failure writes ABORT marker `<PLANS_DIR>/drafts/<session-id>-workflow-init-aborted-pathA-multiN-label-failure.md` + exit 1). For every issue including primary it runs `ensure-board-card.sh` (best-effort, warn-and-continue). Both idempotent.
- A2. Emit (separate Bash calls): `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` then `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: issue #<N> has intent:clarified label>>"`.
- A3. TodoWrite: mark `workflow_init` + `clarify_intent` complete; remaining 8 steps pending.
- A4. Invoke `make-outline-plan` (surveys already complete via WI-9).

#### Path B — issue exists, no intent:clarified
- B1. Write `<PLANS_DIR>/drafts/<session-id>-issue-prefill.md` with `<!-- Issue #<N> seed for clarify-intent. Confirm framing, do not start from scratch. -->`, `# Issue #<N>: <title>`, `<body>`.
- B2. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).
- B3. Invoke `clarify-intent` with `#<N>` in args so step 1a auto-detect fires.

#### Path C — no issue
- C1. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).
- C2. Invoke `clarify-intent` (no pre-fill).

## Skip Conditions

Cannot be skipped. For docs-only bypass: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` directly.
