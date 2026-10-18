"use strict";
// Probe for the complexity-side fragments of tests/bin/feature-2460-jev-judge.sh (#2460):
// drives the two-stage module API that the CLI cannot reach (resolveEntry, failCopyFor,
// afterCopy, maxArtifactBytes, crashAt) plus fixture seeding.
// Usage: node two-stage-probe.js <repo-root> <cmd> [args...]
// A target module that does not exist yet prints MODULE_MISSING:<rel> and exits 3; an
// exported function the suite expects but cannot find prints API_MISSING:<names>, exit 3.

const fs = require("fs");
const path = require("path");

const [root, cmd, ...args] = process.argv.slice(2);

function load(rel) {
  try {
    return require(path.join(root, rel));
  } catch (e) {
    if (e && e.code === "MODULE_NOT_FOUND" && String(e.message).includes(path.basename(rel))) {
      process.stdout.write("MODULE_MISSING:" + rel);
      process.exit(3);
    }
    throw e;
  }
}

const QUERY = "hooks/lib/jev/two-stage/query.js";
const FINALIZE = "hooks/lib/jev/two-stage/finalize.js";
const SETTLE = "hooks/lib/jev/two-stage/settle-complexity.js";
const BROKER = "hooks/lib/jev/broker.js";
const REGISTRY = "hooks/lib/jev/registry.js";
const COMMON = "bin/workflow/lib/jev-request-common.js";
const WRITE_CTX = "bin/workflow/lib/workflow-init/phases/write-context.js";
const STATE_IO = "hooks/workflow-state/state-io.js";
const APPROVAL = "hooks/workflow-state/completion-approval.js";

const out = (v) => process.stdout.write(typeof v === "string" ? v : JSON.stringify(v));
const sortArr = (a) => (Array.isArray(a) ? a.slice().sort() : a);

function pick(mod, names) {
  const fn = names.map((n) => mod[n]).find((f) => typeof f === "function");
  if (!fn) {
    out("API_MISSING:" + names.join("|"));
    process.exit(3);
  }
  return fn;
}

// resolveEntry built from a patch: {point: {...fields}} overlays registryEntry(point);
// {point: null} unregisters the point; a field set to "__unset__" is removed from the entry.
// Points not in the patch resolve unchanged.
function resolver(patch) {
  const { registryEntry } = load(REGISTRY);
  return (p) => {
    if (patch && Object.prototype.hasOwnProperty.call(patch, p)) {
      if (patch[p] === null) return null;
      const merged = Object.assign({}, registryEntry(p) || {}, patch[p]);
      for (const k of Object.keys(merged)) if (merged[k] === "__unset__") delete merged[k];
      return merged;
    }
    return registryEntry(p);
  };
}

function moduleOpts(raw) {
  const o = raw ? JSON.parse(raw) : {};
  const opts = {};
  if (o.entryPatch) opts.resolveEntry = resolver(o.entryPatch);
  if (o.failCopyFor) opts.failCopyFor = o.failCopyFor;
  if (o.maxArtifactBytes !== undefined) opts.maxArtifactBytes = o.maxArtifactBytes;
  if (o.crashAt) opts.crashAt = o.crashAt;
  // ticketId forces the query's ticket id (a guessed test-only option, like crashAt) so the
  // owner tie-break can be exercised with ids that sort after "failsafe-" (ff...).
  if (o.ticketId) opts.ticketId = o.ticketId;
  if (o.afterCopy) {
    const { file, content } = o.afterCopy;
    opts.afterCopy = () => fs.writeFileSync(file, content);
  }
  return opts;
}

// The module either prints its KEY=VALUE lines itself and returns an exit code, or returns
// {exit, stdout_lines|lines|stdout}; both shapes end as the same stdout + exit status.
function emit(r) {
  if (typeof r === "number") process.exit(r);
  if (r && typeof r === "object") {
    let lines = r.stdout_lines || r.lines || null;
    if (!lines && typeof r.stdout === "string") lines = r.stdout.split("\n").filter(Boolean);
    if (Array.isArray(lines) && lines.length) process.stdout.write(lines.join("\n") + "\n");
    const code = [r.exit, r.code, r.exitCode].find((v) => typeof v === "number");
    process.exit(code === undefined ? 0 : code);
  }
  process.exit(0);
}

const CMDS = {
  // query <sid> <point> <stage> <opts-json>
  async query() {
    const fn = pick(load(QUERY), ["query", "runQuery"]);
    const opts = moduleOpts(args[3]);
    const a = { session: args[0], sessionId: args[0], sid: args[0], point: args[1], stage: args[2] };
    emit(await fn(Object.assign({}, a, opts), opts));
  },
  // finalize <sid> <ticket> <opts-json>
  async finalize() {
    const fn = pick(load(FINALIZE), ["finalize", "runFinalize"]);
    const opts = moduleOpts(args[2]);
    const a = { session: args[0], sessionId: args[0], sid: args[0], ticket: args[1] };
    emit(await fn(Object.assign({}, a, opts), opts));
  },
  // sweep <sid> <ttl-ms>: broker.sweepSession with a short TTL (nothing on stdout but "done").
  async sweep() {
    const broker = load(BROKER);
    await broker.sweepSession(args[0], { pendingTtlMs: Number(args[1]) });
    out("done");
  },
  // settle <sid> <stage> <merged-line> <csv> <owner-id> <created-ms> -> ok|superseded
  async settle() {
    const fn = pick(load(SETTLE), ["settleComplexity"]);
    const r = await fn(args[0], args[1], args[2], args[3], { id: args[4], created_ms: Number(args[5]) });
    out(typeof r === "string" ? r : String(r && (r.settle || r.result || r.status)));
  },
  // compare-owner <idA> <msA> <idB> <msB> -> "<sign(a,b)>|<sign(b,a)>" of the shared
  // compareOwner, or "n/a" when no candidate module exports it (the export site is a guess).
  "compare-owner"() {
    const cands = [SETTLE, "hooks/lib/jev/two-stage/owner.js", "hooks/lib/jev/two-stage/compare-owner.js"];
    let fn = null;
    for (const rel of cands) {
      let mod = null;
      try { mod = require(path.join(root, rel)); } catch (_e) { mod = null; }
      if (mod && typeof mod.compareOwner === "function") { fn = mod.compareOwner; break; }
    }
    if (!fn) return out("n/a");
    const a = { id: args[0], owner_id: args[0], created_ms: Number(args[1]), owner_created_ms: Number(args[1]) };
    const b = { id: args[2], owner_id: args[2], created_ms: Number(args[3]), owner_created_ms: Number(args[3]) };
    return out(Math.sign(fn(a, b)) + "|" + Math.sign(fn(b, a)));
  },
  // required <sid> <required-json> <sections-json> <sources-failed-json> -> {met, missing, exempt}
  required() {
    const { requiredSectionsStatus } = load(COMMON);
    const r = requiredSectionsStatus(args[0], JSON.parse(args[1]), JSON.parse(args[2]), JSON.parse(args[3]));
    out({ met: r.met, missing: sortArr(r.missing), exempt: sortArr(r.exempt) });
  },
  consts() {
    const c = load(COMMON);
    const w = load(WRITE_CTX);
    const src = c.STAGE_SOURCE_SECTIONS || {};
    const stageSources = Object.fromEntries(Object.keys(src).sort().map((k) => [k, sortArr(src[k])]));
    out({ stage_sources: stageSources, order: c.SECTION_ORDER,
      cap: c.MAX_ARTIFACT_READ_BYTES, no_issue_body: w.NO_ISSUE_BODY });
  },
  // jev-input-budget: the Jev input body budget, so fixtures are sized from it, not a literal.
  "jev-input-budget"() {
    out(String(load("hooks/lib/jev/two-stage/jev-input.js").MAX_JEV_INPUT_CHARS));
  },
  // state-steps <sid> <{step: status}>: seed a fresh workflow state through the event API.
  "state-steps"() {
    const io = load(STATE_IO);
    const approval = load(APPROVAL);
    io.writeState(args[0], io.createInitialState(args[0]));
    for (const [k, st] of Object.entries(JSON.parse(args[1]))) {
      if (st === "complete" && approval.isApprovalGatedStep && approval.isApprovalGatedStep(k)) {
        approval.recordPlanApproval(args[0], k, { source: "confirm-flag-off", reason: "test fixture" });
      }
      io.markStep(args[0], k, st, st === "skipped" ? { skip_reason: "test fixture" } : undefined);
    }
    out("ok");
  },
  // body-match <mock-request-log> <file>: "equal" when some string inside a captured
  // request body is byte-equal to <file>, "contains" when one only contains it, else "none".
  "body-match"() {
    const want = fs.existsSync(args[1]) ? fs.readFileSync(args[1], "utf8") : null;
    if (want === null) return out("none");
    const lines = fs.existsSync(args[0]) ? fs.readFileSync(args[0], "utf8").split("\n").filter(Boolean) : [];
    const strs = [];
    const walk = (v) => {
      if (typeof v === "string") strs.push(v);
      else if (v && typeof v === "object") Object.values(v).forEach(walk);
    };
    for (const l of lines) {
      try {
        const rec = JSON.parse(l);
        if (typeof rec.body_text === "string") walk(JSON.parse(rec.body_text));
      } catch (_e) { /* a non-JSON body holds no Jev input field */ }
    }
    if (strs.some((s) => s === want)) return out("equal");
    return out(strs.some((s) => s.includes(want)) ? "contains" : "none");
  },
  // ce-count <sid>: complexity_evaluation events recorded so far.
  "ce-count"() {
    const io = load(STATE_IO);
    const p = io.getStatePath(args[0]);
    if (!fs.existsSync(p)) return out("0");
    const s = JSON.parse(fs.readFileSync(p, "utf8"));
    return out(String((s.events || []).filter((e) => e && e.kind === "complexity_evaluation").length));
  },
};

if (!Object.prototype.hasOwnProperty.call(CMDS, cmd)) {
  process.stderr.write("two-stage-probe: unknown cmd\n");
  process.exit(2);
}
Promise.resolve(CMDS[cmd]()).catch((e) => {
  process.stderr.write("two-stage-probe: " + (e && e.message) + "\n");
  process.exit(5);
});
