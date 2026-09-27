# Case-Marker Gate

A `.sh` test whose `# Tests:` header lists several paths is retired case by case: a case goes
when the target named on its `case_begin` line is gone. That only works when retire can split
the file, so a new multi-path test without well-placed `case_begin`/`case_end` markers is
blocked at two points (#2388): an `Edit`/`Write`/`MultiEdit` that would leave such a file is
rejected before it lands (`hooks/block-case-markers.js`), and `git commit` blocks as a backstop
for anything that reaches the staging area another way — editFiles, NotebookEdit, or a shell
write (`_precommit_check_tests_case_markers` in `hooks/lib/precommit-tests-frontmatter.sh`).

Both layers judge with `bin/check-case-markers.sh`, whose verdict comes from the retire parser
itself (`trp_marker_conformance`), so a file the gate accepts is one retire can split. Writing
rules live in `skills/_shared/test-design/case-markers.md`.

Only new files are judged — a test entrypoint absent from `HEAD`, a rename target included —
and only in a repository carrying `tests/lib/harness.sh`. Existing files that predate the gate
are left alone, so an unrelated edit never blocks on old debt (tracked in #2372). The commit
layer judges the staged blob, not the working tree, because the blob is what the commit records.

A marker that follows a multi-line quoted string (an inline `node -e '...'` script, say) gets a
warning, not a block: the parser cannot tell whether a keyword inside the quotes opened a block,
and refusing a correct test on a parser limit is worse than letting retire fall back to
whole-file granularity for that one file.

Both layers fail open on infrastructure errors (checker missing, timeout, unreadable payload, a git lookup that cannot say whether the file is in `HEAD`),
and the commit layer says so on stderr, so a gate that stops working never does so silently.
Set `CASE_MARKERS_ENFORCE=off` in the config dir's `.env` to disable both layers at once; an
ambient shell variable of the same name is ignored, and neither `WORKFLOW_OFF` nor
`WORKTREE_OFF` suspends the gate (see [marker-bypass-contract.md](marker-bypass-contract.md)).
