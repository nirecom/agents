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

3. **Fetch issue**: `gh issue view <N> --json number,title,body,labels,state`
   - Fails → `AskUserQuestion` "Continue as Path C?" — yes: Path C; no: abort.
   - `CLOSED` → ask: reopen / pick different #N / continue as Path C.
   - `OPEN` → extract `labels[].name` → step 4.

4. **Route**: `intent:clarified` ∈ labels → Path A; otherwise → Path B.

---

### Path A — intent:clarified

A1. Write `~/.workflow-plans/<session-id>-intent.md` (strip `<<WORKFLOW_[A-Z_]+[^>]*>>` from body):
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

A2.5. `cc-session-title set-issue <N> "<title>"` where `<title>` is the `.title` field
      from the JSON fetched in **global step 3** (already in scope before Path A executed).
      Separate Bash call.

A3. TodoWrite: mark `workflow_init` + `clarify_intent` complete; remaining 8 steps pending.

A4. Invoke `survey-code` and/or `survey-history` and/or `deep-research` if needed (or `<<WORKFLOW_RESEARCH_NOT_NEEDED: reason>>`), then `make-outline-plan`.

---

### Path B — issue exists, no intent:clarified

B1. Write `~/.workflow-plans/drafts/<session-id>-issue-prefill.md`:
```
<!-- Issue #<N> seed for clarify-intent. Confirm framing, do not start from scratch. -->
# Issue #<N>: <title>
<body>
```

B2. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).

B2.5. `cc-session-title set-issue <N> "<title>"` (title from global step 3 — same provenance
      as Path A). Separate Bash call.

B3. Invoke `clarify-intent` with `#<N>` in args so step 1a auto-detect fires.

---

### Path C — no issue

C1. `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` (separate Bash call).

C2. Invoke `clarify-intent` (no pre-fill).

---

## Skip Conditions

Cannot be skipped. For docs-only bypass: `echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"` directly.
