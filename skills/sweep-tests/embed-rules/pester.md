> Rewrite rules for one Pester test file (`*.Tests.ps1`) under `/sweep-tests --embed-cases` (STE-4). The embed subagent reads this file; `pester_case_embed rules-doc` names it.

# Embedding Case Markers — Pester

Goal: the file loads the shared harness and every case is a top-level `Describe` tagged `-Tag 'target:<path>'`, so retire can drop one case when its target is deleted.
The verifier (`bin/verify-case-embed.sh`) re-checks every rule marked (V); a file that fails is reverted and retried.
Marker grammar is owned by `skills/_shared/test-design/case-markers/pester.md` — follow it; this file adds only the rewrite rules.

## Input and output

- Rewrite the file given as the item's input path; write the whole new file to the item's output path. Never touch any other file.
- Embed every file the gate hands you; never skip one because it is hard to read.
- Keep the `# Tests:` / `# Tags:` header and its first-10-lines position as given (the header was already fixed in Stage 1).
- The gate never hands you a file of a shape it does not embed yet; `pester_case_embed skip-reason` names it:

| Word | Shape |
|---|---|
| `nested-describe` | A `Describe` sits inside another `Describe` |

## Harness

- Load `tests/lib/harness.ps1` once, with the load line of the notation doc, inside a top-level `BeforeAll` (V).
- Delete every self-implemented harness piece and use the harness one instead: `$PASS = 0` / `$FAIL = 0` counters and functions that redefine a harness name (V).
- Keep `Should` assertions as they are; Pester counts the results, so add no trailer.

## Cases

- One case per original top-level `Describe`; never merge two of them into one case.
- When one `Describe` checks several targets, split its `It` blocks into one top-level `Describe` per target, each `It` unchanged.
- Name each `Describe` in a descriptive string constant taken from what its tests check.
- Use one `# Tests:` path as the target of each case (V: every header path is the target of at least one case).
- A block that checks several targets at once and cannot be split goes to its main target only; record the choice in the item's notes line so the report keeps it.
- Never change what an assertion checks: same command, same expected value, same comparison.

## Helpers and setup

- Move a function, variable or setup step used by only one case into that case's `BeforeAll`.
- Keep a helper used by two or more cases in the top-level `BeforeAll`, above the first case.
- Leave no function that nothing calls any more (V: `leftover-defs` must be empty).
- Shared setup that every case needs (temp dir, `AfterAll` cleanup, environment pinning) stays in the top-level `BeforeAll` / `AfterAll`.

## Do not

- Never put a `target:` tag on a nested `Describe`, a `Context` or an `It`.
- Never build a `Describe` name or a tag from a variable or an expression.
- Never add `-Skip`, `try { } catch { }` or other changes that hide a failing assertion: the verifier compares the before/after result class and pass/fail counts.
