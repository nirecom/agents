---
name: clarify-intent
description: Conduct a decision-tree interview with the user to lock in requirements, motivation, scope, and non-goals before planning.
model: sonnet
---

IMPORTANT: Interactive session required. Hard-fail in non-interactive contexts (`claude -p`, `/loop`, subagents).

## Skip Conditions

Emit `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: reason>>"` when a prior `*-intent.md` covers the request, or the task is self-contained and unambiguous.

## Procedure

Apply `skills/_shared/resolve-plans-dir.md` once at the start of Procedure;
substitute the resolved absolute path for every `<PLANS_DIR>` placeholder
below. Reuse across all subsequent steps — do not re-resolve.

CI-1. Read the user's request; identify the root question that unlocks all downstream decisions.

CI-1a. **closes_issues auto-detect**: Scan for `(?:[a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)?)?#\d+` (detects all three forms: `#N`, `repo#N`, `owner/repo#N`). Pre-fill file (CI-1b) auto-satisfies this when it sets the issue number. Single unambiguous match → `closes_issues: [N]`. Multiple matches → record all in insertion order (`closes_issues: [N1, N2, ...]`). None → `closes_issues: []`. See `rules/github-issues.md` "Session model" for the canonical N-issue relation.

CI-1b. **Pre-fill detection**: Check `<PLANS_DIR>/<session-id>-issue-prefill.md` (written by `/workflow-init` Path B). If present: read it; treat body as Background/Scope seed and proceed to CI-2 (CONFIRM_OUTLINE check) normally. During the interview in CI-3, the background question is auto-skipped since the prefill body serves as the background. No AskUserQuestion — users who want to discard the issue framing say so via free text during the interview.

CI-2. Check via Bash: `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_OUTLINE on'`. If stdout is `OFF`: add delivery-plan-direction question (required even past the 5-round cap). **Scope constraint:** the delivery-plan-direction question MUST cover execution order / staging priority only — it MUST NOT ask about PR count or bundling; `rules/github-issues.md` fixes `1 session = 1 PR` as a non-negotiable invariant.

CI-2a. Aggregate candidate class members per `reference/aggregate-class-members.md`.

CI-2b. **Companion-issue re-search.** Skip when `closes_issues` is empty (Path C). Run `bash "$AGENTS_CONFIG_DIR/skills/clarify-intent/scripts/companion-search.sh" --seed "${closes_issues[0]}" --exclude "$(IFS=,; echo "${closes_issues[*]}")"`. Exit 1 → skip. Exit 0: for each TSV line (`<N>\t<title>\t<reason>\t<state>`), one `AskUserQuestion`: "Add #<N> (<title>) as a companion issue for this session? Reason: <reason>" — options "Yes (add)" / "No (skip)". Accepted `#M` appended to `closes_issues` before CI-4 writes intent.md. On "Yes (add)": immediately call `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-set-single.sh" <M>`; exit-code handling matches the Completion WIP-set loop (exit 0 `META_SKIP` → log; exit 1 → warn-continue; exit 2 `RC2` → AskUserQuestion "Skip and continue / Abort").

CI-3. Interview via `AskUserQuestion`: 1 question per call; include one **(recommended)** option; dependency order; max 5 rounds; unresolved branches → document as constraints.

   **Class members proposal (when candidates ≥ 1):** run `reference/class-members-proposal.md`.

CI-3a. **Decomposition probe** (run after CI-3 scope is agreed, before writing intent.md and CI-3b):
   - Read `skills/_shared/judge-decomposition.md` to load the signal table.
   - Evaluate all D1–D5 signals against the agreed scope. Do not short-circuit on the first match.
   - Emit in Claude text output: `VERDICT: wf-meta | <signal IDs>` or `VERDICT: wf-code | none`
   - **If VERDICT is `wf-code`**: proceed silently to CI-4 (no user prompt).
   - **If VERDICT is `wf-meta`** (≥2 signals triggered):
     - Compose a concrete sub-deliverable list: one bullet per natural split point identified during the signals evaluation.
     - Present it via `AskUserQuestion`:
       - Prompt: "This scope is a candidate for session decomposition. Proposed breakdown: [sub-deliverable bullets]. Proceed in WF-META mode (planning phase only, no implementation this session)?"
       - Options: "Yes, proceed as WF-META (planning only)" / "No, implement everything in this session (WF-CODE)"
     - **If user chooses WF-META**:
       - Read `$CLAUDE_ENV_FILE` to resolve `SESSION_ID` (same value as used in CI-4).
       - Run `bin/workflow/set-workflow-type "$SESSION_ID" "wf-meta"` (separate Bash call).
       - Proceed to CI-4 (write intent.md as normal — scope is already agreed).
       - After CI-5 confirm-plan, route to `make-outline-plan` as normal; the oracle will auto-skip the 9 non-applicable WF-CODE steps (includes `detail`).
     - **If user chooses WF-CODE**: proceed silently to CI-4.

CI-3b. **Multi-repo probe** (run after CI-3a, before writing intent.md):
   - Skip silently when `closes_issues` contains no cross-repo references (no `owner/repo#N` or bare `repo#N` form). Proceed to CI-4.
   - Determine primary repo: run `git remote get-url origin` and normalize to `owner/repo` format.
   - Collect all cross-repo entries from `closes_issues`; normalize bare `repo#N` to `owner/repo#N` using the primary owner; deduplicate by insertion order.
   - For each unique sibling `owner/repo` (i.e. not the primary repo): call `AskUserQuestion` once: "セッションに `<owner/repo>` のイシューが含まれています。このセッションで使用するそのリポジトリのリンク worktree の絶対パスを入力してください（スキップする場合は空白のままにしてください）。"
   - Non-empty answer → record as `{repo: "<owner/repo>", worktree_path: "<answer>"}`.
   - Empty / skipped → record `<owner/repo> の sibling worktree 不在` under `## Constraints` in intent.md.
   - After all probes: CI-4 writes a `## worktrees` section with the collected results.

CI-4. Write `<PLANS_DIR>/<session-id>-intent.md` (Write tool, no mkdir). Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `YYYYMMDD-HHMMSS`. Sections (in order): `## Issues` (mandatory — single SSOT for `closes_issues`; canonical parser: `hooks/lib/parse-closes-issues.js`), Background/Motivation, Scope, Constraints, Interview Log (optional), `## Class members` (mandatory — see schema below), `## Accepted Tradeoffs` (schema: `### <title>` heading + 1-paragraph rationale per entry; empty → write `(none)`), `## worktrees` (optional — omit for single-repo sessions; include when CI-3b collected sibling worktree paths). The `## Accepted Tradeoffs` section captures design decisions already settled — used by `extract-mandatory-sections` to suppress re-raised concerns in later codex reviews.

   **`## worktrees` schema (optional section):** written by CI-4 when CI-3b collected at least one non-empty worktree path. Omit entirely for single-repo sessions. Format per entry: one `- repo: <owner/repo>` line followed by `  worktree_path: <absolute path>` (2-space indent) on the next line.

   **`## Class members` schema (mandatory section):** appears immediately before
   `## Accepted Tradeoffs`. Format per member:
   ```
   - <name>: <description> — triage: <MUST | OPTIONAL | NA>
   ```
   Triage enum (exact strings — protocol violation otherwise):
   - `triage: MUST` — symmetric change required for class consistency; planner MUST cover.
   - `triage: OPTIONAL` — related; planner SHOULD address or explicitly defer in `## Confirmed non-goals`.
   - `triage: NA` — sibling exists but orthogonal; out of scope for this task.

   When no candidates were detected: write `- (none detected)` (no triage field).

   **`## Issues` section rules** (immediately after H1, before Background/Motivation — mandatory; this is the single SSOT, no separate `## closes_issues` section is written):
   - One entry line per issue in `closes_issues`, in the order found. Current-repo issues use `- #<N>: <title>`. Cross-repo issues use `- repo#<N>: <title>` (short form) or `- owner/repo#<N>: <title>` (full form, preferred when owner is known).
   - **Path B** (issue known via auto-detect): read the first entry's title from `context.md ## Issue metadata - title:`; for any additional issues, fetch via `gh issue view <N> --json title --jq .title`. If a fetch fails, write `- #<N>: (title unavailable)`. For cross-repo entries, pass `--repo <owner/repo>` to the fetch.
   - **Path C** (no issue yet — empty `closes_issues`): write an EMPTY `## Issues` section as placeholder:
     ```
     ## Issues
     (none — pending issue creation or NON_GITHUB)
     ```
     Completion Step 3 backfills `- #<N>: <title>` after a successful `gh issue create`. The empty placeholder satisfies `assemble-mandatory.sh`'s "heading must be present" invariant.
   - **context.md missing or title line absent**: write `- #<N>: (title unavailable)`.

CI-5. Apply `skills/_shared/confirm-plan.md` protocol using `CONFIRM_INTENT`. On the `ON` path: in the SAME response as `echo "<<WORKFLOW_CONFIRM_INTENT: <one-line summary>>>"`, also include the next tool_use — the GitHub reconciliation Bash block from Completion, then the `make-outline-plan` Skill invocation. Do NOT end the response on the CONFIRM echo. Revise: update intent.md (re-run interview if scope changes significantly), loop back to protocol Step 1.

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

1. Read `closes_issues` from intent.md (canonical parser: `hooks/lib/parse-closes-issues.js`).
2. **Non-empty `closes_issues`** (skip when `NON_GITHUB=1`):
   - **CLOSED state check for all entries.** For each issue N in `closes_issues` (in insertion order):
     `if STATE=$(bash "$AGENTS_CONFIG_DIR/bin/github-issues/issue-state-check.sh" "$N" 2>/dev/null); then :; else STATE=error; fi`
     - CLOSED: `AskUserQuestion` "Issue #N is CLOSED. How to proceed?" — options: "Reopen and continue" / "Remove from closes_issues and continue" (offered only when `len(closes_issues) >= 2`; Read + Edit intent.md to remove N) / "Abort session".
     - `error` → warn and continue.
   - **Label all entries.** For each issue N in `closes_issues` (in insertion order):
     `gh issue edit <N> --add-label "intent:clarified"`.
     On failure for any N: warn `[clarify-intent]`, add `intent:clarified-label-failed: #<N>: <reason>` under Constraints. Continue with the remaining entries (best-effort per-N).
   - **WIP set for all entries.** For each N in `closes_issues` (in insertion order): `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-set-single.sh" <N>`. Exit 0 (`META_SKIP`): log `[clarify-intent: skipping WIP set for #<N> — meta label detected]`. Exit 1 (`WARN_CONTINUE`): warn `[clarify-intent: wip-state set failed for #<N> — Projects v2 Status not updated]` and continue. Exit 2 (`RC2`): `AskUserQuestion` "WIP set rc=2 for #<N> (session-id/env failed — neither $CLAUDE_ENV_FILE nor $CLAUDE_SESSION_ID resolvable; conflict detection broken). How to proceed?" → "Skip and continue (acknowledge risk)" → warn + continue; "Abort session" → `echo "<<WORKFLOW_ABORTED_WIP_SET_RC2: #<N>>>"` + stop.
     Every issue in `closes_issues` receives its own WIP fingerprint so cross-session conflict detection covers all entries symmetrically (see `rules/github-issues.md` "Session model").
   - **Board-card parity for all entries.** For each issue N in `closes_issues` (in insertion order):
     `bash "$AGENTS_CONFIG_DIR/bin/github-issues/ensure-board-card.sh" <N>`.
     Best-effort per-N — warn and continue on non-zero exit. Runs independently of `wip-state.sh set` so session-id-resolution failures cannot strand any issue without a board card. The primitive is idempotent — running it for an issue already on the board with the correct Content Date is a no-op.
3. **Empty** (Path C — skip when `NON_GITHUB=1`): `gh issue create --title "<~50 chars>" --body "<Background + Scope + Constraints + auto-created footer>" --label "intent:clarified"`. On success: backfill the `## Issues` placeholder body from `(none — pending issue creation or NON_GITHUB)` to `- #<N>: <title>` using Read + Edit (title is the `--title` arg from this call — no re-fetch needed). Then: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/wip-set-single.sh" <N>` (same exit-code handling as the WIP-set-for-all-entries loop above). Then `bash "$AGENTS_CONFIG_DIR/bin/github-issues/ensure-board-card.sh" <N>` (best-effort). On `gh issue create` failure: warn, leave the `## Issues` placeholder body unchanged.

Then:

<!-- closes_issues guard: canonical parser is hooks/lib/parse-closes-issues.js — do not reimplement. -->

CI-C0. **Tracking-issue guard** — at most 2 automatic passes; further failures escalate to AskUserQuestion.

   `GUARD_ATTEMPT` is persisted to a session-local file under the workflow-plans directory so that the counter survives across `/issue-create` invocations (which run as separate skill contexts and may churn LLM working memory):

   `<session-id>` below is the same value used in CI-4 of the Procedure (read from `$CLAUDE_ENV_FILE` or the `YYYYMMDD-HHMMSS` fallback) — reuse it, do not re-resolve.

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

   - **`GUARD_RC == 0`** → counter unlinked; proceed to CI-C1 below (emit `<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>`).
   - **`GUARD_RC == 1` AND `GUARD_ATTEMPT == 1`** (first failure) → STOP. Do NOT
     emit `<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>`. Invoke `/issue-create` to
     create a tracking issue. After `/issue-create` succeeds and returns issue N,
     backfill the `## Issues` section body in `intent.md` from
     `(none — pending issue creation or NON_GITHUB)` to `- #N: <title>` using Read + Edit
     (same shape as Reconcile CI-C3 Path C).
     Then re-run **only this guard step (CI-C0)** — do NOT re-enter the full "Reconcile with
     GitHub" block (doing so would invoke `gh issue create` a second time and create a duplicate
     issue). Counter file holds `1`.
   - **`GUARD_RC == 1` AND `GUARD_ATTEMPT >= 2`** (`/issue-create` already ran
     once but `closes_issues` is still empty) → DO NOT emit any new sentinel.
     Open `AskUserQuestion` with prompt:
     > "Tracking-issue guard failed twice. `closes_issues` is still empty after `/issue-create`. How should we recover?"

     Options:
     - **"Retry `/issue-create` once more"** — invoke `/issue-create` again, then re-run this guard (counter stays at 2; next failure re-asks).
     - **"Manual recovery"** — instruct the user to run `gh issue create` manually and edit `## Issues` in `intent.md` directly. When the user confirms completion, re-run the guard (which on success unlinks the counter file).
     - **"Abort workflow"** — `rm -f "$COUNTER_FILE"`, emit `echo "<<WORKFLOW_RESET_FROM_clarify_intent>>"`, and exit the skill.

     Note (§4 Orthogonality): no new sentinel is introduced here. Existing workflow sentinels are binary (`*_COMPLETE` = stage finished, `*_NOT_NEEDED` = stage skipped); a `BLOCKED` third axis would break the workflow-sentinel class invariant. Retry-exhaustion is treated as an interactive recovery prompt, not a workflow state transition.
   - **`GUARD_RC == 2`** (CLOSED entry detected) → STOP. Do NOT emit the completion sentinel. The issue exists; we must NOT create a duplicate.
     `AskUserQuestion`: "Tracking-issue guard detected a CLOSED entry in `closes_issues`. The issue exists but is closed. How should we recover?"
     Options: "Reopen the closed entry and retry" (user runs `gh issue reopen <N>` manually, then re-run guard; counter unchanged) / "Abort session" (`rm -f "$COUNTER_FILE"`, emit `<<WORKFLOW_RESET_FROM_clarify_intent>>`).

CI-C1. `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
CI-C1a. If `NON_GITHUB=0` and `closes_issues` is non-empty, run `cc-session-title set-issue` as a separate Bash call: `node "$AGENTS_CONFIG_DIR/bin/cc-session-title" set-issue "$(pwd)" "<PLANS_DIR>"` (mirrors workflow-init Path A A1a; call after intent.md is written; `<PLANS_DIR>` resolved from `WORKFLOW_PLANS_DIR` or the same source as CI-4).
CI-C2. TodoWrite: mark `workflow_init` + `clarify_intent` completed; remaining steps pending.
CI-C3. Apply the validity check from `skills/_shared/survey-artifact-valid.md` to both
   workflow-init survey artifacts:
   - Both valid → emit `WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init`.
   - Either invalid → invoke the affected survey(s) directly before proceeding.
   Optionally invoke `/deep-research` if external knowledge is required.

## Rules

- Report observations per rules/supervisor-reporting.md.
