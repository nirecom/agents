> Rewrite rules for one JavaScript test file (`*.js`) under `/sweep-tests --embed-cases` (STE-4). The embed subagent reads this file; `js_case_embed rules-doc` names it.

# Embedding Case Markers — JavaScript

Goal: the file requires the shared harness and every test sits between a column-0 `caseBegin("<name>", "<target>");` and `caseEnd();`, so retire can drop one case when its target is deleted.
The verifier (`bin/verify-case-embed.sh`) re-checks every rule marked (V); a file that fails is reverted and retried.
Marker grammar is owned by `skills/_shared/test-design/case-markers/js.md` — follow it; this file adds only the rewrite rules.

## Input and output

- Rewrite the file given as the item's input path; write the whole new file to the item's output path. Never touch any other file.
- Embed every file the gate hands you; never skip one because it is hard to read.
- Keep the shebang, the `// Tests:` / `// Tags:` header and its first-10-lines position as given (the header was already fixed in Stage 1).
- The gate never hands you a file of a shape it does not embed yet; `js_case_embed skip-reason` names it:

| Word | Shape |
|---|---|
| `custom-runner` | The file does not use `node:test` (its own runner or a plain script) |

## Harness

- Require `tests/lib/harness.js` once at the top, with the load line of the notation doc, listing `caseBegin` and `caseEnd` (V).
- Delete every self-implemented harness piece and use the harness one instead: top-level `PASS = 0` / `FAIL = 0` counters and functions that redefine a harness name (V).
- Keep `assert` calls as they are; the `node:test` reporter counts the results, so add no trailer.

## Cases

- One case per original top-level `test(...)` or `describe(...)` call; never merge two tests into one case or split one test across cases.
- Name each case in descriptive kebab-case taken from what the test checks.
- Use one `// Tests:` path as the target of each case (V: every header path is the target of at least one case).
- A block that checks several targets at once and cannot be split goes to its main target only; record the choice in the item's notes line so the report keeps it.
- Never change what an assertion checks: same call, same expected value, same comparison.

## Helpers and setup

- Move a function, constant or setup step used by only one case inside that case's range.
- Keep a helper used by two or more cases (or outside every case) at top level, above the first case.
- Leave no function that nothing calls any more (V: `leftover-defs` must be empty).
- Shared setup that every case needs (`require` lines, temp dir, `before`/`after` hooks, environment pinning) stays at top level before the first case.

## Do not

- Never indent a marker or put one inside a function, a `describe` body, a block comment or a template string.
- Never call the markers through a variable or another object.
- Never add `{ skip: true }`, `todo`, `try`/`catch` or other changes that hide a failing assertion: the verifier compares the before/after result class and pass/fail counts.
