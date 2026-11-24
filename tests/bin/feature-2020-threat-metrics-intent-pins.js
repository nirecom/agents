"use strict";
// Tests: bin/lib/review-threat-metrics/post-boundary-stats.js, bin/lib/review-threat-metrics/pre-boundary-stats.js, bin/lib/review-threat-metrics/gh.js
// Tags: TL2, threat-boundary, concern-journal, review-metrics, issue-2020, scope:issue-specific, table-driven
// #2020 layer 3, the behaviors the intent settles (test review round 1, C1-C5): post-boundary counts
// every journal row per boundary version apart from the rejected subset; the v0 classification runs
// once; the comparison subset takes the pre-boundary sample rule, is calibrated against the
// reviewers' self tags and compares vN with its boundary baseline vN-1; criteria_hash is the real
// hash of the delivered criteria block; gh.js reads numbered and ledger finding lines.
// Shares the stubs of ./feature-2020-threat-metrics/ (fake claude keyed by kw-<A>-<B>-<cat> tokens).
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");
const F = require("./feature-2020-threat-metrics/fixture");

const restore = isolate();
after(() => {
  F.cleanup();
  restore();
});

const LIB = path.join(F.ROOT, "bin", "lib", "review-threat-metrics");
const fwd = (p) => p.replace(/\\/g, "/");
const near = (got, want, what) =>
  assert.ok(typeof got === "number" && Math.abs(got - want) < 0.001, `${what}: want ${want}, got ${JSON.stringify(got)}`);
const ok = (r, what) => assert.ok(r.status === 0 && r.json !== null, `${what}: rc=${r.status} ${r.err.slice(0, 400)}`);
const { discrim: dsc } = require(path.join(LIB, "discrim.js"));
const issueBody = (sid, ts) => `${F.originMarker(sid)}\n## Concern Delta\n${ts.map((t, i) => `${i + 1}. [HIGH] ${t}`).join("\n")}\n`;
const jrow = (discrim, version, axisA = "A5", axisB = "B2", kind = "concern") =>
  ({ discrim, round: 1, version, axisA, axisB, kind, category: "security", text: `finding ${discrim}` });

caseBegin("post-boundary-journal-totals-per-version", "bin/lib/review-threat-metrics/post-boundary-stats.js");
test("post-boundary-journal-totals-per-version", () => {
  const sc = F.scenario("totals");
  F.session(sc, "p1", F.POST_AT);
  F.journalRows(sc, "p1", "detail-plan", [jrow("aaaa0001", "v1"), jrow("aaaa0002", "v1"),
    jrow("aaaa0003", "v1", "A2", "B1", "out-of-boundary"), jrow("bbbb0001", "v2"), jrow("bbbb0002", "v2"), jrow("cccc0001", "v3")]);
  F.rejectRows(sc, "p1", "detail-plan", ["aaaa0001", "bbbb0001"].map((d) => ({ discrim: d, text: `finding ${d}` })));
  F.ghPages(sc, [], 1);
  const r = F.metrics(sc, ["post-boundary", "--json"]);
  ok(r, "post-boundary --json");
  const bv = r.json.by_version || {};
  const total = (v) => (bv[v] || {}).journal_rows;
  assert.deepStrictEqual([total("v1"), total("v2"), total("v3")], [3, 2, 1],
    `every journal row is counted per version, matched or not: ${JSON.stringify(bv)}`);
  assert.deepStrictEqual([bv.v1.population.carrier, bv.v2.population.carrier], [1, 1], "the rejected subset is counted apart");
  assert.strictEqual(bv.v3.population.carrier, 0, "a version with journal rows only has an empty subset");
});
caseEnd();

caseBegin("v0-classification-runs-once", "bin/lib/review-threat-metrics/pre-boundary-stats.js");
test("v0-classification-runs-once", () => {
  const sc = F.scenario("once");
  F.carrier(sc, "s1", "detail-plan", F.texts(120, "A5", "B2", "security", "an eval reached by input"));
  F.ghPages(sc, [], 1);
  ok(F.metrics(sc, ["pre-boundary", "--json"]), "first run");
  const calls = F.claudeCalls(sc).length;
  const cacheFile = path.join(sc.plans, "review-threat-metrics-v0-cache.json");
  assert.ok(calls > 0 && fs.existsSync(cacheFile), "precondition: the first run classifies and writes the v0 cache");
  const before = fs.readFileSync(cacheFile);
  F.carrier(sc, "s2", "security-plan", F.texts(5, "A2", "B1", "security", "a carrier row added later"));
  ok(F.metrics(sc, ["pre-boundary", "--json", "--seed", "9"]), "re-run with another seed and more input");
  assert.strictEqual(F.claudeCalls(sc).length, calls, "the re-run makes no classifier call");
  assert.ok(fs.readFileSync(cacheFile).equals(before), "the v0 cache stays byte-identical");
});
caseEnd();

// v1: two rejected carrier rows + one issue finding row; v2: one issue with two finding rows.
// The fake classifier answers from the kw token, so the self tags agree on A2 and A0, not on A5.
function calibScenario() {
  const sc = F.scenario("calib");
  F.session(sc, "p1", F.POST_AT);
  const [i1, i2, i3] = ["issue first kw-A5-B2-security", "issue second kw-A3-B0-security", "issue third kw-A0-B0-security"];
  F.journalRows(sc, "p1", "detail-plan", [jrow("cccc0001", "v1", "A2", "B1", "out-of-boundary"), jrow("cccc0002", "v1"),
    jrow(dsc(i3), "v1", "A0", "B0", "no-path"), jrow(dsc(i1), "v2"), jrow(dsc(i2), "v2", "A3", "B0", "out-of-boundary")]);
  F.rejectRows(sc, "p1", "detail-plan", [{ discrim: "cccc0001", text: "carrier one kw-A2-B1-security" },
    { discrim: "cccc0002", text: "carrier two kw-A1-B1-security" }]);
  F.ghIssues(sc, [F.findingIssue(1, "x", { created_at: F.POST_AT, body: issueBody("p1", [i1, i2]) }),
    F.findingIssue(2, "x", { created_at: F.POST_AT, body: issueBody("p1", [i3]) })]);
  return F.metrics(sc, ["post-boundary", "--json"]);
}

caseBegin("post-boundary-issue-rows-and-calibration", "bin/lib/review-threat-metrics/post-boundary-stats.js");
test("post-boundary-issue-rows-and-calibration", () => {
  const r = calibScenario();
  ok(r, "post-boundary --json");
  const { v1, v2 } = r.json.by_version;
  assert.deepStrictEqual([v1.population.carrier, v1.population.issue], [2, 1], "v1: two carrier rows and one issue finding row");
  assert.deepStrictEqual([v2.population.carrier, v2.population.issue], [0, 2], "v2: both finding rows of one issue count");
  assert.strictEqual(v1.calibration.compared, 3, "v1: every tagged row with a valid answer is compared");
  near(v1.calibration.agree_axisA, 2 / 3, "v1: A2=A2, A5!=A1, A0=A0");
  near(v1.calibration.agree_kind, 1, "v1: out-of-boundary, concern and no-path all agree");
  assert.strictEqual(v2.calibration.compared, 2, "v2: both issue rows are compared");
  near(v2.calibration.agree_axisA, 1, "v2: the issue rows agree on axis A");
});
caseEnd();

caseBegin("post-boundary-version-against-boundary-baseline", "bin/lib/review-threat-metrics/post-boundary-stats.js");
test("post-boundary-version-against-boundary-baseline", () => {
  const r = calibScenario();
  ok(r, "post-boundary --json");
  const { v1, v2 } = r.json.by_version;
  const base = v2.boundary_baseline;
  assert.ok(base && base.version === "v1", `v2 is compared with its boundary baseline v1: ${JSON.stringify(base)}`);
  near(base.out_ratio.all, v1.self.out_ratio.all, "the baseline carries v1's out-of-boundary ratio");
  near(base.nopath_ratio.all, v1.self.nopath_ratio.all, "the baseline carries v1's no-path ratio");
});
caseEnd();

caseBegin("post-boundary-subset-sample-rule", "bin/lib/review-threat-metrics/post-boundary-stats.js");
test("post-boundary-subset-sample-rule", () => {
  const sc = F.scenario("post-sample");
  F.session(sc, "p1", F.POST_AT);
  const ct = F.texts(70, "A5", "B2", "security", "a rejected carrier row");
  const it = F.texts(50, "A1", "B1", "docs", "an issue finding row");
  const id = (k) => `r${String(k).padStart(7, "0")}`;
  F.journalRows(sc, "p1", "detail-plan", [...ct.map((t, k) => jrow(id(k), "v1")), ...it.map((t) => jrow(dsc(t), "v1"))]);
  F.rejectRows(sc, "p1", "detail-plan", ct.map((t, k) => ({ discrim: id(k), text: t })));
  F.ghIssues(sc, it.map((t, k) => F.findingIssue(100 + k, "x", { created_at: F.POST_AT, body: issueBody("p1", [t]) })));
  const r = F.metrics(sc, ["post-boundary", "--json"]);
  ok(r, "post-boundary --json");
  const v1 = r.json.by_version.v1;
  assert.deepStrictEqual([v1.population.carrier, v1.population.issue], [70, 50], "the subset population is every attributed row");
  assert.deepStrictEqual(v1.sample, { carrier: 60, issue: 40 }, `the subset is sampled 60 + 40: ${JSON.stringify(v1.sample)}`);
  assert.strictEqual(F.claudeCalls(sc).reduce((s, c) => s + c.rows, 0), 100, "only the 100 sampled rows are classified");
});
caseEnd();

caseBegin("pre-boundary-criteria-hash-value", "bin/lib/review-threat-metrics/pre-boundary-stats.js");
test("pre-boundary-criteria-hash-value", () => {
  const sc = F.scenario("hash");
  const hashOut = fwd(path.join(sc.dir, "criteria-hash.txt"));
  const b = spawnSync("bash", [fwd(path.join(F.ROOT, "bin", "review-criteria-block"))],
    { cwd: sc.dir, env: { ...process.env, REVIEW_CRITERIA_HASH_OUT: hashOut }, encoding: "utf8" });
  const want = (fs.existsSync(hashOut) ? fs.readFileSync(hashOut, "utf8") : "").split(/\r?\n/)[0];
  assert.match(want, /^[0-9a-f]{12}$/, `precondition: the delivered criteria block has a hash: ${b.stderr}`);
  F.carrier(sc, "s1", "detail-plan", ["a plain finding kw-A5-B2-security"]);
  F.ghPages(sc, [], 1);
  const r = F.metrics(sc, ["pre-boundary", "--json"]);
  ok(r, "pre-boundary --json");
  assert.strictEqual(r.json.criteria_hash, want, "criteria_hash equals the delivered criteria block's hash");
});
caseEnd();

caseBegin("post-boundary-journal-rows-exclude-cross-version", "bin/lib/review-threat-metrics/post-boundary-stats.js");
test("post-boundary-journal-rows-exclude-cross-version", () => {
  const sc = F.scenario("cross-version");
  F.session(sc, "p1", F.POST_AT);
  F.journalRows(sc, "p1", "detail-plan", [jrow("aaaa0001", "v1"), jrow("bbbb0001", "v2"),
    jrow("dddd0001", "v1"), jrow("dddd0001", "v2", "A2", "B1", "out-of-boundary")]);
  F.ghPages(sc, [], 1);
  const r = F.metrics(sc, ["post-boundary", "--json"]);
  ok(r, "post-boundary --json");
  const bv = r.json.by_version || {};
  assert.deepStrictEqual([(bv.v1 || {}).journal_rows, (bv.v2 || {}).journal_rows], [1, 1],
    `the unit spanning v1 and v2 is in neither version, the clean units stay: ${JSON.stringify(bv)}`);
  assert.deepStrictEqual(r.json.journal_excluded, { "multi-version": 1 },
    "the one cross-version (session, DISCRIM) unit is counted under multi-version");
});
caseEnd();

caseBegin("pre-boundary-v0-excludes-sessions-with-post-boundary-rows", "bin/lib/review-threat-metrics/pre-boundary-stats.js");
test("pre-boundary-v0-excludes-sessions-with-post-boundary-rows", () => {
  const sc = F.scenario("v0-post-rows");
  const mixed = F.texts(3, "A2", "B1", "security", "a carrier row of a session the boundary reached");
  F.carrier(sc, "s1", "detail-plan", mixed);
  F.journalRows(sc, "s1", "detail-plan", [jrow("eeee0001", "v1")]);
  F.carrier(sc, "s2", "detail-plan", F.texts(2, "A5", "B2", "security", "a carrier row of a plain v0 session"));
  F.ghPages(sc, [], 1);
  const r = F.metrics(sc, ["pre-boundary", "--json"]);
  ok(r, "pre-boundary --json");
  assert.strictEqual(r.json.excluded["post-boundary-rows"], 1,
    `the pre-boundary session with a v1 journal row is excluded as post-boundary-rows: ${JSON.stringify(r.json.excluded)}`);
  assert.strictEqual(r.json.population.carrier, 2, "only the session without a journal feeds the v0 carrier rows");
  const got = new Set(r.json.rows.map((x) => x.discrim));
  assert.ok(mixed.every((t) => !got.has(dsc(t))), "no carrier row of the excluded session reaches v0");
});
caseEnd();

caseBegin("gh-finding-line-parser-table", "bin/lib/review-threat-metrics/gh.js");
test("gh-finding-line-parser-table", () => {
  const { findingsOf } = require(path.join(LIB, "gh.js"));
  const cases = [
    { name: "numbered", input: "1. [HIGH] a numbered finding", want: ["a numbered finding"] },
    { name: "numbered-c-prefix", input: "C12. [MEDIUM] a codex finding", want: ["a codex finding"] },
    { name: "numbered-indented-tags-stripped", input: "  3. [LOW] axis:A2/B1 cat:security a tagged finding", want: ["a tagged finding"] },
    { name: "ledger", input: "[HIGH] C1 | bin/x.sh#run | security | a ledger finding", want: ["a ledger finding"] },
    { name: "ledger-bulleted", input: "- [LOW] C2 | docs/a.md#- | docs | a bulleted ledger finding", want: ["a bulleted ledger finding"] },
    { name: "both-forms-crlf", input: "1. [HIGH] first\r\n[LOW] C2 | a#- | docs | second", want: ["first", "second"] },
    { name: "numbered-unknown-severity", input: "1. [CRITICAL] not a finding", want: [] },
    { name: "numbered-no-space", input: "1.[HIGH] not a finding", want: [] },
    { name: "numbered-letter", input: "a. [HIGH] not a finding", want: [] },
    { name: "numbered-tags-only", input: "1. [HIGH] axis:A1/B1 cat:docs", want: [] },
    { name: "ledger-too-few-columns", input: "[HIGH] C1 | bin/x.sh#run | a two-column row", want: [] },
    { name: "ledger-no-severity", input: "C1 | bin/x.sh#run | security | no severity", want: [] },
    { name: "prose", input: "The review found [HIGH] risk in prose.", want: [] },
    { name: "empty", input: "", want: [] },
  ];
  for (const { name, input, want } of cases) assert.deepStrictEqual(findingsOf(input), want, name);
});
caseEnd();

// #2020 security round 2: a source file that exists but cannot be read is a failure (exit 5), never
// an empty source.
caseBegin("unreadable-source-exits-5", "bin/lib/review-threat-metrics/pre-boundary-stats.js");
test("unreadable-source-exits-5", () => {
  const sc = F.scenario("unreadable");
  F.carrier(sc, "s1", "detail-plan", ["a plain finding kw-A5-B2-security"]);
  fs.mkdirSync(path.join(sc.ctl("s1"), "security-plan-concern-carrier.md"));
  F.ghPages(sc, [], 1);
  const r = F.metrics(sc, ["pre-boundary", "--json"]);
  assert.strictEqual(r.status, 5, `an unreadable carrier exits 5: rc=${r.status} ${r.err.slice(0, 300)}`);
  assert.match(r.err, /security-plan-concern-carrier\.md/, "stderr names the unreadable file");
  assert.strictEqual(r.out, "", "no report is printed");
});
caseEnd();

// #2020 security round 2: the v0 cache keeps how many sampled findings share a text, and the
// post-boundary v0 ratios count each of them.
caseBegin("v0-ratios-weigh-findings-sharing-a-text", "bin/lib/review-threat-metrics/post-boundary-stats.js");
test("v0-ratios-weigh-findings-sharing-a-text", () => {
  const sc = F.scenario("v0-count");
  const same = "a network attacker swaps the script kw-A2-B1-security";
  F.carrier(sc, "s1", "detail-plan", [same, same, same, "an unquoted argument reaches eval kw-A5-B2-security"]);
  F.ghPages(sc, [], 1);
  ok(F.metrics(sc, ["pre-boundary", "--json"]), "pre-boundary --json");
  const cache = JSON.parse(fs.readFileSync(path.join(sc.plans, "review-threat-metrics-v0-cache.json"), "utf8"));
  assert.deepStrictEqual(Object.values(cache.items).map((a) => a.count).sort(), [1, 3], "the cache keeps the count per text");
  const r = F.metrics(sc, ["post-boundary", "--json"]);
  ok(r, "post-boundary --json");
  assert.strictEqual(r.json.v0_comparison.status, "comparable", "precondition: the v0 cache is comparable");
  near(r.json.v0_comparison.out_ratio.all, 3 / 4, "three of four v0 findings are out-of-boundary");
});
caseEnd();

// #2020 security round 2: answers outside the vocabulary are still answers, so the v0 cache is written
// once; a call that answers nothing exits 5 and writes no cache, so the next run classifies again.
caseBegin("v0-cache-written-for-invalid-answers-not-for-no-answer", "bin/lib/review-threat-metrics/pre-boundary-stats.js");
test("v0-cache-written-for-invalid-answers-not-for-no-answer", () => {
  const cacheOf = (sc) => path.join(sc.plans, "review-threat-metrics-v0-cache.json");
  const bad = F.scenario("all-invalid");
  F.carrier(bad, "s1", "detail-plan", F.texts(3, "A9", "B9", "security", "an answer outside the axes"));
  F.ghPages(bad, [], 1);
  const r = F.metrics(bad, ["pre-boundary", "--json"]);
  ok(r, "pre-boundary --json with every answer invalid");
  assert.strictEqual(r.json.invalid, 3, "precondition: every answer is invalid");
  assert.ok(fs.existsSync(cacheOf(bad)), "the v0 cache is written even when every answer is invalid");
  const calls = F.claudeCalls(bad).length;
  ok(F.metrics(bad, ["pre-boundary", "--json"]), "re-run");
  assert.strictEqual(F.claudeCalls(bad).length, calls, "the re-run does not classify v0 again");
  const none = F.scenario("no-answer");
  F.carrier(none, "s1", "detail-plan", ["a finding the classifier gives no answer for"]);
  F.ghPages(none, [], 1);
  const n = F.metrics(none, ["pre-boundary", "--json"]);
  assert.strictEqual(n.status, 5, `no answer exits 5: rc=${n.status} ${n.err.slice(0, 300)}`);
  assert.match(n.err, /answered no class/, "stderr says the classifier answered nothing");
  assert.ok(!fs.existsSync(cacheOf(none)), "no v0 cache is written without an answer");
});
caseEnd();
