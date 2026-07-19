---
name: make-outline-plan
description: Propose 2-3 mutually-exclusive high-level approaches via outline-planner + outline-reviewer, then get user sign-off. Stage 2 of the three-stage planning pipeline. Outputs <session-id>-outline.md.
model: sonnet
user-invocable: false
---
<!-- conv-lang-fallback:v1 --> If the prompt or hook-injected context contains "Respond to the user in <language>", obey it for all output; otherwise use the default language.

Propose high-level approaches and get user sign-off before detailed planning.

Skip this stage via `<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>` when a single obvious approach exists. To skip both this stage AND detail, emit `WORKFLOW_OUTLINE_NOT_NEEDED` and `WORKFLOW_DETAIL_NOT_NEEDED` in sequence.
When `outline-planner` returns `SINGLE_APPROACH_JUSTIFIED`, skip the review/sign-off loop and proceed directly to `make-detail-plan`.

## Inputs

- `<PLANS_DIR>/<session-id>-intent.md` — output of `clarify-intent` (cross-session carry-in allowed)
- `<PLANS_DIR>/<session-id>-survey-{code,history}.md` — optional; contain `## Verified Claims`
- All sentinels in MOP-0 are emitted by the orchestrator (Bash tool), never by a subagent.
- Session-id used for `*-outline.md` matches the intent file actually used.

## Procedure

Apply `skills/_shared/resolve-plans-dir.md` once; substitute the resolved absolute path for every `<PLANS_DIR>` below. Reuse across steps.

MOP-0. **Surface premise contradictions** from Research artifacts.
   MOP-0a. Determine session-id from `CLAUDE_SESSION_ID` env (MOP-1 has not run yet — this lookup precedes intent-file resolution).
       - `state.steps.research.status === "skipped"` → skip to MOP-0d.
       - One/both `<session-id>-survey-{code,history}.md` missing AND research not skipped → warn once in chat ("Research artifacts incomplete — proceeding without full premise verification") and continue to MOP-0d. Do not block.
   MOP-0b. Read `## Verified Claims` from each existing artifact; collect items with `verdict: contradicted`.
   MOP-0c. Any contradicted claims → display the contradicted claim list in chat; instruct the user: "The survey has found premise contradictions. Revise intent.md to reflect the correct premises and re-run /clarify-intent."; abort the skill (do not proceed further).
   MOP-0d. Emit `<<WORKFLOW_MARK_STEP_research_complete>>` to mark Research complete (aggregating survey-code and survey-history, which no longer emit it individually; deep-research's emit, if any, is idempotent).

MOP-1. Locate the intent file:
   a. `<session-id>-intent.md` exists → use it.
   b. Otherwise list `<PLANS_DIR>/*-intent.md`. Exactly one → inform the user and use it; multiple → `AskUserQuestion` to select one; none → abort with "clarify-intent must run before make-outline-plan. Run /clarify-intent first."
   c. Extract session-id from the chosen file's name; use it for all subsequent output paths.
   d. Evaluate the skip-outline 2-condition checklist. First run a separate Bash call to check 0-signal: `SESSION_ID="$SESSION_ID" bash "$AGENTS_CONFIG_DIR/skills/make-outline-plan/scripts/check-outline-skip.sh"`. If `auto`, no judgment needed — proceed to record. Otherwise evaluate via LLM judgment (so_c1: a single obvious approach exists; so_c2: change files/locations are uniquely identified). Record via a SEPARATE Bash call: `node "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" --session "$SESSION_ID" --target outline --c1 <true|false> --c2 <true|false>`. When both conditions are true, emit `<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>` in a SEPARATE Bash call and skip to Completion. Record call and sentinel MUST be separate Bash calls — never chained.

MOP-2. Delegate to **outline-planner** subagent (`subagent_type: outline-planner`). Pass full contents of `<session-id>-intent.md` and task context.

MOP-3. If outline-planner returns `SINGLE_APPROACH_JUSTIFIED: <reason>` (optionally `DELIVERY_PLAN: <plan>` on next line):
   - Parse both lines. If `DELIVERY_PLAN:` is absent (pre-change planner output), use the fallback text "(not provided — planner pre-dates this convention)".
   - Inform user that only one approach is viable (citing the reason) and that the skill is proceeding directly to `/make-detail-plan`.
   - Write a minimal planner output containing the H1, the approved single approach text, and a `## Delivery plan` section from the `DELIVERY_PLAN:` text (or fallback) to `<PLANS_DIR>/<session-id>-outline.md`. Do NOT write `## Issues` / `## Class members` / `## Accepted Tradeoffs` — the helper carries them forward next.
   - Assemble the final outline.md by invoking the shared helper (same call as the normal path in MOP-4a):
     Run `"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent "$PLANS_DIR/$SESSION_ID-intent.md" "$PLANS_DIR/$SESSION_ID-outline.md" "$PLANS_DIR/$SESSION_ID-outline.md"` (Bash tool).
   - Apply the full `skills/_shared/confirm-plan.md` protocol (Steps 1+2+3) using `CONFIRM_OUTLINE`. Even single viable approach may need artifact revision — protocol Step 3 covers that. Revise → ask what to change, re-run outline-planner, loop back to MOP-2.
   - Proceed to the **Completion** sequence below.

MOP-4. If outline-planner returns `NEEDS_RESEARCH`: run `/deep-research`, then re-prompt outline-planner with findings. Research budget: 2 rounds.

MOP-4a. **Mandatory sections carry-forward (helper handles assembly — do not instruct planner to author them):**
   After outline-planner returns its draft (initial or revised round), the orchestrator carries the 3 mandatory sections (`## Issues`, `## Class members`, `## Accepted Tradeoffs`) verbatim from intent.md into the final outline.md via the shared helper:
   Run `"$AGENTS_CONFIG_DIR/skills/_shared/assemble-mandatory.sh" --source-kind intent "$PLANS_DIR/$SESSION_ID-intent.md" "$PLANS_DIR/$SESSION_ID-outline.md" "$PLANS_DIR/$SESSION_ID-outline.md"` (Bash tool).
   - The helper extracts the 3 sections from intent.md with headers, strips any planner-authored copies plus the planner's H1 from the draft, and writes the assembled outline.md.
   - Helper exit non-zero → re-prompt outline-planner once and re-assemble; second failure → halt the loop.
   - Do NOT instruct the planner to author the 3 mandatory sections — the helper strips planner-authored copies before the final write.
   - Legacy intent.md (pre-#462) lacking `## Class members` is handled by the helper's soft-fail path (auto-injects a stub) — no orchestrator action needed.

   Constraint: outline-planner cannot add new entries to `## Accepted Tradeoffs` — `assemble-mandatory.sh` carries the intent.md tradeoffs verbatim. Record new design decisions in `## Confirmed non-goals` or `## Constraints` instead.

   `EXTENSIONS_USED` counter initialized to 0 at loop start.

MOP-5. **Codex review loop.** Follows `skills/_shared/codex-review-loop.md`
   (parameter values for the outline stage: FORMAT=outline-plan, CAP=1,
   MAX_EXTENSIONS=1, PLANNER_AGENT=outline-planner,
   REVIEWER_AGENT=outline-reviewer,
   ACCEPTED_TRADEOFFS_FILE=<PLANS_DIR>/<session-id>-intent.md,
   NON_APPROVED_VERDICT=MISSING_ALTERNATIVE).

   For each review round, invoke `"$AGENTS_CONFIG_DIR/skills/make-outline-plan/scripts/run-codex-review-loop.sh"`
   (Bash tool) with env vars exported: `AGENTS_CONFIG_DIR`, `SESSION_ID`, `PLANS_DIR`, `EXTENSIONS_USED` (required);
   `CTX_SURVEY_CODE`, `CTX_SURVEY_HISTORY`, `CTX_CONCERNS_LOG` (optional — passed as
   `--context` when the file exists and is non-empty). Exit codes pass through unchanged.

   Outline-stage caller paths:
   - RAW_FILE: `<PLANS_DIR>/<session-id>-outline-codex-round-<N>-raw.md`
   - CONCERNS_LOG: `<PLANS_DIR>/<session-id>-outline-concerns-log.md`
   - DEBUG_LOG: `<PLANS_DIR>/<session-id>-outline-debug.log`

   Exit code → action mapping: see the SSOT table in
   `skills/_shared/codex-review-loop.md` (#exit-code--orchestrator-action-ssot).

   **Exit 4 must NOT trigger `outline-reviewer` fallback** — halt and surface
   stderr to the user. Only exit 3 falls back silently.

   The per-stage wrapper script maintains a `ROUND_NUMBER` counter on disk at `<PLANS_DIR>/<session-id>-outline-plan-round-number.txt`, independent of `EXTENSIONS_USED`. It increments on each wrapper invocation and is passed as `--round "$ROUND_NUMBER"` to `bin/run-codex-review-loop`. The counter is cleared on APPROVED (exit 0) or ESCALATE (exit 2), and persists on CONTINUE (exit 1). See `skills/_shared/codex-review-loop.md ## Round Counter (ROUND_NUMBER)` for the full contract.

MOP-6. **Cap outcome dispatch.**

   Apply only when the per-stage wrapper script (Step MOP-5) returns a non-zero non-one exit code:

   **Exit 5 (AUTO_EXTEND):** Increment `EXTENSIONS_USED` by 1, then loop back to MOP-5 (no user confirmation). `EXTENSIONS_USED` tracking is the caller's responsibility (see `skills/_shared/codex-review-loop.md`).

   **Exit 2 (ESCALATE):** Run `"$AGENTS_CONFIG_DIR/bin/review-loop-summarize-concerns" --ledger <PLANS_DIR>/<session-id>-outline-plan-concern-ledger-cap-snapshot.txt --raw <RAW_FILE>` and present the output to the user. Then stop the loop and re-run `/clarify-intent` (outline-specific override: `adjust` path means scope needs revision).

   `<RAW_FILE>` = `<PLANS_DIR>/<session-id>-outline-codex-round-<round_number-1>-raw.md`; `<round_number-1>` = `$(( $(cat <PLANS_DIR>/<session-id>-outline-plan-round-number.txt) - 1 ))`.

MOP-7. On `APPROVED`:
   Retrieve `CONV_LANG=$(bash "$AGENTS_CONFIG_DIR/bin/get-config-var" CONV_LANG 2>/dev/null || true)`.

   Evaluate each approach and select the recommended one (highest trade-off score across cost, risk, existing-code consistency, and delivery timeline). Record it as `CHOSEN_APPROACH=<approach-name>`.

   Emit this prose rationale summary as the turn-final assistant message, not as mid-turn text between tool calls — the VS Code extension renders only turn-final assistant text. Write the summary in `CONV_LANG` (or English if unset). For each approach, write one paragraph (rationale + trade-offs + delivery plan). End with: `Recommended approach: <name> — <one-line reason>`.

   Do NOT write this prose to outline.md. MOP-8 handles the file write.

MOP-8. Write the chosen approach to `<PLANS_DIR>/<session-id>-outline.md` per the Output Schema. Always execute confirm-plan Steps 1+2 (artifact write + breadcrumb). Then branch on the bypass condition:
   - **Bypass (CONFIRM_OUTLINE=off only):** emit one-paragraph prose summary and proceed without `<<WORKFLOW_CONFIRM_OUTLINE>>`.
   - **Sentinel** (ON path): apply confirm-plan Step 3 — in the SAME response as `echo "<<WORKFLOW_CONFIRM_OUTLINE: {one-line summary}>>"`, also include the `make-detail-plan` Skill invocation. Do NOT end the response on the CONFIRM echo. Revise → ask what to change, re-run outline-planner, loop back to MOP-7.

## Output Schema (`<session-id>-outline.md`)

The file (per `PLAN_LANG` in `.env`; see `.env.example`) contains:

- **Title** (H1): "Confirmed Approach" + `<session-id>`
- **Mandatory sections** (assembled by `skills/_shared/assemble-mandatory.sh` from intent.md, not authored by planner):
  - `## Issues` — always present (empty placeholder allowed for Path C)
  - `## Class members`
  - `## Accepted Tradeoffs`
- **Planner-authored body sections** (drafted by outline-planner):
  - **Adopted approach**: 1 paragraph + rationale for choosing it
  - **Delivery plan**: triage rationale / execution order / split policy for the adopted approach
  - **Considered alternatives (rejected)**: one entry per rejected approach with reason
  - **Reused existing utilities / building blocks**: list
  - **Confirmed non-goals**: inherited from intent.md + any added during this stage

## Rules

- **Chat output during the discussion loop** is restricted to:
  (a) one status line per round (`Round N: APPROVED` / `Round N: NEEDS_REVISION (proceeding)`)
  (b) NO path output — `show-plan-link.js` PostToolUse hook emits the sole authoritative breadcrumb. Orchestrator MUST NOT print, duplicate, translate, paraphrase, or reformat the path. See `skills/_shared/confirm-plan.md` Step 2.
  (c) the MOP-7 turn-final prose rationale summary
  (d) the concern summary block rendered by the MOP-6 ESCALATE path when exit 2 fires — exactly one block per cap-reach event.
  No per-round natural-language summaries (the cap-reach summary in (d) is the sole exception), no codex/reviewer transcripts, no "falling back to Claude reviewer" notices in chat. Diagnostics go to `<session-id>-outline-debug.log` only.
- Write every orchestrator-authored outline.md body — both the MOP-3 minimal single-approach file and the MOP-8 chosen-approach file — in the PLAN_LANG language (see .env.example) from the first draft; do not draft in English and re-translate.
- outline-planner and outline-reviewer never see implementation details — direction-level only.
- `WORKFLOW_MARK_STEP_detail_complete` is NOT emitted here; only `make-detail-plan` emits it. This skill emits `WORKFLOW_MARK_STEP_outline_complete` (marks outline-stage state).
- **Confirmation dialogs per run**: OFF mode fires none. ON mode fires exactly one: the MOP-8 `<<WORKFLOW_CONFIRM_OUTLINE>>` sentinel. The MOP-7 AskUserQuestion and the multi-approach passthrough bypass option are abolished (#1522); the orchestrator auto-selects the recommended approach. `CONFIRM_OUTLINE=off` is the sole remaining MOP-8 bypass path.
- **`AskUserQuestion` is for choices, not content.** `question` is one sentence; option `description` ≤80 chars. Approach bodies/rationales/trade-offs go in the MOP-7 prose preamble — never inside dialog fields. The dialog UI is narrow; long content there is unreadable.
- Never pause for user confirmation during intermediate steps (codex/reviewer revision rounds in MOP-6, between-step summaries). Update files silently; inform the user with plain text only.
- Report observations per rules/supervisor-reporting.md.

## Completion

MOP-C1. Evaluate the skip-detail 3-condition checklist. First run a separate Bash call: `SESSION_ID="$SESSION_ID" bash "$AGENTS_CONFIG_DIR/skills/make-outline-plan/scripts/check-detail-skip.sh"`. If `auto`, no judgment needed — proceed to record. Otherwise evaluate via LLM judgment against outline.md (sd_c1: all changed files are listed by path; sd_c2: each file's edit content is clear; sd_c3: no unresolved multi-layer design decisions). Record via a SEPARATE Bash call BEFORE the outline-complete sentinel: `node "$AGENTS_CONFIG_DIR/bin/workflow/record-skip-judgment" --session "$SESSION_ID" --target detail --c1 <true|false> --c2 <true|false> --c3 <true|false>`. When all conditions are true, also launch `skip-verifier` via the Agent tool (run_in_background: true) with session_id=`$SESSION_ID`, target=`detail`, intent_path=`<PLANS_DIR>/$SESSION_ID-intent.md`, outline_path=`<PLANS_DIR>/$SESSION_ID-outline.md`. Then:
`echo "<<WORKFLOW_MARK_STEP_outline_complete>>"` (marks the outline step in workflow state; must be the ENTIRE Bash command — no pipes, no && chaining, no redirection)
