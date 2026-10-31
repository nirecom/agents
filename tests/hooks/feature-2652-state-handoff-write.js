#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/state-handoff-record.js
// Tags: TL2, workflow-state, state-handoff-record, active-period, redaction, state-lock, regression-2652, regression-2446, regression-2578, scope:issue-specific, dup-group-keep:size-hard-limit, pwsh-not-required
// lang-check: ignore — multibyte fixture strings are test data for truncation/UTF-8 handling.
// #2652 S1-4: the write entry appendStateHandoffRecord against real files in a temp WORKFLOW_STATE_DIR
// (detail plan S1-3 / S1-4); also carries the handoff-writer half of feat-2430-workflow-active-period.sh.
// TL3 gap (what this test does NOT catch):
// - hooks calling the entry from a real Claude Code session (gate-block, auto-record, post-compact);
// - a real cleanup sweep at the race point: the deletion is injected by patching core.readRawState.

const { isolate } = require("../lib/harness");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2652w-"));
process.chdir(SCRATCH);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const { check, eq, show } = require("./feature-2652-state-handoff/check");
const X = require("./feature-2652-state-handoff-write/fixture");
const { F } = X;
const ROOT = path.resolve(__dirname, "..", "..");
const S = require(path.join(ROOT, "hooks", "workflow-state", "state-io"));
const W = process.env.WORKFLOW_STATE_DIR;

let entryLoadError = "not exported";
let ENTRY = null;
try { ENTRY = require(path.join(ROOT, "hooks", "lib", "state-handoff-record")).appendStateHandoffRecord; } catch (e) { entryLoadError = e.message.split("\n")[0]; }
function append(sid, inp) {
  if (typeof ENTRY !== "function") throw new Error(`appendStateHandoffRecord not loadable: ${entryLoadError}`);
  return ENTRY(sid, inp);
}
const input = (over) => Object.assign({ cls: "C", step: "write_tests", key: "gate:block", summary: "blocked by the gate", pointer: "-", origin: "gate-block" }, over);
const active = (sid) => { F.makeState(sid, SCRATCH); return sid; };
const pause = (sid, forStep) => fs.writeFileSync(path.join(W, sid + ".next-step-paused"), JSON.stringify({
  version: 2, reason: "fixture", for_step: forStep, set_at: new Date().toISOString(), expires_at: new Date(Date.now() + 3600000).toISOString(),
}));
const written = (r) => { if (!r || r.written !== true) throw new Error(`want written:true got=${show(r)}`); };
// expectNoChange(sid, call, reason) — the call returns {written:false, reason} and leaves the file bytes alone.
function expectNoChange(sid, call, reason) {
  const before = X.bytesOf(sid);
  const r = call();
  eq([r && r.written, r && r.reason], [false, reason], "result");
  if (String(before) !== String(X.bytesOf(sid))) throw new Error("the state file changed");
}
const ownTotal = (sid) => X.records(sid).reduce((s, e) => s + X.compactBytes(e), 0);

// --- active period (the handoff-writer half of feat-2430-workflow-active-period.sh) ---
check("no state file -> no-state, and no file is created", () => {
  const r = append("w-none", input());
  eq([r.written, r.reason], [false, "no-state"], "result");
  eq(fs.existsSync(F.statePath("w-none")), false, "state file exists");
});
check("workflow_init not complete -> outside-period, file unchanged", () => {
  S.writeState("w-init", S.createInitialState("w-init", { cwd: SCRATCH, git_branch: "feature/x" }));
  expectNoChange("w-init", () => append("w-init", input()), "outside-period");
});
check("final_report complete -> outside-period, file unchanged", () => {
  active("w-final");
  S.markStep("w-final", "final_report", "complete");
  expectNoChange("w-final", () => append("w-final", input()), "outside-period");
});
const periodSeeds = [
  ["the active period", (sid) => active(sid)],
  ["a WORKFLOW_OFF marker (#2578)", (sid) => { active(sid); fs.writeFileSync(path.join(W, sid + ".workflow-off"), ""); }],
  ["a session-wide NEXT_STEP_PAUSE (#2578)", (sid) => { active(sid); pause(sid, "any"); }],
  ["a NEXT_STEP_PAUSE on the current step (#2578)", (sid) => {
    active(sid);
    const cur = require(path.join(ROOT, "hooks", "workflow-state", "current-step")).resolveCurrentEffectiveStep(sid);
    if (!cur) throw new Error("fixture: no current step");
    pause(sid, cur);
  }],
];
periodSeeds.forEach(([label, seed], i) => {
  check(`${label} -> written, exactly one record stored`, () => {
    const sid = `w-period-${i}`;
    seed(sid);
    written(append(sid, input()));
    eq(X.records(sid).length, 1, "stored records");
  });
});
check("a corrupt state file -> no throw, written:false, bytes unchanged", () => {
  fs.writeFileSync(F.statePath("w-corrupt"), "{ not json");
  const r = append("w-corrupt", input());
  eq(r && r.written, false, "written");
  eq(fs.readFileSync(F.statePath("w-corrupt"), "utf8"), "{ not json", "file");
});
for (const sid of ["../escape", "", null, "a b"]) {
  check(`sid ${show(sid)} -> invalid, no throw`, () => {
    const r = append(sid, input());
    eq([r && r.written, r && r.reason], [false, "invalid"], "result");
  });
}

// --- input refusal ---
active("w-invalid");
const refused = [
  ["cls H", { cls: "H" }], ["origin flush", { origin: "flush" }], ["step outside VALID_STEPS", { step: "nope" }],
  ["a key with a space", { key: "gate block" }], ["a 121-character key", { key: "k".repeat(121) }],
  ["the reserved overflow key", { cls: "B", key: "state-handoff:overflow" }], ["a non-string key", { key: 42 }], ["a null cls", { cls: null }],
];
for (const [label, over] of refused) {
  check(`${label} -> invalid, file unchanged`, () => expectNoChange("w-invalid", () => append("w-invalid", input(over)), "invalid"));
}

// --- stored shape and provenance ---
check("stored shape: at_step from step, provenance declared for procedure-point, observed otherwise, `at` set", () => {
  const sid = active("w-shape");
  written(append(sid, input({ cls: "A", step: "-", key: "p.point", origin: "procedure-point" })));
  written(append(sid, input({ cls: "C", key: "g.block", origin: "gate-block" })));
  written(append(sid, input({ cls: "D", key: "a.record", origin: "auto-record" })));
  const got = X.records(sid).map((e) => [e.cls, e.at_step, e.record_key, e.origin, e.provenance, typeof e.at, Object.prototype.hasOwnProperty.call(e, "step")]);
  eq(got, [
    ["A", "-", "p.point", "procedure-point", "declared", "string", false],
    ["C", "write_tests", "g.block", "gate-block", "observed", "string", false],
    ["D", "write_tests", "a.record", "auto-record", "observed", "string", false],
  ], "records");
});

// --- noop-identical ---
check("the same record twice -> second is noop-identical", () => {
  const sid = active("w-noop-1");
  written(append(sid, input()));
  expectNoChange(sid, () => append(sid, input()), "noop-identical");
});
check("X, Y (same cls), X -> the third is written (only the last own record of the cls counts)", () => {
  const sid = active("w-noop-2");
  written(append(sid, input({ summary: "X" })));
  written(append(sid, input({ summary: "Y" })));
  written(append(sid, input({ summary: "X" })));
  eq(X.records(sid).length, 3, "stored records");
});
check("X (cls C), Y (cls D), X (cls C) -> the third is noop-identical", () => {
  const sid = active("w-noop-3");
  written(append(sid, input({ summary: "X" })));
  written(append(sid, input({ cls: "D", summary: "Y" })));
  expectNoChange(sid, () => append(sid, input({ summary: "X" })), "noop-identical");
});

// --- redaction ---
check("secrets and sentinels in summary / pointer are redacted before storing", () => {
  const sid = active("w-redact");
  const aws = "AKIA" + "ABCDEFGHIJKLMNOP";
  const gh = "ghp_" + "a".repeat(36);
  written(append(sid, input({ summary: `token=hunter2value ${aws} <<WORKFLOW_RESET_FROM_write_code: x>>`, pointer: `see ${gh}` })));
  const [rec] = X.records(sid);
  const text = `${rec.summary} ${rec.pointer}`;
  for (const leak of ["hunter2value", aws, gh, "<<WORKFLOW_"]) if (text.includes(leak)) throw new Error(`stored text still carries ${leak}: ${text}`);
  if (!rec.summary.includes("<redacted>") || !rec.summary.includes("<<_REDACTED_WORKFLOW") || !rec.pointer.includes("<redacted>")) throw new Error(`no redaction marks: ${text}`);
});
check("a secret-shaped record_key is stored as redacted-key and the state file text never carries it", () => {
  const sid = active("w-redact-key");
  const gh = "ghp_" + "a1B2c3D4e5".repeat(3) + "f6G7h8";
  written(append(sid, input({ key: gh })));
  eq(X.records(sid).map((e) => e.record_key), ["redacted-key"], "stored keys");
  if (String(X.bytesOf(sid)).includes(gh)) throw new Error("the raw state file still carries the secret key");
});

// --- one-record limit and total budget ---
const big = input({ key: "k".repeat(120), summary: "あ".repeat(400), pointer: "あ".repeat(300) });
const full = X.storedBytes(X.storedShape(big));
check("one record over 2048 bytes: summary cut at a character boundary with `...`, stored form <= 2048 bytes", () => {
  if (full <= 2049) throw new Error(`fixture: the untruncated record is only ${full} bytes`);
  const sid = active("w-cap");
  written(append(sid, big));
  const [rec] = X.records(sid);
  if (X.compactBytes(rec) > 2048) throw new Error(`stored record is ${X.compactBytes(rec)} bytes`);
  if (!/^あ+\.\.\.$/.test(rec.summary) || rec.summary.includes("�")) throw new Error(`summary not cut cleanly: ${rec.summary.slice(-12)}`);
  eq(rec.pointer, "あ".repeat(300), "pointer");
});
check("total budget uses the truncated size: a record that only fits after truncation is written", () => {
  const sid = active("w-total");
  X.fillTo(sid, 65536 - (full - 1));
  written(append(sid, big));
  const own = ownTotal(sid);
  if (own > 65536) throw new Error(`own records total ${own} bytes`);
  eq(X.records(sid).filter((e) => e.record_key === big.key).length, 1, "big record stored");
});
function expectOverflow(sid, fillerCount) {
  const late = (k) => input({ key: `late.${k}`, summary: "one more record past the budget" });
  for (const k of [1, 2]) {
    const r = append(sid, late(k));
    eq([r && r.written, r && r.reason], [false, "overflow"], `write ${k}`);
  }
  const recs = X.records(sid);
  const over = recs.filter((e) => e.record_key === "state-handoff:overflow");
  eq(over.map((e) => e.cls), ["B"], "overflow records");
  eq([recs.length, recs.some((e) => /^late\./.test(e.record_key))], [fillerCount + 1, false], "records after overflow");
}
check("byte budget first: own records near 64KB -> one class B overflow record, nothing more", () => {
  const sid = active("w-bytes");
  expectOverflow(sid, X.fillTo(sid, 65536 - 100));
});
check("overflow is sticky: after the overflow record, a small record that would still fit is refused", () => {
  const sid = active("w-sticky");
  const spare = 600;
  const fillerCount = X.fillTo(sid, 65536 - spare);
  const tooBig = input({ key: "too.big", summary: "x".repeat(300), pointer: "x".repeat(300) });
  const small = input({ cls: "F", key: "small.after", summary: "s", pointer: "-", origin: "auto-record" });
  const bigBytes = X.storedBytes(X.storedShape(tooBig));
  const smallBytes = X.storedBytes(X.storedShape(small));
  if (bigBytes <= spare) throw new Error(`fixture: the too-big record is only ${bigBytes} bytes, it fits the ${spare} spare bytes`);
  if (smallBytes > spare) throw new Error(`fixture: the small record is ${smallBytes} bytes, it does not fit the ${spare} spare bytes`);
  const r = append(sid, tooBig);
  eq([r && r.written, r && r.reason], [false, "overflow"], "too-big write");
  eq(X.records(sid).filter((e) => e.record_key === "state-handoff:overflow").length, 1, "overflow records after the too-big write");
  expectNoChange(sid, () => append(sid, small), "overflow");
  const recs = X.records(sid);
  eq(recs.filter((e) => e.record_key === "state-handoff:overflow").length, 1, "overflow records");
  eq([recs.length, recs.some((e) => e.record_key === "small.after")], [fillerCount + 1, false], "records after the small write");
});
check("count budget: 300 minimal own records stay under 64KB and the 300th is written", () => {
  const sid = active("w-count");
  F.pushEvents(sid, Array.from({ length: 299 }, (_, i) => F.record({ cls: "F", record_key: `n.${i}`, summary: "s", pointer: "-", origin: "auto-record", at: X.AT })));
  written(append(sid, input({ cls: "F", key: "n.299", summary: "s", pointer: "-", origin: "auto-record" })));
  const recs = X.records(sid);
  eq(recs.length, 300, "stored records");
  const total = recs.reduce((s, e) => s + X.storedBytes(e), 0);
  if (total >= 65536) throw new Error(`fixture: 300 minimal records already take ${total} bytes, so the byte budget would fire first`);
});
check("count budget: the 301st own record -> one overflow record, nothing more", () => {
  expectOverflow("w-count", 300);
});
// --- overflow record provenance follows its origin (same mapping as a normal record) ---
const provenanceOf = (origin) => (origin === "procedure-point" ? "declared" : "observed");
const overflowSids = [];
[["OV-1", "procedure-point"], ["OV-2", "gate-block"], ["OV-3", "auto-record"]].forEach(([label, origin]) => {
  check(`${label}: an overflow triggered by origin ${origin} stores origin ${origin}, provenance ${provenanceOf(origin)}`, () => {
    const sid = active(`w-ov-${origin}`);
    overflowSids.push(sid);
    X.fillTo(sid, 65536 - 100);
    const r = append(sid, input({ key: `ov.${origin}`, summary: "x".repeat(200), origin }));
    eq([r && r.written, r && r.reason], [false, "overflow"], "result");
    const over = X.records(sid).filter((e) => e.record_key === "state-handoff:overflow");
    eq(over.map((e) => [e.cls, e.origin, e.provenance]), [["B", origin, provenanceOf(origin)]], "overflow records");
  });
});
check("OV-4: every stored record in OV-1..3 keeps provenance === (origin procedure-point ? declared : observed)", () => {
  eq(overflowSids.length, 3, "overflow sessions seeded");
  const broken = overflowSids.flatMap((sid) => X.records(sid))
    .filter((e) => e.provenance !== provenanceOf(e.origin))
    .map((e) => [e.record_key, e.origin, e.provenance]);
  eq(broken, [], "records breaking the mapping");
});
check("records at or before upstream_copy_seq do not count toward the budget", () => {
  const sid = active("w-upstream");
  // 150 x 440 bytes = 66000 bytes: over the whole budget if these counted as own records.
  const last = F.pushEvents(sid, Array.from({ length: 150 }, (_, i) => X.filler(`u${i}`, 440)));
  F.setTopLevel(sid, { upstream_session_id: "s2652-upstream", upstream_copy_seq: last });
  written(append(sid, input({ key: "after.copy" })));
});

// --- the lock: deleted state file, concurrent writers, a held lock ---
check("state file deleted after the lock-free check -> no-state, no file recreated", () => {
  const sid = active("w-race");
  const c = X.runChild(["race", sid, JSON.stringify(input())]);
  if (!c.out) throw new Error(`child printed nothing (${c.status}): ${c.raw} ${c.stderr.slice(0, 200)}`);
  if (c.out.threw) throw new Error(`entry threw: ${c.out.threw}`);
  if (!c.out.fired) throw new Error("injection never fired: the entry did not check through core.readRawState outside the lock");
  eq([c.out.result.written, c.out.result.reason], [false, "no-state"], "result");
  eq(fs.existsSync(F.statePath(sid)), false, "state file recreated");
});
check("8 writers in parallel (#2446): all 40 records stored, seq contiguous", () => {
  const sid = active("w-fanout");
  const c = X.runChild(["fanout", sid, "8", "5"], 110000);
  if (!Array.isArray(c.out)) throw new Error(`fanout printed nothing (${c.status}): ${c.raw}`);
  const results = c.out.map((o) => { try { return JSON.parse(o.stdout); } catch (e) { return [{ threw: `burst exit=${o.code} ${o.stderr}` }]; } }).flat();
  const bad = results.filter((x) => !x.result || x.result.written !== true);
  if (bad.length) throw new Error(`${bad.length} writes not written, first=${show(bad[0])}`);
  const state = X.readState(sid);
  eq(state.events.filter((e) => e.kind === "state_handoff_record").length, 40, "stored records");
  eq(state.events.map((e) => e.seq), state.events.map((_, i) => i + 1), "seq");
  require(path.join(ROOT, "hooks", "workflow-state", "state-io", "projection")).assertStreamIntegrity(state.events);
});

// --- `at` stamped inside the lock: ISO, never the build-time placeholder, never going backwards ---
const ISO = /^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$/;
const PLACEHOLDER = "1970-01-01T00:00:00.000Z"; // write.js AT_PLACEHOLDER, by inspection
const FUTURE = "2099-01-01T00:00:00.000Z";
function expectStamped(e, label) {
  if (!e || typeof e.at !== "string" || !ISO.test(e.at) || e.at === PLACEHOLDER) throw new Error(`${label}: at=${show(e && e.at)}`);
}
// stampedNow(sid, inp) — appends and returns the new record, checking its `at` lies inside the call's wall-clock window.
function stampedNow(sid, inp) {
  const t0 = new Date().toISOString();
  written(append(sid, inp));
  const t1 = new Date().toISOString();
  const rec = X.records(sid).pop();
  expectStamped(rec, "new record");
  if (rec.at < t0 || rec.at > t1) throw new Error(`at ${rec.at} outside [${t0}, ${t1}]`);
  return rec;
}
check("AT-1: after the 8 parallel writers, every `at` is ISO, not the placeholder, and non-decreasing in seq order", () => {
  const recs = X.records("w-fanout").sort((a, b) => a.seq - b.seq);
  eq(recs.length, 40, "stored records");
  recs.forEach((e, i) => {
    expectStamped(e, `seq ${e.seq}`);
    if (i > 0 && e.at < recs[i - 1].at) throw new Error(`seq ${e.seq} at ${e.at} < seq ${recs[i - 1].seq} at ${recs[i - 1].at}`);
  });
});
check("AT-2: clock rollback — an own record stamped in 2099 keeps the next record's `at` >= 2099", () => {
  const sid = active("w-at-rollback");
  F.pushEvents(sid, [F.record({ record_key: "future.own", summary: "from the future", at: FUTURE })]);
  written(append(sid, input({ key: "after.future" })));
  const rec = X.records(sid).pop();
  expectStamped(rec, "new record");
  eq([rec.record_key, rec.at >= FUTURE], ["after.future", true], "new record at >= 2099");
});
check("AT-3a: a 2099 `at` on an event at or before upstream_copy_seq is not used — the new `at` is now", () => {
  const sid = active("w-at-upstream");
  const last = F.pushEvents(sid, [F.record({ record_key: "future.upstream", summary: "copied", at: FUTURE })]);
  F.setTopLevel(sid, { upstream_session_id: "s2652-upstream", upstream_copy_seq: last });
  stampedNow(sid, input({ key: "after.upstream" }));
});
check("AT-3b: a non-ISO `at` (\"zzzz\") on an own record is ignored — the new `at` is now", () => {
  const sid = active("w-at-noniso");
  F.pushEvents(sid, [F.record({ record_key: "bad.at", summary: "bad at", at: "zzzz" })]);
  stampedNow(sid, input({ key: "after.bad" }));
});
check("AT-4: the overflow mark's `at` is stamped in the lock — ISO, not the placeholder, >= the latest own `at`", () => {
  const sid = active("w-at-overflow");
  F.pushEvents(sid, [F.record({ cls: "F", record_key: "future.seed", summary: "s", pointer: "-", origin: "auto-record", at: FUTURE })]);
  X.fillTo(sid, 65536 - 200);
  const r = append(sid, input({ key: "ov.at", summary: "x".repeat(250) }));
  eq([r && r.written, r && r.reason], [false, "overflow"], "result");
  const over = X.records(sid).filter((e) => e.record_key === "state-handoff:overflow");
  eq(over.length, 1, "overflow records");
  expectStamped(over[0], "overflow mark");
  if (over[0].at < FUTURE) throw new Error(`overflow at ${over[0].at} < latest own at ${FUTURE}`);
});
check("a lock held past the 3000ms default -> lock-timeout and one `record dropped` stderr line", () => {
  const sid = active("w-locked");
  const lock = F.statePath(sid) + ".lock";
  fs.writeFileSync(lock, JSON.stringify({ pid: process.pid, host: os.hostname(), at: new Date().toISOString() }));
  const before = X.bytesOf(sid);
  let c;
  try { c = X.runChild(["append", sid, JSON.stringify(input())]); } finally { fs.rmSync(lock, { force: true }); }
  if (!c.out) throw new Error(`child printed nothing (${c.status}): ${c.raw}`);
  if (c.out.threw) throw new Error(`entry threw: ${c.out.threw}`);
  eq([c.out.result.written, c.out.result.reason], [false, "lock-timeout"], "result");
  if (c.elapsed < 2900) throw new Error(`gave up after ${c.elapsed}ms, before the 3000ms default`);
  const lines = c.stderr.split(/\r?\n/).filter((l) => l.startsWith("[state-handoff]"));
  eq(lines, ["[state-handoff] record dropped: lock-timeout cls=C key=gate:block"], "stderr lines");
  if (String(before) !== String(X.bytesOf(sid))) throw new Error("the state file changed");
});
