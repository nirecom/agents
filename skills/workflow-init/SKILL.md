---
name: workflow-init
description: Routing entry point for the Claude Code workflow. Inspects #N and the intent:clarified label: Path A (skip interview), Path B (pre-fill interview), Path C (full interview + auto-create).
model: sonnet
---

IMPORTANT: Interactive session required. Hard-fail in non-interactive contexts (`claude -p`, `/loop`, subagents).

## Purpose

First step of every workflow session. Routes on GH issue context: Path A (`#N` + `intent:clarified`) skips interview; Path B (`#N`, no label) pre-fills interview; Path C (no `#N`) runs full interview and auto-creates a tracking issue.

## Procedure

### Step 0 — Resolve <PLANS_DIR>

Canonical: `skills/_shared/resolve-plans-dir.md`. Run once at start:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
```

Substitute the resolved absolute path for every `<PLANS_DIR>` placeholder below. Subagent prompts must receive literals — they cannot expand `$VAR`.

### Step 0.5 — Non-GitHub remote gate

Canonical: `skills/_shared/non-github-remote-gate.md`. Inline:

```bash
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
NON_GITHUB=$([ "$rc" = "1" ] && echo 1 || echo 0)  # rc=2 → fail-open
[ "$NON_GITHUB" = "1" ] && echo "[GITHUB_ISSUES disabled: non-GitHub remote, routing as Path C]"
```

When `NON_GITHUB=1`: skip steps 1–4 (issue detection / `gh issue view` / route logic), proceed as **Path C**. Steps 5–7 (context.md write, survey launch, C1–C2) run as normal.

1. **Detect `#N`** (regex `#\d+`):
   - **0** → Path C.
   - **1** → step 2 with `ISSUES=(<N>)`.
   - **2+** → set `ISSUES=(<all found numbers, in the order found>)`. All entries become `closes_issues` (no narrowing). `ISSUES[0]` is the primary candidate.
     **Primary confirmation (single-window invariant):** immediately
     `AskUserQuestion`:
     - question: "Which is the primary issue for this session?"
     - options: one branch per found issue, e.g. "#<ISSUES[0]> (first — recommended)" for index 0, "#<ISSUES[1]>" for index 1, etc.
     Move the selected entry to index 0 in `ISSUES`; it becomes closes_issues[0] (the primary).
     Write all entries to `closes_issues` (in confirmed order) when the
     downstream intent.md is created. Append the mutual-exclusion marker
     `<!-- workflow-init: confirmed primary = <selected-N> -->` at the end of
     `<PLANS_DIR>/drafts/<session-id>-issue-prefill.md` (Path B) — this
     suppresses the duplicate confirmation in `clarify-intent` Completion.
     For Path A (label-clarified), the marker is unnecessary because
     `clarify-intent` does not run.
     Use the primary `ISSUES[0]` for steps 2–4 (Session ID, gh issue view, label routing).
2. **Session ID**: read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `date +%Y%m%d-%H%M%S`.
3. **Fetch issue**: `gh issue view <N> --json number,title,body,labels,state,createdAt`
   - Fails → `AskUserQuestion` "Continue as Path C?" — yes: Path C; no: abort.
   - `CLOSED` → ask: reopen / pick different #N / continue as Path C.
     **State-check for related issues (ISSUES[1+]).** For each N in ISSUES[1+], probe state via the helper (same invocation shape as (c) below). On `STATE=closed`, raise a single `AskUserQuestion` "Related issue #N is CLOSED. How to proceed?" with options "Reopen and continue" / "Remove from session" / "Abort" (Remove is allowed for related issues only — never for primary). On `STATE=error`, warn and continue (does NOT abort).
   - `OPEN` →
     (a) **Aggregate WIP check across all ISSUES.** For each issue N in `ISSUES` (primary first), call:
         `WIP_N=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" check <N> 2>/dev/null)` and capture `WIP_RC_N=$?`.
         Collect per-N status into vectors `WIP[]` and `WIP_RC[]`.
         Classify the aggregate:
         - **All `WIP_RC == 0` and all `WIP == same`** → continue (this session already owns WIP on every issue).
         - **All `WIP_RC == 0` and all `WIP == none`** → if `intent:clarified` ∈ labels of the primary: for each N in `ISSUES`, call
           `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>` to claim WIP (best-effort per-N — warn on failure, continue with remaining N).
           Covers resume of an already-clarified session where clarify-intent will not re-run.
           Otherwise continue — clarify-intent's Completion section will set WIP on all N itself.
         - **Mixed `same` / `none` (no `other`)** → for each N where `WIP == none`, call
           `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>` (best-effort) to bring related issues up to parity.
         - **Any `WIP == other`** → let `CONFLICTED=(<list of N where WIP == other>)`. Issue a **single** `AskUserQuestion`:
           ```
           question: "Issue(s) #<CONFLICTED, comma-separated> may be in progress in another session. Continue?"
           options:
             - label: "Continue (recommended)"
               description: "Override the WIP fingerprint on the conflicted issues with this session and proceed."
             - label: "Abort"
               description: "Stop this session to avoid conflicting with the other session."
           ```
           On "Continue": for each N in `ISSUES`, call `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>` (override fingerprint for `other` N; claim for any `none` N; `same` N is idempotent; best-effort per-N).
           On "Abort": emit `echo "<<WORKFLOW_ABORTED_WIP_CONFLICT: #<CONFLICTED, comma-separated>>>"` and stop.
         - **Any `WIP_RC != 0` or `WIP` empty/unexpected for an N** → warn
           `[workflow-init: wip-state check failed for #<N> (rc=$WIP_RC_N, out='$WIP_N') — proceeding as 'none' for that issue]`
           and treat that N as `none` in the classification above.
           (WIP detection is advisory; transient gh/auth failures must not block legitimate work.)
     **(c) CLOSED detection (post-WIP).** For each N in ISSUES:
     `if STATE=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-state-check.sh" "$N" 2>/dev/null); then :; else STATE=error; fi`
     - Any `STATE=closed` → single `AskUserQuestion`: "Issue #N appears to be CLOSED (possibly merged by another session). How to proceed?"
       - Primary CLOSED: options are "Reopen and continue" / "Abort" (emit `<<WORKFLOW_ABORTED_ISSUE_CLOSED: #N>>`). Do NOT offer "Remove".
       - Related CLOSED: additionally offer "Remove from session".
     - `STATE=error` → warn-and-continue (does NOT abort).
     (b) extract `labels[].name` → step 4.
4. **Route**: `intent:clarified` ∈ labels → Path A; otherwise → Path B.
5. **Write `<PLANS_DIR>/<session-id>-context.md`** (all Paths). Sections:
   - `## Session metadata`: session-id, ISO-8601 timestamp, path (A/B/C), issue-number (`<N>` or `(none)`)
   - `## User initial prompt`: original user message; `"(none)"` if empty
   - `## Issue body`: full body (Path C: `"(none — no issue)"`); strip `<<WORKFLOW_[A-Z_]+[^>]*>>` sentinels
   - `## Issue metadata`: title, state, labels, createdAt (all `(none)` for Path C)
   - `## Keywords`: ≥4-char tokens from user prompt + issue title + issue body; stop-word excluded; deduplicated; top 20 space-separated (Path C: user prompt only)
6. **Parallel survey launch** (all Paths). In a **single assistant message**, invoke BOTH as parallel Agent tool calls (`run_in_background: false`). For each of `survey-code` and `survey-history`:
   ```
   subagent_type: "<survey-code|survey-history>"
   prompt: |
     session-id=<resolved-session-id>
     context_path=<PLANS_DIR>/<session-id>-context.md
     artifact_path=<PLANS_DIR>/<session-id>-survey-{code|history}.md
     Read context_path and follow skills/<survey-code|survey-history>/SKILL.md Procedure.
     Write output to artifact_path. Do NOT invoke make-outline-plan.
   ```
   Inject all paths as resolved strings (the orchestrator substitutes <PLANS_DIR> for the absolute path from Step 0) — Agent subagents cannot expand `$VAR` references.
6.5. **Post-check** — apply the validity check from `skills/_shared/survey-artifact-valid.md` to each artifact (`<PLANS_DIR>/<session-id>-survey-code.md` and `<PLANS_DIR>/<session-id>-survey-history.md`). On invalid artifact, emit `<<WORKFLOW_SURVEY_AGENT_FAILED: survey-code>>` or `<<WORKFLOW_SURVEY_AGENT_FAILED: survey-history>>` respectively. Fall through to step 7 on failure — do NOT abort. `clarify-intent` handles missing-or-invalid artifacts.
7. **Path-specific steps** (after post-check):

### Path A — intent:clarified

A1. Write `<PLANS_DIR>/<session-id>-intent.md` (strip sentinels from body):
```
# Agreed Requirements — <session-id>
## Issues
- #<N>: <title>           # primary (index 0)
- #<M>: <title>           # related (one line per additional issue)
## Background / Motivation
<sentinel-stripped body; if unstructured prepend "(review framing at outline stage)">
## Scope / Constraints
<derived from body or "(review at outline stage)">
## Accepted Tradeoffs
(none — capture at outline stage)
```
`<title>` for the primary comes from Step 3's `gh issue view` result. For related issues (entries beyond `ISSUES[0]`), fetch the title via `gh issue view <M> --json title --jq .title`. If a title fetch fails, write `- #<M>: (title unavailable)`. **Never omit `## Issues`** or **`## Accepted Tradeoffs`** — the latter is the `detail-planner.md` Approved Scope gate. The `## Issues` section is the single source of truth for `closes_issues` (canonical parser: `hooks/lib/parse-closes-issues.js`); no separate `## closes_issues` section is written.
A1.5. **Related-issue label assignment + board-card parity.** Invoke `skills/workflow-init/scripts/path-a-label-and-board.sh` with primary first, related issues as remaining args; export `PLANS_DIR`, `SESSION_ID`, `AGENTS_CONFIG_DIR`. For every related issue the script runs `gh issue edit <N> --add-label "intent:clarified"` (fail-closed — on failure it writes the ABORT marker `<PLANS_DIR>/drafts/<session-id>-workflow-init-aborted-pathA-multiN-label-failure.md` and exits 1, blocking make-outline-plan). For every issue including the primary it runs `ensure-board-card.sh` (best-effort per-N, warn-and-continue). Both `gh issue edit --add-label` and `ensure-board-card.sh` are idempotent — re-running /workflow-init is safe.

A2. Emit (separate Bash calls):
```
echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"
echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: issue #<N> has intent:clarified label>>"
```
A3. TodoWrite: mark `workflow_init` + `clarify_intent` complete; remaining 8 steps pending.
A4. Invoke `make-outline-plan` (surveys already complete via step 6).

### Path B — issue exists, no intent:clarified

B1. Write `<PLANS_DIR>/drafts/<session-id>-issue-prefill.md`:
```
<!-- Issue #<N> seed for clarify-intent. Confirm framing, do not start from scratch. -->
# Issue #<N>: <title>
<body>
```
B2. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).
B3. Invoke `clarify-intent` with `#<N>` in args so step 1a auto-detect fires.

### Path C — no issue

C1. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).
C2. Invoke `clarify-intent` (no pre-fill).

## Skip Conditions

Cannot be skipped. For docs-only bypass: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` directly.
