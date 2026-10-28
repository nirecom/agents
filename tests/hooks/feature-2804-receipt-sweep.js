#!/usr/bin/env node
// tests/hooks/feature-2804-receipt-sweep.js
// Tests: hooks/lib/presentation-receipt.js, hooks/confirm-checkpoint.js
// Tags: TL2, hooks, confirm-plan, presentation-receipt, zombie-cleanup, confirm-checkpoint, scope:issue-specific, pwsh-not-required
// #2804 Steps 3, 5, 6: a receipt Stop wrote survives another session's SessionStart sweep
// (cleanupZombies(7)) and the echo then reaches the dialog; writeReceipt / consumeReceipt append
// write / consume lines to <sid>.control/presentation-receipt-log.jsonl without changing their
// results; a no-receipt deny finding names the receipt path, its absence and the log's verdict.
// TL3 gap: a real SessionStart of a second Claude Code session between the Stop and the echo; here
// the sweep is called in-process. Mitigation: bin/check-verification-gate.sh category hook-registration.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("fs");
const os = require("os");
const path = require("path");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2804r-"));
fs.mkdirSync(path.join(SCRATCH, "no-transcripts"));
process.env.CLAUDE_TRANSCRIPT_BASE_DIR = path.join(SCRATCH, "no-transcripts");
process.env.PLAN_SYNC_REMOTE_URL = "";
// The developer's CONV_LANG would prefix every block reason and hide the "[confirm-plan] continue:" start.
process.env.CONV_LANG = "english";
process.chdir(SCRATCH);
process.on("exit", () => {
  process.chdir(os.tmpdir());
  restore();
  fs.rmSync(SCRATCH, { recursive: true, force: true });
});

const R = require("./feature-2729-presentation-receipt/fixture");
const ZC = require("../../hooks/workflow-state/state-io/zombie-cleanup");
const PR = require("../../hooks/lib/presentation-receipt");
const { A, T, W, TR, BASH, U, show } = R;

// check(name, ok, detail) — one node:test test over a verdict computed now (the cases run hooks in
// order against one state root, so nothing is evaluated lazily inside the test body).
function check(name, ok, detail) {
  const why = (typeof detail === "string" ? detail : show(detail)).replace(/[\r\n]+/g, " ").slice(0, 400);
  test(name, () => { if (!ok) assert.fail(why); });
}

const norm = (p) => String(p).replace(/\\/g, "/").toLowerCase();
const statePath = (sid) => path.join(R.stateDirOf(sid), `${sid}.json`);
const logPath = (sid) => path.join(R.stateDirOf(sid), `${sid}.control`, "presentation-receipt-log.jsonl");
// logLines(sid) -> the parsed presentation receipt log lines ([] when the log is absent).
function logLines(sid) {
  let raw = "";
  try { raw = fs.readFileSync(logPath(sid), "utf8"); } catch (_) { return []; }
  return raw.split("\n").filter(Boolean).map((l) => { try { return JSON.parse(l); } catch (_) { return { unparsed: l }; } });
}
const lastWriteAt = (sid, stage) => {
  const w = logLines(sid).filter((l) => l.event === "write" && l.stage === stage);
  return w.length ? w[w.length - 1].at : null;
};
const lastFinding = (sid) => { const f = R.findings(sid); return f.length ? f[f.length - 1] : null; };
const detailOf = (f) => (f && typeof f.detail === "string" ? f.detail : "");
const ABSENT_RE = /absent|missing|not exist|exists[=:] ?false/i;
const present = (s, stage, text) => R.stop(s.sid, R.presentTurn(s, [stage], (text || "Here is the plan.\n\n") + s.urlLine));
const sweep = () => { try { ZC.cleanupZombies(7); return null; } catch (e) { return String(e && e.message); } };

caseBegin("sweep-keeps-written-receipt", "hooks/confirm-checkpoint.js");
{
  // R1b order: denied echo (no receipt) -> re-presentation -> Stop continue -> sweep -> echo.
  const b = R.sessionAt("outline", { tag: 2804 });
  const ag = { type: "tool_use", id: "ag1", name: "Agent", input: { description: "survey", prompt: "survey" } };
  const turn1 = [U("continue the outline", "u-prompt1"), A("a-agent", ag), TR("ag1", "u-ag1"), A("a-echo1", BASH(R.echoOf("outline"), "eb1"))];
  const e1 = R.echo(b.sid, "outline", { transcriptPath: R.writeTranscript(b.sid, turn1) });
  check("scenario: the echo before any presentation is denied", e1.denied && !e1.dialog, show(e1.json));
  const before = turn1.concat([
    { type: "user", message: { role: "user", content: [{ type: "tool_result", tool_use_id: "eb1", content: e1.reason || "denied", is_error: true }] }, uuid: "u-eb1" },
    { type: "user", origin: { kind: "task-notification" }, message: { role: "user", content: "<task-notification>agent done</task-notification>" }, uuid: "u-notif" },
  ]);
  const tp = R.presentTurn(b, ["outline"], "Here is the outline again.\n\n" + b.urlLine, { before, anchorUuid: "a-anchor" });
  const st = R.stop(b.sid, tp);
  check("scenario: Stop continues for the CONFIRM echo", st.continued, show({ rc: st.rc, out: st.out }));
  check("scenario: Stop writes the outline receipt", R.receiptExists(b.sid, "outline"), "no receipt");
  const threw = sweep();
  check("scenario: the sweep does not throw", threw === null, threw);
  check("scenario: the owner state survives the sweep", fs.existsSync(statePath(b.sid)), "state removed");
  check("scenario: the receipt survives another session's sweep", R.receiptExists(b.sid, "outline"), "receipt removed by cleanupZombies(7)");
  const e2 = R.echo(b.sid, "outline", { transcriptPath: tp });
  check("scenario: the echo after the sweep reaches the dialog", e2.dialog, show({ rc: e2.rc, json: e2.json }));
}
caseEnd();

caseBegin("session-downstream-receipt-key", "hooks/confirm-checkpoint.js");
{
  const firstSid = R.uuidSid(2807);
  const downSid = R.uuidSid(2808);
  R.F.writePlan(firstSid, "intent");
  R.F.writePlan(firstSid, "outline");
  const steps = { workflow_init: "complete", clarify_intent: "complete", research: "complete", outline: "pending" };
  const top = { first_session_id: firstSid, upstream_session_id: firstSid };
  // Written twice: the approval sha is computed from the state on disk, which must already name first_session_id.
  R.F.writeState(downSid, steps, [], top);
  R.F.writeState(downSid, steps, [{ step: "clarify_intent" }], top);
  const L = R.linesFor(firstSid, "outline");
  R.turnMarker(downSid, "outline", L.plan);
  const tp = R.writeTranscript(downSid, [U("write the plan", "u-d1"), A("a-dw", W(L.plan, "dw1")), TR("dw1", "u-dtr"), A("a-danchor", T("Here is the outline.\n\n" + L.urlLine))]);
  const st = R.stop(downSid, tp);
  check("downstream: Stop continues for the CONFIRM echo", st.continued, show({ rc: st.rc, out: st.out }));
  check("downstream: the receipt is keyed by the runtime sid (<downSid>.confirm-plan-receipt-outline.json)", R.receiptExists(downSid, "outline") && !R.receiptExists(firstSid, "outline"),
    show({ down: R.receiptExists(downSid, "outline"), first: R.receiptExists(firstSid, "outline") }));
  check("downstream: <downSid>.json exists", fs.existsSync(statePath(downSid)), "no state");
  sweep();
  check("downstream: the receipt survives the sweep", R.receiptExists(downSid, "outline"), "receipt removed by cleanupZombies(7)");
  const e = R.echo(downSid, "outline", { transcriptPath: tp });
  check("downstream: the echo after the sweep reaches the dialog", e.dialog, show({ rc: e.rc, json: e.json }));
}
caseEnd();

caseBegin("d1-no-write-record", "hooks/confirm-checkpoint.js");
{
  const s = R.sessionAt("outline", { tag: 2811 });
  const e = R.echo(s.sid, "outline");
  const f = lastFinding(s.sid);
  const d = detailOf(f);
  check("D1: the first echo with no presentation is denied (no-receipt)", e.denied && d.includes("(no-receipt)"), show({ json: e.json, d }));
  check("D1: the finding detail names the expected receipt path", norm(d).includes(norm(R.receiptPath(s.sid, "outline"))), d);
  check("D1: the finding detail says the receipt does not exist", ABSENT_RE.test(d), d);
  check("D1: the finding detail says no write record", /no write record/i.test(d), d);
  check("D1: categories, severity and reporter are unchanged",
    f && show(f.categories) === show(["workflow"]) && f.severity === "notice" && f.reporter === "confirm-checkpoint", f);
}
caseEnd();

caseBegin("d2-written-then-removed", "hooks/confirm-checkpoint.js");
{
  const s = R.sessionAt("outline", { tag: 2812 });
  const st = present(s, "outline");
  check("D2 setup: Stop continues and writes the receipt", st.continued && R.receiptExists(s.sid, "outline"), show({ rc: st.rc, out: st.out }));
  try { fs.unlinkSync(R.receiptPath(s.sid, "outline")); } catch (_) { /* checked by the setup case */ }
  const e = R.echo(s.sid, "outline");
  const d = detailOf(lastFinding(s.sid));
  const at = lastWriteAt(s.sid, "outline");
  check("D2: the echo is denied (no-receipt)", e.denied && d.includes("(no-receipt)"), show({ json: e.json, d }));
  check("D2: the log holds the write record of the Stop", typeof at === "string" && !Number.isNaN(Date.parse(at)), show(logLines(s.sid)));
  check("D2: the finding detail says the receipt does not exist", ABSENT_RE.test(d), d);
  check("D2: the finding detail carries the last write at", at !== null && d.includes(at), { at, d });
  check("D2: the finding detail carries the elapsed time", /elapsed|ago|\d+\s*m?s\b/i.test(d.replace(at || "\u0000", "")), d);
  check("D2: the finding detail says no consume record follows", /no consume/i.test(d), d);
}
caseEnd();

caseBegin("d3-consumed-then-echoed-again", "hooks/confirm-checkpoint.js");
{
  const s = R.sessionAt("outline", { tag: 2813 });
  present(s, "outline");
  const e1 = R.echo(s.sid, "outline");
  check("D3 setup: the first echo reaches the dialog and spends the receipt", e1.dialog && !R.receiptExists(s.sid, "outline"), show(e1.json));
  const e2 = R.echo(s.sid, "outline");
  const d = detailOf(lastFinding(s.sid));
  const at = lastWriteAt(s.sid, "outline");
  check("D3: the second echo is denied (no-receipt)", e2.denied && d.includes("(no-receipt)"), show({ json: e2.json, d }));
  check("D3: the finding detail carries the last write at", at !== null && d.includes(at), { at, d });
  check("D3: the finding detail says a consume record follows the write", /consume/i.test(d) && !/no consume/i.test(d), d);
}
caseEnd();

caseBegin("d4-represented-then-removed", "hooks/confirm-checkpoint.js");
{
  // write -> consume -> re-presentation write -> the receipt vanishes: the diagnostic follows the latest write.
  const s = R.sessionAt("outline", { tag: 2818 });
  present(s, "outline");
  const e1 = R.echo(s.sid, "outline");
  check("D4 setup: the first echo reaches the dialog and spends the receipt", e1.dialog && !R.receiptExists(s.sid, "outline"), show(e1.json));
  const at1 = lastWriteAt(s.sid, "outline");
  const st = present(s, "outline", "Here is the outline again.\n\n");
  check("D4 setup: the re-presentation writes a fresh receipt", st.continued && R.receiptExists(s.sid, "outline"), show({ rc: st.rc, out: st.out }));
  const lines = logLines(s.sid).filter((l) => l.stage === "outline").map((l) => l.event);
  check("D4 setup: the log reads write, consume, write", show(lines) === show(["write", "consume", "write"]), lines);
  const at2 = lastWriteAt(s.sid, "outline");
  check("D4 setup: the two write records carry distinct times", typeof at1 === "string" && typeof at2 === "string" && at1 !== at2, { at1, at2 });
  try { fs.unlinkSync(R.receiptPath(s.sid, "outline")); } catch (_) { /* checked by the setup case */ }
  const e2 = R.echo(s.sid, "outline");
  const d = detailOf(lastFinding(s.sid));
  check("D4: the echo is denied (no-receipt)", e2.denied && d.includes("(no-receipt)"), show({ json: e2.json, d }));
  check("D4: the finding detail says the receipt does not exist", ABSENT_RE.test(d), d);
  check("D4: the finding detail carries the latest write at", at2 !== null && d.includes(at2), { at2, d });
  check("D4: the finding detail does not carry the earlier write at", at1 !== null && !d.includes(at1), { at1, d });
  check("D4: the finding detail says no consume record follows the latest write", /no consume record follows/i.test(d), d);
}
caseEnd();

caseBegin("deny-other-cause-no-diagnostic", "hooks/confirm-checkpoint.js");
{
  const s = R.sessionAt("outline", { tag: 2814 });
  present(s, "outline");
  fs.writeFileSync(s.plan, fs.readFileSync(s.plan, "utf8") + "\nedited after the presentation\n");
  const e = R.echo(s.sid, "outline");
  const f = lastFinding(s.sid);
  const d = detailOf(f);
  check("content deny: the echo is denied (content)", e.denied && d.includes("(content)"), show({ json: e.json, d }));
  check("content deny: the finding detail carries no receipt diagnostic", !/no write record|consume/i.test(d) && !norm(d).includes(norm(R.receiptPath(s.sid, "outline"))), d);
  check("content deny: categories, severity and reporter are unchanged",
    f && show(f.categories) === show(["workflow"]) && f.severity === "notice" && f.reporter === "confirm-checkpoint", f);
}
caseEnd();

caseBegin("d5-corrupt-log-line", "hooks/confirm-checkpoint.js");
{
  // readReceiptLog drops a non-JSON line and keeps the valid ones, so the diagnostic still follows the write.
  const s = R.sessionAt("outline", { tag: 2819 });
  const st = present(s, "outline");
  check("D5 setup: Stop continues and writes the receipt", st.continued && R.receiptExists(s.sid, "outline"), show({ rc: st.rc, out: st.out }));
  const at = lastWriteAt(s.sid, "outline");
  const valid = fs.existsSync(logPath(s.sid)) ? fs.readFileSync(logPath(s.sid), "utf8") : "";
  fs.writeFileSync(logPath(s.sid), "{ not json\n" + valid + "garbage {\n");
  try { fs.unlinkSync(R.receiptPath(s.sid, "outline")); } catch (_) { /* checked by the setup case */ }
  const e = R.echo(s.sid, "outline");
  const d = detailOf(lastFinding(s.sid));
  check("D5: the echo is denied (no-receipt) despite a corrupt log line", e.denied && !e.dialog && d.includes("(no-receipt)"), show({ json: e.json, d }));
  check("D5: the deny finding names the receipt path and its absence", norm(d).includes(norm(R.receiptPath(s.sid, "outline"))) && ABSENT_RE.test(d), d);
  check("D5: the finding detail carries the valid write at", typeof at === "string" && d.includes(at), { at, d });
  check("D5: the finding detail says no consume record follows", /no consume record follows/i.test(d), d);
}
caseEnd();

caseBegin("d6-unreadable-log", "hooks/confirm-checkpoint.js");
{
  // An unreadable log (its path is a directory) reads as [], so the diagnostic says "no write record".
  const s = R.sessionAt("outline", { tag: 2820 });
  const st = present(s, "outline");
  check("D6 setup: Stop continues and writes the receipt", st.continued && R.receiptExists(s.sid, "outline"), show({ rc: st.rc, out: st.out }));
  fs.rmSync(logPath(s.sid), { force: true });
  fs.mkdirSync(logPath(s.sid), { recursive: true });
  try { fs.unlinkSync(R.receiptPath(s.sid, "outline")); } catch (_) { /* checked by the setup case */ }
  const e = R.echo(s.sid, "outline");
  const f = lastFinding(s.sid);
  const d = detailOf(f);
  check("D6: the echo is denied (no-receipt) when the log is a directory", e.denied && !e.dialog && d.includes("(no-receipt)"), show({ json: e.json, d }));
  check("D6: the deny finding names the receipt path and its absence", norm(d).includes(norm(R.receiptPath(s.sid, "outline"))) && ABSENT_RE.test(d), d);
  check("D6: the finding detail says no write record", /no write record/i.test(d), d);
  check("D6: categories, severity and reporter are unchanged",
    f && show(f.categories) === show(["workflow"]) && f.severity === "notice" && f.reporter === "confirm-checkpoint", f);
}
caseEnd();

const PLAN = path.join(SCRATCH, "unit-plan.md");
fs.writeFileSync(PLAN, "# Outline\n");
const FIELDS = { absPath: PLAN, link: { kind: "url", value: "https://example.invalid/test-owner/test-repo/blob/main/unit-plan.md" }, contentSha: "a".repeat(64), anchorUuid: "x" };

caseBegin("receipt-log-lines", "hooks/lib/presentation-receipt.js");
{
  const sid = R.uuidSid(2815);
  const w = PR.writeReceipt(sid, "outline", FIELDS);
  const l1 = logLines(sid);
  const wl = l1[0] || {};
  check("log: writeReceipt returns true", w === true, w);
  check("log: a successful write appends one {event:write, stage, path, at} line",
    l1.length === 1 && wl.event === "write" && wl.stage === "outline" && PR.samePath(wl.path, PR.receiptPath(sid, "outline")) && !Number.isNaN(Date.parse(wl.at)), l1);
  const c = PR.consumeReceipt(sid, "outline");
  const l2 = logLines(sid);
  const cl = l2[1] || {};
  check("log: consumeReceipt returns true", c === true, c);
  check("log: a successful consume appends one {event:consume, stage, path, at} line",
    l2.length === 2 && cl.event === "consume" && cl.stage === "outline" && PR.samePath(cl.path, PR.receiptPath(sid, "outline")) && !Number.isNaN(Date.parse(cl.at)), l2);
  const c2 = PR.consumeReceipt(sid, "outline");
  check("log: a consume of an absent receipt returns false and appends nothing", c2 === false && logLines(sid).length === 2, { c2, lines: logLines(sid) });
  PR.writeReceipt(sid, "detail", FIELDS);
  PR.discardReceipt(sid, "detail");
  const l3 = logLines(sid);
  check("log: discardReceipt appends nothing (only the detail write is added)",
    l3.length === 3 && l3[2].event === "write" && l3[2].stage === "detail" && !R.receiptExists(sid, "detail"), l3);
  const bad = PR.writeReceipt(sid, "nonsense", FIELDS);
  check("log: an invalid writeReceipt returns false and appends nothing", bad === false && logLines(sid).length === 3, { bad, lines: logLines(sid) });
}
caseEnd();

caseBegin("receipt-log-write-failure", "hooks/lib/presentation-receipt.js");
{
  const sid = R.uuidSid(2816);
  fs.mkdirSync(R.stateDirOf(sid), { recursive: true });
  fs.writeFileSync(path.join(R.stateDirOf(sid), `${sid}.control`), "a regular file, not a control dir");
  let w = null; let c1 = null; let c2 = null; let threw = null;
  try { w = PR.writeReceipt(sid, "outline", FIELDS); c1 = PR.consumeReceipt(sid, "outline"); c2 = PR.consumeReceipt(sid, "outline"); } catch (e) { threw = e.message; }
  check("log failure (<sid>.control is a file): no throw, write true, consume true, then false", threw === null && w === true && c1 === true && c2 === false, { threw, w, c1, c2 });
  const sid2 = R.uuidSid(2817);
  const orig = fs.appendFileSync;
  fs.appendFileSync = function (p, ...rest) {
    if (String(p).includes("presentation-receipt-log")) throw Object.assign(new Error("injected EIO"), { code: "EIO" });
    return orig.call(fs, p, ...rest);
  };
  let w2 = null; let d1 = null; let d2 = null; let threw2 = null;
  try { w2 = PR.writeReceipt(sid2, "outline", FIELDS); d1 = PR.consumeReceipt(sid2, "outline"); d2 = PR.consumeReceipt(sid2, "outline"); } catch (e) { threw2 = e.message; } finally { fs.appendFileSync = orig; }
  check("log failure (appendFileSync throws): no throw, write true, consume true, then false", threw2 === null && w2 === true && d1 === true && d2 === false, { threw2, w2, d1, d2 });
}
caseEnd();
