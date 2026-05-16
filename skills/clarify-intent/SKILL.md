---
name: clarify-intent
description: Conduct a decision-tree interview with the user to lock in requirements, motivation, scope, and non-goals before planning.
model: sonnet
---

IMPORTANT: Interactive session required. Hard-fail in non-interactive contexts (`claude -p`, `/loop`, subagents).

## Skip Conditions

Emit `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: reason>>"` when a prior `*-intent.md` covers the request, or the task is self-contained and unambiguous.

## Procedure

1. Read the user's request; identify the root question that unlocks all downstream decisions.

1a. **closes_issues auto-detect**: Scan for `#\d+`. Pre-fill file (step 1b) auto-satisfies this when it sets the issue number. Single unambiguous match → `closes_issues: [N]`. Multiple/ambiguous → ask in step 3 (counts toward 5-round cap). None → `closes_issues: []`. One issue per session.

1b. **Pre-fill detection**: Check `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/drafts/<session-id>-issue-prefill.md` (written by `/workflow-init` Path B). If present: read it; treat body as Background/Scope seed; first AskUserQuestion: "Approve framing / Revise / Start over". Approve or Revise → skip background question. Start over → delete file, proceed normally.

2. `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'`. If OFF: add delivery-plan-direction question (required even past the 5-round cap).

3. Interview via `AskUserQuestion`: 1 question per call; include one **(recommended)** option; dependency order; max 5 rounds; unresolved branches → document as constraints.

4. Write `${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<session-id>-intent.md` (Write tool, no mkdir). Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `YYYYMMDD-HHMMSS`. Sections: Background/Motivation, Scope, Constraints, Interview Log (optional), `## closes_issues` (integer list or `(empty)`).

5. Apply `skills/_shared/confirm-plan.md` protocol using `CONFIRM_INTENT`. Revise: update intent.md (re-run interview if scope changes significantly), loop back to protocol Step 1.

6. Check whether workflow-init's survey artifacts exist (both paths are absolute):
   - Both present → surveys are already complete. Optionally invoke `/deep-research`
     if external knowledge is required; otherwise emit:
     `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init>>"`
   - Either missing (workflow-init survey Agent failed) → invoke the missing survey(s):
     - Missing `<session-id>-survey-code.md` → invoke `/survey-code`
     - Missing `<session-id>-survey-history.md` → invoke `/survey-history`
   Then invoke `/make-outline-plan`.

## Completion

After confirm-plan protocol returns, reconcile with GitHub:

1. Read `closes_issues` from intent.md.
2. **One issue N**: `gh issue edit <N> --add-label "intent:clarified"`. On failure: warn `[clarify-intent]`, add `intent:clarified-label-failed: <reason>` under Constraints.
   Then: `cc-session-title set-issue <N> "$(gh issue view <N> --json title --jq .title)"` (idempotent; safe to re-run if title already set by workflow-init).
3. **Empty** (Path C — no issue): `gh issue create --title "<~50 chars>" --body "<Background + Scope + Constraints + auto-created footer>" --label "intent:clarified"`. On success: update closes_issues. On failure: warn, leave as `(empty)`.
   Then: `cc-session-title set-issue <N> "<title used in --title flag>"`.
4. **Multiple**: abort, cite `rules/github-issues.md`.

Then:
1. `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
2. TodoWrite: mark `workflow_init` + `clarify_intent` completed; remaining steps pending.
3. Check whether workflow-init's survey artifacts exist:
   - Both present → emit `WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init`.
   - Either missing → invoke the missing survey(s) directly before proceeding.
   Optionally invoke `/deep-research` if external knowledge is required.
   Then invoke `make-outline-plan`.
