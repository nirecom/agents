"use strict";
// hooks/lib/jev/two-stage/failsafe.js — `jev-judge failsafe` (#2460, caller step JJ-5): settle
// the point's fail-safe through the owner marker under a failsafe-<hex> owner dated at the
// caller's ticket's query time, so it beats that ticket and loses to any newer query.
// Never a judgment: nothing is written to the decision log.

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const pending = require("../pending");
const { registryEntry } = require("../registry");
const { isValidId, readVersioned } = require("../state-paths");
const { settleComplexity } = require("./settle-complexity");
const { failsafeSkip } = require("./settle-skip");
const { TICKET_RE, readDone, pointStageEntry } = require("./paths");

const UNDECIDABLE = "S0-undecidable";

// The ticket's created_ms from its pending hand, any claim, or its done marker; else null.
function ticketCreatedMs(sid, tid) {
  const dir = pending.pendingDir(sid);
  const names = [`${tid}.json`];
  try {
    for (const n of fs.readdirSync(dir)) if (n.startsWith(`${tid}.claimed-`)) names.push(n);
  } catch (_e) { /* no pending dir */ }
  for (const n of names) {
    const h = readVersioned(path.join(dir, n), pending.PENDING_VERSION);
    if (h && Number.isFinite(h.created_ms)) return h.created_ms;
  }
  const done = readDone(sid, tid);
  return done && Number.isFinite(done.created_ms) ? done.created_ms : null;
}

// failsafe(args, opts) -> {exit, stdout_lines}. args: {sid|session, point, stage, ticket ("-" or an id)}.
// A skip point takes MS instead and prints SKIP=false; no judgment is written.
function failsafe(args, optsArg = {}) {
  const a = args || {};
  const opts = Object.assign({}, a, optsArg);
  const sid = a.sid || a.session || a.sessionId;
  const resolveEntry = typeof opts.resolveEntry === "function" ? opts.resolveEntry : registryEntry;
  const entry = isValidId(sid) ? pointStageEntry(a.point, a.stage, resolveEntry) : null;
  const tid = a.ticket;
  if (!entry || (tid !== "-" && !(typeof tid === "string" && TICKET_RE.test(tid)))) return { exit: 2, stdout_lines: [] };
  const created = tid === "-" ? null : ticketCreatedMs(sid, tid);
  const owner = { id: `failsafe-${crypto.randomBytes(8).toString("hex")}`, created_ms: created === null ? Date.now() : created };
  try {
    if (entry.target) {
      const s = failsafeSkip(sid, entry.target, owner);
      return { exit: 0, stdout_lines: ["RESULT=ok", "SKIP=false", `SETTLE=${s.settle}`] };
    }
    const v = settleComplexity(sid, a.stage, `SIGNALS: ${UNDECIDABLE}`, UNDECIDABLE, owner, opts);
    return {
      exit: 0,
      stdout_lines: ["RESULT=ok", `SIGNALS_CSV=${v.settle === "ok" ? UNDECIDABLE : "-"}`, `SETTLE=${v.settle}`],
    };
  } catch (_e) {
    return { exit: 3, stdout_lines: [] };
  }
}

module.exports = { failsafe, ticketCreatedMs };
