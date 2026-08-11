# Issue Verdict Cascade (SSOT)

The single definition of the verdict-decision criteria for a filing candidate. Both
`/issue-create`'s survey subagent and the review stage in
`bin/github-issues/review-survey-verdict-codex.sh` read this one file.
Neither side duplicates the body.

## Evaluation order

**Evaluate top to bottom; the first rule that matches decides (first match wins).** A
later rule never overrides an earlier one. Once a rule matches, no rule below it is
evaluated.

## IC-C1 — reopen (highest priority)

Ask of each candidate: does **one fix resolve this proposal and that candidate at the
same time**? Yes for even one candidate → decide `reopen`.
Differences in surface framing, wording, or scope description are never grounds for non-match.
Symptom similarity alone must never carry a `reopen`: when the underlying causes differ, two separate fixes are needed, so fall through to the later rules.
`target` = the matching candidate's number. `children` / `related` are empty.

## IC-C2 — sub-of (attach to an existing meta parent)

Evaluate **only** when IC-C1 does not match. Among candidates with
`relation_status: resolved`, if any has a parent with `parent_is_meta: true`, decide
`sub-of` targeting that **parent's number**. When multiple qualify, pick the single
parent whose subject is closest. If the candidate itself is a meta parent, its own
number may be used as `target`. `children` / `related` are empty.

## IC-C3 — make-parent (group orphan candidates)

Evaluate **only** when both IC-C1 and IC-C2 do not match. Decide `make-parent` when
two or more candidates with `relation_status: resolved` and `parent_number: null`
can be treated as the same class.
List that orphan group in `children`; `target` is `null`.

## IC-C4 — sibling / none

Only when none of IC-C1 / IC-C2 / IC-C3 match. `sibling` when a related candidate
exists (listed in `related`, `target` is `null`); `none` when there is no relation
at all (`target` is `null`, `children` / `related` are empty).

## same_fix — required on every verdict

Answers the IC-C1 question for the decided verdict: does **one fix resolve both the
proposal and the existing issue this verdict names**?
A pure function of the verdict — copy the value from the table, never re-judge it.
A different axis from the confirm gate: `same_fix` is whether one fix covers both; the
gate is how destructive the action is.
`bulk-sub-of` is deliberately absent below — outside the review grammar; the
validator's machine-readable map carries it for the survey artifact.

| verdict | same_fix |
|---|---|
| `reopen` | `true` |
| `sub-of` | `false` |
| `make-parent` | `false` |
| `sibling` | `false` |
| `none` | `false` |

`reopen` is the only `true`: IC-C1 asks the one-fix question of every candidate, so any
verdict below it was reached because the answer was no for all of them.

Both parent-attaching verdicts are `false` because the issue they name is a meta parent,
a container never implemented against. `make-parent` creates one and its grouped children
each keep their own fix; `sub-of` attaches to an existing one, which resolves it no more
than creating it would.

## Auxiliary rules

- Candidate age is used **only as a tie-break**. Order: closed > open, newer > older,
  smaller number > larger number.
- No numeric threshold is set. Judgment is based on explainable evidence of content
  identity.
- For candidates whose `relation_status` is not `resolved`, do not evaluate the
  IC-C2 / IC-C3 conditions (to avoid misreading "unknown" as "no parent"). If all
  candidates are unresolved, decide using only IC-C1 → IC-C4.
- `reason` is one sentence, written so the matching rule is identifiable, and — when
  `same_fix` is `true` — so the single fix that covers both is identifiable too.
