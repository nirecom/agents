# Case-Marker Gate

A test whose `Tests:` header lists several paths is retired case by case where retire can split
its language (see below): a case goes when the target named on its case marker is gone. That only works when retire can split the file, so a
new multi-path test without well-placed case markers is blocked at two points (#2388): an
`Edit`/`Write`/`MultiEdit` that would leave such a file is rejected before it lands
(`hooks/block-case-markers.js`), and `git commit` blocks as a backstop for anything that reaches
the staging area another way — editFiles, NotebookEdit, or a shell write
(`_precommit_check_tests_case_markers` in `hooks/lib/precommit-tests-frontmatter.sh`).

The gate covers every language whose registry entry names both a `caseMarkerReader` and a
`helperLibrary` (bash, Pester, pytest and JavaScript since #2411); neither layer names a language
itself. Both layers judge with `bin/check-case-markers.sh`, whose verdict is the file state
`crr_read` reports (`bin/lib/case-record-reader.sh`) — the same reader retire splits with, so a
file the gate accepts is one retire can split. Retire splits per case only for an entry that
also names `caseEmbedRules` (bash today); Pester, pytest and JavaScript files are retired whole
until #2502 adds theirs. The marker name, the hints and the document a
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
a missing tool must not stop a commit.

Both layers fail open on infrastructure errors (checker missing, timeout, unreadable payload, a git lookup that cannot say whether the file is in `HEAD`),
and the commit layer says so on stderr, so a gate that stops working never does so silently.
Neither `WORKFLOW_OFF` nor `WORKTREE_OFF` suspends the gate (see [marker-bypass-contract.md](marker-bypass-contract.md)).
