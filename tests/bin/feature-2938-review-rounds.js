"use strict";
// Tests: bin/lib/codex-review-loop/review-rounds.js, bin/lib/codex-review-loop/review-rounds-store.js, bin/lib/codex-review-loop/state-interval.js, bin/review-rounds
// Tags: feature-2938, feature-2478, review-rounds, review-record, loop-cycle, kind-route, no-park, audit-block, has-run, scope:issue-specific, TL1
// #2938 T4-1..15: the review record writes one row per round through appendRow, which fixes
// loop_cycle / row_no / kind / route from the previous row and the state event interval;
// summarize counts by (loop_cycle, row_no); older-input filtering, the single writer and the
// audit-block route. #2478: a CC-fallback round is a prestaged loop round (an append with source
// cc-fallback), the stage / record / discard-fallback route is gone, and append --no-park
// closes the inflight without parking. Rows are read back from the first sid's control dir.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { after, test } = require("node:test");
const F = require("./feature-2938-review-rounds/fixture");

const restore = isolate();
after(() => restore());

const D = "detail-plan";
const pick = (rs, k) => rs.map((r) => r[k]);
const ok = (r, what) => assert.strictEqual(r.status, 0, `${what}: ${r.err}`);
const interval = (...a) => F.mod("bin/lib/codex-review-loop/state-interval.js").readInterval(...a);

caseBegin("t4-1-kind-is-decided-by-row-no-and-fingerprint", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-1-kind-is-decided-by-row-no-and-fingerprint", () => {
  const sid = "k1";
  F.seed(sid);
  F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append(sid, D, 2, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.b });
  F.append(sid, D, 1, 1, "NEEDS_REVISION");
  F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.b });
  const rs = F.rows(sid, D);
  assert.deepStrictEqual(pick(rs, "loop_cycle"), [1, 1, 2, 3, 4, 5], "counter_round=1 opens a cycle");
  assert.deepStrictEqual(pick(rs, "row_no"), [1, 2, 1, 1, 1, 1]);
  // first row / row_no>1 / same fp / different fp / null fp / after a null fp
  assert.deepStrictEqual(pick(rs, "kind"), ["explore", "confirm", "confirm", "explore", "explore", "explore"]);
  assert.strictEqual(rs[0].route, "initial");
  assert.strictEqual(rs[1].route, "in-cycle");
  assert.strictEqual(rs[4].fingerprint, null, "no --fingerprint is a null fingerprint");
  assert.deepStrictEqual(pick(rs, "fingerprint_changed").slice(1, 4), [false, false, true]);
  assert.ok(rs.every((r) => r.schema_version === 1 && r.format === D && r.source === "codex"));
});
caseEnd();

caseBegin("t4-2-resumed-cycle-route-and-kind-are-independent", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-2-resumed-cycle-route-and-kind-are-independent", () => {
  const cases = [
    ["k2r-same", F.reset, F.FP.a, "reset", "confirm"],
    ["k2r-diff", F.reset, F.FP.b, "reset", "explore"],
    ["k2w-same", F.writeCode, F.FP.a, "write-code", "confirm"],
    ["k2w-diff", F.writeCode, F.FP.b, "write-code", "explore"],
  ];
  for (const [sid, ev, fp, route, kind] of cases) {
    F.seed(sid);
    F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
    ev(sid);
    F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp });
    const r = F.lastRow(sid, D);
    assert.deepStrictEqual([r.loop_cycle, r.row_no, r.route, r.kind], [2, 1, route, kind], sid);
    assert.strictEqual(r.interval_basis, "same-state", sid);
  }
});
caseEnd();

caseBegin("t4-3-reset-outranks-write-code-and-unknown-keeps-kinds", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-3-reset-outranks-write-code-and-unknown-keeps-kinds", () => {
  F.seed("k3b");
  F.append("k3b", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.writeCode("k3b");
  F.reset("k3b");
  F.append("k3b", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  assert.strictEqual(F.lastRow("k3b", D).route, "reset", "reset and write_code in one interval -> reset");
  const kinds = F.lastRow("k3b", D).interval_kinds || [];
  assert.ok(kinds.includes("reset") && kinds.includes("step_status"), `interval_kinds: ${kinds}`);

  F.seed("k3n");
  F.append("k3n", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.neutral("k3n");
  F.append("k3n", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const r = F.lastRow("k3n", D);
  assert.strictEqual(r.route, "unknown", "neither reset nor write_code -> unknown, not a plain rerun");
  assert.strictEqual(r.interval_basis, "same-state");
  assert.deepStrictEqual(r.interval_kinds, ["step_status"], "the interval kinds stay on the row");
});
caseEnd();

caseBegin("t4-3-until-seq-bounds-the-interval", "bin/lib/codex-review-loop/state-interval.js");
test("t4-3-until-seq-bounds-the-interval", () => {
  const sid = "k3u";
  F.seed(sid);
  const since = F.headSeq(sid);
  F.writeCode(sid);
  const until = F.headSeq(sid);
  F.reset(sid);
  const bounded = interval(sid, since, until, {});
  assert.strictEqual(bounded.state, "present");
  assert.strictEqual(bounded.has_write_code, true);
  assert.strictEqual(bounded.has_reset, false, "a reset after untilSeq is not in the interval");
  assert.strictEqual(bounded.has_audit_block, false, "no opts.format -> has_audit_block false");
  const open = interval(sid, since, null, {});
  assert.strictEqual(open.has_reset, true, "untilSeq null reads to the end of the stream");
  assert.strictEqual(open.head_seq, F.headSeq(sid));
  assert.ok(Array.isArray(open.kinds) && open.kinds.includes("reset"));
});
caseEnd();

caseBegin("t4-4-state-absent-unreadable-and-cross-generation", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-4-state-absent-unreadable-and-cross-generation", () => {
  F.append("k4a", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  assert.strictEqual(F.lastRow("k4a", D).route, "outside-workflow", "no state file -> outside-workflow");
  assert.strictEqual(interval("k4a", 0, null, {}).state, "absent");

  F.corrupt("k4c");
  F.append("k4c", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const c = F.lastRow("k4c", D);
  assert.deepStrictEqual([c.route, c.interval_basis], ["unknown", "state-unreadable"], "a broken state file is not outside-workflow");
  assert.strictEqual(interval("k4c", 0, null, {}).state, "unreadable");

  // Generation sids differ from "k4a" beyond case: Windows file systems are case-insensitive.
  F.seed("k4g1");
  F.seed("k4g2");
  F.handover("k4g2", "k4g1");
  F.append("k4g1", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append("k4g2", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const rs = F.rows("k4g1", D);
  assert.strictEqual(rs.length, 2, "both generations write the first sid's record");
  assert.deepStrictEqual([rs[1].route, rs[1].interval_basis, rs[1].interval_kinds], ["unknown", "cross-generation", null]);
  assert.deepStrictEqual([rs[0].state_sid, rs[1].state_sid], ["k4g1", "k4g2"]);
});
caseEnd();

caseBegin("t4-5-summarize-splits-kind-and-source-and-drops-duplicates", "bin/lib/codex-review-loop/review-rounds.js");
test("t4-5-summarize-splits-kind-and-source-and-drops-duplicates", () => {
  const sid = "k5";
  F.seed(sid);
  F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append(sid, D, 2, 1, "NEEDS_REVISION", { fp: F.FP.a, source: "cc-fallback" });
  F.addRaw(sid, D, F.rawLine(sid, D, 2));
  F.addRaw(sid, D, "{ broken");
  F.append(sid, D, 3, 0, "APPROVED", { fp: F.FP.a });
  const s = F.summarize(sid, D);
  assert.strictEqual(s.rows, 3);
  assert.deepStrictEqual(s.by_kind, { explore: 1, confirm: 2 });
  assert.deepStrictEqual(s.by_source, { codex: 2, cc_fallback: 1 });
  assert.strictEqual(s.duplicate_rows, 1, "the same (loop_cycle, row_no) is counted once");
  assert.strictEqual(s.unreadable_rows, 1);
  assert.strictEqual(s.current_cycle, 1);
  assert.strictEqual(s.fingerprints.length, 3);
  assert.deepStrictEqual([s.last.row_no, s.last.verdict, s.last.exit], [3, "APPROVED", 0]);
});
caseEnd();

caseBegin("t4-6-codex-round-after-a-fallback-round-is-the-next-round", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-6-codex-round-after-a-fallback-round-is-the-next-round", () => {
  F.seed("k6a");
  F.fallback("k6a", D, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append("k6a", D, 2, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const a = F.rows("k6a", D);
  assert.deepStrictEqual(pick(a, "counter_round"), [1, 2], "the fallback round is counted like a codex round");
  assert.deepStrictEqual(pick(a, "loop_cycle"), [1, 1]);
  assert.deepStrictEqual(pick(a, "row_no"), [1, 2]);
  assert.deepStrictEqual(pick(a, "kind"), ["explore", "confirm"]);
  assert.deepStrictEqual(pick(a, "route"), ["initial", "in-cycle"]);
  assert.deepStrictEqual([a[0].source, a[0].exit], ["cc-fallback", 1], "a fallback row carries the loop's exit");
  assert.match(String(a[0].run_id), /^[0-9a-f]+$/, "and the loop run's id");

  F.seed("k6b");
  F.fallback("k6b", D, 1, "APPROVED");
  F.append("k6b", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  assert.deepStrictEqual(pick(F.rows("k6b", D), "loop_cycle"), [1, 2], "after an APPROVED fallback round 1 opens a cycle");
});
caseEnd();

caseBegin("t4-6-reset-or-new-generation-after-fallback-opens-a-cycle", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-6-reset-or-new-generation-after-fallback-opens-a-cycle", () => {
  F.seed("k6r");
  F.fallback("k6r", D, 1, "NEEDS_REVISION");
  F.reset("k6r");
  F.append("k6r", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const r = F.rows("k6r", D);
  assert.deepStrictEqual(pick(r, "loop_cycle"), [1, 2], "a reset is a cycle boundary");
  assert.deepStrictEqual([r[1].row_no, r[1].route, r[1].kind], [1, "reset", "explore"]);
  assert.strictEqual(r.filter((x) => x.loop_cycle === 1).length, 1, "the earlier cycle keeps the fallback row only");

  F.seed("k6g1");
  F.seed("k6g2");
  F.handover("k6g2", "k6g1");
  F.fallback("k6g1", D, 1, "NEEDS_REVISION");
  F.append("k6g2", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const g = F.rows("k6g1", D);
  assert.deepStrictEqual(pick(g, "loop_cycle"), [1, 2], "another generation is not joined to the fallback's cycle");
  assert.deepStrictEqual([g[1].route, g[1].interval_basis], ["unknown", "cross-generation"]);
});
caseEnd();

caseBegin("t4-7-extensions-used-counts-current-cycle-auto-extend-once", "bin/lib/codex-review-loop/review-rounds.js");
test("t4-7-extensions-used-counts-current-cycle-auto-extend-once", () => {
  const sid = "k7";
  F.seed(sid);
  F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append(sid, D, 2, 5, "AUTO_EXTEND", { fp: F.FP.a });
  F.append(sid, D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append(sid, D, 2, 5, "AUTO_EXTEND", { fp: F.FP.a });
  F.append(sid, D, 3, 5, "AUTO_EXTEND", { fp: F.FP.a, source: "cc-fallback" });
  F.addRaw(sid, D, F.rawLine(sid, D, 4));
  const s = F.summarize(sid, D);
  assert.strictEqual(s.current_cycle, 2);
  assert.strictEqual(s.extensions_used, 2, "the earlier cycle and the duplicate row are not counted");
  const derive = (r) => F.rr(["derive-ext", "--session", sid, "--format", D, "--counter-round", r]);
  const d4 = derive(4);
  assert.strictEqual(d4.status, 0, d4.err);
  assert.match(d4.out.trim(), /(^|=)2$/, "derive-ext for round 4");
  assert.match(derive(1).out.trim(), /(^|=)0$/, "round 1 derives 0");
  assert.strictEqual(derive(7).status, 3, "no row for round 6 in the current cycle -> cannot derive (exit 3)");
});
caseEnd();

caseBegin("t4-9-downstream-writes-the-first-sid-record", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-9-downstream-writes-the-first-sid-record", () => {
  F.seed("k9A");
  F.seed("k9B");
  F.handover("k9B", "k9A");
  F.append("k9B", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  assert.ok(fs.existsSync(F.recPath("k9A", D)), "B's row is in A's control dir");
  assert.ok(!fs.existsSync(F.recPath("k9B", D)), "and not in B's");
  assert.deepStrictEqual(F.summarize("k9B", D), F.summarize("k9A", D), "A and B read the same record");
  const sa = F.rr(["summary", "--session", "k9A", "--format", D]);
  assert.strictEqual(sa.status, 0, sa.err);
  assert.strictEqual(F.rr(["summary", "--session", "k9B", "--format", D]).out, sa.out);
  assert.strictEqual(F.kv(sa.out).rows, "1");

  const pf = F.rr(["preflight", "--session", "k9B", "--format", "test-review"]);
  assert.strictEqual(pf.status, 0, pf.err);
  const infl = fs.readdirSync(F.ctlDir("k9A")).filter((n) => /^test-review-review-rounds-inflight-[0-9a-f]+\.json$/.test(n));
  assert.strictEqual(infl.length, 1, "B's inflight is in A's control dir");
});
caseEnd();

caseBegin("t4-8-older-input-keeps-open-concerns-of-older-input", "bin/review-rounds");
test("t4-8-older-input-keeps-open-concerns-of-older-input", () => {
  const sid = "c8", fmt = "detail-plan";
  F.seed(sid);
  F.append(sid, fmt, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append(sid, fmt, 2, 1, "NEEDS_REVISION", { fp: F.FP.b });
  F.append(sid, fmt, 3, 1, "NEEDS_REVISION");
  const s8 = "0".repeat(8);
  const line = (n, st, first, last) => `C${n}|HIGH|${st}|${first}|${last}|${s8}|${s8}|codex|codex||concern ${n}`;
  const ledger = path.join(F.ctlDir(sid), "c8-ledger.txt");
  fs.mkdirSync(path.dirname(ledger), { recursive: true });
  fs.writeFileSync(ledger, [
    `#concern-ledger-v2|${fmt}|${sid}|cycle=1`,
    line(1, "open", 1, 1), line(2, "open", 1, 2), line(3, "resolved", 1, 1),
    line(4, "reopened", 1, 1), line(5, "open", 1, 3), "",
  ].join("\n"));
  const r = F.rr(["older-input", "--session", sid, "--format", fmt, "--ledger", ledger, "--fingerprint", F.FP.b]);
  ok(r, "older-input");
  const ids = (r.out.match(/\bC\d+\b/g) || []).filter((v, i, a) => a.indexOf(v) === i);
  // Last raised against input a (round 1) and still open / reopened; round 2 is the current b,
  // round 3 has no fingerprint, C3 is resolved.
  assert.deepStrictEqual(ids, ["C1", "C4"]);
});
caseEnd();

const CODE_EXT = /\.(js|cjs|mjs|sh)$/;
function codeFiles(dir, out = []) {
  for (const e of fs.readdirSync(F.rel(dir), { withFileTypes: true })) {
    const p = path.posix.join(dir, e.name);
    if (e.isDirectory()) { if (e.name !== "node_modules") codeFiles(p, out); continue; }
    if (CODE_EXT.test(e.name) || (dir === "bin" && !path.extname(e.name))) out.push(p);
  }
  return out;
}
const src = (p) => fs.readFileSync(F.rel(p), "utf8");

caseBegin("t4-10-store-is-the-only-writer-of-the-record", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-10-store-is-the-only-writer-of-the-record", () => {
  const STORE = "bin/lib/codex-review-loop/review-rounds-store.js";
  const hits = ["bin", "hooks", "skills"].flatMap((d) => codeFiles(d)).filter((p) => src(p).includes("review-rounds.jsonl"));
  assert.deepStrictEqual(hits, [STORE], "only the store names the record file");
  assert.strictEqual(typeof F.mod(STORE).appendRow, "function", "the store exports appendRow");
  for (const p of ["bin/review-rounds", "bin/lib/codex-review-loop/review-rounds.js"]) {
    assert.doesNotMatch(src(p), /appendFileSync|writeFileSync|createWriteStream/, `${p} writes through appendRow only`);
  }
});
caseEnd();

caseBegin("t4-10-every-writer-fills-the-derived-fields", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-10-every-writer-fills-the-derived-fields", () => {
  F.seed("c10");
  F.append("c10", "detail-plan", 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.fallback("c10", "detail-plan", 2, "NEEDS_REVISION");
  const rs = F.rows("c10", "detail-plan");
  assert.strictEqual(rs.length, 2);
  for (const r of rs) {
    for (const k of ["loop_cycle", "row_no", "kind", "route", "interval_basis", "writer_sid", "at"]) {
      assert.ok(r[k] !== undefined && r[k] !== null, `${r.source} row has ${k}`);
    }
  }
});
caseEnd();

caseBegin("t4-11-cli-has-no-wrapper-external-fallback-route", "bin/review-rounds");
test("t4-11-cli-has-no-wrapper-external-fallback-route", () => {
  F.seed("c11");
  for (const cmd of [["stage-fallback"], ["record-fallback", "--verdict", "NEEDS_REVISION"], ["discard-fallback", "--reason", "x"]]) {
    const r = F.rr([...cmd, "--session", "c11", "--format", D]);
    assert.strictEqual(r.status, 2, `${cmd[0]} is not a command any more: ${r.err}`);
    assert.match(r.err, /usage: review-rounds </, `${cmd[0]}: refused as an unknown command`);
    assert.ok(!r.err.split("usage:")[1].includes(cmd[0]), `${cmd[0]} is not listed in the usage`);
  }
  const ctl = fs.existsSync(F.ctlDir("c11")) ? fs.readdirSync(F.ctlDir("c11")) : [];
  assert.deepStrictEqual(ctl.filter((n) => /fallback-(pending|discarded)/.test(n)), [], "nothing is staged");
  assert.strictEqual(F.rows("c11", D).length, 0);
});
caseEnd();

// noParkRun(sid, extra) — preflight, then an append that meets a directory at the record path.
function noParkRun(sid, extra) {
  F.seed(sid);
  const pf = F.rr(["preflight", "--session", sid, "--format", D]);
  ok(pf, "preflight");
  const runId = pf.out.trim();
  fs.rmSync(F.recPath(sid, D), { force: true });
  fs.mkdirSync(F.recPath(sid, D));
  const r = F.rr(["append", "--session", sid, "--format", D, "--counter-round", 1, "--exit", 1,
    "--verdict", "NEEDS_REVISION", "--source", "cc-fallback", "--run-id", runId, ...extra]);
  fs.rmSync(F.recPath(sid, D), { recursive: true, force: true });
  const names = fs.readdirSync(F.ctlDir(sid));
  return { r, inflight: names.filter((n) => n.includes(`inflight-${runId}`)), parked: names.filter((n) => n.endsWith("-unrecorded.jsonl")) };
}

caseBegin("t4-16-append-no-park-closes-the-inflight-and-parks-nothing", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-16-append-no-park-closes-the-inflight-and-parks-nothing", () => {
  const n = noParkRun("c16n", ["--no-park"]);
  assert.strictEqual(n.r.status, 4, `a failed --no-park append is a HALT (4), not a park (5): ${n.r.err}`);
  assert.deepStrictEqual([n.inflight, n.parked], [[], []], "the inflight is closed and no row is parked");
  ok(F.rr(["preflight", "--session", "c16n", "--format", D]), "the next preflight");
  assert.strictEqual(F.rows("c16n", D).length, 0, "the next preflight replays no row");
});
caseEnd();

caseBegin("t4-16-append-without-no-park-still-parks", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-16-append-without-no-park-still-parks", () => {
  const p = noParkRun("c16p", []);
  assert.strictEqual(p.r.status, 5, `a failed append parks the row (5): ${p.r.err}`);
  assert.deepStrictEqual([p.inflight, p.parked.length], [[], 1], "the inflight is closed and the row is parked");
  ok(F.rr(["preflight", "--session", "c16p", "--format", D]), "the next preflight");
  assert.strictEqual(F.rows("c16p", D).length, 1, "the next preflight replays the parked row");
});
caseEnd();

// #2478 C1: has-run tells the loop whether its --no-park append landed although the CLI failed.
const hasRun = (sid, fmt, extra) => F.rr(["has-run", "--session", sid, "--format", fmt, ...extra]);

caseBegin("t4-17-has-run-reports-a-landed-run-id", "bin/review-rounds");
test("t4-17-has-run-reports-a-landed-run-id", () => {
  F.seed("c17");
  F.append("c17", D, 1, 1, "NEEDS_REVISION", { source: "cc-fallback" });
  const runId = F.lastRow("c17", D).run_id;
  const r = hasRun("c17", D, ["--run-id", runId]);
  ok(r, "has-run");
  assert.strictEqual(r.out.trim(), "recorded=1", "the run's row is in the record");
  const store = F.mod("bin/lib/codex-review-loop/review-rounds-store.js");
  assert.strictEqual(typeof store.hasRun, "function", "the store exports hasRun");
  assert.strictEqual(store.hasRun({ sid: "c17", format: D, runId }), true, "hasRun finds the run's row");
});
caseEnd();

caseBegin("t4-17-has-run-reports-an-absent-run-id", "bin/review-rounds");
test("t4-17-has-run-reports-an-absent-run-id", () => {
  F.seed("c17a");
  F.append("c17a", D, 1, 1, "NEEDS_REVISION");
  const unknown = hasRun("c17a", D, ["--run-id", "0fdeadbeef"]);
  ok(unknown, "has-run for an unknown run id");
  assert.strictEqual(unknown.out.trim(), "recorded=0", "no row carries that run id");
  const none = hasRun("c17a", "test-review", ["--run-id", "0fdeadbeef"]);
  ok(none, "has-run for a format without a record file");
  assert.strictEqual(none.out.trim(), "recorded=0", "no record file is no row");
});
caseEnd();

caseBegin("t4-17-has-run-without-run-id-is-a-usage-error", "bin/review-rounds");
test("t4-17-has-run-without-run-id-is-a-usage-error", () => {
  F.seed("c17u");
  const r = hasRun("c17u", D, []);
  assert.strictEqual(r.status, 2, `has-run without --run-id: ${r.err}`);
  assert.match(r.err, /--run-id is required/, "refused for the missing --run-id, not as an unknown command");
});
caseEnd();

caseBegin("t4-17-has-run-on-an-unreadable-record-halts", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-17-has-run-on-an-unreadable-record-halts", () => {
  F.seed("c17h");
  fs.mkdirSync(F.recPath("c17h", D), { recursive: true });
  const r = hasRun("c17h", D, ["--run-id", "0fdeadbeef"]);
  fs.rmSync(F.recPath("c17h", D), { recursive: true, force: true });
  assert.strictEqual(r.status, 4, `an unreadable record cannot answer (4), never recorded=0: ${r.err}`);
  assert.doesNotMatch(r.out, /recorded=/, "no answer is printed");
});
caseEnd();

caseBegin("t4-12-audit-block-route", "bin/lib/codex-review-loop/state-interval.js");
test("t4-12-audit-block-route", () => {
  const O = "outline-plan";
  // run(sid, fmt, between) — row 1, then `between` after its `at`, then row 2; returns row 2.
  const run = (sid, fmt, between) => {
    const v = fmt === O ? "MISSING_ALTERNATIVE" : "NEEDS_REVISION";
    F.seed(sid);
    F.append(sid, fmt, 1, 1, v, { fp: F.FP.a });
    F.sleep(30);
    between(sid);
    F.sleep(30);
    F.append(sid, fmt, 1, 1, v, { fp: F.FP.a });
    return F.lastRow(sid, fmt);
  };
  const now = () => new Date().toISOString();
  assert.strictEqual(run("c12a", O, (s) => F.auditEntry(s, "TR2", now())).route, "audit-block");
  const iv = F.rr(["interval", "--session", "c12a", "--format", O, "--since-at", F.rows("c12a", O)[0].at]);
  ok(iv, "interval");
  assert.strictEqual(F.kv(iv.out).has_audit_block, "1");

  assert.strictEqual(run("c12n", O, () => {}).route, "unknown", "no supervisor-state");
  assert.strictEqual(run("c12c", O, (s) => F.auditEntry(s, "TR2", now(), "CONTINUE")).route, "unknown", "CONTINUE is not a block");
  assert.strictEqual(run("c12o", O, (s) => F.auditEntry(s, "TR2", "2000-01-01T00:00:00.000Z")).route, "unknown", "a block before the previous row");
  assert.strictEqual(run("c12r", O, (s) => { F.auditEntry(s, "TR2", now()); F.reset(s); }).route, "reset", "reset outranks audit-block");
  assert.strictEqual(run("c12w", O, (s) => { F.auditEntry(s, "TR2", now()); F.writeCode(s); }).route, "write-code", "write_code outranks audit-block");
  assert.strictEqual(run("c12s", "security-plan", (s) => F.auditEntry(s, "TR2", now())).route, "unknown",
    "only outline-plan / detail-plan get audit-block");
});
caseEnd();

caseBegin("t4-13-outline-fallback-records-missing-alternative", "bin/review-rounds");
test("t4-13-outline-fallback-records-missing-alternative", () => {
  const O = "outline-plan";
  F.seed("c13");
  F.fallback("c13", O, 1, "MISSING_ALTERNATIVE");
  assert.strictEqual(F.lastRow("c13", O).verdict, "MISSING_ALTERNATIVE");
  assert.strictEqual(F.summarize("c13", O).rows, 1);
  F.append("c13", O, 2, 1, "MISSING_ALTERNATIVE", { fp: F.FP.a });
  const rs = F.rows("c13", O);
  assert.deepStrictEqual([pick(rs, "loop_cycle"), pick(rs, "row_no")], [[1, 1], [1, 2]], "the next codex round joins the fallback's cycle");
  assert.deepStrictEqual(F.summarize("c13", O).by_source, { codex: 1, cc_fallback: 1 });
});
caseEnd();

caseBegin("t4-15-torn-tail-keeps-the-next-row-on-its-own-line", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-15-torn-tail-keeps-the-next-row-on-its-own-line", () => {
  const store = F.mod("bin/lib/codex-review-loop/review-rounds-store.js");
  const sid = "c15", fmt = "detail-plan";
  F.seed(sid);
  F.append(sid, fmt, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  fs.appendFileSync(F.recPath(sid, fmt), '{"schema_version":1,"form');
  const before = store.readRows(sid, fmt);
  assert.deepStrictEqual([before.parsed.length, before.unreadable, before.torn], [1, 1, true]);
  F.append(sid, fmt, 2, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const after = store.readRows(sid, fmt);
  assert.deepStrictEqual([after.parsed.length, after.unreadable, after.torn], [2, 1, false]);
  assert.strictEqual(after.parsed[1].counter_round, 2, "the new row parses as its own line");
});
caseEnd();
