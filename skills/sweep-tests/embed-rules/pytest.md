> Rewrite rules for one pytest test file (`test_*.py`) under `/sweep-tests --embed-cases` (STE-4). The embed subagent reads this file; `pytest_case_embed rules-doc` names it.

# Embedding Case Markers — pytest

Goal: the file imports the shared harness and every case is a module-level test decorated with `@pytest.mark.target("<path>")`, so retire can drop one case when its target is deleted.
The verifier (`bin/verify-case-embed.sh`) re-checks every rule marked (V); a file that fails is reverted and retried.
Marker grammar is owned by `skills/_shared/test-design/case-markers/pytest.md` — follow it; this file adds only the rewrite rules.

## Input and output

- Rewrite the file given as the item's input path; write the whole new file to the item's output path. Never touch any other file.
- Embed every file the gate hands you; never skip one because it is hard to read.
- Keep the `# Tests:` / `# Tags:` header and its first-10-lines position as given (the header was already fixed in Stage 1).
- The gate never hands you a file of a shape it does not embed yet; `pytest_case_embed skip-reason` names it:

| Word | Shape |
|---|---|
| `parametrized-case` | A test uses `@pytest.mark.parametrize` |

## Harness

- Import `tests/lib/harness.py` once at module top, with the path line and load line of the notation doc (V).
- Delete every self-implemented harness piece and use the harness one instead: module-level `PASS = 0` / `FAIL = 0` counters and definitions that redefine a harness name (V).
- Keep `assert` statements as they are; pytest counts the results, so add no trailer.

## Cases

- One case per original module-level `test_*` function or `Test*` class; never merge two tests into one case or split one test across cases.
- Keep each original function or class name; rename only a name that does not say what the test checks.
- Use one `# Tests:` path as the target of each case (V: every header path is the target of at least one case).
- A test that checks several targets at once and cannot be split goes to its main target only; record the choice in the item's notes line so the report keeps it.
- Never change what an assertion checks: same command, same expected value, same comparison.

## Helpers and setup

- Move a helper function or constant used by only one case inside that case.
- Keep a helper or fixture used by two or more cases at module level, above the first case.
- Leave no function that nothing calls any more (V: `leftover-defs` must be empty).
- Shared setup that every case needs (fixtures, `tmp_path` use, environment pinning) stays at module level before the first case.

## Do not

- Never put the target mark on a method, a nested function, a fixture or a helper.
- Never set the target through a `pytestmark` variable or a mark added at run time.
- Never add `pytest.skip`, `xfail`, `try`/`except` or other changes that hide a failing assertion: the verifier compares the before/after result class and pass/fail counts.
