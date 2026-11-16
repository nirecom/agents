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
// over (optional): { root, baseWt, env } replaces --root / --base-wt and extends the child env.
function compare(base, branch, end = "normal", linesOut = null, over = {}) {
  assert.ok(fs.existsSync(CLI), `comparer not implemented yet: ${CLI}`);
  const done = spawnSync(
    process.execPath,
    [CLI, "--base-res", side(base), "--branch-res", side(branch), "--file", TARGET, "--rename-map", RENAME_MAP,
      "--root", over.root || ROOT, "--base-wt", over.baseWt || BASE_WT, "--branch-end", end, ...(linesOut ? ["--new-lines-out", linesOut] : [])],
    { encoding: "utf8", timeout: 30000, env: over.env ? { ...process.env, ...over.env } : process.env },
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

// #3054: failure-line normalization must not depend on where a temp path sits in the line, nor on
// how deeply the path separators are escaped. Fixtures are written in the folded spelling.
// deep(p, k) — p's separators as one backslash (k=0, a raw native path) or 2^k backslashes (folded k times).
const deep = (p, k) => p.replace(/[\\/]+/g, k === 0 ? "\\" : "\\".repeat(2 ** k));
const nl = (n) => `${"\\".repeat(n)}n`; // an escaped newline: n=1 is the fold's own, 2+ is escaped again
const tb = (n) => `${"\\".repeat(n)}t`; // an escaped tab, same depth scheme as nl()
const DEPTHS = [0, 1, 2, 3, 4];
const HOME = os.homedir();
const same = (name, a, b) => ({ name, base: one(a), branch: one(b), verdict: "same", count: 0 });
const kept = (name, a, b) => ({ name, base: one(a), branch: one(b), verdict: "new", count: 1 });
// Rows about the literal /tmp rule run with the temp dir moved off /tmp, else Linux/WSL's own tmpdir rule would hide a miss.
const NOTMP = { TMPDIR: path.join(HOME, "f3054-notmp"), TEMP: path.join(HOME, "f3054-notmp"), TMP: path.join(HOME, "f3054-notmp") };
const nt = (r) => ({ ...r, env: NOTMP });
// check3054(rows) — verdict, count, and for a "same" row the two fingerprints agree.
function check3054(rows) {
  for (const r of rows) {
    const got = compare(r.base, r.branch, "normal", null, r);
    assert.equal(got.verdict, r.verdict, `${r.name}: verdict (${got.raw})`);
    assert.equal(got.count, r.count, `${r.name}: new_count (${got.raw})`);
    if (r.verdict === "same") assert.equal(got.fpBase, got.fpBranch, `${r.name}: fp (${got.raw})`);
  }
}

caseBegin("escape-depth-tmp-3054", "bin/lib/run-tests-baseline-compare/normalize.js");
test("#3054 /tmp after an escaped newline, at any escape depth, normalizes", () => {
  check3054([
    ...[1, 2, 4].map((n) => same(`slash-tmp-after-newline-${n}`, `boom${nl(n)}/tmp/tmp.AAAA1/x.sh`, `boom${nl(n)}/tmp/tmp.BBBB2/x.sh`)),
    same("slash-tmp-line-start", "/tmp/tmp.AAAA1/x.sh", "/tmp/tmp.BBBB2/x.sh"),
    same("slash-tmp-after-space", "see /tmp/tmp.AAAA1/x.sh", "see /tmp/tmp.BBBB2/x.sh"),
  ].map(nt));
});
test("#3054 relative tmp.XXXX names (mktemp shape) normalize wherever they sit", () => {
  check3054([
    ...[1, 2, 4].map((n) => same(`tmp-xxxx-after-newline-${n}`, `boom${nl(n)}tmp.AB12cd/x`, `boom${nl(n)}tmp.ZY98xw/x`)),
    ...[1, 2].map((n) => same(`tmp-xxxx-after-tab-${n}`, `boom${tb(n)}tmp.AB12cd/x`, `boom${tb(n)}tmp.ZY98xw/x`)),
    same("tmp-xxxx-line-start", "tmp.AB12cd/x", "tmp.ZY98xw/x"),
    same("tmp-xxxx-after-space", "cd tmp.AB12cd", "cd tmp.ZY98xw"),
    same("tmp-xxxx-after-separator", "in /work/tmp.AB12cd/x", "in /work/tmp.ZY98xw/x"),
    ...[1, 2, 4].map((k) => same(`tmp-xxxx-after-backslash-sep-${k}`, `in ${deep("C:\\x\\tmp.AB12cd\\y", k)}`, `in ${deep("C:\\x\\tmp.ZY98xw\\y", k)}`)),
    same("tmp-xxxx-len-4", "cd tmp.AB12", "cd tmp.CD34"),
    same("tmp-xxxx-letters-only-standalone", "tmp.AbCdEf", "tmp.QwErTy"),
    same("tmp-xxxx-letters-only-after-newline", `boom${nl(1)}tmp.AbCdEf/x`, `boom${nl(1)}tmp.QwErTy/x`),
    same("tmp-xxxx-digits-vs-mixed", "tmp.123456", "tmp.AbCdEf"),
    // Accepted tradeoff (detail plan): an all-lowercase suffix is deliberately not replaced.
    kept("tmp-xxxx-all-lowercase", "tmp.abcdef", "tmp.ghijkl"),
    kept("tmp-xxxx-len-3", "cd tmp.AB1", "cd tmp.CD3"),
    kept("tmp-xxxx-dot-prefixed", "a.tmp.AB12cd", "a.tmp.ZY98xw"),
    kept("tmp-xxxx-underscore-prefixed", "_tmp.AB12cd", "_tmp.ZY98xw"),
    kept("tmp-xxxx-underscore-suffixed", "tmp.AB12cd_x", "tmp.ZY98xw_x"),
  ]);
});
test("#3054 /tmp after an escaped newline or tab with a non-mktemp tail: only the /tmp lookbehind can match", () => {
  check3054([
    ...[1, 2, 4].map((n) => same(`slash-tmp-plain-after-newline-${n}`, `boom${nl(n)}/tmp/build-1/x`, `boom${nl(n)}/tmp/build-2/x`)),
    ...[1, 2, 4].map((n) => same(`slash-tmp-plain-after-tab-${n}`, `boom${tb(n)}/tmp/build-1/x`, `boom${tb(n)}/tmp/build-2/x`)),
  ].map(nt));
});
test("#3054 os.tmpdir() leaf (not mktemp-shaped, so only the tmps rule applies) at base depth 0 vs branch depth k, and both at depth k", () => {
  const leaf = (d, k) => `read ${deep(path.join(tmpd, d, "x.txt"), k)}`;
  check3054(DEPTHS.map((k) => same(`tmpdir-0-vs-${k}`, leaf("build-1", 0), leaf("build-2", k))));
  check3054(DEPTHS.map((k) => same(`tmpdir-both-${k}`, leaf("build-1", k), leaf("build-2", k))));
  check3054([same("tmpdir-0-vs-6", leaf("build-1", 0), leaf("build-2", 6)), same("tmpdir-3-vs-0", leaf("build-1", 3), leaf("build-2", 0))]);
});
caseEnd();

caseBegin("escape-depth-home-root-3054", "bin/lib/run-tests-baseline-compare/normalize.js");
test("#3054 home path: every (base depth, branch depth) pair reads the same", () => {
  const rows = [];
  for (const j of DEPTHS) for (const k of DEPTHS) if (j !== k) rows.push(same(`home-${j}-${k}`, `open ${deep(HOME, j)} failed`, `open ${deep(HOME, k)} failed`));
  rows.push(same("home-0-vs-6", `open ${deep(HOME, 0)} failed`, `open ${deep(HOME, 6)} failed`));
  check3054(rows);
});
// skipped off win32: only a win32 host folds path case, elsewhere the two spellings differ
test("#3054 home path case-folds at depth 3 on a case-insensitive (win32) host", { skip: process.platform !== "win32" }, () => {
  check3054([same("home-casefold-depth-3", `open ${deep(HOME, 3)} failed`, `open ${deep(HOME.toUpperCase(), 3)} failed`)]);
});
test("#3054 checkout root at depth 0..4 (and 0 vs 6) stays <root> (not eaten by <tmp>/<home>)", () => {
  const at = (r, k) => `open ${deep(path.join(r, "bin", "x"), k)}`;
  check3054([...DEPTHS.map((k) => same(`root-depth-${k}`, at(BASE_WT, k), at(ROOT, k))), same("root-0-vs-6", `open ${deep(BASE_WT, 0)} failed`, `open ${deep(ROOT, 6)} failed`)]); // no tail: tail escapes are not unified across depths (Accepted Tradeoffs)
  // Host-independent order guard: the branch root sits under home / tmpdir, the base worktree outside both.
  const under = (dir) => path.join(dir, "f3054-root");
  check3054([["home", HOME], ["tmpdir", tmpd]].flatMap(([label, dir]) => [0, 1, 2].map((k) => (
    { ...same(`root-under-${label}-depth-${k}`, at(BASE_WT, k), at(under(dir), k)), root: under(dir) }))));
});
test("#3054 home path at depth 4 on the branch never leaks the user name into the head", () => {
  const user = os.userInfo().username;
  const got = compare(one("boom"), { fail: { X: ["boom", `as ${deep(HOME, 4)} bad`] } });
  assert.equal(got.verdict, "new", got.raw);
  assert.equal(got.count, 1, got.raw);
  const text = got.head.join("\n");
  assert.ok(!text.includes(user), `head leaks the user name: ${text}`);
  assert.ok(text.includes("<home>"), `head carries <home>: ${text}`);
});
test("#3054 a home split by an escaped newline before an n/t-initial segment is read as home (known looseness)", () => {
  // A synthetic home (child HOME / USERPROFILE) whose last segment starts with n keeps this host-independent.
  const synHome = path.join(path.dirname(ROOT), "nhome3054");
  const split = `${deep(path.dirname(synHome), 1)}\\${path.basename(synHome)}`; // a lone backslash + n spells the fold's newline
  check3054([{ ...same("home-split-by-newline", `open ${deep(synHome, 1)} failed`, `open ${split} failed`), env: { HOME: synHome, USERPROFILE: synHome } }]);
});
caseEnd();

caseBegin("escape-depth-guards-3054", "bin/lib/run-tests-baseline-compare/normalize.js");
test("#3054 names that merely look like temp paths are kept (over-replacement guards)", () => {
  check3054([
    kept("foo-slash-tmp", "see foo/tmp/a", "see foo/tmp/b"),
    kept("foo-slash-tmp-after-newline", `boom${nl(1)}foo/tmp/a`, `boom${nl(1)}foo/tmp/b`),
    kept("tmp-json-vs-test", "cd tmp.json", "cd tmp.test"),
    kept("xtmp-prefixed", "cd xtmp.AB12cd", "cd xtmp.ZY98xw"),
    kept("xtmp-prefixed-after-newline", `boom${nl(1)}xtmp.AB12cd`, `boom${nl(1)}xtmp.ZY98xw`),
    kept("tmp-too-short", "cd tmp.A1", "cd tmp.B2"),
    kept("slash-tmp-lookalike", "/tmpA/x", "/tmpB/x"),
    kept("slash-tmp-lookalike-after-newline-2", `boom${nl(2)}/tmpA/x`, `boom${nl(2)}/tmpB/x`),
    kept("n-before-slash-tmp", "see run/tmp/a", "see run/tmp/b"),
    kept("t-before-slash-tmp", "see out/tmp/a", "see out/tmp/b"),
    kept("n-before-tmp-xxxx", "cd intmp.AB12cd", "cd intmp.ZY98xw"),
    kept("home-then-newline-text", `open ${deep(HOME, 1)}${nl(1)}xyz`, `open ${deep(HOME, 1)}${nl(1)}abc`),
  ].map(nt));
});
caseEnd();

caseBegin("escape-depth-issue-shapes-3054", "bin/lib/run-tests-baseline-compare/normalize.js");
test("#3054 the three failures of #2941 (shapes synthesized from the issue text)", () => {
  const f2475 = (d) => `review-plan-codex-input-limit: codex-core.sh missing codex-lang.sh${nl(1)}/tmp/tmp.${d}/codex-lang.sh: No such file`;
  const f2681 = (d, k) => `{"error":"MODULE_NOT_FOUND","user":"${deep(HOME, k)}","dir":"tmp.${d}/cfg"}`;
  const f468 = (d) => `{"T23b":"injected-top-level-field:workflow_aborted","dir":"tmp.${d}/state"}`;
  check3054([
    nt(same("feature-2475", f2475("AbC123"), f2475("XyZ789"))),
    same("feature-2681", f2681("AB12cd", 0), f2681("ZY98xw", 2)),
    same("feature-resume-session-468", f468("Qw3rTy"), f468("Zx9cVb")),
  ]);
});
caseEnd();
