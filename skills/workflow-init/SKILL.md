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

Before any tool call below that references <PLANS_DIR>, run the following Bash command exactly once:

```bash
PLANS_DIR=$(bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
              || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}")
printf 'PLANS_DIR=%s\n' "$PLANS_DIR"
```

Capture the printed absolute path and substitute it for every <PLANS_DIR>
placeholder in the remainder of this SKILL.md. Subagent prompts must receive
the resolved absolute path as a literal string (subagents cannot expand $VAR).
Reuse across all subsequent steps in this skill invocation — do not re-resolve.

Canonical documentation: skills/_shared/resolve-plans-dir.md.

### Step 0.5 — Non-GitHub remote gate

```bash
NON_GITHUB=0
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
case $rc in
  0) ;;                # GitHub — proceed with gh
  1) NON_GITHUB=1 ;;   # non-GitHub — skip gh invocation
  *) ;;                # unknown (rc=2) — fail-open, keep existing behavior
esac
if [ "${NON_GITHUB:-0}" = "1" ]; then
  echo "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping workflow-init issue routing]"
fi
```

When `NON_GITHUB=1`: skip steps 1–4 (issue detection, `gh issue view`, and route logic) and proceed directly as **Path C**. Steps 5–7 (context.md write, survey launch, Path C path-specific steps C1–C2) run as normal.

When `NON_GITHUB=0` or exit 2 (unknown, fail-open): continue with steps 1–7 as normal.

1. **Detect `#N`** (regex `#\d+`): 0 → Path C; 1 → step 2; 2+ → `AskUserQuestion` to pick one.
2. **Session ID**: read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `date +%Y%m%d-%H%M%S`.
3. **Fetch issue**: `gh issue view <N> --json number,title,body,labels,state,createdAt`
   - Fails → `AskUserQuestion` "Continue as Path C?" — yes: Path C; no: abort.
   - `CLOSED` → ask: reopen / pick different #N / continue as Path C.
   - `OPEN` →
     (a) `WIP=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" check <N> 2>/dev/null)`
         and capture exit code `WIP_RC=$?`.
         - `WIP_RC == 0` and `WIP == same` → continue (this session already owns WIP).
         - `WIP_RC == 0` and `WIP == none` → if `intent:clarified` ∈ labels: call
           `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>` to claim WIP
           (covers resume of an already-clarified issue, where clarify-intent will not run).
           Otherwise continue — clarify-intent's Completion section will set WIP itself.
         - `WIP_RC == 0` and `WIP == other` → `AskUserQuestion`:
           ```
           question: "Issue #<N> may be in progress in another session. Continue?"
           options:
             - label: "Continue (recommended)"
               description: "Override the WIP fingerprint with this session and proceed."
             - label: "Abort"
               description: "Stop this session to avoid conflicting with the other session."
           ```
           On "Continue": call `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>` (overrides fingerprint). On "Abort": emit `echo "<<WORKFLOW_ABORTED_WIP_CONFLICT: #<N>>>"` and stop.
         - `WIP_RC != 0` or `WIP` empty/unexpected → warn
           `[workflow-init: wip-state check failed (rc=$WIP_RC, out='$WIP') — proceeding as 'none']`
           and continue without prompting.
           (WIP detection is advisory; transient gh/auth failures must not block legitimate work.)
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
6.5. **Post-check** (separate Bash calls): verify each artifact exists at its absolute path.
   - `<session-id>-survey-code.md` missing → `echo "<<WORKFLOW_SURVEY_AGENT_FAILED: survey-code>>"`
   - `<session-id>-survey-history.md` missing → `echo "<<WORKFLOW_SURVEY_AGENT_FAILED: survey-history>>"`
   - On failure: fall through to step 7 — do NOT abort. `clarify-intent` handles missing artifacts.
7. **Path-specific steps** (after post-check):

### Path A — intent:clarified

A1. Write `<PLANS_DIR>/<session-id>-intent.md` (strip sentinels from body):
```
# Agreed Requirements — <session-id>
## Issue
#<N>: <title>
## Background / Motivation
<sentinel-stripped body; if unstructured prepend "(review framing at outline stage)">
## Scope / Constraints
<derived from body or "(review at outline stage)">
## closes_issues
- <N>
```
`<title>` is the issue title from the Step 3 `gh issue view --json title` result (already in scope; no re-read required). If the title is empty or unavailable, OMIT the `## Issue` section entirely.
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
