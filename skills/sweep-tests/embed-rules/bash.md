> Rewrite rules for one bash test file under `/sweep-tests --embed-cases` (STE-4). The embed subagent reads this file; `bash_case_embed rules-doc` names it.

# Embedding Case Markers — bash

Goal: the file sources the shared harness and every test sits in a `case_begin`/`case_end` block, so retire can drop one case when its target is deleted.
The verifier (`bin/verify-case-embed.sh`) re-checks every rule marked (V); a file that fails is reverted and retried.
Marker grammar is owned by `skills/_shared/test-design/case-markers.md` — follow it; this file adds only the rewrite rules.

## Input and output

- Rewrite the file given as the item's input path; write the whole new file to the item's output path. Never touch any other file.
- Embed every file the gate hands you; never skip one because it is hard to read.
- Keep the shebang, the `# Tests:` / `# Tags:` header and its first-10-lines position as given (the header was already fixed in Stage 1).

## Harness

- Source `tests/lib/harness.sh` once near the top, with the path form the file already uses for `AGENTS_DIR` (V).
- Delete every self-implemented harness piece and use the harness one instead: `pass`/`fail`/`skip`/`assert_eq` definitions, `PASS=0`/`FAIL=0` counters, local `case_begin`/`case_end` (V).
- Keep the trailer `echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"` and the final `exit` on the fail count; the harness has no replacement for them.
- A file that already sources another `tests/lib/*harness*.sh` never reaches you (it is skipped as `narrow-harness`).

## Cases

- One case per original test function or test block; never merge two tests into one case or split one test across cases.
- Name each case in descriptive kebab-case taken from what the test checks.
- Use one `# Tests:` path as the target of each case (V: every header path is the target of at least one case).
- A block that checks several targets at once and cannot be split goes to its main target only; record the choice in the item's notes line so the report keeps it.
- Never change what an assertion checks: same command, same expected value, same comparison.

## Helpers and setup

- Move a function, variable or setup step used by only one case inside that case.
- Keep a helper used by two or more cases (or outside every case) at top level, above the first case.
- Leave no function that nothing calls any more (V: `leftover-defs` must be empty).
- Shared setup that every case needs (temp dir, `trap`, environment pinning) stays at top level before the first case.

## Do not

- Never put a marker inside a function, loop, `if`, `{ }` group or heredoc.
- Never write the marker words in a comment or string.
- Never add `|| true`, `set +e` or other changes that hide a failing assertion: the verifier compares the before/after result class and pass/fail counts.
