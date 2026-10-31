"use strict";
// Tests: bin/check-session-id-ssot.sh
// Tags: TL1, bin, session-id, fixture, test-lang-exception:symmetry, scope:issue-specific
// Fixture rows of tests/bin/feature-2507-session-id-ssot-node.js (#2507). Holds no case markers.
// Each row is one file of a positional run: { path, lines | bytes, want: [reported line numbers] }.
// @S@ / @E@ are the retired relay names (this tree is not tombstone-exempt), @CR@ a carriage return;
// the entrypoint fills them in. Rows mirror tests/bin/bin-check-session-id-ssot.sh (G / T / L / LX)
// plus the #2507 additions: waiver placement, NUL files and report-line shape.

const WAIVER = "// session-id-ssot: waived (bootstrap) — runs before the resolver is loadable";

// Direct-read gate (READ_RE). Allowlisted paths come from the guard's own path tables at run time.
const READ_ROWS = [
  { path: "hooks/plain.js", lines: ["const x = process.env.HOME;", "module.exports = { x };"], want: [] },
  { path: "hooks/g2.js", lines: ["const sid = process.env.SESSION_ID;"], want: [1] },
  { path: "bin/g4.js", lines: ["const sid = process.env.CLAUDE_CODE_SESSION_ID;"], want: [1] },
  { path: "hooks/g5.js", lines: ['const sid = process.env["CLAUDE_CODE_SESSION_ID"];'], want: [1] },
  { path: "hooks/g6.js", lines: ["const sid = process.env['SESSION_ID'];"], want: [1] },
  { path: "hooks/g6-spaced.js", lines: ['const sid = process.env[ "SESSION_ID" ];'], want: [1] },
  { path: "hooks/g6-end.js", lines: ["x = process.env.SESSION_ID"], want: [1] },
  { path: "hooks/g7.js", lines: ["const w = process.env.WORKFLOW_SESSION_ID;"], want: [] },
  { path: "hooks/g7-suffix.js", lines: ["const w = process.env.SESSION_ID_X + process.env.SESSION_IDS;"], want: [] },
  { path: "bin/g8.sh", lines: ["#!/usr/bin/env bash", 'echo "$CLAUDE_CODE_SESSION_ID ${SESSION_ID}"'], want: [] },
  { path: "hooks/g9.js", lines: ["const name = pick();", "const v = process.env[name];"], want: [] },
  { path: "tests/some-test.sh", lines: ["node -e 'console.log(process.env.CLAUDE_CODE_SESSION_ID)'"], want: [] },
  { path: "docs/note.md", lines: ["Reads process.env.CLAUDE_CODE_SESSION_ID at startup."], want: [] },
  { path: "README.md", lines: ["Set process.env.SESSION_ID before running."], want: [] },
  { path: "changelog/2026-09.md", lines: ["- now reads process.env.SESSION_ID"], want: [] },
  { path: "hooks/g13c.js", lines: [`const sid = process.env.CLAUDE_CODE_SESSION_ID; ${WAIVER}`, "const unrelated = 1;",
    "const other = process.env.SESSION_ID;"], want: [3] },
  { path: "hooks/g14.js", lines: [`const sid = process.env.SESSION_ID; ${WAIVER}`], want: [] },
  { path: "hooks/g15.js", lines: [WAIVER, "const sid = process.env.SESSION_ID;"], want: [] },
  { path: "hooks/g16.js", lines: ["const sid = process.env.SESSION_ID; // session-id-ssot: waived (bootstrap) — "], want: [1] },
  { path: "hooks/waiver-two-above.js", lines: [WAIVER, "", "const sid = process.env.SESSION_ID;"], want: [3] },
  { path: "hooks/waiver-below.js", lines: ["const sid = process.env.SESSION_ID;", WAIVER], want: [1] },
  { path: "hooks/waiver-no-role.js", lines: ["const sid = process.env.SESSION_ID; // session-id-ssot: waived — no role given"], want: [1] },
  { path: "hooks/waiver-covers-one.js", lines: [WAIVER, "const a = process.env.SESSION_ID;", "const b = process.env.SESSION_ID;"], want: [3] },
  { path: "hooks/indented.js", lines: ["\t    const sid = process.env.SESSION_ID;"], want: [1] },
  { path: "hooks/crlf.js", lines: ["const sid = process.env.SESSION_ID;@CR@"], want: [1] },
  { path: "hooks/two-on-a-line.js", lines: ["f(process.env.SESSION_ID, process.env.CLAUDE_CODE_SESSION_ID);"], want: [1] },
  // NUL-row basenames avoid the Windows device name "nul": git on Windows cannot index such a file.
  { path: "hooks/nul-byte.js", bytes: ["const sid = process.env.SESSION_ID;\n", "\0\n"], want: [] },
  { path: "hooks/nul-late.js", bytes: ["const ok = 1;\n".repeat(50), "const sid = process.env.SESSION_ID;\n\0"], want: [] },
];

// Tombstone gate (TOMBSTONE_RE + the registry's envClearLine). Exempt paths come from the guard's tables.
const TOMB_ROWS = [
  { path: "lib/a.js", lines: ["const sid = process.env.@S@;"], want: [1] },
  { path: "skills/x/SKILL.md", lines: ["Run `echo $@S@` first."], want: [1] },
  { path: "tests/foo.sh", lines: ["unset @S@"], want: [1] },
  { path: "bin/x.sh", lines: ['cat "$@E@"'], want: [1] },
  { path: "skills/x/look-alike.md", lines: ["Read $CLAUDE_CODE_SESSION_ID.", "Ignore MY_@S@_X and @E@_OLD."], want: [] },
  { path: "docs/history/2026.md", lines: ["- dropped @S@ relay"], want: [] },
  { path: "docs/history.md", lines: ["- dropped @E@ read"], want: [] },
  { path: "changelog/2026.md", lines: ["- dropped @S@ relay"], want: [] },
  { path: "CHANGELOG.md", lines: ["- dropped @E@ read"], want: [] },
  { path: "tests/_archive/a.sh", lines: ["unset @S@"], want: [] },
  { path: "hooks/lib/temporary-migrations/legacy-session-id-relay-purge.js.txt", lines: ["@S@"], want: [1] },
  { path: "hooks/w.js", lines: [`const sid = process.env.@S@; ${WAIVER}`], want: [1] },
  { path: "tests/hooks/unset-plain.sh", lines: ["#!/usr/bin/env bash", "unset @S@ CLAUDE_CODE_SESSION_ID @E@"], want: [] },
  { path: "tests/hooks/unset-quiet.sh", lines: ["  unset TERM_PROGRAM @S@ @E@ 2>/dev/null || true"], want: [] },
  { path: "tests/lib/dash-u.sh", lines: ["DENV=(env -u WORKFLOW_STATE_DIR -u @S@", "  -u CLAUDE_CODE_SESSION_ID -u @E@)"], want: [] },
  { path: "tests/hooks/mixed.sh", lines: ["unset @S@ 2>/dev/null || true", "# @E@ is cleared above", "@E@=/tmp/x",
    "export @S@=abc"], want: [2, 3, 4] },
  { path: "tests/hooks/chained.sh", lines: ['unset @S@ && echo "$@E@"', "unset FOO", 'echo "$@S@" -u @E@'], want: [1, 3] },
  { path: "bin/lib/other-exec.sh", lines: ["        unset @S@ CLAUDE_CODE_SESSION_ID @E@"], want: [1] },
  { path: "tests/hooks/note.txt", lines: ["unset @S@"], want: [1] },
  { path: "bin/lib/run-tests-baseline-exec.sh", lines: ["        unset @S@ CLAUDE_CODE_SESSION_ID @E@", "# @S@ comment"], want: [2] },
  { path: "tests/lib/harness.sh", lines: ["unset @S@ @E@"], want: [] },
  { path: "tests/a/b/c/rs-deep.Tests.ps1", lines: ["Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue"], want: [] },
  { path: "tests/a/b/c/test_rs_deep.py", lines: ['os.environ.pop("@S@", None)'], want: [] },
  { path: "tests/a/b/c/rs-deep.js", lines: ["delete process.env.@S@;"], want: [] },
  { path: "tests/hooks/crlf-unset.sh", lines: ["unset @S@@CR@"], want: [] },
  { path: "lib/crlf.js", lines: ["const x = process.env.@S@;@CR@"], want: [1] },
  { path: "tests/hooks/two-hits.sh", lines: ["export @S@=1", "unset @E@", "echo $@E@"], want: [1, 3] },
  { path: "tests/hooks/nul-byte.sh", bytes: ["export @S@=1\n", "\0\n"], want: [] },
  { path: "lib/nul-byte.js", bytes: ["\0", "const sid = process.env.@S@;\n"], want: [] },
];

// LX (#2411): one clear line per file, judged by the file's own language part.
const LX_TABLE = `
js-delete-sid          | tests/hooks/js-delete-sid.js           | 0 | delete process.env.@S@;
js-delete-no-semicolon | tests/hooks/js-delete-env.js           | 0 | delete process.env.@E@
js-delete-indented     | tests/tests/sub/js-indented.js         | 0 |     delete process.env.@S@;
js-harness-lib         | tests/lib/harness.js                   | 0 |   delete process.env.@E@;
js-list-literal        | tests/hooks/js-list.js                 | 1 | const R = ["@S@", "@E@"];
js-assignment          | tests/hooks/js-assign.js               | 1 | process.env.@S@ = "x";
js-bracket-delete      | tests/hooks/js-bracket.js              | 1 | delete process.env["@S@"];
js-trailing-comment    | tests/hooks/js-comment.js              | 1 | delete process.env.@S@; // clear
js-bash-unset          | tests/hooks/js-unset.js                | 1 | unset @S@
js-crlf                | tests/hooks/js-crlf.js                 | 0 | delete process.env.@S@;@CR@
js-tests-top-level     | tests/top.js                           | 1 | delete process.env.@S@;
js-lib-not-harness     | tests/lib/other.js                     | 0 | delete process.env.@S@;
js-bin-path            | bin/x.js                               | 1 | delete process.env.@S@;
ps-path-form           | tests/hooks/ps-path.Tests.ps1          | 0 | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-backslash-force     | tests/hooks/ps-bs.Tests.ps1            | 0 | Remove-Item Env:\\@S@ -Force
ps-harness-lib         | tests/lib/harness.ps1                  | 0 |     Remove-Item -Path Env:@E@ -ErrorAction SilentlyContinue
ps-assignment          | tests/hooks/ps-assign.Tests.ps1        | 1 | $env:@S@ = 'x'
ps-other-option        | tests/hooks/ps-recurse.Tests.ps1       | 1 | Remove-Item Env:@S@ -Recurse
ps-crlf                | tests/hooks/ps-crlf.Tests.ps1          | 0 | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue@CR@
ps-not-a-tests-file    | tests/hooks/helper.ps1                 | 1 | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
ps-lib-not-harness     | tests/lib/other.ps1                    | 1 | Remove-Item -Path Env:@S@ -ErrorAction SilentlyContinue
py-double-quote        | tests/hooks/test_py_dq.py              | 0 | os.environ.pop("@S@", None)
py-single-quote        | tests/hooks/test_py_sq.py              | 0 | os.environ.pop('@E@', None)
py-harness-lib         | tests/lib/harness.py                   | 0 |     os.environ.pop("@S@", None)
py-pop-no-default      | tests/hooks/test_py_nodefault.py       | 1 | os.environ.pop("@S@")
py-crlf                | tests/hooks/test_py_crlf.py            | 0 | os.environ.pop("@S@", None)@CR@
py-not-a-test-file     | tests/hooks/helper.py                  | 1 | os.environ.pop("@S@", None)
py-lib-not-harness     | tests/lib/other.py                     | 1 | os.environ.pop("@S@", None)
sh-js-delete           | tests/hooks/sh-delete.sh               | 1 | delete process.env.@S@;
sh-python-pop          | tests/hooks/sh-pop.sh                  | 1 | os.environ.pop("@S@", None)
`;

function lxRows() {
  return LX_TABLE.split("\n").filter((l) => l.trim() !== "").map((l) => {
    const [name, p, want] = l.split("|").map((s) => s.trim());
    const line = l.split("|").slice(3).join("|").replace(/^ /, "");
    return { name, path: p, lines: [line], want: want === "1" ? [1] : [] };
  });
}

module.exports = { READ_ROWS, TOMB_ROWS, lxRows, WAIVER };
