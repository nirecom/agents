"use strict";
// T1-T5: pickContinuationStage with an injected probe and timeoutMsFor. The probe is called only
// when exactly one stage passes the spawn-free pre-checks, with timeoutMsFor()'s value, and never
// once the remaining time drops under MIN_PROBE_MS. Prints PASS|name / FAIL|name|detail lines.
const X = require("./fixture");

const { A, T, U, show, check } = X;
const CC = X.tryRequire("hooks/lib/confirm-continuation.js");
if (CC.__missing || typeof CC.pickContinuationStage !== "function") {
  check("hooks/lib/confirm-continuation.js exports pickContinuationStage and MIN_PROBE_MS", false, "not implemented: " + (CC.__missing || "no export"));
  process.exit(0);
}
check("MIN_PROBE_MS is a positive number below the 1500 ms probe default",
  typeof CC.MIN_PROBE_MS === "number" && CC.MIN_PROBE_MS > 0 && CC.MIN_PROBE_MS < 1500, show(CC.MIN_PROBE_MS));

// scene(stages) -> a session with no stage approved and a plan for each named stage; the last
// text shows every named stage's plan-link line.
function scene(stages) {
  const sid = X.uuidSid(1);
  X.F.writeState(sid, { workflow_init: "complete", clarify_intent: "pending" }, []);
  const lines = stages.map((st) => { X.F.writePlan(sid, st); return X.linesFor(sid, st); });
  const lastText = "Here are the plans.\n\n" + lines.map((l) => l.line).join("\n");
  const entries = [U("write the plans", "u-prompt"), A("a-anchor", T(lastText))];
  return { sid, lines, lastText, entries };
}

// run(sc, verdict, ms) -> {got, calls}: calls records every probe invocation's (stage, timeoutMs).
function run(sc, verdict, ms) {
  const calls = [];
  let got;
  try {
    got = CC.pickContinuationStage({
      sid: sc.sid, lastText: sc.lastText, plansDir: X.F.PLANS_DIR, markers: [], entries: sc.entries,
      probe: (stage, opts) => { calls.push({ stage, timeoutMs: opts && opts.timeoutMs }); return verdict; },
      timeoutMsFor: () => ms,
    });
  } catch (e) { got = { threw: e.message }; }
  return { got, calls };
}

{
  const r = run(scene(["intent", "outline", "detail"]), "ON", 1200);
  check("T1 three candidates — returns null", r.got === null, show(r.got));
  check("T1 three candidates — the probe is never called", r.calls.length === 0, show(r.calls));
}
{
  const r = run(scene(["intent", "outline"]), "ON", 1200);
  check("T2 two candidates — returns null", r.got === null, show(r.got));
  check("T2 two candidates — the probe is never called", r.calls.length === 0, show(r.calls));
}
{
  const sc = scene(["intent"]);
  const r = run(sc, "ON", 1234);
  check("T3 one candidate — the probe is called exactly once, for that stage", r.calls.length === 1 && r.calls[0].stage === "intent", show(r.calls));
  check("T3 one candidate — the probe gets timeoutMsFor()'s value", r.calls.length === 1 && r.calls[0].timeoutMs === 1234, show(r.calls));
  const g = r.got || {};
  check("T3 one candidate, gate ON — returns {stage, absPath, link, sha} bound to the plan",
    g.stage === "intent" && typeof g.absPath === "string" && g.link && typeof g.link === "object" &&
    g.sha === X.F.implSha(sc.sid, "clarify_intent") && !!g.sha, show(g));
}
{
  const r = run(scene(["intent"]), "ON", (typeof CC.MIN_PROBE_MS === "number" ? CC.MIN_PROBE_MS : 1) - 1);
  check("T4 remaining time under MIN_PROBE_MS — returns null", r.got === null, show(r.got));
  check("T4 remaining time under MIN_PROBE_MS — the probe is never called", r.calls.length === 0, show(r.calls));
}
{
  const min = typeof CC.MIN_PROBE_MS === "number" ? CC.MIN_PROBE_MS : 1;
  const r = run(scene(["intent"]), "ON", min);
  check("T4b remaining time exactly MIN_PROBE_MS — the probe is called once with that timeout",
    r.calls.length === 1 && r.calls[0].stage === "intent" && r.calls[0].timeoutMs === min, show(r.calls));
  check("T4b remaining time exactly MIN_PROBE_MS, gate ON — continues on the intent stage", !!r.got && r.got.stage === "intent", show(r.got));
}
{
  const r = run(scene(["intent"]), "ERROR", 1200);
  check("T5 probe times out (ERROR) — returns null after one call", r.got === null && r.calls.length === 1, show([r.got, r.calls]));
  const off = run(scene(["intent"]), "OFF", 1200);
  check("T5 control — an OFF verdict also returns null (only ON continues)", off.got === null && off.calls.length === 1, show([off.got, off.calls]));
}
