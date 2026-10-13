"use strict";
// Probe for the skip-side fragments of tests/bin/feature-2460-jev-judge.sh (#2460): drives the
// two-stage query/finalize module API (test-only knobs: resolveEntry, crashAt, failCopyFor,
// maxArtifactBytes), the broker sweep and the workflow state in-process.
// Usage: node skip-probe.js <repo-root> <cmd> [args...]
// A module that does not exist yet prints MODULE_MISSING:<rel> and exits 3.
// crashAt makes the finalize module end this process with exit 99 at the named boundary.

const fs = require("fs");
const path = require("path");

const [root, cmd, ...args] = process.argv.slice(2);

function load(rel) {
  try {
    return require(path.join(root, rel));
  } catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND" && String(e.message).includes(path.basename(rel))) {
      process.stdout.write("MODULE_MISSING:" + rel + "\n");
      process.exit(3);
    }
    throw e;
  }
}

const QUERY = "hooks/lib/jev/two-stage/query.js";
const FINALIZE = "hooks/lib/jev/two-stage/finalize.js";
const BROKER = "hooks/lib/jev/broker.js";
const REGISTRY = "hooks/lib/jev/registry.js";
const STATE = "hooks/workflow-state/skip-signal-resolver.js";
const STATE_IO = "hooks/workflow-state/state-io";
const SCHEMAS = "hooks/workflow-state/skip-signal-resolver/condition-schemas.js";

const out = (v) => process.stdout.write((typeof v === "string" ? v : JSON.stringify(v)) + "\n");

// resolveEntry(point): the registry entry with <over> shallow-merged on top (data only).
// over = {"__removed__": true} resolves the point as unregistered (null).
function resolver(over) {
  const { registryEntry } = load(REGISTRY);
  return (point) => {
    if (over && over.__removed__ === true) return null;
    const base = registryEntry(point);
    if (!base || !over) return base;
    return Object.assign({}, base, over);
  };
}

// emit(r): print the module's KEY=VALUE lines. Accepts a string, {stdout_lines|lines}, or a
// plain object whose keys map to upper-case line names (null / [] -> "-").
function emit(r) {
  if (r === undefined || r === null) return;
  if (typeof r === "string") return out(r.replace(/\n$/, ""));
  const lines = Array.isArray(r.stdout_lines) ? r.stdout_lines : (Array.isArray(r.lines) ? r.lines : null);
  if (lines) return out(lines.join("\n"));
  for (const [k, v] of Object.entries(r)) {
    if (v !== null && typeof v === "object" && !Array.isArray(v)) continue;
    const val = v === null || (Array.isArray(v) && v.length === 0) ? "-" : (Array.isArray(v) ? v.join(",") : String(v));
    out(k.toUpperCase() + "=" + val);
  }
}

function parseOpts(s) { return s ? JSON.parse(s) : {}; }

// Walk any JSON value and count step_annotation skip_judgment events for <step>.
function countSkipEvents(v, step) {
  if (Array.isArray(v)) return v.reduce((n, x) => n + countSkipEvents(x, step), 0);
  if (!v || typeof v !== "object") return 0;
  const self = v.kind === "step_annotation" && v.key === "skip_judgment" && v.step === step ? 1 : 0;
  return self + Object.values(v).reduce((n, x) => n + countSkipEvents(x, step), 0);
}

const CMDS = {
  // query <opts-json>: {sid, point, stage, entry, failCopyFor, maxArtifactBytes, ticketId}.
  // ticketId (test-only, guessed API) pins the issued 16-hex ticket id instead of a random one.
  async query() {
    const o = parseOpts(args[0]);
    const m = load(QUERY);
    const fn = typeof m === "function" ? m : m.query;
    const r = await fn({ sessionId: o.sid, point: o.point, stage: o.stage, resolveEntry: resolver(o.entry),
      failCopyFor: o.failCopyFor, maxArtifactBytes: o.maxArtifactBytes, ticketId: o.ticketId });
    emit(r);
  },
  // finalize <opts-json>: {sid, ticket, entry, crashAt}.
  async finalize() {
    const o = parseOpts(args[0]);
    const m = load(FINALIZE);
    const fn = typeof m === "function" ? m : m.finalize;
    const r = await fn({ sessionId: o.sid, ticket: o.ticket, resolveEntry: resolver(o.entry), crashAt: o.crashAt });
    emit(r);
  },
  // sweep <sid> <pendingTtlMs>: broker.sweepSession with a short TTL.
  async sweep() {
    const { sweepSession } = load(BROKER);
    await sweepSession(args[0], { pendingTtlMs: Number(args[1]) });
    out("SWEPT=1");
  },
  // record <sid> <target> <conds-json> <source> <ticket>: the judgment write alone, no advance.
  record() {
    const { recordSkipJudgment } = load(STATE);
    recordSkipJudgment(args[0], args[1], JSON.parse(args[2]), args[3], { ticket: args[4] });
    out("WROTE=1");
  },
  // mark <sid> <step> <status>: move a step as the caller would.
  mark() {
    const { markStep } = load(STATE_IO);
    markStep(args[0], args[1], args[2]);
    out("MARKED=1");
  },
  // step <sid> <step> <field> -> JSON of state.steps[step][field], or "null".
  step() {
    const { readState } = load(STATE_IO);
    const s = readState(args[0]);
    const e = s && s.steps && s.steps[args[1]];
    const v = e ? e[args[2]] : undefined;
    out(v === undefined ? "null" : JSON.stringify(v));
  },
  // sj-events <sid> <step> -> how many skip_judgment annotation events the state file holds.
  "sj-events"() {
    const { getStatePath } = load(STATE_IO);
    const p = getStatePath(args[0]);
    out(String(fs.existsSync(p) ? countSkipEvents(JSON.parse(fs.readFileSync(p, "utf8")), args[1]) : 0));
  },
  // valid <sid> <target> -> "<hasValidSkipJudgment>|<isRecordedVerdictValid(sj, target)>".
  valid() {
    const r = load(STATE);
    const sj = r.readSkipJudgment(args[0], args[1]);
    out(String(r.hasValidSkipJudgment(args[0], args[1])) + "|" + String(r.isRecordedVerdictValid(sj, args[1])));
  },
  // sj-q <sid> <target> <expr>: evaluate <expr> over sj (readSkipJudgment; null when none).
  "sj-q"() {
    const r = load(STATE);
    const sj = r.readSkipJudgment(args[0], args[1]);
    // eslint-disable-next-line no-new-func
    const v = new Function("sj", "return (" + args[2] + ");")(sj);
    out(typeof v === "string" ? v : JSON.stringify(v));
  },
  // state-mtime <sid> -> mtimeMs of the state file (0 when absent): a re-write moves it.
  "state-mtime"() {
    const { getStatePath } = load(STATE_IO);
    const p = getStatePath(args[0]);
    out(String(fs.existsSync(p) ? fs.statSync(p).mtimeMs : 0));
  },
  // schema <target> -> CONDITION_SCHEMAS[target] sorted, comma-joined.
  schema() {
    const { CONDITION_SCHEMAS } = load(SCHEMAS);
    out((CONDITION_SCHEMAS[args[0]] || []).slice().sort().join(","));
  },
};

if (!Object.prototype.hasOwnProperty.call(CMDS, cmd)) {
  process.stderr.write("skip-probe: unknown cmd\n");
  process.exit(2);
}
Promise.resolve()
  .then(() => CMDS[cmd]())
  .then(() => process.exit(0), (e) => {
    process.stderr.write("skip-probe: " + (e && e.message ? e.message : String(e)) + "\n");
    process.exit(1);
  });
