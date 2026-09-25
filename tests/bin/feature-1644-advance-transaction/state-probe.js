#!/usr/bin/env node
"use strict";
// Read-only probe over a fixture workflow state file. Used by the #1644
// feature-1644-advance-transaction bash cases so state assertions never rely on
// fragile inline `node -e` strings (MSYS mangles bare "/name.json" literals).
//
// Inputs come from env vars only (no argv path interpolation):
//   WFSTATE_MODULE  absolute path to hooks/workflow-state
//   PROBE_SID       session id
//   PROBE_STEP      step name (entry/field/lastevent modes)
//   PROBE_FIELD     projected field name (field mode)
// argv[2] selects the mode.

const path = require("path");
const fs = require("fs");

const mode = process.argv[2];
const wf = require(process.env.WFSTATE_MODULE);
const sid = process.env.PROBE_SID;
const step = process.env.PROBE_STEP;

function sortedStringify(v) {
  return JSON.stringify(v, (k, val) => {
    if (val && typeof val === "object" && !Array.isArray(val)) {
      return Object.keys(val).sort().reduce((a, kk) => { a[kk] = val[kk]; return a; }, {});
    }
    return val;
  });
}

function stepsOf(state) {
  if (!state) return null;
  return state.steps || (state.current && state.current.steps) || null;
}

function readRawFile() {
  const p = path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json");
  return JSON.parse(fs.readFileSync(p, "utf8"));
}

try {
  if (mode === "field") {
    const m = stepsOf(wf.readState(sid));
    const e = m && m[step];
    const v = e ? e[process.env.PROBE_FIELD] : undefined;
    process.stdout.write(JSON.stringify(v === undefined ? null : v) + "\n");
  } else if (mode === "entry") {
    // Projected step entry with volatile/audit fields removed. `updated_at` is a
    // wall-clock timestamp and `skip_verdict` carries recorded_at + a per-path
    // `source` token, so both are compared separately by the caller.
    // `skip_judgment.recorded_at` is the same kind of wall-clock stamp:
    // recordSkipJudgment rewrites it unconditionally on every call, so it is
    // dropped by name. The rest of skip_judgment (conditions, all_conditions_met,
    // judgment_source) stays IN the comparison — that is the part a repeat must
    // not disturb.
    const m = stepsOf(wf.readState(sid));
    const e = Object.assign({}, (m && m[step]) || {});
    delete e.updated_at;
    delete e.skip_verdict;
    if (e.skip_judgment && typeof e.skip_judgment === "object" && !Array.isArray(e.skip_judgment)) {
      e.skip_judgment = Object.assign({}, e.skip_judgment);
      delete e.skip_judgment.recorded_at;
    }
    process.stdout.write(sortedStringify(e) + "\n");
  } else if (mode === "sub") {
    // PROBE_FIELD is a dotted path into the projected step entry, e.g.
    // "skip_verdict.verdict". Missing intermediates yield null.
    const m = stepsOf(wf.readState(sid));
    let v = m && m[step];
    for (const key of String(process.env.PROBE_FIELD).split(".")) {
      v = v === undefined || v === null ? undefined : v[key];
    }
    process.stdout.write(JSON.stringify(v === undefined ? null : v) + "\n");
  } else if (mode === "lastevent") {
    // Last step_status event for the step, exposing the audit pair the plan
    // pins by expectation table: provenance + origin.
    const raw = readRawFile();
    const evs = (raw.events || []).filter(
      (ev) => ev.kind === "step_status" && ev.step === step
    );
    const last = evs.length ? evs[evs.length - 1] : null;
    process.stdout.write(
      JSON.stringify(last ? { provenance: last.provenance, origin: last.origin } : null) + "\n"
    );
  } else if (mode === "eventcount") {
    // Number of raw stream events for the step, optionally narrowed to one
    // `kind` via PROBE_FIELD. An empty PROBE_STEP counts the whole stream.
    // Used by the idempotency cases: a repeated forward call must append
    // nothing, and a count is the only view that can see a duplicate append
    // (the folded projection looks identical either way).
    const raw = readRawFile();
    const kind = process.env.PROBE_FIELD || "";
    const n = (raw.events || []).filter(
      (ev) => (!step || ev.step === step) && (!kind || ev.kind === kind)
    ).length;
    process.stdout.write(String(n) + "\n");
  } else if (mode === "topkeys") {
    process.stdout.write(JSON.stringify(Object.keys(readRawFile()).sort()) + "\n");
  } else {
    process.stderr.write("state-probe: unknown mode " + String(mode) + "\n");
    process.exit(2);
  }
} catch (e) {
  process.stdout.write("PROBE_ERR:" + e.message + "\n");
}
