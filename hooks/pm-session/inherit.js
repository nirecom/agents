"use strict";
// `/resume-session --from <sid>` for the pm key writer (#2941): the new generation of a PM. The
// assignment always comes over; the upstream table is checked (sequence.checkSequence) inside the PM
// lock and copied only when it passes, or with the unverified mark when only the forge failed.

const path = require("path");
const io = require("../workflow-state/state-io");
const S = require("./schema");
const scan = require("./scan");
const C = require("./writer-common");
const { budgetOf } = require("./budget");

const BIN = path.join(__dirname, "..", "..", "bin", "lib", "pm-state");
const FROM_RE = /(?:^|\s)--from\s+([A-Za-z0-9_-]+)(?=\s|$)/;
const EMPTY_SEQ = () => ({ updated_at: null, tables: [], unverified: null });

const refKeys = (issues, home) => (Array.isArray(issues) ? issues : [])
  .map((i) => `${S.resolveRepo(i, home).toLowerCase()}#${Number(i.number)}`).sort().join(",");

// verdictOf(r, upSeq, at) -> {sequence, value, reason}: the table to write and the words to report.
function verdictOf(r, upSeq, at) {
  const { refLabelOf } = require(path.join(BIN, "overlap"));
  if (r.ok) return { sequence: Object.assign({}, upSeq, { unverified: upSeq.unverified || null }), value: "copied", reason: null };
  const refs = r.issues.map(refLabelOf).join(" ");
  if (r.kind === "unverified") {
    return { sequence: Object.assign({}, upSeq, { unverified: { reason: r.reason, at } }), value: "copied-unverified", reason: `${r.reason} ${refs}`.trim() };
  }
  const reason = r.kind === "structure" ? `structure ${r.reason}` : r.kind === "out-of-range" ? `out-of-range ${refs}` : `${r.reason} ${refs}`;
  return { sequence: EMPTY_SEQ(), value: "not-copied", reason };
}

function exitOf(value, reason, upSid) {
  if (value === "copied-unverified") return "Exit: when the forge is back, run `bin/pm-state set-sequence --revalidate` in this session.";
  if (value !== "not-copied") return null;
  const lo = /label-overflow/.test(reason || "") ? " (for label-overflow, reducing the labels to 100 or fewer also works)" : "";
  return `Exit: restore it with \`/pm-add\`, or fix or drop that issue in the table from \`bin/pm-state show --session ${upSid}\` and rewrite it with \`bin/pm-state set-sequence --file\`${lo}.`;
}

// upstreamOf(sid, args) -> {upSid, up} when args name another session holding an active PM, else null.
function upstreamOf(sid, args) {
  const m = String(args || "").match(FROM_RE);
  if (!m || m[1] === sid) return null;
  let up;
  try { up = io.readRawState(m[1]); } catch (_) { return null; }
  return S.isActivePm(up) ? { upSid: m[1], up } : null;
}

// wantsInherit(sid, args) -> whether the writer takes the PM lock for this /resume-session at all.
const wantsInherit = (sid, args) => upstreamOf(sid, args) !== null;

// Carried to the new generation as they are (#2942): the rename record and the notify-side bookkeeping.
const CARRIED_KEYS = ["retired_tags", "rename_pending", "meta_children", "seen_notifications"];

// inherit(sid, args, nowMs, input, deps) -> {pm, context, notice} or null when there is nothing to
// inherit. The caller holds the PM lock (#2942): the upstream state is read and checked inside it.
function inherit(sid, args, nowMs, input, deps) {
  const u = upstreamOf(sid, args);
  if (!u) return null;
  const { upSid, up } = u;
  const entries = scan.listPmFiles();
  const oldGen = (es) => {
    const cur = scan.currentOf(up.pm.tag, es);
    C.refuse(`session ${upSid} is an old generation of ${up.pm.tag}; resume from the current one, ${cur ? cur.session_id : "(unknown)"}.`);
  };
  if (!scan.isCurrentGeneration(upSid, entries)) oldGen(entries);
  if (S.hasPmMark(C.rawOf(sid))) C.refuse("this session already has a PM; resume the PM in a new session.");
  if (C.workflowBegun(sid)) C.refuse("this session has started a workflow; resume the PM in a new session.");
  const home = C.homeRepoOf(input, deps);
  const upSeq = up.pm.sequence && typeof up.pm.sequence === "object" ? up.pm.sequence : EMPTY_SEQ();
  const tables = upSeq.tables;
  const snap = { tag: up.pm.tag, issues: refKeys(up.pm.issues, home), updated_at: upSeq.updated_at === undefined ? null : upSeq.updated_at };
  const at = new Date(nowMs).toISOString();
  let v;
  if (Array.isArray(tables) && tables.length === 0) v = { sequence: Object.assign(EMPTY_SEQ(), upSeq, { tables: [] }), value: "none", reason: null };
  else {
    const { checkSequence } = require(path.join(BIN, "sequence"));
    const r = checkSequence(tables, { tag: up.pm.tag, session_id: upSid, issues: up.pm.issues || [] }, { ancestry: C.ancestryOf(deps, budgetOf(deps).checkDeadline({ write: false })), homeRepo: home });
    v = verdictOf(r, upSeq, at);
  }
  let pm = null;
  io.updateTopLevel(sid, (rec) => {
    if (S.hasPmMark(rec)) C.refuse("this session already has a PM.");
    let now;
    try { now = io.readRawState(upSid); } catch (_) { now = null; }
    if (!S.isActivePm(now) || now.pm.tag !== snap.tag) {
      C.refuse(`the PM of session ${upSid} ended or changed its tag while this command ran; resume from its current session.`);
    }
    if (!scan.isCurrentGeneration(upSid)) oldGen(scan.listPmFiles());
    const nowSeq = now.pm.sequence && typeof now.pm.sequence === "object" ? now.pm.sequence : EMPTY_SEQ();
    const nowAt = nowSeq.updated_at === undefined ? null : nowSeq.updated_at;
    if (refKeys(now.pm.issues, home) !== snap.issues || nowAt !== snap.updated_at) v = { sequence: EMPTY_SEQ(), value: "not-copied", reason: "changed" };
    const upSince = Date.parse(now.pm.current_since);
    const since = new Date(Number.isNaN(upSince) ? nowMs : Math.max(nowMs, upSince + 1)).toISOString();
    const issues = (now.pm.issues || []).map((i) => C.normalizeStoredRef(i, home));
    const logReason = `from ${upSid} sequence=${v.value}${v.reason ? ` sequence_reason=${v.reason}` : ""}`;
    pm = {
      tag: now.pm.tag, issues, objective: now.pm.objective || null, current_since: since, upstream_session_id: upSid,
      assignment_log: (now.pm.assignment_log || []).concat([{ at: since, op: "inherit", issues, reason: logReason }]),
      sequence: v.sequence, archived_at: null,
    };
    for (const k of CARRIED_KEYS) if (now.pm[k] !== undefined) pm[k] = now.pm[k];
    rec.pm = pm;
  });
  const exit = exitOf(v.value, v.reason, upSid);
  const lines = [`sequence=${v.value}`].concat(v.reason ? [`sequence_reason=${v.reason}`] : []).concat(exit ? [exit] : []);
  const notice = `[pm-session] inherited ${pm.tag} from session ${upSid}: sequence=${v.value}${v.reason ? ` (${v.reason})` : ""}${exit ? `. ${exit}` : ""}`;
  return { pm, context: C.note("inherit", pm, lines), notice };
}

module.exports = { inherit, wantsInherit };
