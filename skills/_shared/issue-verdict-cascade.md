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

If even one candidate shares **substantially the same root cause or observed
symptom**, decide `reopen`. Differences in surface framing, wording, or scope
description must not be used as grounds for non-match.
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

## Auxiliary rules

- Candidate age is used **only as a tie-break**. Order: closed > open, newer > older,
  smaller number > larger number.
- No numeric threshold is set. Judgment is based on explainable evidence of content
  identity.
- For candidates whose `relation_status` is not `resolved`, do not evaluate the
  IC-C2 / IC-C3 conditions (to avoid misreading "unknown" as "no parent"). If all
  candidates are unresolved, decide using only IC-C1 → IC-C4.
- `reason` is one sentence, written so the matching rule is identifiable.
