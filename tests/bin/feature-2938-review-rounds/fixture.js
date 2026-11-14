"use strict";
// Private fixture of tests/bin/feature-2938-review-rounds*.js (#2938 T4). The caller runs
// isolate() from tests/lib/harness.js before the first helper call; the state, control-dir and
// supervisor-state modules are required lazily so they resolve the pinned WORKFLOW_STATE_DIR.
// Rows are written only through bin/review-rounds (append / stage-fallback / record-fallback);
// the record file is read here directly to check what appendRow wrote.
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..", "..");
const rel = (p) => path.join(ROOT, p);
const FP = { a: "a".repeat(64), b: "b".repeat(64), c: "c".repeat(64) };

// mod(p) — a module of the checkout; a missing one fails the case with a clear reason.
function mod(p) {
  try {
    return require(rel(p));
  } catch (e) {
    throw new Error(`${p} could not be loaded (not implemented yet?): ${e.message}`);
  }
}

const io = () => require(rel("hooks/workflow-state/state-io"));
const ctlDir = (sid) => require(rel("hooks/workflow-state/state-io/control-dir")).getSessionControlDir(sid);
const recPath = (sid, fmt) => path.join(ctlDir(sid), `${fmt}-review-rounds.jsonl`);

function sleep(ms) {
  Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, ms);
}

// State events. markStep appends exactly one step_status event (no annotations).
const seed = (sid) => io().markStep(sid, "clarify_intent", "in_progress");
const neutral = (sid) => io().markStep(sid, "outline", "in_progress");
const writeCode = (sid) => io().markStep(sid, "write_code", "in_progress");
const reset = (sid) => io().appendEvents(sid, [
  { kind: "reset", from_step: "outline", reason: "fixture", provenance: "declared", origin: "reset-sentinel" },
]);
const headSeq = (sid) => {
  const ev = (io().readState(sid) || { events: [] }).events;
  return ev.length ? ev[ev.length - 1].seq : 0;
};
function corrupt(sid) {
  const p = io().getStatePath(sid);
  fs.mkdirSync(path.dirname(p), { recursive: true });
  fs.writeFileSync(p, "{ not json");
}
// handover(B, A) — B is a session-downstream whose first generation is A.
const handover = (b, a) => io().updateTopLevel(b, (r) => { r.first_session_id = a; });

// One terminal audit run on the supervisor-state of sid.
function auditEntry(sid, trId, terminalAt, verdict = "BLOCK") {
  const shared = require(rel("hooks/lib/supervisor-state-writer/shared"));
  const st = require(rel("hooks/lib/supervisor-state-schema")).createEmptyState(sid);
  const id = "run-0001";
  st.audit.run_seq = 1;
  st.audit.last_terminal_run_id = id;
  st.audit.audit_verdict = verdict;
  st.audit.ledger = [{
    id, outcome: "terminal", verdict, tr_ids: [trId], sub_checks: [], cause: `pre-confirm:${trId}`,
    armed_at: terminalAt, terminal_at: terminalAt,
  }];
  shared.writeAtomic(shared.getStatePath(sid, { forWrite: true }), st);
}

let runSeq = 0;
// rr(args) -> {status, out, err}: one bin/review-rounds run from the checkout.
function rr(args) {
  const r = spawnSync(process.execPath, [rel("bin/review-rounds"), ...args.map(String)], {
    encoding: "utf8", timeout: 30000, env: Object.assign({}, process.env, { AGENTS_MAIN_ROOT: ROOT }),
  });
  return { status: r.status, out: r.stdout || "", err: (r.stderr || "") + (r.error ? String(r.error) : "") };
}
// append(sid, fmt, counterRound, exit, verdict, {source, fp}) — a wrapper row (asserted to succeed).
function append(sid, fmt, cr, exit, verdict, o = {}) {
  runSeq += 1;
  const args = ["append", "--session", sid, "--format", fmt, "--counter-round", cr, "--exit", exit,
    "--verdict", verdict, "--source", o.source || "codex", "--run-id", `0f${String(runSeq).padStart(6, "0")}`];
  if (o.fp) args.push("--fingerprint", o.fp);
  const r = rr(args);
  assert.strictEqual(r.status, 0, `append ${sid} ${fmt} r${cr}: ${r.err}`);
  return r;
}
// fallback(sid, fmt, verdict) — a CC fallback outside the wrapper: stage-fallback, then record-fallback.
function fallback(sid, fmt, verdict) {
  const s = rr(["stage-fallback", "--session", sid, "--format", fmt]);
  assert.strictEqual(s.status, 0, `stage-fallback ${sid} ${fmt}: ${s.err}`);
  const r = rr(["record-fallback", "--session", sid, "--format", fmt, "--verdict", verdict]);
  assert.strictEqual(r.status, 0, `record-fallback ${sid} ${fmt} ${verdict}: ${r.err}`);
}

// rows(sid, fmt) — the parsed rows of the record in the first sid's control dir (bad lines skipped).
function rows(sid, fmt) {
  let text = "";
  try { text = fs.readFileSync(recPath(sid, fmt), "utf8"); } catch (_) { return []; }
  const out = [];
  for (const l of text.split(/\r?\n/)) {
    if (!l.trim()) continue;
    try { out.push(JSON.parse(l)); } catch (_) { /* counted by summarize, not here */ }
  }
  return out;
}
const lastRow = (sid, fmt) => rows(sid, fmt).slice(-1)[0] || {};
const rawLine = (sid, fmt, n) => fs.readFileSync(recPath(sid, fmt), "utf8").split(/\r?\n/).filter(Boolean)[n - 1];
const addRaw = (sid, fmt, line) => fs.appendFileSync(recPath(sid, fmt), line + "\n");

// kv(text) -> {key: value} from key=value lines.
function kv(text) {
  const o = {};
  for (const l of String(text).split(/\r?\n/)) {
    const m = l.match(/^([A-Za-z_][A-Za-z0-9_]*)=(.*)$/);
    if (m) o[m[1]] = m[2].trim();
  }
  return o;
}

const summarize = (sid, fmt) => mod("bin/lib/codex-review-loop/review-rounds.js").summarize({ sid, format: fmt });

module.exports = {
  ROOT, rel, FP, mod, io, ctlDir, recPath, sleep, seed, neutral, writeCode, reset, headSeq, corrupt,
  handover, auditEntry, rr, append, fallback, rows, lastRow, rawLine, addRaw, kv, summarize,
};
