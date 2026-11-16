"use strict";
// Shared fixture for the #2852 tests (tests/{hooks,bin}/feature-2852-*.js). Not a test on its own.
// The caller pins WORKFLOW_STATE_DIR and WORKFLOW_PLANS_DIR (harness isolate()) before use.
//
// States are written at the stream level: every event is placed in the state file as the writers
// would have stored it, so a case exercises the reader under test, never a writer. A reset is the
// same batch hooks/workflow-mark/reset-handler.js buildResetEvents writes. Gated plan steps carry
// a hash-exempt approval (source session-inherit), so a completion is never refused at read time
// whatever the CONFIRM_* flags say; a case that wants the refusal leaves the approval out.

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const fwd = (p) => String(p).replace(/\\/g, "/");
const mod = (rel) => require(path.join(ROOT, rel));
const io = () => mod("hooks/workflow-state/state-io");
const STEPS = io().VALID_STEPS;
const GATED = ["clarify_intent", "outline", "detail"];
const ORIGIN = "fixture-2852";
const ALL_OFF = Object.freeze({ CONFIRM_INTENT: "off", CONFIRM_OUTLINE: "off", CONFIRM_DETAIL: "off" });

// need(rel, name) — the module (or its export `name`); a missing module or export fails the
// calling case with that name, so an unimplemented API reads as such, never as a crash.
function need(rel, name) {
  let m;
  try {
    m = mod(rel);
  } catch (e) {
    assert.fail(`${rel} not loadable: ${String(e && e.message).split("\n")[0]}`);
  }
  if (name === undefined) return m;
  assert.strictEqual(typeof (m && m[name]), "function", `${rel} does not export ${name}()`);
  return m[name];
}

const idx = (step) => {
  const i = STEPS.indexOf(step);
  if (i === -1) throw new Error(`fixture: unknown step ${step}`);
  return i;
};
const isoAt = (n) => new Date(Date.UTC(2026, 0, 1, 0, 0, 0) + n * 60000).toISOString();

const st = (step, status, origin) => ({ kind: "step_status", step, status, provenance: "declared", origin: origin || ORIGIN });
const note = (step, key, value) => ({ kind: "step_annotation", step, key, value, provenance: "observed", origin: ORIGIN });
const approval = (step) => ({
  kind: "plan_approval", step, source: "session-inherit", reason: "fixture approval",
  artifact_sha256: null, artifact_session_id: null, artifact_hash_status: "unknown",
  provenance: "declared", origin: ORIGIN,
});
const cycleBoundary = (n) => ({ kind: "cycle_boundary", closed_cycle: n, reason: "reinit-entry", provenance: "declared", origin: "cycle-boundary" });

// completeRange(from, to, opts) — complete events for every step in [from, to); a gated step gets
// its approval first unless opts.unapproved lists it.
function completeRange(from, to, opts) {
  const skipApproval = (opts && opts.unapproved) || [];
  const end = to === null ? STEPS.length : idx(to);
  const out = [];
  for (let i = idx(from); i < end; i++) {
    const step = STEPS[i];
    if (GATED.includes(step) && !skipApproval.includes(step)) out.push(approval(step));
    out.push(st(step, "complete"));
  }
  return out;
}

// resetEvents(target, reason) — the batch RESET_FROM_<target> leaves in the stream.
function resetEvents(target, reason) {
  const t = idx(target);
  const out = [{ kind: "reset", from_step: target, reason, provenance: "declared", origin: "reset-sentinel" }];
  for (let i = 0; i < t; i++) out.push(st(STEPS[i], "complete", "reset-sentinel"));
  for (let i = t; i < STEPS.length; i++) {
    out.push({ kind: "step_annotations_cleared", step: STEPS[i], provenance: "declared", origin: "reset-sentinel" });
    out.push(st(STEPS[i], "pending", "reset-sentinel"));
  }
  return out;
}

// history(current, items) — a session standing at `current`; each item is a reset target (string),
// { to, reason } or a raw event (has `kind`). After a reset to an earlier step the steps up to
// `current` are completed again, as the session would have redone them.
function history(current, items) {
  const ev = completeRange("workflow_init", current);
  let n = 0;
  for (const item of items || []) {
    if (item && typeof item === "object" && item.kind) { ev.push(item); continue; }
    n += 1;
    const to = typeof item === "string" ? item : item.to;
    const reason = typeof item === "string" ? `fixture reset ${n} to ${to}` : item.reason;
    ev.push(...resetEvents(to, reason));
    if (idx(to) < idx(current)) ev.push(...completeRange(to, current));
  }
  return ev;
}

const statePath = (sid) => path.join(process.env.WORKFLOW_STATE_DIR, `${sid}.json`);

// seed(sid, events, opts) — writes the state file. opts: the delivery path (default "pull_request"), cwd.
function seed(sid, events, opts) {
  const o = opts || {};
  const s = io().createInitialState(sid, {
    cwd: o.cwd ? fwd(o.cwd) : "/fixture/2852", git_branch: "feature/fixture-2852", transcript_path: "/fixture/t/2852.jsonl",
  });
  s.deliverable_type = "wf-code";
  s.delivery_path = o.deliveryPath || "pull_request";
  s.auto_merge_pr = "on";
  s.events = events.map((e, i) => Object.assign({ at: isoAt(i) }, e, { seq: i + 1 }));
  fs.writeFileSync(statePath(sid), JSON.stringify(s, null, 2), "utf8");
  return s;
}

const raw = (sid) => JSON.parse(fs.readFileSync(statePath(sid), "utf8"));
const writeRaw = (sid, obj) => fs.writeFileSync(statePath(sid), JSON.stringify(obj, null, 2), "utf8");

// append(sid, events) — adds events with the next seq.
function append(sid, events) {
  const s = raw(sid);
  let seq = s.events.length;
  for (const e of events) {
    seq += 1;
    s.events.push(Object.assign({ at: isoAt(seq) }, e, { seq }));
  }
  writeRaw(sid, s);
}

function setTop(sid, fields) {
  writeRaw(sid, Object.assign(raw(sid), fields));
}

const read = (sid) => io().readState(sid);

// writeIntent(sid) — an intent with one issue, so next-step does not stop at closes_issues-empty.
function writeIntent(sid) {
  fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, `${sid}-intent.md`), "# Intent\n\n## Issues\n\n- #2852\n");
}

module.exports = {
  ROOT, fwd, mod, need, STEPS, GATED, ALL_OFF, idx, isoAt,
  st, note, approval, cycleBoundary, completeRange, resetEvents, history,
  statePath, seed, raw, writeRaw, append, setTop, read, writeIntent,
};
