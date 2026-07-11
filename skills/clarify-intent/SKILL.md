---
name: clarify-intent
description: Conduct a decision-tree interview with the user to lock in requirements, motivation, scope, and non-goals before planning.
model: sonnet
---

IMPORTANT: Interactive session required. Hard-fail (hard-fail with a diagnostic message) in non-interactive contexts (`claude -p`, `/loop`, subagents). Do not silently proceed — emit the diagnostic and stop.

## Skip Conditions

Emit `echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {reason}>>"` when a prior `*-intent.md` covers the request, or the task is self-contained and unambiguous.

## Procedure

Apply `skills/_shared/resolve-plans-dir.md` once at the start of Procedure;
substitute the resolved absolute path for every `<PLANS_DIR>` placeholder
below. Reuse across all subsequent steps — do not re-resolve.

CI-1. Read the user's request; identify the root question that unlocks all downstream decisions. Adopt a grill-me interrogation stance (after Matt Pocock's `grill-me`): probe assumptions until scope is unambiguous.

CI-1a. **closes_issues auto-detect**: Scan for `(?:[a-zA-Z0-9_.-]+(?:\/[a-zA-Z0-9_.-]+)?)?#\d+` (detects all three forms: `#N`, `repo#N`, `owner/repo#N`). Pre-fill file (CI-1b) auto-satisfies this when it sets the issue number. Single unambiguous match → `closes_issues: [N]`. Multiple matches → record all in insertion order (`closes_issues: [N1, N2, ...]`). None → `closes_issues: []`. See `rules/github-issues.md` "Session model" for the canonical N-issue relation.

CI-1b. **Pre-fill detection**: Check `<PLANS_DIR>/<session-id>-issue-prefill.md` (written by `/workflow-init` Path B). If present: read it; treat body as Background/Scope seed and proceed to CI-2 (CONFIRM_OUTLINE check) normally. During the interview in CI-3, the background question is auto-skipped since the prefill body serves as the background. No AskUserQuestion — users who want to discard the issue framing say so via free text during the interview.

CI-2. Check via Bash: `bash -c 'cd "$AGENTS_CONFIG_DIR" && bash "$AGENTS_CONFIG_DIR/bin/confirm-off" CONFIRM_OUTLINE on'`. If stdout is `OFF`: add delivery-plan-direction question (required even past the 5-round cap). **Scope constraint:** the delivery-plan-direction question MUST cover execution order / staging priority only — it MUST NOT ask about PR count or bundling; `rules/github-issues.md` fixes `1 session = 1 PR` as a non-negotiable invariant.

CI-2a. Aggregate candidate class members per `reference/aggregate-class-members.md`.

CI-2b. **Companion-issue pre-check + batch presentation.** Skip when `closes_issues` is empty (Path C). Run `bash "$AGENTS_CONFIG_DIR/skills/clarify-intent/scripts/precheck-companions.sh" --seed "${closes_issues[0]}" --exclude "$(IFS=,; echo "${closes_issues[*]}")" --output-file "<PLANS_DIR>/<session-id>-companion-precheck.json"`. The precheck wraps `companion-search.sh --seed <N> --exclude <csv>` (SSOT), carries each candidate's `reason` column, and evaluates decomposition impact. Exit 1 → no candidates → skip. Exit 0 → follow `reference/companion-batch-presentation.md`: display the per-candidate decomposition annotations and `Reason:` field in the main conversation, then present all candidates in a single batch multiSelect. Selected `#M` appended to `closes_issues` before CI-4 writes intent.md. No WIP claim or side effects here — reconciliation happens in Completion after CI-5.

CI-3. Interview via `AskUserQuestion`: 1 question per call; include one **(recommended)** option; dependency order; max 5 rounds; unresolved branches → document as constraints.

   **Class members proposal (when candidates ≥ 1):** run `reference/class-members-proposal.md`.

CI-3a. **Decomposition impact** — computed non-interactively by `precheck-companions.sh` (CI-2b) across baseline (seed-only), full-set, and per-candidate trials. No standalone probe here.
   - Read `skills/_shared/judge-decomposition.md` for the signal table and provenance rules.
   - The precheck snapshot records `VERDICT: wf-meta | <signal IDs>` or `VERDICT: wf-code | none` per trial, with `(companion-driven)` annotations.
   - **wf-code**: proceed silently to CI-4 (no user prompt).
   - **wf-meta** (≥2 signals): the sub-deliverable list is displayed in the MAIN CONVERSATION per `reference/companion-batch-presentation.md` (#1096 — never inside AskUserQuestion). Ask at most ONE wf-meta confirmation AskUserQuestion (pre-announced): "Proceed in WF-META mode (planning only, no implementation this session)?" — options "Yes, WF-META (planning only)" / "No, WF-CODE (implement this session)".
     - **WF-META**: read `$CLAUDE_ENV_FILE` to resolve `SESSION_ID`; run `bin/workflow/set-workflow-type "$SESSION_ID" "wf-meta"` (separate Bash call); proceed to CI-4. After CI-5, route to `make-outline-plan`; next-step auto-skips the non-applicable WF-CODE steps.
     - **WF-CODE**: proceed silently to CI-4. Never auto-switch to wf-meta without this confirmation.

CI-3b. **Multi-repo probe** (run after CI-3a, before writing intent.md):

   **Layer 1 — existing closes_issues cross-repo references:**
   - Skip silently when `closes_issues` contains no cross-repo references (no `owner/repo#N` or bare `repo#N` form). Proceed to Layer 2.
   - Determine primary repo: run `git remote get-url origin` and normalize to `owner/repo` format.
   - Collect all cross-repo entries from `closes_issues`; normalize bare `repo#N` to `owner/repo#N` using the primary owner; deduplicate by insertion order.
   - For each unique sibling `owner/repo` (i.e. not the primary repo): call `AskUserQuestion` once: "The session contains an issue from `<owner/repo>`. Enter the absolute path to the linked worktree for that repository (leave blank to skip)."
   - Non-empty answer → record as `{repo: "<owner/repo>", worktree_path: "<answer>"}`.
   - Empty / skipped → record `<owner/repo> sibling worktree absent` under `## Constraints` in intent.md.

   **Layer 2 — prose detection for additional cross-repo issue references:**
   - From context.md `## User initial prompt` and `## Issue body`, extract candidate strings that look like `repo#N` or `owner/repo#N` tokens (broad prefilter: any word containing `#` followed by digits).
   - Pipe candidate strings to `node "$AGENTS_CONFIG_DIR/bin/parse-issue-tokens" <candidates...>` — Node handles `#` splitting (C2: shell must not parse).
   - Filter for entries with `repo` field set AND not already in `closes_issues`.
   - For each candidate: normalize short-form repo via `gh repo view "<repo>" --json owner,name --jq '.owner.login + "/" + .name'`; on failure, skip.
   - Propose each via `AskUserQuestion` (confirm/skip): "A reference to `<owner/repo>#<N>` was found in the context. Add this issue to closes_issues?"
   - Add confirmed ones to `closes_issues` in intent.md as `- owner/repo#N` format.

   After all probes: CI-4 writes a `## worktrees` section with the collected results.

CI-4. Write `<PLANS_DIR>/<session-id>-intent.md` (Write tool, no mkdir). `<PLANS_DIR>` resolves to `~/.workflow-plans/` unless `WORKFLOW_PLANS_DIR` overrides it (`$HOME/.workflow-plans/` on POSIX). Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `YYYYMMDD-HHMMSS`. Sections (in order): `## Issues` (mandatory — single SSOT for `closes_issues`; canonical parser: `hooks/lib/parse-closes-issues.js`), Background/Motivation, Scope, Constraints, Interview Log (optional), `## Class members` (mandatory — see schema below), `## Accepted Tradeoffs` (schema: `### <title>` heading + 1-paragraph rationale per entry; empty → write `(none)`), `## worktrees` (optional — omit for single-repo sessions; include when CI-3b collected sibling worktree paths). The `## Accepted Tradeoffs` section captures design decisions already settled — used by `extract-mandatory-sections` to suppress re-raised concerns in later codex reviews.

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
     Completion backfills `- #<N>: <title>` after a successful `gh issue create`. The empty placeholder satisfies `assemble-mandatory.sh`'s "heading must be present" invariant.
   - **context.md missing or title line absent**: write `- #<N>: (title unavailable)`.

CI-5. Apply `skills/_shared/confirm-plan.md` protocol using `CONFIRM_INTENT`. On the `ON` path: in the SAME response as `echo "<<WORKFLOW_CONFIRM_INTENT: {one-line summary}>>"`, also include the next tool_use — the Completion side-effect Bash call, then the `make-outline-plan` Skill invocation. Do NOT end the response on the CONFIRM echo. Revise: update intent.md (re-run interview if scope changes significantly), loop back to protocol Step 1.

CI-6. This step exits exclusively via the Completion section below — the skill terminates only after CI-C1 emits the completion sentinel.

## Completion

Scope is final after CI-5. Side effects fire now — never before — so a CI-5 scope change cannot strand a stale WIP claim or board card.

Run the non-GitHub gate: `"$AGENTS_CONFIG_DIR/bin/is-github-dotcom-remote"`. rc=0 → GitHub (proceed). rc=1 → non-GitHub (`NON_GITHUB=1`, pass `--non-github`). rc=2 → unknown (fail-open, proceed as GitHub).

Read `closes_issues` from intent.md (canonical parser: `hooks/lib/parse-closes-issues.js`). This is the confirmed post-CI-5 SSOT.

Build `REPO_MAP_ARGS` from the parsed entries: for each entry at index `i` with `repo` field set, add `--repo-map i:<repo>`. Pass bare integers as `--issues` CSV.

**Reconcile side effects** (label / WIP set / board-card parity for all entries, or Path-C issue creation when empty):
`bash "$AGENTS_CONFIG_DIR/bin/github-issues/clarify-commit-scope.sh" --session-id "<session-id>" --plans-dir "<PLANS_DIR>" --issues "$(IFS=,; echo "${closes_numbers[*]}")" "${REPO_MAP_ARGS[@]}" [--non-github]`.

(`closes_numbers` is the bare-integer CSV extracted from the parsed `closes_issues` array.)

The CLI runs the per-entry order For each issue N in `closes_issues`:
1. `intent:clarified` add-label,
2. `wip-state.sh set`,
3. board card.
Best-effort per-N — continue with the remaining entries on any per-N failure. On a persistent `wip-state set failed for #<N>` warning, add `intent:clarified-wip-failed: #<N>` under Constraints.

Handle its stdout / exit code:
- Exit 0, empty stdout → all entries labelled, WIP-set, board-carded per the order above.
- `CREATED:<N>` (Path C — empty `closes_issues`) → backfill the `## Issues` placeholder body from `(none — pending issue creation or NON_GITHUB)` to `- #<N>: <title>` (Read + Edit; title = the created issue's title). The CLI already ran WIP set + board card for the new N.
- `CLOSED:<N>` + exit 2 → `AskUserQuestion` "Issue #<N> is CLOSED. How to proceed?" — options: "Reopen and continue" (run `gh issue reopen <N>`, then re-run the call) / "Remove from closes_issues and continue" (offered only when `len(closes_issues) >= 2`; Read + Edit intent.md to remove N, then re-run) / "Abort session". No side effects fired yet — the CLI stops on the first CLOSED entry before any mutation.
- `RC2` + exit 2 → `AskUserQuestion` "WIP set rc=2 for #<N> (session-id/env unresolvable; conflict detection broken). How to proceed?" → "Skip and continue (acknowledge risk)" → warn + re-run for remaining / "Abort session" → `echo "<<WORKFLOW_ABORTED_WIP_SET_RC2: #{N}>>"` + stop.

Then:

<!-- closes_issues guard: canonical parser is hooks/lib/parse-closes-issues.js — do not reimplement. -->

CI-C0. **Tracking-issue guard** — at most 2 automatic passes; further failures escalate to AskUserQuestion. `<session-id>` and `<PLANS_DIR>` are the same values used in CI-4 — reuse, do not re-resolve.

   Run: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/clarify-guard-loop.sh" --session-id "<session-id>" --plans-dir "<PLANS_DIR>" [--non-github]` (add `--non-github` when the gate set it). The CLI owns the `GUARD_ATTEMPT` counter file under `<PLANS_DIR>` and wraps `check-closes-issues-nonempty.sh` (SSOT — parse-closes-issues.js). Branch on its single stdout token:

   - **`PROCEED`** → counter cleared; proceed to CI-C1 (emit `<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>`).
   - **`NEED_ISSUE`** → STOP. Do NOT emit the completion sentinel. Invoke `/issue-create` to create a tracking issue. After it returns issue N, backfill the `## Issues` body in intent.md from `(none — pending issue creation or NON_GITHUB)` to `- #N: <title>` (Read + Edit). Then re-run **only this guard step** — do NOT re-enter the Reconcile block (a second `gh issue create` would duplicate the issue).
   - **`RETRY_EXHAUSTED`** (`/issue-create` already ran but `closes_issues` is still empty) → emit no new sentinel. Open `AskUserQuestion`: "Tracking-issue guard failed twice. `closes_issues` is still empty. How should we recover?"
     - **"Retry `/issue-create` once more"** — invoke `/issue-create` again, then re-run this guard.
     - **"Manual recovery"** — instruct the user to run `gh issue create` and edit `## Issues` directly; on confirmation, re-run the guard.
     - **"Abort workflow"** — emit `echo "<<WORKFLOW_RESET_FROM_clarify_intent: tracking-issue guard exhausted>>"` and exit the skill.
   - **`CLOSED_ENTRY`** → STOP. Do NOT emit the completion sentinel. The issue exists but is closed — do NOT create a duplicate. `AskUserQuestion`: "Tracking-issue guard detected a CLOSED entry. How should we recover?" — options: "Reopen the closed entry and retry" (user runs `gh issue reopen <N>`, then re-run guard) / "Abort session" (emit `<<WORKFLOW_RESET_FROM_clarify_intent: closed tracking entry>>`).

   Note (CPR-5 Orthogonality): no new workflow sentinel is introduced. Retry-exhaustion is an interactive recovery prompt, not a workflow state transition.

CI-C1. `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
CI-C1a. If `NON_GITHUB=0` and `closes_issues` is non-empty, run `cc-session-title set-issue` as a separate Bash call: `node "$AGENTS_CONFIG_DIR/bin/cc-session-title" set-issue "$(pwd)" "<PLANS_DIR>"` (mirrors workflow-init Path A A1a; call after intent.md is written).
CI-C1b. Read `skills/_shared/judge-task-complexity.md`; evaluate all S1–S6 signals against the confirmed intent.md (S6 approximated from intent.md line count only — outline.md does not exist yet). Then as a separate Bash call: `node "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-evaluation" --session "$SESSION_ID" --verdict <high|low> --signals <csv-or-empty>`. This is the sole guaranteed write point for complexity_evaluation.
CI-C1c. **Outline skip record**: First evaluate `resolveSkipConditionsFromComplexity` via a separate Bash call: `node -e "const r=require('$AGENTS_CONFIG_DIR/hooks/lib/workflow-state/skip-signal-resolver.js');const v=r.resolveSkipConditionsFromComplexity('$SESSION_ID','outline');process.stdout.write(v?'auto':'manual')"`. If output is `auto` (0-signal-low session), so_c1 and so_c2 are auto-satisfied as true. Otherwise fall back to manual evaluation: so_c1 (single obvious approach) and so_c2 (change locations uniquely identified). When both conditions are true (either path) — perform 2 SEPARATE Bash calls in order: (1) `node "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" --session "$SESSION_ID" --target outline --c1 true --c2 true`; (2) `echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>"`. No chaining. Detail skip is NOT recorded here — outline.md does not exist yet. If both conditions are not met, skip this step.
CI-C2. TodoWrite: mark `workflow_init` + `clarify_intent` completed; remaining steps pending.
CI-C3. Apply the validity check from `skills/_shared/survey-artifact-valid.md` to both
   workflow-init survey artifacts:
   - Both valid → emit `WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init`.
   - Either invalid → invoke the affected survey(s) directly before proceeding.
   Optionally invoke `/deep-research` if external knowledge is required.

Then invoke `/make-outline-plan`.

## Rules

- Report observations per rules/supervisor-reporting.md.
