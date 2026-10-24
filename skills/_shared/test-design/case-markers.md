> Detail file of `skills/_shared/test-design.md`. Read it when writing or editing a test whose `Tests:` header lists 2+ paths.

# Case Markers

Scope: every NEW test entrypoint (`tests/<category>/<file>`) whose `Tests:` header lists two or more paths, in a language whose registry entry names a `caseMarkerReader`.
Hard gate: `bin/check-case-markers.sh`, run by the Edit-time hook `hooks/block-case-markers.js` and by `hooks/pre-commit`.
Why: retire splits such a file per case (a case retires when its target is gone); a marker the reader cannot split degrades retire to whole-file granularity. Today only bash retires per case; the other languages retire whole files until #2502, but write markers now so they split once it lands.
Design and fail-open behavior: `docs/architecture/claude-code/case-marker-gate.md`.

## Notation per language

- Match the file name to its entry in `hooks/lib/test-language-registry.json`, then Read that entry's `notationDoc` before writing a marker.
- The notation documents live in `skills/_shared/test-design/case-markers/`, one per language (`bash.md` for a `.sh` test).
- Each notation document owns its language's marker spelling, helper-library load line, and malformed reasons.

## Rules common to every language

- Give every case exactly one target (the file it guards).
- Make each target a repo-relative path of `A-Z a-z 0-9 . _ / -` only, with no leading `/` or `./` and no `..` segment.
- Make each target a path that also appears in the `Tests:` header (per-case retire checks that path's survival).
- Write name and target as literal strings (the reader takes them from the source text and never runs the file).
- Place markers at the top level of the file only; cases never nest or overlap.
- Read a case's range as the lines from its opening marker to its closing line, both included.
- Give each case a name unique within its file (a repeated name is `MALFORMED_CASE_MARKER`, reason `duplicate-name`).
- Name each case descriptively (`missing-header-blocks`), not by a serial id like `T1` or `P1` (the name is what a retire report shows).

## What the hard gate checks

- Blocks (HIGH): no markers at all (`MISSING_CASE_MARKERS`); a marker the language's reader rejects (`MALFORMED_CASE_MARKER`, with the reason in parentheses).
- Warns only (WARN): a marker whose placement the reader cannot settle (`UNCERTAIN_CASE_MARKER`); a language runtime that is not installed (`CASE_MARKER_RUNTIME_UNAVAILABLE`).
- Not checked (soft rules above): descriptive names and agreement between a target and the `Tests:` header.
- Existing files already in HEAD are out of scope of this gate; a rename counts as a new file.
- Adding a case to an existing marker-less file whose working `Tests:` header lists 2+ paths (or none) is blocked as `CASE_ADDED_WITHOUT_MARKERS` by `bin/check-test-language-match.sh`; a file whose header keeps exactly one path is not checked. Design: `docs/architecture/claude-code/case-marker-gate.md`.
- Migrate existing marker-less files with `/sweep-tests` STE-4 (`--embed-cases`), never by hand in bulk.
