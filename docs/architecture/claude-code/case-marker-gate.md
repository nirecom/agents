# Case-Marker Gate

A test whose `Tests:` header lists several paths is retired case by case where retire can split
its language (see below): a case goes when the target named on its case marker is gone. That only works when retire can split the file, so a
new multi-path test without well-placed case markers is blocked at two points (#2388): an
`Edit`/`Write`/`MultiEdit` that would leave such a file is rejected before it lands
(`hooks/block-case-markers.js`), and `git commit` blocks as a backstop for anything that reaches
the staging area another way — editFiles, NotebookEdit, or a shell write
(the case-marker gate of the `tests-frontmatter` check,
`hooks/pre-commit.d/checks/tests-frontmatter/case-markers-gate.js`; see
[pre-commit-runner.md](pre-commit-runner.md)).

The gate covers every language whose registry entry names both a `caseMarkerReader` and a
`helperLibrary` (bash, Pester, pytest and JavaScript since #2411); neither layer names a language
itself. Both layers judge with the logic of `bin/check-case-markers.sh` (the hook through that CLI,
the commit layer in process through `hooks/lib/test-gates/case-markers.js`), whose verdict is the
file state `crr_read` reports (`bin/lib/case-record-reader.sh`, ported to
`hooks/lib/test-gates/case-records.js`) — the same reader retire splits with, so a file the gate
accepts is one retire can split. Retire splits per case only for an entry that
also names `caseEmbedRules` (all four supported entries since #2502). The marker name, the hints and the document a
message points to come from the entry's `diagnostics`. Writing rules live in
`skills/_shared/test-design/case-markers.md`, with one notation document per language beside it.

Only new files are judged — a test entrypoint absent from `HEAD`, a rename target included —
and only in a repository that carries the entry's helper library (the hook looks in the working
tree, the commit layer in the staged index). Existing files that predate the gate are left
alone, so an unrelated edit never blocks on old debt (tracked in #2372). The commit layer judges
the staged blob, not the working tree, because the blob is what the commit records.

Two findings warn instead of blocking. A marker whose placement the reader cannot settle
(`UNCERTAIN_CASE_MARKER`; in bash, one that follows a multi-line quoted string such as an inline
`node -e '...'` script) passes, because refusing a correct test on a reader limit is worse than
letting retire fall back to whole-file granularity for that one file. A language whose runtime
is not installed (`CASE_MARKER_RUNTIME_UNAVAILABLE`) passes too: its reader cannot run here, and
a missing tool must not stop a commit. A file whose language has no test case reader — a
`recognized-only` entry, or no entry at all — passes with `CASE_MARKER_READER_UNSUPPORTED`
whatever its header holds, so an unchecked file is reported instead of passing silently (#2502).
A file whose `caseEmbedRules` `deps` op failed passes with `CASE_EMBED_DEPS_FAILED`: its markers
were read, but its case records are incomplete.

## Self-implemented harness

The same two points also judge a test file of any language with `bin/check-self-impl.sh`
(#2502): a hand-made pass/fail counter, or a redefinition of a name the entry's helper library
defines, is `SELF_IMPLEMENTED_HARNESS` and blocks. A new file blocks on any detection. An existing
file is compared with its HEAD copy (`--head`): detections are counted per (kind, detail) key, and
only those beyond HEAD's count for the same key block, so an existing file's old counter does not
stop an unrelated edit, while adding one more of the same kind does. The detection is the entry's `caseEmbedRules`
`self-impl` op (reached through `report` in `hooks/lib/test-gates/self-impl.js`); its limits are
in [test-language-registry/case-embed-ops.md](test-language-registry/case-embed-ops.md). A
language with no `caseEmbedRules` passes with `SELF_IMPL_CHECK_UNSUPPORTED`, and one whose runtime
is missing with `SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE`. The commit layer calls it from the staged
frontmatter check (`stagedCheck` in `hooks/lib/test-gates/frontmatter/staged.js`, the logic of
`bin/check-test-frontmatter.sh --staged`), with the same new-file and HEAD-count rule. When HEAD
lists the file but its content cannot be read, the HEAD copy is empty and the file is judged as
new: the commit blocks on any detection (fail-closed), with no separate diagnostic.

## Test-language match

`rules/test.md` "Test Language" says a test is written in the language of the code it tests. The
same two points enforce it with `bin/check-test-language-match.sh` (#2502), on every `tests/` file
outside `tests/_archive/` and `tests/lib/`, new or existing (the commit layer runs the same logic,
`hooks/lib/test-gates/language-match.js`, from
`hooks/pre-commit.d/checks/tests-frontmatter/language-match-gate.js`). The test's language is its
registry entry; a code target's language is the entry whose `sourcePatterns` match its name, else
its shebang (`tokenLanguage` in `hooks/lib/test-gates/code-language.js`). A target with no code
language (documentation, JSON) is not judged. A mismatch is `TEST_LANGUAGE_MISMATCH`, and the line
names the code language's new-file name shape.

- A new file is judged on every `Tests:` header token and, when `crr_read` reports it conforming,
  on every case target too — so a header naming same-language code cannot hide a case that tests
  another language.
- A file in `HEAD` blocks only on a mismatch `HEAD` did not have, so editing or deleting an old
  case never blocks. The hook and the commit layer pass the `HEAD` blob with `--head <copy>`. When
  both versions are conforming, `pair` (`hooks/lib/test-gates/language-match/pairing.js`) pairs cases: same name first, then a renamed case
  paired 1:1 with a vanished `HEAD` case that had the same target; an unpaired case is added. An
  added case blocks on a mismatch; a paired one blocks only if its `HEAD` target matched. Otherwise
  only header tokens absent from the `HEAD` header are judged.
- When either version is not conforming, cases cannot be paired, so a grown file blocks with
  `CASE_ADDED_WITHOUT_MARKERS`: by the `case-count` op when both versions can be counted (pytest,
  pester), else by non-blank, non-comment lines (always for bash and js). Whatever language the added case tests, it blocks; the
  line carries no line number and says to add the entry's marker to every case first, after which
  each case's target is judged. Fixes that do not grow the count (edits, deletions, renames,
  reordering) pass; one case removed and one added passes; an added line in a version that cannot
  be counted blocks. A new non-conforming file counts from 0.
- Markers are required only where the working `Tests:` header does not list exactly one path, so
  the case-addition check is skipped, for new and existing files alike, when the working header
  has one token; its header tokens are still judged. A header with no token stays fail-closed, and
  an edit that grows a one-path header to two paths blocks like any other multi-path file.
- This case-addition check applies to test entrypoints only: a 2-level `tests/<category>/<file>`
  file matching a `supported` registry pattern whose helper library exists. Other candidates
  (`tests/run-all.sh`, sibling part files) get the language judgment alone.
- Marker migration: when `HEAD` is not conforming and the working version is, the case-addition
  check is skipped so that adding markers never blocks. Every working case target is judged
  instead (`TEST_LANGUAGE_MISMATCH` with the case's begin line), except a target whose key was a
  `HEAD` `Tests:` token; the header-token diff still runs.
- A test whose language has no registry entry passes with `TEST_LANGUAGE_UNSUPPORTED`.

A test that is a `rules/test.md` exception declares it in `Tags:` as `test-lang-exception:<value>`
and is judged for neither mismatch nor case addition. Only the first `headerMaxLines` (10) lines of
the file are read for `Tests:` / `Tags:` (`readHeaders` in `hooks/lib/test-gates/headers.js`), so a `Tags:` line
further down is body text and declares nothing. The allowed values are the registry key `testLanguageExceptions`
(see [test-language-registry.md](test-language-registry.md)). A value outside the list, or two
declarations, is `INVALID_TEST_LANG_EXCEPTION` — on any file, mismatch or not — and counts as no
declaration, so a bad value cannot slip the mismatch check. Validation lives in this CLI only; the
frontmatter check (`checkContent` in `hooks/lib/test-gates/frontmatter/content.js`) does not repeat it, so the
edit-time and commit-time verdicts come from one place and a commit never shows the line twice.

Overlap with #2440: deciding whether an existing file gained a case (`pair` and `caseAddition` under
`hooks/lib/test-gates/language-match/`) and collecting existing-file edits at edit time
(`hooks/lib/block-case-markers/language-match-candidates.js`) are what #2440 needs to enforce case
markers on existing files. Both are private to this check for now; #2440 should expose them as a
shared entry point and call them from both checks. The case-marker check itself still
judges new files only.

## CLI output and the original path

| CLI | HIGH (blocks) | WARN (reported, never blocks) |
|---|---|---|
| `bin/check-case-markers.sh` | `MISSING_CASE_MARKERS`, `MALFORMED_CASE_MARKER` | `UNCERTAIN_CASE_MARKER`, `CASE_EMBED_DEPS_FAILED`, `CASE_MARKER_RUNTIME_UNAVAILABLE`, `CASE_MARKER_READER_UNSUPPORTED` |
| `bin/check-self-impl.sh` | `SELF_IMPLEMENTED_HARNESS` | `SELF_IMPL_CHECK_UNSUPPORTED`, `SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE` |
| `bin/check-test-language-match.sh` | `TEST_LANGUAGE_MISMATCH`, `CASE_ADDED_WITHOUT_MARKERS`, `INVALID_TEST_LANG_EXCEPTION` | `TEST_LANGUAGE_UNSUPPORTED` |

Every CLI prints one line per finding, `HIGH: <file> …: <description> code=<CODE>` or
`WARN: <file> …: <description> code=<CODE>`, and exits 0 (no HIGH), 1 (HIGH) or 2 (infra error).
The hook keeps only lines matching `/^HIGH: .* code=/` from an exit 1 and joins every CLI's HIGH
lines into one block reason; it collects `/^WARN: .* code=/` lines at any exit and sends them as
`additionalContext` (or adds them to the block reason next to a HIGH). A CLI whose file is missing
is skipped on its own. The commit layer prints the WARN lines on stderr.

Both layers judge a temp copy, so each CLI takes `--rel <repo-relative original path>` for one
file (with two or more files it exits 2). The original path picks the registry entry and names the
file in the output; the copy is only read. Without `--rel` the file's own path is used. An
argument, not an environment variable, so the value a verdict used is visible on the command line
and cannot leak into the next file of a loop. The hook runs the CLIs from the repository root.
`bin/check-test-language-match.sh` also takes `--head <copy>` (one file only, like `--rel`); a
missing copy is an infra error.

## Failure handling

Both layers fail open on infrastructure errors (checker missing, timeout, unreadable payload, a git lookup that cannot say whether the file is in `HEAD`),
and the commit layer says so on stderr, so a gate that stops working never does so silently.
Neither `WORKFLOW_OFF` nor `WORKTREE_OFF` suspends the gate (see [marker-bypass-contract.md](marker-bypass-contract.md)).
