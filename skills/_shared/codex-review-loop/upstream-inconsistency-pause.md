# Upstream Inconsistency Pause

A reviewer tags a deviation from a prior-step decision, an upstream contradiction or an upstream gap with `[upstream-inconsistency …]` (format and recommend rules: [`skills/_shared/priority-hierarchy/core.md`](../priority-hierarchy/core.md)).
A downstream plan step never settles such a concern alone, so the loop pauses for the user's decision.
CLI: `bin/review-loop-upstream` (`list` / `decide` / `pick-upstream` / `return` / `accepted`).

## When to pause

- On every non-APPROVED round (exit 1 / exit 5, or a non-APPROVED fallback report), run `review-loop-upstream list --session <sid> --format <fmt> --round <N> --from-report <report>` before re-delegating to the planner and before appending to `CONCERNS_LOG`.
- For `test-review`, add `--context-file "$AGENTS_MAIN_ROOT/skills/_shared/test-design.md"` (the test design the review read); without it a `source=test-design` B is downgraded to A. The plan formats need no flag: `list` resolves intent / outline / detail from the session.
- On the codex path, run it after that round's `reduce`.
- Pause when `list` prints a row whose `prior_choice` is empty.
- A row with `prior_choice=C` is not asked again; treat it as accepted.
- The trigger is the tag itself, so the codex path and the fallback path pause the same way.

## Who asks

- make-outline-plan and make-detail-plan ask the user themselves, in the main conversation.
- review-plan-security and review-tests run with `context: fork`, so they never ask:
  - stop without the completion sentinel;
  - return the `list` output under an `## Upstream inconsistency` section to the main conversation;
  - the main conversation then asks, following this procedure.

## How to ask

- Show each concern's quote, defect and downgrade reason verbatim, as body text before the dialog.
- For a `source=test-design` concern, state that B revises the shared `skills/_shared/test-design.md` in write_tests, as a change of this PR that goes through review.
- Issue one AskUserQuestion: one question per concern, with the choices A / B / C / D for every format.
- Mark the `effective_recommend` choice `(recommended)`.
- Record every answer with `review-loop-upstream decide --session <sid> --format <fmt> --id <id> --text-hash <hash> --choice <A|B|C|D> --reason <reason>`.

## A and D: who revises what

| format | reviser | revised artifact | resume |
|---|---|---|---|
| `detail-plan` | the detail-planner (PLANNER_AGENT) | detail | the review loop runs the next round |
| `outline-plan` | the outline-planner (PLANNER_AGENT) | outline | the review loop runs the next round |
| `security-plan` | the main conversation | detail | re-run `/review-plan-security`; the round count stays, so it is the next round |
| `test-review` | the main conversation | test files (staged again after the revision) | re-run `/review-tests`; the round count stays, so it is the next round |

- A: the reviser revises the downstream to match the upstream quote.
- D: the reviser receives the user's instruction verbatim and revises exactly as it says.
  - With a PLANNER_AGENT, put the D instruction verbatim into the re-delegation prompt.
  - When the main conversation revises, record the D instruction verbatim first, then revise.
- A D instruction that amounts to C takes the C path.
- The concern stays open either way; the next round confirms whether it is fixed.
- For test-review, A on a `source=test-design` concern aligns the test files with the test design; the test design is not revised.

## B: return to the upstream plan step

B concerns are already recorded by `decide` (How to ask). Then:

1. Pass every B concern's `b_return_step` to `review-loop-upstream pick-upstream <step>...`; it prints the most upstream step.
2. The main conversation emits `<<WORKFLOW_RESET_FROM_<step>: upstream-inconsistency C<N>[,C<M>…]>>` once.
3. Then run `review-loop-upstream return --session <sid> --to <step> --from-format <fmt>` once; it clears the loop work data (ledger, round count, built marker) of that step and every later format, and bumps the cycle. Plan files, test files and test design stay untouched.
   - `return` exits 3 and changes nothing while `<step>` is not pending (the reset was refused or failed); fix the reset, then re-run `return`.

- The new cycle starts with `EXTENSIONS_USED=0`.
- When the skill of that step re-runs, pass it:
   - the quote and defect of every B concern;
   - the paths of that step's existing artifacts (the plan, or the test files and the test design), which the planner revises as a diff against the re-approved upstream;
   - the quote and defect of the A/D concerns of the same confirmation, and the D instruction verbatim; the reviser of the re-run step and of each later step applies them to its own artifact.
- A return to write_tests also revises `skills/_shared/test-design.md` as a change of this PR; that revision goes through the review_tests re-review and the PR code review.
- When one confirmation holds a B, B wins: record A / C / D with `decide` and revise nothing yet; the A / D content rides on the B re-run inputs above; C is accepted as usual.
- With B and C in one confirmation, C applies only to the current cycle; the same inconsistency reported again in the next cycle after B is asked again.

## C: accept the downstream as is

- Record C with the user's reason through `decide`; when the ledger holds the id, `decide` also accepts it there, and a failed accept leaves no C recorded (exit 1).
- With a PLANNER_AGENT, the planner writes `accepted(upstream-inconsistency): <reason>`.
- When the main conversation is the reviser, it revises nothing and leaves the accepted record.
- Scope: core.md "C scope" (the current cycle, that concern's exact body only).
- Fallback path (no ledger id): the decisions.tsv row (cycle, text_hash, `ledger=absent`) is the only C record; `list` marks the same body `prior_choice=C` in the next round. When only accepted concerns remain in a round, end the loop as accepted.

## Downstream after B

- The steps the reset set back to pending also re-run as a diff revision of their existing artifacts; no downstream plan file is deleted.
- Each revised downstream is reviewed from round 1 of the new cycle.
- C records of an earlier cycle never apply to the new cycle's concerns.

## Approval screen

- List "Accepted upstream inconsistencies" from `review-loop-upstream accepted --session <sid> --format <fmt>` (the current cycle only; never `--all-cycles`).
