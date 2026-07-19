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
- Emit companion analysis (issue comparison, scope clarification, trade-off summary) as turn-final assistant text or AskUserQuestion preview/description — not as mid-turn text between tool calls (invisible in VS Code).

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

CI-4. Write `<PLANS_DIR>/<session-id>-intent.md` (Write tool, no mkdir). `<PLANS_DIR>` resolves to `~/.workflow-plans/` unless `WORKFLOW_PLANS_DIR` overrides it (`$HOME/.workflow-plans/` on POSIX). Read `CLAUDE_SESSION_ID` from `$CLAUDE_ENV_FILE`; fallback `YYYYMMDD-HHMMSS`. Sections (in order): `## Issues` (mandatory — single SSOT for `closes_issues`; canonical parser: `hooks/lib/parse-closes-issues.js`), Background/Motivation, Scope, Constraints, Interview Log (optional), `## Class members` (mandatory — see schema below), `## Accepted Tradeoffs` (schema: `### <title>` heading + 1-paragraph rationale per entry; empty → write `(none)`), `## worktrees` (optional — omit for single-repo sessions; include when CI-3b collected sibling worktree paths). The `## Accepted Tradeoffs` section captures design decisions already settled — used by `extract-mandatory-sections` to suppress re-raised concerns in later codex reviews. Write intent.md body text in the language set by `PLAN_LANG` (`$AGENTS_CONFIG_DIR/.env`) when it is a concrete non-English language; lines whose trimmed text starts with `#` (headings of any level) are exempt. When `PLAN_LANG` is unset, `any`, or `english`, write in English (`any` disables the artifact-language policy — keep the conversation/request language).

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

Scope is final after CI-5. Side effects fire now — never before.

`run-completion.sh` reconciles: calls `clarify-commit-scope.sh` (per-N side-effect order), then `clarify-guard-loop.sh` (uses `check-closes-issues-nonempty.sh`). For each issue N in `closes_issues`:
1. `intent:clarified` add-label,
2. `wip-state.sh set`,
3. board card.
Best-effort per-N — continue with the remaining entries on any per-N failure. On a persistent `wip-state set failed for #<N>` warning, add `intent:clarified-wip-failed: #<N>` under Constraints. Path C (empty `closes_issues`): `gh issue create` → `CREATED:<N>`.

Run `bash "$AGENTS_CONFIG_DIR/skills/clarify-intent/scripts/run-completion.sh" --session-id "<session-id>" --plans-dir "<PLANS_DIR>"`.

CI-C0. **Tracking-issue guard** — handled by `run-completion.sh`. Branch on its single stdout token:

- `PROCEED` → proceed to CI-C1 (emit `<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>`).
- `CREATED:<N>` (Path C) → backfill `## Issues` from `(none — pending issue creation or NON_GITHUB)` to `- #<N>: <title>` (Read + Edit). Re-run **guard-loop only**: `bash "$AGENTS_CONFIG_DIR/bin/github-issues/clarify-guard-loop.sh" --session-id "<session-id>" --plans-dir "<PLANS_DIR>"` → branch on its token below.
- `CLOSED:<N>` → `AskUserQuestion` "Issue #<N> is CLOSED. How to proceed?" — "Reopen and continue" / "Remove from closes_issues and continue" (when `len(closes_issues) >= 2` only) / "Abort session" → re-run run-completion.sh.
  - Remove-and-continue branch: after removing the issue from closes_issues, also remove the corresponding `- #N: title` line from the `## Issues` section of the in-progress `intent.md` (and from `outline.md` if it already exists).
  - This keeps plan artifacts in sync with closes_issues — stale `- #N:` entries cause confusion in downstream steps.
- `RC2` → `AskUserQuestion` "WIP set rc=2 for #<N>. How to proceed?" → "Skip and continue" / "Abort session".
- `NEED_ISSUE` → invoke `/issue-create` → backfill `## Issues` → re-run guard-loop only.
- `RETRY_EXHAUSTED` → `AskUserQuestion` "Tracking-issue guard failed twice. `closes_issues` is still empty. How should we recover?" — "Retry `/issue-create`" / "Manual recovery" / "Abort workflow" → emit `<<WORKFLOW_RESET_FROM_clarify_intent: tracking-issue guard exhausted>>`.
- `CLOSED_ENTRY` → `AskUserQuestion` "Tracking-issue guard detected a CLOSED entry. How should we recover?" — "Reopen the closed entry and retry" / "Abort session" → `<<WORKFLOW_RESET_FROM_clarify_intent: closed tracking entry>>`.

Note (CPR-5 Orthogonality): no new workflow sentinel is introduced. Interactive recovery remains in SKILL.md.

CI-C1. `echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
CI-C1a. If `NON_GITHUB=0` and `closes_issues` is non-empty, run `cc-session-title set-issue` as a separate Bash call: `node "$AGENTS_CONFIG_DIR/bin/cc-session-title" set-issue "$(pwd)" "<PLANS_DIR>"` (mirrors workflow-init Path A A1a; call after intent.md is written).
CI-C1b. Read `skills/_shared/judge-task-complexity.md`; evaluate all S1–S6 signals against the confirmed intent.md (S6 approximated from intent.md line count only — outline.md does not exist yet). Then run as a separate Bash call: `SKIP_MODE=$(bash "$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip" --session "$SESSION_ID" --verdict <high|low> --signals <csv-or-empty> --target outline)`. `$SKIP_MODE` is `auto` or `judgment`; the shared script records complexity_evaluation and (when `auto`) record-skip-judgment.
CI-C1c. **Outline skip — sentinel dispatch**: `SKIP_MODE=judgment` → evaluate so_c1 (single obvious approach) and so_c2 (change locations identified) from intent.md context first. Run `TOKEN=$(bash "$AGENTS_CONFIG_DIR/skills/clarify-intent/scripts/check-complexity-skip.sh" --session "$SESSION_ID" [--so-c1 <bool>] [--so-c2 <bool>] | tail -1)` (script emits `<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>` when applicable; `SKIP_MODE` inherited from CI-C1b).
   - `SENTINEL_EMITTED` → Agent tool (run_in_background: true): subagent_type=skip-verifier, session_id=`$SESSION_ID`, target=`outline`, intent_path=`<PLANS_DIR>/$SESSION_ID-intent.md` → CI-C2.
   - `NO_SENTINEL` → CI-C2.
CI-C2. TodoWrite: mark `workflow_init` + `clarify_intent` completed; remaining steps pending.
CI-C3. Apply the validity check from `skills/_shared/survey-artifact-valid.md` to both
   workflow-init survey artifacts:
   - Both valid → emit `WORKFLOW_RESEARCH_NOT_NEEDED: surveys already complete via workflow-init`.
   - Either invalid → invoke the affected survey(s) directly before proceeding.
   Optionally invoke `/deep-research` if external knowledge is required.

Then invoke `/make-outline-plan`.

## Rules

- Report observations per rules/supervisor-reporting.md.
