"use strict";
// Reader-error cases of feature-2576-from-handoff.js: the --from view must tell a state handoff
// reader failure apart from "no records", as --list does.

const path = require("path");
const fs = require("fs");
const { ROOT, mod, fx, STATE_DIR, check, show, eq, fromView, seedActive } = require("./common");

const viewOf = (sid) => mod("bin/lib/resume-session/upstream-view").buildUpstreamView({ heirSid: null, upstreamSid: sid });
const controlDirOf = (sid) => path.dirname(fx.legacyHandoffPath(sid));
const corruptState = (sid) => fs.writeFileSync(path.join(STATE_DIR, `${sid}.json`), "{ not json", "utf8");
const hasMarker = (v, m) => eq(typeof v.handoff_rendered === "string" && v.handoff_rendered.indexOf(m) !== -1, true, "marker in " + show(v.handoff_rendered));
// A regular file at <sid>.control makes the legacy source unreadable (the reader's R24 fixture).
const blockControlDir = (sid) => { fs.rmSync(controlDirOf(sid), { recursive: true, force: true }); fs.writeFileSync(controlDirOf(sid), "not a directory", "utf8"); };
const quietView = (sid) => { const orig = process.stderr.write; process.stderr.write = () => true; try { return viewOf(sid); } finally { process.stderr.write = orig; } };

function corruptStateNamesState() {
  const up = "f2576-e1-corrupt-state";
  corruptState(up);
  check("E1: a corrupt-state-only session is none/state-unreadable naming \"state\" (view and CLI exit 3), unlike a session with no records", () => {
    const v = viewOf(up);
    eq(Array.isArray(v.state_handoff_errors) && v.state_handoff_errors.indexOf("state") !== -1, true, "state in " + show(v.state_handoff_errors));
    eq([v.availability, v.reason], ["none", "state-unreadable"], "view availability/reason");
    eq(viewOf("f2576-e1-no-record-at-all").state_handoff_errors, [], "no-record view state_handoff_errors");
    const cli = fromView(up);
    eq([cli.run.status, cli.d.availability, cli.d.reason, cli.d.state_handoff_errors], [3, "none", "state-unreadable", ["state"]], "CLI exit/availability/reason/state_handoff_errors");
  });
}

function readerExceptionIsReaderError() {
  const up = "f2576-e2-reader-throws";
  seedActive(up);
  fx.pushEvents(up, [fx.record({ cls: "A", at_step: "-", record_key: "e2", summary: "F2576-E2" })]);
  check("E2: a throwing readStateHandoff yields state_handoff_errors [\"reader\"] and the view is still returned", () => {
    const barrel = require(require.resolve(path.join(ROOT, "hooks", "lib", "state-handoff-record")));
    const real = barrel.readStateHandoff;
    barrel.readStateHandoff = () => { throw new Error("F2576-E2 forced reader failure"); };
    const viewPath = require.resolve(path.join(ROOT, "bin", "lib", "resume-session", "upstream-view"));
    delete require.cache[viewPath];
    let v;
    try { v = require(viewPath).buildUpstreamView({ heirSid: null, upstreamSid: up }); } finally { barrel.readStateHandoff = real; delete require.cache[viewPath]; }
    eq([!!v && v.type, v.state_handoff_errors, v.handoff_rendered], ["upstream", ["reader"], null], "type/state_handoff_errors/handoff_rendered");
  });
}

function errorAndNoErrorViews() {
  const e3 = "f2576-e3-legacy-unreadable";
  blockControlDir(e3);
  check("E3: an unresolvable control dir puts \"legacy-handoff-md\" in state_handoff_errors", () => {
    eq(fs.statSync(controlDirOf(e3)).isFile(), true, "fixture anchor: <sid>.control is a regular file");
    const v = quietView(e3);
    eq([v.state_handoff_errors, v.handoff_rendered], [["legacy-handoff-md"], null], "state_handoff_errors/handoff_rendered");
  });
  const e4 = "f2576-e4-zero-records";
  seedActive(e4);
  check("E4: a readable state file with zero records is state_handoff_errors [] and handoff_rendered null", () => {
    const v = viewOf(e4);
    eq([v.availability, v.state_handoff_errors, v.handoff_rendered], ["state-and-artifacts", [], null], "availability/state_handoff_errors/handoff_rendered");
  });
  const e5 = "f2576-e5-with-records";
  seedActive(e5);
  fx.pushEvents(e5, [fx.record({ cls: "A", at_step: "-", record_key: "e5", summary: "F2576-E5-MARK" })]);
  check("E5: a readable state file with records is state_handoff_errors [] and renders the entry", () => {
    const v = viewOf(e5);
    eq(v.state_handoff_errors, [], "state_handoff_errors");
    hasMarker(v, "F2576-E5-MARK");
  });
  check("E7: the NONE views (nothing stored, invalid sid) are unknown-session and carry state_handoff_errors []", () => {
    const a = viewOf("f2576-e7-nothing");
    const b = viewOf("../x");
    eq([a.availability, a.reason, a.state_handoff_errors, b.availability, b.state_handoff_errors], ["none", "unknown-session", [], "none", []], "availability/reason/state_handoff_errors");
  });
  const e6 = "f2576-e6-corrupt-state-legacy-ok";
  fx.writeLegacyHandoff(e6, [{ cls: "A", at: fx.isoAt(1), step: "-", key: "e6", summary: "F2576-E6-MARK" }]);
  corruptState(e6);
  check("E6: a corrupt state file with a readable legacy handoff renders the legacy entry, names \"state\", and is not none/state-unreadable", () => {
    const v = viewOf(e6);
    eq(v.state_handoff_errors, ["state"], "state_handoff_errors");
    eq([v.availability !== "none", v.reason !== "state-unreadable"], [true, true], "availability=" + show(v.availability) + " reason=" + show(v.reason));
    hasMarker(v, "F2576-E6-MARK");
  });
  const e6b = "f2576-e6b-state-ok-legacy-blocked";
  seedActive(e6b);
  fx.pushEvents(e6b, [fx.record({ cls: "A", at_step: "-", record_key: "e6b", summary: "F2576-E6B-MARK" })]);
  blockControlDir(e6b);
  check("E6b: readable state records still render while the legacy source names \"legacy-handoff-md\"", () => {
    const v = quietView(e6b);
    eq(v.state_handoff_errors, ["legacy-handoff-md"], "state_handoff_errors");
    hasMarker(v, "F2576-E6B-MARK");
  });
}

module.exports = { corruptStateNamesState, readerExceptionIsReaderError, errorAndNoErrorViews };
