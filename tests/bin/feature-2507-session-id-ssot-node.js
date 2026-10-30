"use strict";
// Tests: bin/check-session-id-ssot/main.js, bin/check-session-id-ssot.sh
// Tags: TL1, bin, session-id, tombstone, table-driven, test-lang-exception:symmetry, scope:issue-specific, fail-closed
// #2507 (D7): the session-id guard moves to Node and starts no child process. Each row set runs
// through the pre-port bash guard (green now: it pins the expectation) and through run() of the
// Node port, which must print the same bytes and exit the same. Additions over the bash suite:
// waiver placement, the clear-line parts' accept / reject lines, fail-closed parts and NUL files.
// Retired names are spelled split (this file is not tombstone-exempt). Contract assumed for run():
// feature-2507-session-id-ssot-node/fixture.js. Plan gap: with no paths the port still lists the tree
// via `git ls-files`, so the zero-spawn case allows exactly that one git call and nothing else.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const { after, test } = require("node:test");

const counter = require("./feature-2507-session-id-ssot-node/spawn-counter");
counter.install();
const F = require("./feature-2507-session-id-ssot-node/fixture");
const R = require("./feature-2507-session-id-ssot-node/rows");
const T = require("./feature-2507-session-id-ssot-node/tables-and-registry");
const G = require("./feature-2507-session-id-ssot-node/git-failure");

const restore = isolate();
after(() => {
  F.cleanup();
  restore();
});

const bashRun = async (cwd, argv) => F.bashCli(cwd, argv);
const nodeRun = (cwd, argv) => F.nodeRun(cwd, argv);
const WAIVER_ROWS = R.READ_ROWS.filter((r) => /^hooks\/(g13c|g14|g15|g16|waiver-)/.test(r.path));
const NUL_ROWS = [...R.READ_ROWS, ...R.TOMB_ROWS].filter((r) => r.bytes);
const PART_ROWS = R.TOMB_ROWS.filter((r) => /^tests\/(hooks|lib)\/(unset-|dash-u|mixed|chained|crlf-unset|two-hits|harness)/.test(r.path));

// rowsRun(run, tag, rows, gate) — one positional run over rows, checked against the rows' verdict.
async function rowsRun(run, tag, rows, gate) {
  const got = await run(F.makeTree(tag, rows), ["--", ...rows.map((r) => r.path)]);
  F.assertRun(got, F.verdict(rows, gate), tag);
  return got;
}

// parity(tag, rows, gate) — the Node port answers what the bash guard answers on the same tree.
async function parity(tag, rows, gate) {
  const node = await rowsRun(nodeRun, tag, rows, gate);
  const bash = F.bashCli(F.makeTree(`${tag}-bash`, rows), ["--", ...rows.map((r) => r.path)]);
  const fold = (s) => s.replace(/\r\n/g, "\n");
  assert.strictEqual(fold(node.stdout), fold(bash.stdout), `${tag}: Node stdout equals the bash guard's`);
}

caseBegin("bash-read-gate-rows", "bin/check-session-id-ssot.sh");
test("bash guard: direct reads, excluded trees, allowlist, waivers, NUL files", () => rowsRun(bashRun, "read", R.READ_ROWS, "read"));
caseEnd();

caseBegin("node-read-gate-rows", "bin/check-session-id-ssot/main.js");
test("Node run(): direct-read gate over the same rows", () => parity("read", R.READ_ROWS, "read"));
caseEnd();

caseBegin("bash-tombstone-gate-rows", "bin/check-session-id-ssot.sh");
test("bash guard: retired names, excluded and exempt paths, isolation scope", () => rowsRun(bashRun, "tomb", R.TOMB_ROWS, "tomb"));
caseEnd();

caseBegin("node-tombstone-gate-rows", "bin/check-session-id-ssot/main.js");
test("Node run(): tombstone gate over the same rows", () => parity("tomb", R.TOMB_ROWS, "tomb"));
caseEnd();

caseBegin("bash-lx-clear-lines", "bin/check-session-id-ssot.sh");
test("bash guard: one clear line per language part and path (LX)", () => rowsRun(bashRun, "lx", R.lxRows(), "tomb"));
caseEnd();

caseBegin("node-lx-clear-lines", "bin/check-session-id-ssot/main.js");
test("Node run(): LX clear lines judged by each language's Node part", () => parity("lx", R.lxRows(), "tomb"));
caseEnd();

caseBegin("node-waiver-same-or-previous-line-only", "bin/check-session-id-ssot/main.js");
test("Node run(): a waiver counts on the read's line or the line before, nowhere else", () => parity("waiver", WAIVER_ROWS, "read"));
caseEnd();

caseBegin("node-clear-line-part-accepts-and-rejects", "bin/check-session-id-ssot/main.js");
test("Node run(): unset / -u lines pass, comments, exports and chained reads are reported", () => parity("part", PART_ROWS, "tomb"));
caseEnd();

caseBegin("node-nul-files-skipped", "bin/check-session-id-ssot/main.js");
test("Node run(): a file holding NUL is binary to both gates and judged by neither", async () => {
  assert.ok(NUL_ROWS.length >= 4, "NUL rows present");
  await parity("nul-read", NUL_ROWS.filter((r) => !r.bytes.join("").includes("@")), "read");
  await parity("nul-tomb", NUL_ROWS.filter((r) => r.bytes.join("").includes("@")), "tomb");
});
caseEnd();

caseBegin("node-part-unreachable-fails-closed", "bin/check-session-id-ssot/main.js");
test("Node run(): an envClearLine function or file that cannot be reached reports the line (RS3/RS4)", () => T.partUnreachable(nodeRun));
caseEnd();

caseBegin("node-registry-scope-follows-entries", "bin/check-session-id-ssot/main.js");
test("Node run(): isolation scope follows the entries' patterns and helperLibrary.path (RS5/RS6)", () => T.registryScope(nodeRun));
caseEnd();

caseBegin("bash-path-tables", "bin/check-session-id-ssot.sh");
test("bash guard: table rows, CRLF tables, broken shapes, fallback notice", async () => {
  await T.tablesAddRows(bashRun);
  await T.tablesBroken(bashRun);
  await T.tablesFallback(bashRun);
});
caseEnd();

caseBegin("node-path-tables", "bin/check-session-id-ssot/main.js");
test("Node run(): table rows, CRLF tables, broken shapes, fallback notice", async () => {
  await T.tablesAddRows(nodeRun);
  await T.tablesBroken(nodeRun);
  await T.tablesFallback(nodeRun);
});
caseEnd();

caseBegin("bash-whole-tree-and-flags", "bin/check-session-id-ssot.sh");
test("bash guard: tracked tree, --staged, positional paths, --, unknown flag", () => T.wholeTree(bashRun));
caseEnd();

caseBegin("node-whole-tree-and-flags", "bin/check-session-id-ssot/main.js");
test("Node run(): tracked tree, --staged, positional paths, --, unknown flag", () => T.wholeTree(nodeRun));
caseEnd();

caseBegin("node-starts-no-child-process", "bin/check-session-id-ssot/main.js");
test("Node run(): positional runs spawn nothing; a no-path run spawns git alone", async () => {
  const rows = [...R.READ_ROWS, ...R.TOMB_ROWS, ...R.lxRows()];
  const tree = F.makeTree("spawn", rows);
  const positional = await counter.during(() => F.nodeRun(tree, ["--", ...rows.map((r) => r.path)]));
  assert.deepStrictEqual(positional, [], "positional run started a child process");
  require("../lib/harness").gitInit(tree);
  F.git(tree, "add", "-A");
  const whole = await counter.during(() => F.nodeRun(tree, []));
  const others = whole.filter((c) => !/(^|[\\/])git(\.exe)?$/.test(c.command));
  assert.deepStrictEqual(others, [], "a no-path run started something other than git");
  assert.ok(whole.length <= 1, `git started ${whole.length} times`);
});
caseEnd();

caseBegin("node-ls-files-nonzero-fails-closed", "bin/check-session-id-ssot/main.js");
test("Node run(): a no-path run whose `git ls-files` exits non-zero ends rc 2, not clean", () => G.lsFilesNonZero());
caseEnd();

caseBegin("node-ls-files-spawn-error-fails-closed", "bin/check-session-id-ssot/main.js");
test("Node run(): a non-ENOENT spawn error of `git ls-files` (ENOBUFS, ETIMEDOUT) ends rc 2", () => G.lsFilesSpawnError());
caseEnd();

caseBegin("node-ls-files-signal-fails-closed", "bin/check-session-id-ssot/main.js");
test("Node run(): `git ls-files` killed by a signal (status null, no error) ends rc 2", () => G.lsFilesSignal());
caseEnd();

caseBegin("node-ls-files-enoent-fails-closed", "bin/check-session-id-ssot/main.js");
test("Node run(): a no-path run that cannot find git (ENOENT) ends rc 2 with a diagnostic", () => G.lsFilesEnoent());
caseEnd();
