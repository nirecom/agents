"use strict";
// --from view cases of feature-2576-from-handoff.js: the state handoff record, the legacy
// handoff.md, their time order, the empty session, and the single reader call.

const path = require("path");
const fs = require("fs");
const { ROOT, mod, fx, STATE_DIR, PLANS_DIR, check, show, eq, fromView, seedActive, seedHeir } = require("./common");

function rendersStateRecord() {
  const up = "f2576-t23d-donor";
  const heir = "f2576-t23d-heir";
  const marker = "F2576-T23D-RECORD-MARKER";
  seedActive(up);
  seedHeir(heir);
  fx.pushEvents(up, [fx.record({ cls: "A", at_step: "-", record_key: "t23d", summary: marker, origin: "procedure-point", provenance: "declared" })]);
  let d = null;
  check("T23d: --from exits 0 and answers on one JSON record", () => {
    const r = fromView(up, heir);
    d = r.d;
    eq(r.run.status, 0, "--from exit (stderr " + show(r.run.stderr) + ")");
  });
  check("T23d: handoff_rendered carries the state handoff record's summary", () => {
    if (!d) return "no record";
    eq(typeof d.handoff_rendered === "string" && d.handoff_rendered.indexOf(marker) !== -1, true, "marker in " + show(d.handoff_rendered));
  });
  check("T23d: artifacts has no handoff kind", () => {
    if (!d) return "no record";
    eq(Object.prototype.hasOwnProperty.call(d.artifacts || {}, "handoff"), false, "artifacts.handoff present (" + show(d.artifacts) + ")");
  });
}

function legacyOnlyIsArtifactsOnly() {
  const up = "f2576-t23f-donor";
  const marker = "F2576-T23F-LEGACY-MARKER";
  // No state file and no plan artifact: the legacy handoff.md is all the session-upstream left.
  fx.writeLegacyHandoff(up, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "t23f", summary: marker }]);
  check("T23f: fixture anchor — only the control-dir handoff.md exists", () => {
    eq(fs.existsSync(fx.legacyHandoffPath(up)), true, "control-dir handoff exists");
    eq(fs.existsSync(path.join(STATE_DIR, `${up}.json`)), false, "state file exists");
    eq(fs.existsSync(path.join(PLANS_DIR, `${up}-intent.md`)), false, "intent exists");
  });
  check("T23f: a legacy-handoff-only session is artifacts-only with state_expired, and its entry is rendered", () => {
    const { run, d } = fromView(up);
    eq(run.status, 0, "--from exit");
    eq(d.availability, "artifacts-only", "availability");
    eq(d.inherit_result && d.inherit_result.reason, "state_expired", "inherit_result.reason");
    eq(typeof d.handoff_rendered === "string" && d.handoff_rendered.indexOf(marker) !== -1, true, "marker in " + show(d.handoff_rendered));
  });
}

function stateAndLegacyInTimeOrder() {
  const up = "f2576-both-donor";
  seedActive(up);
  fx.writeLegacyHandoff(up, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "old-legacy", summary: "F2576-BOTH-LEGACY-FIRST" }]);
  fx.pushEvents(up, [fx.record({ at: fx.isoAt(2), cls: "A", at_step: "-", record_key: "new-state", summary: "F2576-BOTH-STATE-SECOND" })]);
  check("B1: both the legacy entry and the state record are rendered, older first", () => {
    const { d } = fromView(up);
    const text = String(d.handoff_rendered);
    const a = text.indexOf("F2576-BOTH-LEGACY-FIRST");
    const b = text.indexOf("F2576-BOTH-STATE-SECOND");
    eq([a !== -1, b !== -1, a < b], [true, true, true], "legacy then state in " + show(text));
  });
}

function nothingIsNone() {
  check("N1: a session with no state, no plan artifact and no handoff is none with no rendered handoff", () => {
    const v = mod("bin/lib/resume-session/upstream-view").buildUpstreamView({ heirSid: null, upstreamSid: "f2576-nothing-at-all" });
    eq(v.availability, "none", "availability");
    eq(v.handoff_rendered, null, "handoff_rendered");
  });
}

function readsTheReaderOnce() {
  const up = "f2576-once-donor";
  seedActive(up);
  fx.pushEvents(up, [fx.record({ cls: "A", at_step: "-", record_key: "once", summary: "F2576-ONCE" })]);
  check("O1: one buildUpstreamView calls readStateHandoff exactly once, for the session upstream", () => {
    const barrelPath = require.resolve(path.join(ROOT, "hooks", "lib", "state-handoff-record"));
    const barrel = require(barrelPath);
    const real = barrel.readStateHandoff;
    const calls = [];
    barrel.readStateHandoff = (sid) => {
      calls.push(sid);
      return real(sid);
    };
    const viewPath = require.resolve(path.join(ROOT, "bin", "lib", "resume-session", "upstream-view"));
    delete require.cache[viewPath];
    try {
      require(viewPath).buildUpstreamView({ heirSid: null, upstreamSid: up });
    } finally {
      barrel.readStateHandoff = real;
      delete require.cache[viewPath];
    }
    eq(calls, [up], "readStateHandoff calls");
  });
}

module.exports = { rendersStateRecord, legacyOnlyIsArtifactsOnly, stateAndLegacyInTimeOrder, nothingIsNone, readsTheReaderOnce };
