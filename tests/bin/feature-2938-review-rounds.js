"use strict";
// Tests: bin/lib/codex-review-loop/review-rounds.js, bin/lib/codex-review-loop/review-rounds-store.js, bin/lib/codex-review-loop/state-interval.js, bin/review-rounds
// Tags: feature-2938, review-rounds, review-record, loop-cycle, kind-route, stage-fallback, audit-block, scope:issue-specific, TL1
// #2938 T4-1..13: the review record writes one row per round through appendRow, which fixes
// loop_cycle / row_no / kind / route from the previous row and the state event interval;
// summarize counts by (loop_cycle, row_no); older-input filtering, the single writer, stage-fallback
// numbering, the audit-block route and the per-format record-fallback verdicts read from
// skills/_shared/codex-review-loop.md. Rows are written through bin/review-rounds and read back
// from the first sid's control dir. state-interval.js is called directly.
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
const stage = (sid, fmt) => F.rr(["stage-fallback", "--session", sid, "--format", fmt]);
const record = (sid, fmt, v) => F.rr(["record-fallback", "--session", sid, "--format", fmt, "--verdict", v]);
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

caseBegin("t4-6-fallback-retry-stays-in-cycle", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-6-fallback-retry-stays-in-cycle", () => {
  F.seed("k6a");
  F.fallback("k6a", D, "NEEDS_REVISION");
  F.append("k6a", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const a = F.rows("k6a", D);
  assert.deepStrictEqual(pick(a, "loop_cycle"), [1, 1], "a codex retry of the fallback's round stays in its cycle");
  assert.deepStrictEqual(pick(a, "row_no"), [1, 2]);
  assert.deepStrictEqual(pick(a, "kind"), ["explore", "confirm"]);
  assert.deepStrictEqual(pick(a, "route"), ["initial", "in-cycle"]);
  assert.deepStrictEqual([a[0].source, a[0].exit, a[0].run_id], ["cc-fallback", null, null]);

  F.seed("k6b");
  F.fallback("k6b", D, "APPROVED");
  F.append("k6b", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  assert.deepStrictEqual(pick(F.rows("k6b", D), "loop_cycle"), [1, 2], "after an APPROVED fallback round 1 opens a cycle");
});
caseEnd();

caseBegin("t4-6-reset-or-new-generation-after-fallback-opens-a-cycle", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-6-reset-or-new-generation-after-fallback-opens-a-cycle", () => {
  F.seed("k6r");
  F.fallback("k6r", D, "NEEDS_REVISION");
  F.reset("k6r");
  F.append("k6r", D, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const r = F.rows("k6r", D);
  assert.deepStrictEqual(pick(r, "loop_cycle"), [1, 2], "a reset is a cycle boundary");
  assert.deepStrictEqual([r[1].row_no, r[1].route, r[1].kind], [1, "reset", "explore"]);
  assert.strictEqual(r.filter((x) => x.loop_cycle === 1).length, 1, "the earlier cycle keeps the fallback row only");

  F.seed("k6g1");
  F.seed("k6g2");
  F.handover("k6g2", "k6g1");
  F.fallback("k6g1", D, "NEEDS_REVISION");
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

  const st = F.rr(["stage-fallback", "--session", "k9B", "--format", D]);
  assert.strictEqual(st.status, 0, st.err);
  const pend = `${D}-review-rounds-fallback-pending.json`;
  assert.ok(fs.existsSync(path.join(F.ctlDir("k9A"), pend)), "B's pending is in A's control dir");
  assert.ok(!fs.existsSync(path.join(F.ctlDir("k9B"), pend)));
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
  F.fallback("c10", "detail-plan", "NEEDS_REVISION");
  const rs = F.rows("c10", "detail-plan");
  assert.strictEqual(rs.length, 2);
  for (const r of rs) {
    for (const k of ["loop_cycle", "row_no", "kind", "route", "interval_basis", "writer_sid", "at"]) {
      assert.ok(r[k] !== undefined && r[k] !== null, `${r.source} row has ${k}`);
    }
  }
});
caseEnd();

caseBegin("t4-11-stage-fallback-numbers-the-round", "bin/review-rounds");
test("t4-11-stage-fallback-numbers-the-round", () => {
  const fmt = "detail-plan";
  F.seed("c11a");
  F.fallback("c11a", fmt, "NEEDS_REVISION");
  F.fallback("c11a", fmt, "NEEDS_REVISION");
  F.append("c11a", fmt, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  const a = F.rows("c11a", fmt);
  assert.deepStrictEqual(pick(a, "counter_round"), [1, 1, 1], "no rows -> 1, and a non-approved fallback keeps its round");
  assert.deepStrictEqual(pick(a, "loop_cycle"), [1, 1, 1]);
  assert.deepStrictEqual(pick(a, "row_no"), [1, 2, 3]);

  F.seed("c11b");
  F.append("c11b", fmt, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.fallback("c11b", fmt, "NEEDS_REVISION");
  F.fallback("c11b", fmt, "NEEDS_REVISION");
  assert.deepStrictEqual(pick(F.rows("c11b", fmt), "counter_round"), [1, 2, 2], "after a wrapper round K -> K+1");

  F.seed("c11c");
  F.append("c11c", fmt, 1, 1, "NEEDS_REVISION", { fp: F.FP.a });
  F.append("c11c", fmt, 2, 5, "AUTO_EXTEND", { fp: F.FP.a });
  F.fallback("c11c", fmt, "NEEDS_REVISION");
  assert.strictEqual(F.lastRow("c11c", fmt).counter_round, 3, "after AUTO_EXTEND round 2 -> 3");

  F.seed("c11d");
  F.append("c11d", fmt, 1, 0, "APPROVED", { fp: F.FP.a });
  F.fallback("c11d", fmt, "NEEDS_REVISION");
  const d = F.lastRow("c11d", fmt);
  assert.deepStrictEqual([d.counter_round, d.loop_cycle, d.row_no], [1, 2, 1], "after APPROVED -> 1 in a new cycle");
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
  F.fallback("c13", O, "MISSING_ALTERNATIVE");
  assert.strictEqual(F.lastRow("c13", O).verdict, "MISSING_ALTERNATIVE");
  assert.strictEqual(F.summarize("c13", O).rows, 1);
  F.append("c13", O, 1, 1, "MISSING_ALTERNATIVE", { fp: F.FP.a });
  const rs = F.rows("c13", O);
  assert.deepStrictEqual([pick(rs, "loop_cycle"), pick(rs, "row_no")], [[1, 1], [1, 2]], "the codex retry joins the fallback's cycle");

  F.seed("c13d");
  ok(stage("c13d", "detail-plan"), "stage-fallback");
  assert.notStrictEqual(record("c13d", "detail-plan", "MISSING_ALTERNATIVE").status, 0, "detail-plan rejects MISSING_ALTERNATIVE");
  assert.strictEqual(F.rows("c13d", "detail-plan").length, 0);
});
caseEnd();

// NON_APPROVED_VERDICT per format, from the parameter tables of the shared loop doc.
function docVerdicts() {
  const NAME = { "outline value": "outline-plan", "detail value": "detail-plan" };
  const out = {};
  let cols = null;
  for (const l of src("skills/_shared/codex-review-loop.md").split(/\r?\n/)) {
    const cells = l.split("|").slice(1, -1).map((c) => c.trim());
    if (cells[0] === "Parameter") cols = cells.slice(1).map((c) => NAME[c] || c);
    else if (cols && cells[0] === "NON_APPROVED_VERDICT") {
      cells.slice(1).forEach((c, i) => { out[cols[i]] = c.replace(/`/g, "").replace(/:$/, ""); });
    }
  }
  return out;
}

caseBegin("t4-13-record-fallback-verdicts-follow-the-doc-table", "bin/review-rounds");
test("t4-13-record-fallback-verdicts-follow-the-doc-table", () => {
  const v = docVerdicts();
  assert.deepStrictEqual(Object.keys(v).sort(), ["detail-plan", "outline-plan", "security-plan", "test-review"]);
  for (const [fmt, verdict] of Object.entries(v)) {
    const sid = `c13t-${fmt}`;
    F.seed(sid);
    ok(stage(sid, fmt), `${fmt} stage-fallback`);
    assert.notStrictEqual(record(sid, fmt, "BOGUS").status, 0, `${fmt} rejects an unknown verdict`);
    assert.strictEqual(F.rows(sid, fmt).length, 0, `${fmt}: a rejected verdict writes no row`);
    if (fmt !== "outline-plan") assert.notStrictEqual(record(sid, fmt, "MISSING_ALTERNATIVE").status, 0, `${fmt} rejects MISSING_ALTERNATIVE`);
    ok(record(sid, fmt, verdict), `${fmt} records ${verdict}`);
    assert.strictEqual(F.rows(sid, fmt).length, 1);
    ok(stage(sid, fmt), `${fmt} stage-fallback again`);
    ok(record(sid, fmt, "APPROVED"), `${fmt} records APPROVED`);
  }
});
caseEnd();

const pendPath = (sid, fmt) => path.join(F.ctlDir(sid), `${fmt}-review-rounds-fallback-pending.json`);
const ccRows = (sid, fmt) => F.rows(sid, fmt).filter((r) => r.source === "cc-fallback");

caseBegin("t4-14-record-fallback-retry-after-failed-pending-removal-is-one-row", "bin/review-rounds");
test("t4-14-record-fallback-retry-after-failed-pending-removal-is-one-row", () => {
  const sid = "c14", fmt = "detail-plan";
  F.seed(sid);
  ok(stage(sid, fmt), "stage-fallback");
  const raw = fs.readFileSync(pendPath(sid, fmt), "utf8");
  const stagedAt = JSON.parse(raw).staged_at;
  ok(record(sid, fmt, "NEEDS_REVISION"), "record-fallback");
  fs.writeFileSync(pendPath(sid, fmt), raw);
  ok(record(sid, fmt, "NEEDS_REVISION"), "record-fallback retry");
  assert.strictEqual(ccRows(sid, fmt).length, 1, "the retry finds the row instead of appending again");
  assert.ok(!fs.existsSync(pendPath(sid, fmt)), "the retry removes the pending");
  assert.strictEqual(ccRows(sid, fmt)[0].fallback_staged_at, stagedAt);

  F.sleep(5);
  ok(stage(sid, fmt), "stage-fallback for a new pending");
  assert.notStrictEqual(JSON.parse(fs.readFileSync(pendPath(sid, fmt), "utf8")).staged_at, stagedAt);
  ok(record(sid, fmt, "NEEDS_REVISION"), "record-fallback of the new pending");
  assert.strictEqual(ccRows(sid, fmt).length, 2, "a different pending is a different row");
});
caseEnd();

caseBegin("t4-14-record-fallback-module-retry-returns-the-recorded-row", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-14-record-fallback-module-retry-returns-the-recorded-row", () => {
  const store = F.mod("bin/lib/codex-review-loop/review-rounds-store.js");
  const sid = "c14m", fmt = "detail-plan";
  F.seed(sid);
  const p = store.stageFallback({ sid, format: fmt });
  const raw = fs.readFileSync(pendPath(sid, fmt), "utf8");
  const first = store.recordFallback({ sid, format: fmt, verdict: "NEEDS_REVISION" });
  fs.writeFileSync(pendPath(sid, fmt), raw);
  const again = store.recordFallback({ sid, format: fmt, verdict: "NEEDS_REVISION" });
  assert.deepStrictEqual(again, first, "the retry returns the row already recorded");
  assert.strictEqual(again.fallback_staged_at, p.staged_at);
  assert.strictEqual(ccRows(sid, fmt).length, 1);
  assert.ok(!fs.existsSync(pendPath(sid, fmt)));
});
caseEnd();

caseBegin("t4-14-legacy-pending-without-staged-at-is-not-deduped", "bin/lib/codex-review-loop/review-rounds-store.js");
test("t4-14-legacy-pending-without-staged-at-is-not-deduped", () => {
  const sid = "c14l", fmt = "detail-plan";
  F.seed(sid);
  ok(stage(sid, fmt), "stage-fallback");
  const legacy = JSON.parse(fs.readFileSync(pendPath(sid, fmt), "utf8"));
  delete legacy.staged_at;
  const raw = JSON.stringify(legacy) + "\n";
  fs.writeFileSync(pendPath(sid, fmt), raw);
  ok(record(sid, fmt, "NEEDS_REVISION"), "record-fallback of a legacy pending");
  fs.writeFileSync(pendPath(sid, fmt), raw);
  ok(record(sid, fmt, "NEEDS_REVISION"), "record-fallback of the same legacy pending");
  const rs = ccRows(sid, fmt);
  assert.strictEqual(rs.length, 2, "no staged_at -> no mark to dedupe on");
  assert.ok(rs.every((r) => !("fallback_staged_at" in r)), "a legacy row carries no fallback_staged_at");
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
