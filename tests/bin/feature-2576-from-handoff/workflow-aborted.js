"use strict";
// #2920 S9 cases of feature-2576-from-handoff.js: buildUpstreamView carries the upstream's
// workflow_aborted projection (null when live) and render.js prints one "aborted" line for it; the
// mark never changes availability. The abort is pushed as a raw event (consumer tested alone).

const { mod, fx, check, show, eq, seedActive, seedHeir } = require("./common");
const { abortEvent } = require("../../hooks/feature-2920-workflow-abort/fixture");

const viewOf = (sid) => mod("bin/lib/resume-session/upstream-view").buildUpstreamView({ heirSid: null, upstreamSid: sid });
const render = (v) => mod("bin/lib/resume-session/render").renderUpstreamView(v);

function abortedMarker() {
  const live = "f2576-w1-live";
  const aborted = "f2576-w1-aborted";
  const adopted = "f2576-w1-adopted";
  seedActive(live);
  seedActive(aborted);
  seedActive(adopted);
  fx.pushEvents(aborted, [abortEvent("abort-sentinel", { reason: "F2576-W1 user stopped" })]);
  fx.pushEvents(adopted, [abortEvent("adopt-auto", { reason: "adopted by f2576-w1-heir", heir_session_id: "f2576-w1-heir" })]);
  check("W1: a live upstream's view has workflow_aborted null and no aborted line", () => {
    const v = viewOf(live);
    eq(Object.prototype.hasOwnProperty.call(v, "workflow_aborted") ? v.workflow_aborted : "(missing key)", null, "workflow_aborted");
    if (/abort/i.test(render(v))) throw new Error(`a live view renders an aborted line: ${show(render(v))}`);
  });
  check("W1: an aborted upstream's view carries origin/reason and keeps the live view's availability", () => {
    const v = viewOf(aborted);
    const w = v.workflow_aborted || {};
    eq([w.origin, w.reason], ["abort-sentinel", "F2576-W1 user stopped"], "workflow_aborted origin/reason " + show(v.workflow_aborted));
    eq(v.availability, viewOf(live).availability, "availability");
    const b = viewOf(adopted).workflow_aborted || {};
    eq([b.origin, b.heir_session_id], ["adopt-auto", "f2576-w1-heir"], "adopt-auto workflow_aborted " + show(viewOf(adopted).workflow_aborted));
  });
  check("W1: render.js prints one aborted line naming origin and reason", () => {
    const lines = render(viewOf(aborted)).split(/\r?\n/).filter((l) => /abort/i.test(l));
    eq(lines.length, 1, "aborted lines in " + show(render(viewOf(aborted))));
    if (!lines[0].includes("abort-sentinel") || !lines[0].includes("F2576-W1 user stopped")) throw new Error(`the line lacks origin/reason: ${show(lines[0])}`);
  });
}

// #2920: an upstream the adoption could not record as aborted is a Warning line after the adoption lines.
function abortWarnings() {
  const { upstreamAbortLines } = mod("bin/lib/resume-session/render");
  check("W2: upstreamAbortLines gives one Warning line per recorded:false entry", () => {
    const lines = upstreamAbortLines([
      { sid: "w2-ok", recorded: true },
      { sid: "w2-bad", recorded: false, reason: "EIO write failed" },
      { sid: "w2-bad2", recorded: false },
    ]);
    eq(lines.length, 2, "lines " + show(lines));
    if (!/^Warning: upstream w2-bad could not be recorded as aborted \(EIO write failed\)/.test(lines[0])) throw new Error(`line 0: ${show(lines[0])}`);
    if (!lines[1].includes("w2-bad2") || !lines[1].includes("(unknown)")) throw new Error(`line 1: ${show(lines[1])}`);
    if (lines.some((l) => l.includes("w2-ok"))) throw new Error("a recorded:true entry produced a line");
  });
  check("W2: upstreamAbortLines is empty for recorded:true, empty, and non-array input", () => {
    for (const v of [[{ sid: "a", recorded: true }], [], undefined, null, "x", {}]) eq(upstreamAbortLines(v), [], show(v));
  });
  const base = { upstream_session_id: "w2-up", availability: "state-and-artifacts", transcript_tail: { available: false, reason: "none" } };
  const inh = { attempted: true, ok: true, repo_verdict: "same", granularity: "full", inheritance: null };
  check("W2: renderUpstreamView prints the Warning after the adoption lines only when ok", () => {
    const ok = render({ ...base, inherit_result: { ...inh, upstream_aborts: [{ sid: "w2-up", recorded: false, reason: "EIO" }] } }).split(/\r?\n/);
    const i = ok.findIndex((l) => l.startsWith("Warning: upstream w2-up could not be recorded as aborted (EIO)"));
    const side = ok.findIndex((l) => l.startsWith("Each plan artifact is still named after upstream"));
    if (i < 0 || side < 0 || i < side) throw new Error(`warning at ${i}, adoption side line at ${side}: ${show(ok)}`);
    const quiet = render({ ...base, inherit_result: { ...inh, upstream_aborts: [{ sid: "w2-up", recorded: true }] } });
    if (/Warning/.test(quiet)) throw new Error(`recorded:true warned: ${show(quiet)}`);
    const refused = render({ ...base, inherit_result: { attempted: true, ok: false, error: "refused", upstream_aborts: [{ sid: "w2-up", recorded: false, reason: "EIO" }] } });
    if (/Warning/.test(refused)) throw new Error(`a refused adoption warned: ${show(refused)}`);
  });
  check("W2: the aborted header names the downstream, not the heir", () => {
    const h = render({ ...base, inherit_result: { attempted: false, reason: "x" }, workflow_aborted: { origin: "adopt-auto", heir_session_id: "w2-down", reason: "r" } }).split(/\r?\n/)[0];
    if (!h.includes("downstream w2-down") || /heir/.test(h)) throw new Error(`header: ${show(h)}`);
  });
  const up = "f2576-w2-up";
  const heir = "f2576-w2-heir";
  seedActive(up);
  seedHeir(heir);
  check("W2: a real --from adoption carries upstream_aborts (recorded:true) through attemptInherit", () => {
    const { d } = require("./common").fromView(up, heir);
    const r = d.inherit_result || {};
    eq(r.ok, true, "inherit_result.ok " + show(r));
    eq((r.upstream_aborts || []).map((a) => [a.sid, a.recorded]), [[up, true]], "upstream_aborts");
  });
}

module.exports = { abortedMarker, abortWarnings };
