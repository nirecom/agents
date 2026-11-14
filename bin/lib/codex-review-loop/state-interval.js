"use strict";
// bin/lib/codex-review-loop/state-interval.js — the read-only event interval of a workflow state
// between two review-record rows (#2938 D5). The only module that interprets event kinds, `seq`
// and the supervisor audit ledger for the review record.

const fs = require("fs");
const path = require("path");

const HOOKS = path.resolve(__dirname, "..", "..", "..", "hooks");
const STEP_OF_FORMAT = { "outline-plan": "outline", "detail-plan": "detail" };

const io = () => require(path.join(HOOKS, "workflow-state", "state-io"));

function stateFileState(sid) {
  let p;
  try { p = io().getStatePath(sid); } catch { return "unreadable"; }
  return fs.existsSync(p) ? "present" : "absent";
}

function preConfirmTrId(format) {
  const step = STEP_OF_FORMAT[format];
  if (!step) return null;
  const { TRIGGERS } = require(path.join(HOOKS, "lib", "audit-triggers"));
  const t = TRIGGERS.find((x) => x.kind === "pre-confirm" && x.step === step);
  return t ? t.tr_id : null;
}

const ms = (iso) => {
  const n = Date.parse(iso);
  return Number.isNaN(n) ? null : n;
};

// hasAuditBlock(sid, {format, sinceAt, untilAt}) — a terminal BLOCK of the format's pre-confirm
// audit with sinceAt < terminal_at <= untilAt. Anything unreadable is false.
function hasAuditBlock(sid, opts) {
  try {
    const trId = preConfirmTrId(opts && opts.format);
    if (!trId) return false;
    const shared = require(path.join(HOOKS, "lib", "supervisor-state-writer", "shared"));
    if (!fs.existsSync(shared.getStatePath(sid))) return false;
    const ledger = ((shared.readStateOrInit(sid) || {}).audit || {}).ledger;
    if (!Array.isArray(ledger)) return false;
    const since = opts.sinceAt ? ms(opts.sinceAt) : null;
    const until = opts.untilAt ? ms(opts.untilAt) : Date.now();
    return ledger.some((e) => {
      if (!e || e.outcome !== "terminal" || e.verdict !== "BLOCK") return false;
      if (!Array.isArray(e.tr_ids) || !e.tr_ids.includes(trId)) return false;
      const t = ms(e.terminal_at);
      if (t === null) return false;
      return (since === null || t > since) && (until === null || t <= until);
    });
  } catch {
    return false;
  }
}

// readInterval(sid, sinceSeq, untilSeq, opts) -> {state, head_seq, kinds, has_reset,
// has_write_code, has_audit_block}. Events with sinceSeq < seq <= untilSeq (untilSeq null = to the end).
function readInterval(sid, sinceSeq, untilSeq, opts) {
  const o = opts || {};
  const out = { state: stateFileState(sid), head_seq: null, kinds: [], has_reset: false, has_write_code: false, has_audit_block: false };
  if (out.state !== "present") return out;
  const st = io().readState(sid);
  if (!st || !Array.isArray(st.events)) {
    out.state = "unreadable";
    return out;
  }
  const since = Number.isInteger(sinceSeq) ? sinceSeq : 0;
  const until = Number.isInteger(untilSeq) ? untilSeq : null;
  for (const e of st.events) {
    if (!e || !Number.isInteger(e.seq)) continue;
    if (out.head_seq === null || e.seq > out.head_seq) out.head_seq = e.seq;
    if (e.seq <= since || (until !== null && e.seq > until)) continue;
    if (typeof e.kind === "string" && !out.kinds.includes(e.kind)) out.kinds.push(e.kind);
    if (e.kind === "reset") out.has_reset = true;
    if (e.kind === "step_status" && e.step === "write_code") out.has_write_code = true;
  }
  if (out.head_seq === null) out.head_seq = 0;
  if (o.format) out.has_audit_block = hasAuditBlock(sid, o);
  return out;
}

module.exports = { readInterval, hasAuditBlock, preConfirmTrId };
