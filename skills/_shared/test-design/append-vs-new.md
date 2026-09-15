> Detail file of `skills/_shared/test-design.md`. Read it when deciding whether a planned test case goes into an existing file or a new one.

# Append vs New Test File

## The rule

- **Default is append.** When an existing top-level `tests/*.sh` already names the planned case's source set S in its `# Tests:` header, the case goes there; a new file is created only when no such candidate exists.
- **Same-set rule.** A candidate qualifies only when `S ⊆ T`, T being that candidate's own `# Tests:` set — appending to a file that overlaps S partially is prohibited.
- **Appending never widens T**, so the orphan premise of `bin/lib/test-retire-predicate.sh` survives the append untouched.
- **One exception: the 500-line HARD limit** (`rules/coding/file-split.md`: HARD is `>500` lines — a candidate at exactly 500 is still compliant). Append even when the result is expected to cross it, as long as the candidate is at or under it today.
- Only when every candidate already exceeds that limit is a new file created, tagged `dup-group-keep:size-hard-limit` in `# Tags:`.
- **Never split a candidate to dodge the limit** — more files is the outcome this rule exists to prevent.
- **Candidate ranking.** Exact match first, then the superset with fewer extra tokens, then the smaller line count, then the path ascending.
- **Frontmatter on append.** Do not rewrite the target's `# Tests:` line: an appended case adds coverage, never a new protected source.
- `# Tags:` may only be added to — removing or replacing an existing tag is out of scope for an append.

## `dup-group-keep:<reason>` is not an opt-out

- `dup-group-keep:size-hard-limit` is the only value that can justify a new file while an appendable target exists.
- `dup-group-keep:cross-hook` and `dup-group-keep:distinct-layer` stay valid vocabulary for the post-hoc consolidation judgement of `bin/audit-tests.sh --dup-groups`, but they are **not** a waiver of the append rule and never justify a new file on their own.
- `size-hard-limit` is a claim, not an indulgence: name it only when an over-limit candidate actually existed.
- Tagging a file that never had any candidate is a false claim — review-tests disproves it from the helper's `excluded` and `reason` columns.
- The sole human-discretion exception is the `WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED` sentinel, set explicitly by the user.

## How the decision is made

- Run `bin/find-tests-for-source.sh` — write-tests (WT-5) and review-tests (RT-1a) call the same helper, so both read the same verdict.
- Do not decide by eye and do not grep headers here: the helper owns the corpus scan, the ranking and the limit comparison.
