"use strict";
// set-reason cases of tests/bin/feature-2941-pm-state-cli.js (#2941). No case markers.
// set-reason --text writes only the caller's last assignment_log entry, and only when it is an
// init / add / remove still carrying REASON_UNSTATED; never a forge call.
const assert = require("node:assert");
const { test } = require("node:test");
const { P } = require("./fixture");

const UNSTATED = "reason not stated";
const brief = (r) => `code=${r.code} out=${r.out} err=${r.err}`;
let n = 0;
// seed(log, extra) -> sid of a fresh PM (issues in the 9300s) whose assignment_log is log.
function seed(log, extra) {
  const sid = P.uuid(0x29416300 + ++n);
  P.seedPm(sid, P.pm(Object.assign({ tag: `PM-rs${n}`, issues: [9300 + n], assignment_log: log }, extra || {})));
  return sid;
}
const entry = (op, reason, at) => ({ at: at || "2026-11-01T00:00:00.000Z", op, issues: [{ number: 9300 }], reason });

function reason(F) {
  const setReason = (sid, txt, o = {}) => F.run(["set-reason", "--text", txt].concat(o.args || []), Object.assign({ caller: sid }, o));
  test("S1 the caller's last unstated entry takes the text; the others stay", () => {
    const log = [entry("init", "theme"), entry("add", UNSTATED, "2026-11-02T00:00:00.000Z")];
    const sid = seed(log);
    const r = setReason(sid, "PM and EM work closely together");
    assert.strictEqual(r.code, 0, brief(r));
    const got = P.readPm(sid).assignment_log;
    assert.deepStrictEqual(got[0], log[0]);
    assert.strictEqual(got[1].reason, "PM and EM work closely together");
    assert.strictEqual(r.calls.length, 0, JSON.stringify(r.calls));
  });
  test("S1 the last entry of a PM ended by /pm-remove can still be written", () => {
    const sid = seed([entry("init", "theme"), entry("remove", UNSTATED, "2026-11-02T00:00:00.000Z")], { issues: [], archived_at: "2026-11-02T00:00:00.000Z" });
    const r = setReason(sid, "done");
    assert.strictEqual(r.code, 0, brief(r));
    assert.strictEqual(P.readPm(sid).assignment_log[1].reason, "done");
  });
  // refused(label, sid, txt, o, code) — non-zero (exactly code when given) and the state is untouched.
  const refused = (label, mk, txt, o, code) => test(label, () => {
    const sid = mk();
    const before = JSON.stringify(P.raw(sid));
    const r = setReason(sid, txt, o || {});
    assert.ok(r.code !== 0 && r.code !== null && r.code !== 127, brief(r));
    if (code !== undefined) assert.strictEqual(r.code, code, brief(r));
    assert.strictEqual(JSON.stringify(P.raw(sid)), before, "state changed on a refused set-reason");
  });
  refused("S2 a last entry that already has a reason is refused", () => seed([entry("init", "theme")]), "x", {}, 1);
  refused("S2 a last inherit entry is refused", () => seed([entry("init", UNSTATED), entry("inherit", "sequence=none", "2026-11-02T00:00:00.000Z")]), "x", {}, 1);
  refused("S3 --session is not accepted (exit 2)", () => seed([entry("add", UNSTATED)]), "x", { args: ["--session", P.uuid(0x29416399)] }, 2);
  refused("S3 a whitespace-only text exits 2", () => seed([entry("add", UNSTATED)]), "   ", {}, 2);
  refused("S3 a session without a PM mark is refused", () => { const s = P.uuid(0x29416398); P.seedState(s); return s; }, "x");
  test("S3 no caller session id is refused and writes nothing", () => {
    const sid = seed([entry("add", UNSTATED)]);
    const before = JSON.stringify(P.raw(sid));
    const r = F.run(["set-reason", "--text", "x"]);
    assert.ok(r.code !== 0 && r.code !== null && r.code !== 127, brief(r));
    assert.strictEqual(JSON.stringify(P.raw(sid)), before);
  });
  test("S4 the refusal of a filled last entry says why", () => {
    const sid = seed([entry("init", "theme")]);
    const r = setReason(sid, "x");
    assert.ok(`${r.out}${r.err}`.includes("already has a reason"), brief(r));
  });
}

module.exports = { reason };
