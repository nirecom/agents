> Detail file of `skills/_shared/test-design.md`. Read it when writing or editing a `.sh` test whose `# Tests:` header lists 2+ paths.

# Case Markers (`case_begin` / `case_end`)

Scope: every NEW `.sh` test entrypoint (`tests/<category>/<name>.sh`) whose `# Tests:` header lists two or more paths.
Hard gate: `bin/check-case-markers.sh`, run by the Edit-time hook `hooks/block-case-markers.js` and by `hooks/pre-commit`.
Why: retire splits such a file per case (a case retires when its `case_begin` target is gone); a marker the parser cannot split degrades retire to whole-file granularity.
Design and fail-open behavior: `docs/architecture/claude-code/case-marker-gate.md`.

## Rules

- Put `case_begin "<name>" "<target>"` and `case_end` at column 0 and depth 0 — never inside `if`/`while`/`for`/`case`, a function, or a `{ }` group (the parser reads case boundaries only at depth 0).
- Name each case in descriptive kebab-case (`missing-header-blocks`), not a serial id like `T1` or `P1` (the name is what a retire report shows).
- Make `<target>` a repo-relative path that also appears in the `# Tests:` header (per-case retire checks that path's survival).
- Alternate `case_begin` and `case_end` strictly, with equal counts (an unclosed or doubled marker leaves no parseable case).
- Never define `case_begin()`/`case_end()` yourself, and never guard with `declare -f case_begin` (sourcing `tests/lib/harness.sh` provides both; a local definition is a grammar violation).
- Never write the words `case_begin`/`case_end` in a comment or an inline string (the parser treats them as malformed markers); when a fixture needs marker text, put it in a heredoc body (heredoc bodies are skipped).
- Turn any multi-line inline script placed before a marker (`node -e '...'`, multi-line `"..."`) into a heredoc (an `if` or `{` inside the quotes counts toward depth, so the gate only WARNs and retire falls back to whole-file).

## What the hard gate checks

- Blocks (HIGH): no markers at all (`MISSING_CASE_MARKERS`); placement, balance, self-definition, or target-shape violations (`MALFORMED_CASE_MARKER`).
- Warns only (WARN): depth uncertain after a multi-line quoted string (`UNCERTAIN_CASE_MARKER`).
- Not checked (soft rules above): kebab-case names and agreement between a target and the `# Tests:` header.
- Existing files already in HEAD are out of scope; a rename counts as a new file.
- Migrate existing marker-less files with `/sweep-tests` STE-4 (`--embed-cases`), never by hand in bulk.
