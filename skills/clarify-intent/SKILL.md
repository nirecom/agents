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

Apply `skills/_shared/resolve-plans-dir.md` once at the start of Procedure;
substitute the resolved absolute path for every `<PLANS_DIR>` placeholder
below. Reuse across all subsequent steps — do not re-resolve.

1. Read the user's request; identify the root question that unlocks all downstream decisions.

1a. **closes_issues auto-detect**: Scan for `#\d+`. Pre-fill file (step 1b) auto-satisfies this when it sets the issue number. Single unambiguous match → `closes_issues: [N]`. Multiple/ambiguous → ask in step 3 (counts toward 5-round cap). None → `closes_issues: []`. One issue per session.

1b. **Pre-fill detection**: Check `<PLANS_DIR>/drafts/<session-id>-issue-prefill.md` (written by `/workflow-init` Path B). If present: read it; treat body as Background/Scope seed; first AskUserQuestion: "Approve framing / Revise / Start over". Approve or Revise → skip background question. Start over → delete file, proceed normally.

2. `bash -c 'cd "$AGENTS_CONFIG_DIR" && get-config-var --is-off CONFIRM_OUTLINE on && echo OFF || echo ON'`. If OFF: add delivery-plan-direction question (required even past the 5-round cap).

3. Interview via `AskUserQuestion`: 1 question per call; include one **(recommended)** option; dependency order; max 5 rounds; unresolved branches → document as constraints.

4. Write `<PLANS_DIR>/<session-id>-intent.md` (Write tool, no mkdir). Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `YYYYMMDD-HHMMSS`. Sections (in order): optional `## Issue` (see below), Background/Motivation, Scope, Constraints, Interview Log (optional), `## closes_issues` (integer list or `(empty)`), `## Accepted Tradeoffs` (schema: `### <title>` heading + 1-paragraph rationale per entry; empty → write `(none)`). The `## Accepted Tradeoffs` section captures design decisions already settled — used by `extract-accepted-tradeoffs` to suppress re-raised concerns in later codex reviews.

   **`## Issue` section rules** (immediately after H1, before Background/Motivation):
   - **Path B** (issue known via auto-detect): read title from `context.md ## Issue metadata - title:`. Write `## Issue\n#<N>: <title>`.
   - **Path C** (no issue yet — `closes_issues` empty): OMIT. The section is backfilled by Completion Step 3 after `gh issue create` succeeds.
   - **context.md missing or title line absent**: OMIT. (Step 4 does not call `gh`; the title source is context.md, not a live gh call.)
   - Multiple issues (forward-compat): list form, one `- #<N>: <title>` per line.

5. Apply `skills/_shared/confirm-plan.md` protocol using `CONFIRM_INTENT`. Revise: update intent.md (re-run interview if scope changes significantly), loop back to protocol Step 1.

6. Check whether workflow-init's survey artifacts exist (both paths are absolute):
   - Both present → surveys are already complete. Optionally invoke `/deep-research`
     if external knowledge is required; otherwise emit:
     `echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init>>"`
   - Either missing (workflow-init survey Agent failed) → invoke the missing survey(s):
     - Missing `<session-id>-survey-code.md` → invoke `/survey-code`
     - Missing `<session-id>-survey-history.md` → invoke `/survey-history`
   This step is verification only — skill exits exclusively via the Completion section below. Do not invoke `/make-outline-plan` from here.

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
3. **Empty** (Path C — skip when `NON_GITHUB=1`): `gh issue create --title "<~50 chars>" --body "<Background + Scope + Constraints + auto-created footer>" --label "intent:clarified"`. On success: (a) update `closes_issues` from `(empty)` to `- <N>`; (b) insert `## Issue\n#<N>: <title>` immediately after the H1 of intent.md using Read + Edit (title is the `--title` arg from this call — no re-fetch needed). Then: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set <N>` with the freshly created N (same exit-code handling as above). On failure: warn, leave `closes_issues` as `(empty)` and omit `## Issue`.
4. **Multiple**: abort, cite `rules/github-issues.md`.

Then:

<!-- closes_issues guard: canonical parser is hooks/lib/parse-closes-issues.js — do not reimplement. -->

0. **Tracking-issue guard** — at most 2 automatic passes; further failures escalate to AskUserQuestion.

   `GUARD_ATTEMPT` is persisted to a session-local file under the workflow-plans directory so that the counter survives across `/issue-create` invocations (which run as separate skill contexts and may churn LLM working memory):

   `<session-id>` below is the same value used in Step 4 of the Procedure (read from `$CLAUDE_ENV_FILE` or the `YYYYMMDD-HHMMSS` fallback) — reuse it, do not re-resolve.

   ```bash
   # Pre: NON_GITHUB is already set by the non-GitHub gate at the top of Completion.
   #      Do NOT call is-github-dotcom-remote a second time here.
   PLANS_DIR="${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
   COUNTER_FILE="$PLANS_DIR/<session-id>-guard-attempt.tmp"
   GUARD_ATTEMPT=$(cat "$COUNTER_FILE" 2>/dev/null || echo 0)

   GUARD_FLAG=""
   if [ "${NON_GITHUB:-0}" = "1" ]; then
       GUARD_FLAG="--non-github"
   fi
   if bash "$AGENTS_CONFIG_DIR/bin/github-issues/check-closes-issues-nonempty.sh" \
           "$PLANS_DIR/<session-id>-intent.md" $GUARD_FLAG; then
       GUARD_RC=0
       rm -f "$COUNTER_FILE"   # success — unlink counter
   else
       GUARD_RC=$?
       GUARD_ATTEMPT=$((GUARD_ATTEMPT + 1))
       echo "$GUARD_ATTEMPT" > "$COUNTER_FILE"   # persist for next /issue-create round-trip
   fi
   ```

   - **`GUARD_RC == 0`** → counter unlinked; proceed to step 1 below (emit `<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>`).
   - **`GUARD_RC != 0` AND `GUARD_ATTEMPT == 1`** (first failure) → STOP. Do NOT
     emit `<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>`. Invoke `/issue-create` to
     create a tracking issue. After `/issue-create` succeeds and returns issue N:
     (a) update `intent.md`'s `## closes_issues` from `(empty)` to `- N` using Read + Edit;
     (b) insert `## Issue\n#N: <title>` after the H1 if absent (same as Reconcile step 3 Path C).
     Then re-run **only this guard step (step 0)** — do NOT re-enter the full "Reconcile with
     GitHub" block (doing so would invoke `gh issue create` a second time and create a duplicate
     issue). Counter file holds `1`.
   - **`GUARD_RC != 0` AND `GUARD_ATTEMPT >= 2`** (`/issue-create` already ran
     once but `closes_issues` is still empty) → DO NOT emit any new sentinel.
     Open `AskUserQuestion` with prompt:
     > "Tracking-issue guard failed twice. `closes_issues` is still empty after `/issue-create`. How should we recover?"

     Options:
     - **"Retry `/issue-create` once more"** — invoke `/issue-create` again, then re-run this guard (counter stays at 2; next failure re-asks).
     - **"Manual recovery"** — instruct the user to run `gh issue create` manually and edit `## closes_issues` in `intent.md` directly. When the user confirms completion, re-run the guard (which on success unlinks the counter file).
     - **"Abort workflow"** — `rm -f "$COUNTER_FILE"`, emit `echo "<<WORKFLOW_RESET_FROM_clarify_intent>>"`, and exit the skill.

     Note (§2 Orthogonality): no new sentinel is introduced here. Existing workflow sentinels are binary (`*_COMPLETE` = stage finished, `*_NOT_NEEDED` = stage skipped); a `BLOCKED` third axis would break the workflow-sentinel class invariant. Retry-exhaustion is treated as an interactive recovery prompt, not a workflow state transition.

1. `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
2. TodoWrite: mark `workflow_init` + `clarify_intent` completed; remaining steps pending.
3. Check whether workflow-init's survey artifacts exist:
   - Both present → emit `WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init`.
   - Either missing → invoke the missing survey(s) directly before proceeding.
   Optionally invoke `/deep-research` if external knowledge is required.
   Then invoke `/make-outline-plan`.
