"use strict";
// The pm field backfill (#3135): writes the local holder's tag into an empty pm field of a board that had none.
//   backfillPm({repo, read?, write?, prepare?, entries?, homeRepo?}) -> {ok, reason?, written, skipped, failed}
// The listing, the read and every write run inside the PM lock /pm-add and /pm-init take, so a PM command
// cannot change a holder between the empty check and the write. Only an empty field with exactly one local
// holder is written; a field naming another PM, or one held by two local PMs, is skipped ({issue, reason})
// and never overwritten (the field is the ownership SSOT). Idempotent: a second run writes nothing.
// A failed read writes nothing; any failed (or unknown) write makes ok false so the step is retried.
// read/write/prepare default to createPmField's field I/O (prepare adds a missing card first).

const path = require("path");
const { withPmLock, PmLockBusy } = require(path.join(__dirname, "..", "..", "..", "hooks", "pm-session", "pm-lock"));
const S = require(path.join(__dirname, "..", "..", "..", "hooks", "pm-session", "schema"));
const scan = require(path.join(__dirname, "..", "..", "..", "hooks", "pm-session", "scan"));
const { holdersOf, refsOf } = require("./holders");

const BUDGET_MS = 60000;

function ioOf(o) {
  if (typeof o.read === "function" && typeof o.write === "function") return { prepare: o.prepare, read: o.read, write: o.write };
  return require("../pm-field/write").createPmField({ budgetMs: BUDGET_MS });
}

function run(o) {
  const out = { ok: true, written: [], skipped: [], failed: [] };
  const holders = holdersOf(o.repo, { entries: o.entries || scan.listPmFiles(), homeRepo: o.homeRepo });
  const refs = refsOf(holders, o.repo);
  if (refs.length === 0) return out;
  const io = ioOf(o);
  if (typeof io.prepare === "function") {
    const p = io.prepare(refs);
    if (p && p.ok === false) return Object.assign(out, { ok: false, reason: `card read failed (${p.reason || "unknown"})` });
  }
  const r = io.read(refs);
  if (!r || !r.ok) return Object.assign(out, { ok: false, reason: `pm field read failed (${(r && r.reason) || "unknown"})` });
  for (const ref of refs) {
    const issue = `${ref.repo}#${ref.number}`;
    const hs = holders[issue];
    const v = r.values ? r.values[issue] : null;
    if (v !== null && v !== undefined && v !== "") {
      if (!hs.some((t) => S.sameTag(t, v))) out.skipped.push({ issue, reason: `the field names ${v}; local holder ${hs.join(", ")} (conflict)` });
      continue;
    }
    if (hs.length > 1) { out.skipped.push({ issue, reason: `held by more than one local PM: ${hs.join(", ")} (conflict)` }); continue; }
    const w = io.write(ref, hs[0]);
    if (w && w.result === "ok") out.written.push({ issue, tag: hs[0] });
    else out.failed.push({ issue, reason: (w && (w.reason || w.result)) || "no answer" });
  }
  if (out.failed.length > 0) {
    const k = out.failed.filter((f) => f.reason === "budget-exhausted").length;
    const more = k > 0 ? ` (${k} budget-exhausted; re-run to continue)` : "";
    Object.assign(out, { ok: false, reason: `${out.failed.length} write(s) failed${more}` });
  }
  return out;
}

function backfillPm(opts) {
  const o = opts || {};
  try {
    return withPmLock(() => run(o));
  } catch (e) {
    const reason = e instanceof PmLockBusy ? "pm-lock-busy" : `backfill-error: ${e.message}`;
    return { ok: false, reason, written: [], skipped: [], failed: [] };
  }
}

module.exports = { backfillPm };
