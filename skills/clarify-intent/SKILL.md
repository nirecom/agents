---
name: clarify-intent
description: Conduct a decision-tree interview with the user to lock in requirements, motivation, scope, and non-goals before planning.
model: sonnet
---

IMPORTANT: Interactive session required. Hard-fail in non-interactive contexts (`claude -p`, `/loop`, subagents).

## Skip Conditions

Emit `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: reason>>"` when a prior `*-intent.md` covers the request, or the task is self-contained and unambiguous.

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

1. Read the user's request; identify the root question that unlocks all downstream decisions.

1a. **closes_issues auto-detect**: Scan for `#\d+`. Pre-fill file (step 1b) auto-satisfies this when it sets the issue number. Single unambiguous match → `closes_issues: [N]`. Multiple/ambiguous → ask in step 3 (counts toward 5-round cap). None → `closes_issues: []`. One issue per session.

1b. **Pre-fill detection**: Check `<PLANS_DIR>/drafts/<session-id>-issue-prefill.md` (written by `/workflow-init` Path B). If present: read it; treat body as Background/Scope seed; first AskUserQuestion: "Approve framing / Revise / Start over". Approve or Revise → skip background question. Start over → delete file, proceed normally.

2. `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'`. If OFF: add delivery-plan-direction question (required even past the 5-round cap).

3. Interview via `AskUserQuestion`: 1 question per call; include one **(recommended)** option; dependency order; max 5 rounds; unresolved branches → document as constraints.

4. Write `<PLANS_DIR>/<session-id>-intent.md` (Write tool, no mkdir). Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `YYYYMMDD-HHMMSS`. Sections: Background/Motivation, Scope, Constraints, Interview Log (optional), `## closes_issues` (integer list or `(empty)`).

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

After confirm-plan protocol returns, run the non-GitHub gate:

```bash
NON_GITHUB=0
"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"; rc=$?
case $rc in
  0) ;;                # GitHub — proceed with gh
  1) NON_GITHUB=1 ;;   # non-GitHub — skip gh invocation
  *) ;;                # unknown (rc=2) — fail-open, keep existing behavior
esac
if [ "${NON_GITHUB:-0}" = "1" ]; then
  echo "[GITHUB_ISSUES disabled: non-GitHub remote detected, skipping clarify-intent gh issue ops]"
fi
```

Reconcile with GitHub (steps 2–3 require `NON_GITHUB=0`; skip them when `NON_GITHUB=1`):

1. Read `closes_issues` from intent.md.
2. **One issue N** (skip when `NON_GITHUB=1`): `gh issue edit <N> --add-label "intent:clarified"`. On failure: warn `[clarify-intent]`, add `intent:clarified-label-failed: <reason>` under Constraints.
   Then (single-N only): `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>`.
   Exit 1 (Status set failure) → warn `[clarify-intent: wip-state set failed — Projects v2 Status not updated]` and continue.
   Exit 2 (missing env / session-id) → same warn and point at `wip-state setup` / `CLAUDE_ENV_FILE`.
3. **Empty** (Path C — skip when `NON_GITHUB=1`): `gh issue create --title "<~50 chars>" --body "<Background + Scope + Constraints + auto-created footer>" --label "intent:clarified"`. On success: update closes_issues. Then: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>` with the freshly created N (same exit-code handling as above). On failure: warn, leave as `(empty)`.
4. **Multiple**: abort, cite `rules/github-issues.md`.

Then:
1. `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
2. TodoWrite: mark `workflow_init` + `clarify_intent` completed; remaining steps pending.
3. Check whether workflow-init's survey artifacts exist:
   - Both present → emit `WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init`.
   - Either missing → invoke the missing survey(s) directly before proceeding.
   Optionally invoke `/deep-research` if external knowledge is required.
   Then invoke `make-outline-plan`.
