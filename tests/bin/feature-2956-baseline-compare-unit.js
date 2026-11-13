// tests/bin/feature-2956-baseline-compare-unit.js
// Tests: bin/lib/run-tests-baseline-compare.js, bin/lib/run-tests-baseline-compare/normalize.js, bin/lib/run-tests-baseline-compare/markers.js, bin/lib/run-tests-baseline-compare/diff.js, bin/lib/run-tests-baseline-compare/records.js
// Tags: scope:issue-specific, run-tests-baseline, baseline-compare, fail-details, tl2
// #2956 S4/S5: the comparer of bin/run-tests-baseline. Each case builds a base and a branch result
// dir (cases.tsv + fail-details.tsv), runs the CLI and reads its one line
//   RESULT\t<verdict>\t<new_count>\t<new_head_json>\t<fp_base>\t<fp_branch>
// Tables: normalization, the two line-number forms only, the cut rule, missing cases by
// --branch-end, multiset counts, the count / list markers, the outside-case "-" line, the header.
"use strict";

const { test } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const ROOT = path.resolve(__dirname, "..", "..");
const CLI = path.join(ROOT, "bin", "lib", "run-tests-baseline-compare.js");
const NORMALIZE = path.join(ROOT, "bin", "lib", "run-tests-baseline-compare", "normalize.js");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2956-cmp-"));
// Outside the temp area on purpose: a base worktree path must normalize to <root>, never <tmp>.
const BASE_WT = path.join(path.dirname(ROOT), "f2956-base-wt-fixture");
const RENAME_MAP = path.join(TMP, "rename-map.tsv");
fs.writeFileSync(RENAME_MAP, "");
process.on("exit", () => fs.rmSync(TMP, { recursive: true, force: true }));
const restoreEnv = isolate();
process.on("exit", () => restoreEnv());

const TARGET = "tests/bin/t.sh";
const CUT = `${"a".repeat(8192)}\\n[cut]`;
let dirN = 0;

// side(spec) — a result dir. spec: { fail|open: { <case>: [detail, ...] }, pass: [<case>...], outside: [detail...] }
// An open case is begun, never ended. A FAIL case with an empty detail list gets no fail-details line. null -> an empty result dir.
function side(spec) {
  const dir = path.join(TMP, `r${dirN++}`);
  fs.mkdirSync(dir);
  if (spec === null) return dir;
  const cases = [];
  const details = [];
  let seq = 0;
  for (const c of spec.pass || []) {
    seq += 1;
    cases.push(`${seq}\tOPEN\t${c}\t${TARGET}`, `${seq}\tPASS\t${c}\t${TARGET}`);
  }
  for (const [c, ds] of Object.entries(spec.fail || {})) {
    seq += 1;
    cases.push(`${seq}\tOPEN\t${c}\t${TARGET}`, `${seq}\tFAIL\t${c}\t${TARGET}`);
    for (const d of ds) details.push(`${seq}\t${c}\t${d}`);
  }
  for (const [c, ds] of Object.entries(spec.open || {})) {
    cases.push(`${++seq}\tOPEN\t${c}\t${TARGET}`);
    for (const d of ds) details.push(`${seq}\t${c}\t${d}`);
  }
  for (const d of spec.outside || []) details.push(`0\t-\t${d}`);
  if (cases.length) fs.writeFileSync(path.join(dir, "cases.tsv"), `${cases.join("\n")}\n`);
  if (details.length) fs.writeFileSync(path.join(dir, "fail-details.tsv"), `${details.join("\n")}\n`);
  return dir;
}

// compare(base, branch, end) — { verdict, count, head, fpBase, fpBranch, raw }.
function compare(base, branch, end = "normal", linesOut = null) {
  assert.ok(fs.existsSync(CLI), `comparer not implemented yet: ${CLI}`);
  const done = spawnSync(
    process.execPath,
    [CLI, "--base-res", side(base), "--branch-res", side(branch), "--file", TARGET, "--rename-map", RENAME_MAP,
      "--root", ROOT, "--base-wt", BASE_WT, "--branch-end", end, ...(linesOut ? ["--new-lines-out", linesOut] : [])],
    { encoding: "utf8", timeout: 30000 },
  );
  const line = String(done.stdout || "").split(/\r?\n/).find((l) => l.startsWith("RESULT\t"));
  assert.ok(line, `RESULT line (rc=${done.status} stdout=${done.stdout} stderr=${done.stderr})`);
  const [, verdict, count, head, fpBase, fpBranch] = line.split("\t");
  return { verdict, count: Number(count), head: JSON.parse(head), fpBase, fpBranch, raw: line };
}

const one = (detail) => ({ fail: { X: [detail] } });

// check(rows) — each row: { name, base, branch, end?, verdict, count? }.
function check(rows) {
  for (const r of rows) {
    const got = compare(r.base, r.branch, r.end);
    assert.equal(got.verdict, r.verdict, `${r.name}: verdict (${got.raw})`);
    if (r.count !== undefined) assert.equal(got.count, r.count, `${r.name}: new_count (${got.raw})`);
  }
}

const tmpd = os.tmpdir();
// rootForms(p) — the spellings of a checkout root a log may carry: native, forward-slash, and
// (Windows) the MSYS /c/... form.
function rootForms(p) {
  const fwd = p.replace(/\\/g, "/");
  const forms = [p, fwd];
  const m = /^([A-Za-z]):\/(.*)$/.exec(fwd);
  if (m) forms.push(`/${m[1].toLowerCase()}/${m[2]}`);
  return [...new Set(forms)];
}
const ROOT_ROWS = rootForms(BASE_WT).map((b, i) => ({
  name: `checkout-root-form-${i}`,
  base: one(`open ${b}/bin/x`),
  branch: one(`open ${rootForms(ROOT)[i]}/bin/x`),
  verdict: "same",
  count: 0,
}));
const UUID_A = "123e4567-e89b-12d3-a456-426614174000";
const UUID_B = "9b2c7d1e-0f3a-4c5b-8d6e-7f8091a2b3c4";

caseBegin("normalize-values", "bin/lib/run-tests-baseline-compare/normalize.js");
test("volatile values normalize away on both sides", () => {
  check([
    { name: "iso-time", base: one("at 2026-11-11T10:00:00Z boom"), branch: one("at 2026-11-12T11:22:33Z boom"), verdict: "same", count: 0 },
    { name: "clock-time", base: one("12:00:01 boom"), branch: one("23:14:15 boom"), verdict: "same", count: 0 },
    { name: "duration-ms", base: one("took 12ms"), branch: one("took 3400ms"), verdict: "same", count: 0 },
    { name: "duration-s", base: one("took 1.5s"), branch: one("took 20s"), verdict: "same", count: 0 },
    { name: "tmp-path", base: one(`read ${tmpd}${path.sep}tmp.AAAA1${path.sep}x.txt`), branch: one(`read ${tmpd}${path.sep}tmp.BBBB2${path.sep}x.txt`), verdict: "same", count: 0 },
    ...ROOT_ROWS,
    { name: "pid", base: one("child pid=1234 died"), branch: one("child pid=98765 died"), verdict: "same", count: 0 },
    { name: "uuid", base: one(`session ${UUID_A}`), branch: one(`session ${UUID_B}`), verdict: "same", count: 0 },
    { name: "hex-with-letter", base: one("commit abc1234 bad"), branch: one("commit 0f9e8d7c6b bad"), verdict: "same", count: 0 },
    { name: "hex-digits-only-kept", base: one("id 1234567 bad"), branch: one("id 7654321 bad"), verdict: "new", count: 1 },
    { name: "hex-too-short-kept", base: one("id abc12 bad"), branch: one("id def34 bad"), verdict: "new", count: 1 },
  ]);
});
test("host, user and home never reach the published head", () => {
  const host = os.hostname();
  const user = os.userInfo().username;
  const got = compare(one("boom"), { fail: { X: ["boom", `on host ${host} now`, `as user ${user} now`] } });
  assert.equal(got.verdict, "new", got.raw);
  assert.equal(got.count, 2, got.raw);
  const text = got.head.join("\n");
  assert.ok(!text.includes(host), `head leaks the host name: ${text}`);
  assert.ok(!text.includes(user), `head leaks the user name: ${text}`);
  assert.ok(text.includes("<host>") && text.includes("<user>"), `head carries <host> and <user>: ${text}`);
});
test("LINE_NO_EXTS is the plan's extension list", () => {
  assert.ok(fs.existsSync(NORMALIZE), `normalize.js not implemented yet: ${NORMALIZE}`);
  const { LINE_NO_EXTS } = require(NORMALIZE);
  assert.deepEqual([...LINE_NO_EXTS].sort(), ["bash", "cjs", "js", "json", "md", "mjs", "ps1", "psm1", "py", "sh", "ts", "tsv"]);
});
caseEnd();

caseBegin("line-number-two-forms-only", "bin/lib/run-tests-baseline-compare/normalize.js");
test("only <ext-path>:n[:n] and 'line n' drop the number", () => {
  check([
    { name: "sh-colon-n", base: one("at tests/a.sh:12 boom"), branch: one("at tests/a.sh:40 boom"), verdict: "same", count: 0 },
    { name: "js-colon-n-n", base: one("at bin/b.js:3:7 boom"), branch: one("at bin/b.js:9:1 boom"), verdict: "same", count: 0 },
    { name: "every-ext", base: one("x.bash:1 x.mjs:1 x.cjs:1 x.ts:1 x.py:1 x.ps1:1 x.psm1:1 x.md:1 x.json:1 x.tsv:1"), branch: one("x.bash:2 x.mjs:3 x.cjs:4 x.ts:5 x.py:6 x.ps1:7 x.psm1:8 x.md:9 x.json:10 x.tsv:11"), verdict: "same", count: 0 },
    { name: "line-n", base: one("syntax error near line 12"), branch: one("syntax error near line 99"), verdict: "same", count: 0 },
    { name: "host-port-kept", base: one("connect host:8080 refused"), branch: one("connect host:9090 refused"), verdict: "new", count: 1 },
    { name: "fqdn-port-kept", base: one("connect example.com:8080 refused"), branch: one("connect example.com:9090 refused"), verdict: "new", count: 1 },
    { name: "local-port-kept", base: one("connect box.local:8080 refused"), branch: one("connect box.local:9090 refused"), verdict: "new", count: 1 },
    { name: "extensionless-path-kept", base: one("at bin/run-tests-baseline:42 boom"), branch: one("at bin/run-tests-baseline:43 boom"), verdict: "new", count: 1 },
  ]);
});
test("the head shows the normalized line number", () => {
  const got = compare(one("boom"), { fail: { X: ["boom", "new at tests/a.sh:12 bad"] } });
  assert.equal(got.count, 1, got.raw);
  assert.ok(got.head.some((h) => h.includes("tests/a.sh:<n>")), `head: ${JSON.stringify(got.head)}`);
});
caseEnd();

caseBegin("cut-rule", "bin/lib/run-tests-baseline-compare/markers.js");
test("a cut line on the branch is always new; a base-only cut line is not", () => {
  check([
    { name: "same-cut-both-sides", base: one(CUT), branch: one(CUT), verdict: "new", count: 1 },
    { name: "cut-only-at-base", base: { fail: { X: ["boom", CUT] } }, branch: one("boom"), verdict: "same", count: 0 },
    { name: "cut-blocks-count-rule", base: { fail: { X: ["found [count=5]", CUT] } }, branch: { fail: { X: ["found [count=3]", CUT] } }, verdict: "new" },
  ]);
});
caseEnd();

caseBegin("missing-case-by-branch-end", "bin/lib/run-tests-baseline-compare/diff.js");
test("a base FAIL case absent from the branch is branch-missing only when interrupted", () => {
  const base = { fail: { X: ["boom x"], Y: ["boom y"] } };
  check([
    { name: "interrupted-missing", base, branch: one("boom x"), end: "interrupted", verdict: "branch-missing" },
    { name: "normal-missing-is-fixed", base, branch: one("boom x"), end: "normal", verdict: "same", count: 0 },
    { name: "interrupted-passed-not-missing", base, branch: { fail: { X: ["boom x"] }, pass: ["Y"] }, end: "interrupted", verdict: "same", count: 0 },
    { name: "no-branch-records-m1", base, branch: null, end: "normal", verdict: "branch-missing" },
    { name: "no-base-records", base: null, branch: one("boom"), verdict: "base-missing" },
    { name: "no-records-either-side", base: null, branch: null, verdict: "no-records", count: 0 },
    { name: "detail-less-fail-same", base: { fail: { X: [] } }, branch: { fail: { X: [] } }, verdict: "same", count: 0 },
    { name: "detail-added-to-bare-fail", base: { fail: { X: [] } }, branch: one("boom"), verdict: "new", count: 1 },
  ]);
});
caseEnd();

caseBegin("multiset-duplicates", "bin/lib/run-tests-baseline-compare/diff.js");
test("duplicate lines count by multiplicity", () => {
  check([
    { name: "dup-grows", base: { fail: { X: ["dup", "dup"] } }, branch: { fail: { X: ["dup", "dup", "dup"] } }, verdict: "new", count: 1 },
    { name: "dup-equal", base: { fail: { X: ["dup", "dup"] } }, branch: { fail: { X: ["dup", "dup"] } }, verdict: "same", count: 0 },
    { name: "dup-shrinks", base: { fail: { X: ["dup", "dup"] } }, branch: { fail: { X: ["dup"] } }, verdict: "same", count: 0 },
    { name: "same-line-other-case", base: { fail: { X: ["boom"] } }, branch: { fail: { X: ["boom"], Z: ["boom"] } }, verdict: "new", count: 1 },
    { name: "one-line-added", base: one("v1"), branch: { fail: { X: ["v1", "v2"] } }, verdict: "new", count: 1 },
  ]);
});
caseEnd();

caseBegin("count-rule", "bin/lib/run-tests-baseline-compare/markers.js");
test("[count=N] may only go down; unmarked numbers stay new", () => {
  check([
    { name: "count-down", base: one("found [count=5] issues"), branch: one("found [count=3] issues"), verdict: "same", count: 0 },
    { name: "count-equal", base: one("found [count=5] issues"), branch: one("found [count=5] issues"), verdict: "same", count: 0 },
    { name: "count-up", base: one("found [count=5] issues"), branch: one("found [count=7] issues"), verdict: "new", count: 1 },
    { name: "unmarked-down", base: one("found 5 issues"), branch: one("found 3 issues"), verdict: "new", count: 1 },
    { name: "two-marks-down", base: one("[count=5] a [count=2]"), branch: one("[count=4] a [count=2]"), verdict: "same", count: 0 },
    { name: "two-marks-one-up", base: one("[count=5] a [count=2]"), branch: one("[count=4] a [count=3]"), verdict: "new", count: 1 },
    { name: "template-differs", base: one("[count=5] in a"), branch: one("[count=3] in b"), verdict: "new", count: 1 },
    { name: "two-lines-each-side", base: { fail: { X: ["[count=5] a", "other"] } }, branch: { fail: { X: ["[count=3] a", "another"] } }, verdict: "new", count: 2 },
  ]);
});
caseEnd();

caseBegin("list-rule", "bin/lib/run-tests-baseline-compare/markers.js");
test("a complete list may only shrink to a sub-multiset; a cut list stays new", () => {
  check([
    { name: "list-shrinks", base: one("left [list total=3: a | b | c]"), branch: one("left [list total=2: a | c]"), verdict: "same", count: 0 },
    { name: "list-swaps-item", base: one("left [list total=3: a | b | c]"), branch: one("left [list total=3: a | c | d]"), verdict: "new", count: 1 },
    { name: "list-grows", base: one("left [list total=2: a | b]"), branch: one("left [list total=3: a | b | c]"), verdict: "new", count: 1 },
    { name: "list-dup-item-grows", base: one("left [list total=2: a | b]"), branch: one("left [list total=2: a | a]"), verdict: "new", count: 1 },
    { name: "cut-list-shrinks", base: one("left [list total=5: a | b]"), branch: one("left [list total=4: a]"), verdict: "new", count: 1 },
    { name: "unmarked-list-shrinks", base: one("left: a, b, c"), branch: one("left: a, c"), verdict: "new", count: 1 },
    { name: "escaped-pipe-is-one-item", base: one("left [list total=2: x\\|y | z]"), branch: one("left [list total=1: x\\|y]"), verdict: "same", count: 0 },
    { name: "escaped-pipe-not-split", base: one("left [list total=2: x\\|y | z]"), branch: one("left [list total=1: x]"), verdict: "new", count: 1 },
    { name: "escaped-bracket", base: one("left [list total=2: p\\]q | r]"), branch: one("left [list total=1: p\\]q]"), verdict: "same", count: 0 },
    { name: "escaped-backslash", base: one("left [list total=2: c:\\\\d | e]"), branch: one("left [list total=1: c:\\\\d]"), verdict: "same", count: 0 },
  ]);
});
caseEnd();

caseBegin("outside-case-dash-line", "bin/lib/run-tests-baseline-compare/diff.js");
test("a fail outside any case (case -) is compared as one case", () => {
  check([
    { name: "dash-line-added", base: one("boom"), branch: { fail: { X: ["boom"] }, outside: ["setup broke"] }, verdict: "new", count: 1 },
    { name: "dash-line-same", base: { fail: { X: ["boom"] }, outside: ["setup broke"] }, branch: { fail: { X: ["boom"] }, outside: ["setup broke"] }, verdict: "same", count: 0 },
    { name: "dash-only-file", base: { outside: ["no cases here"] }, branch: { outside: ["no cases here"] }, verdict: "same", count: 0 },
    { name: "dash-only-file-grows", base: { outside: ["no cases here"] }, branch: { outside: ["no cases here", "and more"] }, verdict: "new", count: 1 },
  ]);
});
caseEnd();

caseBegin("fingerprint-header", "bin/lib/run-tests-baseline-compare.js");
test("the fp is a sha256 whose records=cases|none header splits no-records from pass", () => {
  const empty = compare(null, null);
  const passOnly = compare(null, { pass: ["P"] });
  assert.match(empty.fpBase, /^[0-9a-f]{64}$/, empty.raw);
  assert.equal(empty.fpBase, empty.fpBranch, `two empty dirs share the fp: ${empty.raw}`);
  assert.notEqual(passOnly.fpBranch, passOnly.fpBase, `pass-only differs from no records: ${passOnly.raw}`);
  const norm = compare(one("took 12ms"), one("took 99ms"));
  assert.equal(norm.fpBase, norm.fpBranch, `the fp is taken over normalized lines: ${norm.raw}`);
  const diff = compare(one("v1"), one("v2"));
  assert.notEqual(diff.fpBase, diff.fpBranch, diff.raw);
});
test("new_head holds at most three normalized lines", () => {
  const got = compare(one("v0"), { fail: { X: ["v0", "n1", "n2", "n3", "n4"] } });
  assert.equal(got.verdict, "new", got.raw);
  assert.equal(got.count, 4, got.raw);
  assert.ok(Array.isArray(got.head) && got.head.length === 3, `head: ${JSON.stringify(got.head)}`);
  const same = compare(one("v0"), one("v0"));
  assert.deepEqual(same.head, [], same.raw);
});
// Boundary pinned as implemented: new_count is the full count, new_head the first three in order.
// The --new-lines-out file keeps every new line, not just the head (checked in the test below).
test("new_head boundary: three new lines all shown, the fourth counted but not in the head", () => {
  const three = compare(one("v0"), { fail: { X: ["v0", "n1", "n2", "n3"] } });
  assert.equal(three.count, 3, three.raw);
  assert.deepEqual(three.head, ["X\tn1", "X\tn2", "X\tn3"], three.raw);
  const four = compare(one("v0"), { fail: { X: ["v0", "n1", "n2", "n3", "n4"] } });
  assert.equal(four.count, 4, four.raw);
  assert.deepEqual(four.head, ["X\tn1", "X\tn2", "X\tn3"], four.raw);
  assert.ok(!four.head.some((h) => h.includes("n4")), `the fourth line is not in the head: ${four.raw}`);
});
test("--new-lines-out keeps every new line, including those past the head of three", () => {
  const out = path.join(TMP, "new-lines-all.tsv");
  const got = compare(one("v0"), { fail: { X: ["v0", "n1", "n2", "n3", "n4", "n5"] } }, "normal", out);
  assert.equal(got.count, 5, got.raw);
  const kept = fs.readFileSync(out, "utf8").split("\n").filter(Boolean);
  assert.deepEqual(kept, ["X\tn1", "X\tn2", "X\tn3", "X\tn4", "X\tn5"], `file rows: ${JSON.stringify(kept)}`);
});
caseEnd();

caseBegin("open-at-end-case-is-a-failure", "bin/lib/run-tests-baseline-compare/records.js");
test("readSide: an OPEN-at-end case gives one [name, ''] line, unless it has a detail row; never seen", () => {
  const { readSide } = require(path.join(ROOT, "bin", "lib", "run-tests-baseline-compare", "records.js"));
  const bare = readSide(side({ fail: { A: ["X"] }, open: { B: [] } }));
  assert.deepEqual(bare.lines, [["A", "X"], ["B", ""]], JSON.stringify(bare.lines));
  assert.ok(!bare.seenCases.has("B") && bare.hasRecords, "OPEN-at-end: a record, not in seenCases");
  const withDetail = readSide(side({ open: { B: ["d"] } }));
  assert.deepEqual(withDetail.lines, [["B", "d"]], `no duplicate "" line: ${JSON.stringify(withDetail.lines)}`);
});
test("compare: a new OPEN-at-end case on the branch is new; the same one on both sides is same", () => {
  check([
    { name: "open-case-added", base: one("X"), branch: { fail: { X: ["X"] }, open: { B: [] } }, verdict: "new", count: 1 },
    { name: "open-case-both-sides", base: { open: { B: [] } }, branch: { open: { B: [] } }, verdict: "same", count: 0 },
    { name: "open-case-with-detail-no-dup", base: { fail: { B: ["d"] } }, branch: { open: { B: ["d"] } }, verdict: "same", count: 0 },
  ]);
});
caseEnd();
