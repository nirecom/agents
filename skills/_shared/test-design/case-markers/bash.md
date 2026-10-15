> Notation file of `skills/_shared/test-design/case-markers.md` (common rules there). Read it when writing or editing a `.sh` test.

# Case markers in bash tests

## Helper library

- Load line: `source` the helper through the checkout-root variable the test file assigns from its own path (`docs/architecture/claude-code/root-names.md`).
- Write the path so that it ends in `tests/lib/harness.sh` (`bin/check-test-frontmatter.sh` looks for that spelling).
- Place the load line before the first marker and before the first line that runs a hook or bin entrypoint.
- Never define `case_begin()`/`case_end()` yourself, and never guard with `declare -f case_begin` (the helper library provides both; a local definition is a grammar violation).

## Notation

- Open a case with `case_begin "<name>" "<target>"` and close it with `case_end`.
- Put both at column 0 and depth 0 — never inside `if`/`while`/`for`/`case`, a function, or a `{ }` group (the reader takes case boundaries only at depth 0).
- Alternate `case_begin` and `case_end` strictly, with equal counts (an unclosed or doubled marker leaves no readable case).
- Name each case in kebab-case.
- Never write the words `case_begin`/`case_end` in a comment or an inline string (the reader treats them as malformed markers).
- Put marker text a fixture needs into a heredoc body (heredoc bodies are skipped).
- Turn any multi-line inline script placed before a marker (`node -e '...'`, multi-line `"..."`) into a heredoc (an `if` or `{` inside the quotes counts toward depth).

## Malformed reasons

| Reason | Cause |
|---|---|
| `grammar` | A marker line the reader cannot read, a marker word in a comment or string, or a local `case_begin`/`case_end` definition |
| `depth` | A marker inside a block, a function, or a group |
| `target` | A target that breaks the common path rule |
| `balance` | Unpaired or doubled markers |

- A `depth` fault after a multi-line quoted string is reported as `UNCERTAIN_CASE_MARKER` (WARN) instead: retire then treats the file as a whole.

## Examples

Correct — three lines, each at column 0:

- `case_begin "missing-header-blocks" "bin/check-test-frontmatter.sh"`
- `assert_eq "$(run_checker "$fixture")" "1"`
- `case_end`

Incorrect (marker inside a block — `depth`): the same `case_begin` line written between `if [ -n "$fixture" ]; then` and `fi`.
