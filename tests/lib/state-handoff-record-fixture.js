"use strict";
// Fixtures for the state handoff reader tests (#2652). Every writer here touches the files
// directly, never through the code under test, so a fixture stays valid whichever writer the
// implementation ends up with:
//   - a state file under WORKFLOW_STATE_DIR with workflow_init complete;
//   - state_handoff_record and reset events appended with the next seq;
//   - a pre-#2652 handoff.md in <WORKFLOW_STATE_DIR>/<sid>.control/ (the format the retired
//     writer produced: "## <cls>" sections of "- at | origin | step | key | summary | pointer").
// The caller pins WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR (harness isolate()) before use.

const fs = require("node:fs");
const path = require("node:path");

const REPO = path.join(__dirname, "..", "..");

function io() {
  return require(path.join(REPO, "hooks", "workflow-state", "state-io"));
}

function stateDir() {
  const dir = process.env.WORKFLOW_STATE_DIR;
  if (!dir) throw new Error("state-handoff-record-fixture: WORKFLOW_STATE_DIR is not pinned");
  return dir;
}

function statePath(sid) {
  return path.join(stateDir(), `${sid}.json`);
}

// makeState(sid, cwd) — a fresh state with workflow_init complete, written by state-io itself.
function makeState(sid, cwd) {
  const stateIo = io();
  stateIo.writeState(sid, stateIo.createInitialState(sid, { cwd: cwd || stateDir(), git_branch: "fixture" }));
  stateIo.markStep(sid, "workflow_init", "complete");
}

// pushEvents(sid, events) — appends raw events with the next seq; `at` defaults to now.
function pushEvents(sid, events) {
  const file = statePath(sid);
  const state = JSON.parse(fs.readFileSync(file, "utf8"));
  let seq = state.events.reduce((m, e) => Math.max(m, Number(e.seq) || 0), 0);
  for (const ev of events) {
    seq += 1;
    state.events.push(Object.assign({ at: new Date().toISOString() }, ev, { seq }));
  }
  fs.writeFileSync(file, JSON.stringify(state, null, 2), "utf8");
  return seq;
}

// setTopLevel(sid, fields) — e.g. { upstream_session_id, upstream_copy_seq }.
function setTopLevel(sid, fields) {
  const file = statePath(sid);
  const state = JSON.parse(fs.readFileSync(file, "utf8"));
  Object.assign(state, fields);
  fs.writeFileSync(file, JSON.stringify(state, null, 2), "utf8");
}

// record({...}) — one state_handoff_record event in the stored shape (seq is added on push).
function record(over) {
  return Object.assign(
    {
      kind: "state_handoff_record",
      cls: "C",
      at_step: "write_code",
      record_key: "gate:block",
      summary: "summary",
      pointer: "",
      origin: "gate-block",
      provenance: "observed",
    },
    over,
  );
}

function resetEvent(over) {
  return Object.assign({ kind: "reset", from_step: "write_tests", reason: "reset reason", provenance: "observed", origin: "reset-handler" }, over);
}

function esc(value) {
  return String(value === undefined || value === null ? "" : value)
    .replace(/\\/g, "\\\\")
    .replace(/\|/g, "\\|")
    .replace(/\n/g, "\\n")
    .replace(/\r/g, "\\r");
}

function legacyHandoffPath(sid) {
  return path.join(stateDir(), `${sid}.control`, "handoff.md");
}

// writeLegacyHandoff(sid, entries) — entries: [{cls, at, origin, step, key, summary, pointer}].
function writeLegacyHandoff(sid, entries) {
  const out = [`# Handoff — ${sid}`, "", "handoff_schema_version: 1", ""];
  for (const cls of ["A", "B", "C", "D", "E", "F", "G"]) {
    const own = entries.filter((e) => e.cls === cls);
    if (own.length === 0) continue;
    out.push(`## ${cls}`);
    for (const e of own) {
      out.push(`- ${e.at} | ${e.origin || "procedure-point"} | ${e.step || "-"} | ${e.key} | ${esc(e.summary)} | ${esc(e.pointer)}`);
    }
    out.push("");
  }
  const file = legacyHandoffPath(sid);
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, out.join("\n"), "utf8");
  return file;
}

// isoAt(n) — a fixed, ordered timestamp: minute n after 2026-01-01T00:00Z.
function isoAt(n) {
  return new Date(Date.UTC(2026, 0, 1, 0, 0, 0) + n * 60000).toISOString();
}

module.exports = { REPO, makeState, pushEvents, setTopLevel, record, resetEvent, writeLegacyHandoff, legacyHandoffPath, statePath, isoAt };
