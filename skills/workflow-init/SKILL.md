---
name: workflow-init
description: Routing entry point for the Claude Code workflow. Inspects #N and the intent:clarified label: Path A (skip interview), Path B (pre-fill interview), Path C (full interview + auto-create).
model: sonnet
---

IMPORTANT: Interactive session required. Hard-fail in non-interactive contexts (`claude -p`, `/loop`, subagents).

## Purpose

First step of every workflow session. Routes on GH issue context: Path A (`#N` + `intent:clarified`) skips interview; Path B (`#N`, no label) pre-fills interview; Path C (no `#N`) runs full interview and auto-creates a tracking issue.

## Procedure

1. **Detect `#N`** (regex `#\d+`): 0 → Path C; 1 → step 2; 2+ → `AskUserQuestion` to pick one.
2. **Session ID**: read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `date +%Y%m%d-%H%M%S`.
3. **Fetch issue**: `gh issue view <N> --json number,title,body,labels,state,createdAt`
   - Fails → `AskUserQuestion` "Continue as Path C?" — yes: Path C; no: abort.
   - `CLOSED` → ask: reopen / pick different #N / continue as Path C.
   - `OPEN` → extract `labels[].name` → step 4.
4. **Route**: `intent:clarified` ∈ labels → Path A; otherwise → Path B.
5. **Write `~/.workflow-plans/<session-id>-context.md`** (all Paths). Sections:
   - `## Session metadata`: session-id, ISO-8601 timestamp, path (A/B/C), issue-number (`<N>` or `(none)`)
   - `## User initial prompt`: original user message; `"(none)"` if empty
   - `## Issue body`: full body (Path C: `"(none — no issue)"`); strip `<<WORKFLOW_[A-Z_]+[^>]*>>` sentinels
   - `## Issue metadata`: title, state, labels, createdAt (all `(none)` for Path C)
   - `## Keywords`: ≥4-char tokens from user prompt + issue title + issue body; stop-word excluded; deduplicated; top 20 space-separated (Path C: user prompt only)
6. **`cc-session-title set-issue <N> "<title>"`** (Path A/B only; Path C: skip). Separate Bash call.
7. **Parallel survey launch** (all Paths). In a **single assistant message**, invoke BOTH as parallel Agent tool calls (`run_in_background: false`). For each of `survey-code` and `survey-history`:
   ```
   subagent_type: "<survey-code|survey-history>"
   prompt: |
     session-id=<resolved-session-id>
     context_path=<full absolute path to <session-id>-context.md>
     artifact_path=<full absolute path to <session-id>-survey-{code|history}.md>
     Read context_path and follow skills/<survey-code|survey-history>/SKILL.md Procedure.
     Write output to artifact_path. Do NOT invoke make-outline-plan.
   ```
   Inject all paths as resolved strings — Agent subagents cannot expand `$VAR` references.
7.5. **Post-check** (separate Bash calls): verify each artifact exists at its absolute path.
   - `<session-id>-survey-code.md` missing → `echo "<<WORKFLOW_SURVEY_AGENT_FAILED: survey-code>>"`
   - `<session-id>-survey-history.md` missing → `echo "<<WORKFLOW_SURVEY_AGENT_FAILED: survey-history>>"`
   - On failure: fall through to step 8 — do NOT abort. `clarify-intent` handles missing artifacts.
8. **Path-specific steps** (after post-check):

### Path A — intent:clarified

A1. Write `~/.workflow-plans/<session-id>-intent.md` (strip sentinels from body):
```
# Agreed Requirements — <session-id>
## Background / Motivation
<sentinel-stripped body; if unstructured prepend "(review framing at outline stage)">
## Scope / Constraints
<derived from body or "(review at outline stage)">
## closes_issues
- <N>
```
A2. Emit (separate Bash calls):
```
echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"
echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: issue #<N> has intent:clarified label>>"
```
A3. TodoWrite: mark `workflow_init` + `clarify_intent` complete; remaining 8 steps pending.
A4. Invoke `make-outline-plan` (surveys already complete via step 7).

### Path B — issue exists, no intent:clarified

B1. Write `~/.workflow-plans/drafts/<session-id>-issue-prefill.md`:
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
