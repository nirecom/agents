"use strict";
// bin/lib/codex-review-loop/review-rounds.js — classification and reading of the step-wide review
// record (#2938 D2 / D5 / D8). Pure functions over rows; file I/O lives in review-rounds-store.js.

// NON_APPROVED_VERDICT per format — mirrors the Parameters tables of skills/_shared/codex-review-loop.md.
const NON_APPROVED_VERDICT = {
  "outline-plan": "MISSING_ALTERNATIVE",
  "detail-plan": "NEEDS_REVISION",
  "security-plan": "NEEDS_REVISION",
  "test-review": "NEEDS_REVISION",
};

const isNonApproved = (verdict, format) => verdict === "NEEDS_REVISION" || verdict === NON_APPROVED_VERDICT[format];

// The verdicts record-fallback accepts for a format; null when the format has no wrapper-external fallback.
function fallbackVerdicts(format) {
  const v = NON_APPROVED_VERDICT[format];
  return v ? ["APPROVED", v] : null;
}

const isWrapperRow = (r) => r.exit !== null && r.exit !== undefined;

// classify(prev, input, iv) -> the derived fields of a new row. prev is the last row of the
// format (or null); iv is readInterval(input.state_sid, prev.event_seq, untilSeq, ...).
function classify(prev, input, iv) {
  const cr = input.counter_round;
  let loopCycle = 1;
  let rowNo = 1;
  if (prev) {
    const resumesFallback = prev.source === "cc-fallback" && !isWrapperRow(prev) && prev.counter_round === cr
      && isNonApproved(prev.verdict, input.format) && prev.state_sid === input.state_sid
      && iv.state === "present" && !iv.has_reset;
    if (cr >= 2 || resumesFallback) {
      loopCycle = prev.loop_cycle;
      rowNo = prev.row_no + 1;
    } else {
      loopCycle = prev.loop_cycle + 1;
    }
  }
  const fp = input.fingerprint || null;
  const prevFp = prev ? prev.fingerprint || null : null;
  let kind = "explore";
  if (prev && (rowNo > 1 || (fp !== null && fp === prevFp))) kind = "confirm";
  const fingerprintChanged = prev && fp !== null && prevFp !== null ? fp !== prevFp : null;

  const sameState = prev && prev.state_sid === input.state_sid;
  let route;
  let basis = "same-state";
  let kinds = sameState ? iv.kinds.slice() : null;
  if (iv.state === "absent") {
    [route, basis, kinds] = ["outside-workflow", null, null];
  } else if (iv.state !== "present") {
    [route, basis, kinds] = ["unknown", "state-unreadable", null];
  } else if (!prev) {
    route = "initial";
  } else if (rowNo > 1) {
    route = "in-cycle";
    if (!sameState) basis = "cross-generation";
  } else if (!sameState) {
    route = "unknown";
    basis = "cross-generation";
  } else if (iv.has_reset) {
    route = "reset";
  } else if (iv.has_write_code) {
    route = "write-code";
  } else if (iv.has_audit_block) {
    route = "audit-block";
  } else {
    route = "unknown";
  }
  return {
    loop_cycle: loopCycle, row_no: rowNo, kind, route, interval_basis: basis, interval_kinds: kinds,
    fingerprint: fp, fingerprint_changed: fingerprintChanged,
  };
}

const keyOf = (r) => `${r.loop_cycle}/${r.row_no}`;
const wellFormed = (r) => r && typeof r === "object" && Number.isInteger(r.loop_cycle) && Number.isInteger(r.row_no);

// summarizeRows(parsed, unreadable) — counts by (loop_cycle, row_no); repeats are duplicate_rows.
function summarizeRows(parsed, unreadable) {
  const seen = new Set();
  const uniq = [];
  let duplicates = 0;
  let bad = unreadable || 0;
  for (const r of parsed) {
    if (!wellFormed(r)) { bad += 1; continue; }
    if (seen.has(keyOf(r))) { duplicates += 1; continue; }
    seen.add(keyOf(r));
    uniq.push(r);
  }
  const last = uniq.length ? uniq[uniq.length - 1] : null;
  const currentCycle = last ? last.loop_cycle : 0;
  const inCycle = uniq.filter((r) => r.loop_cycle === currentCycle);
  return {
    rows: uniq.length,
    by_kind: {
      explore: uniq.filter((r) => r.kind === "explore").length,
      confirm: uniq.filter((r) => r.kind === "confirm").length,
    },
    by_source: {
      codex: uniq.filter((r) => r.source === "codex").length,
      cc_fallback: uniq.filter((r) => r.source === "cc-fallback").length,
    },
    current_cycle: currentCycle,
    extensions_used: inCycle.filter((r) => r.verdict === "AUTO_EXTEND").length,
    fingerprints: uniq.map((r) => ({
      loop_cycle: r.loop_cycle, row_no: r.row_no, counter_round: r.counter_round, fingerprint: r.fingerprint === undefined ? null : r.fingerprint,
    })),
    last,
    duplicate_rows: duplicates,
    unreadable_rows: bad,
    current_rows: inCycle,
  };
}

function summarize({ sid, format }) {
  const { readRows } = require("./review-rounds-store");
  const { parsed, unreadable } = readRows(sid, format);
  const s = summarizeRows(parsed, unreadable);
  delete s.current_rows;
  return s;
}

// deriveExtensions(sid, format, R) -> the AUTO_EXTEND rows of the current cycle with
// counter_round < R (R's own rows never count), or null when the record cannot derive it (D3).
function deriveExtensions(sid, format, round) {
  if (round === 1) return 0;
  let s;
  try {
    const { readRows } = require("./review-rounds-store");
    const { parsed, unreadable } = readRows(sid, format, { strict: true });
    s = summarizeRows(parsed, unreadable);
  } catch {
    return null;
  }
  if (!s.current_rows.some((r) => r.counter_round === round - 1)) return null;
  return s.current_rows.filter((r) => r.verdict === "AUTO_EXTEND" && r.counter_round < round).length;
}

// stageRound(last, format) — the counter round a wrapper-external fallback takes (D2).
function stageRound(last, format) {
  if (!last || !Number.isInteger(last.counter_round)) return 1;
  if (!isWrapperRow(last)) return last.source === "cc-fallback" && isNonApproved(last.verdict, format) ? last.counter_round : 1;
  return isNonApproved(last.verdict, format) || last.verdict === "AUTO_EXTEND" ? last.counter_round + 1 : 1;
}

// olderInput(rows, ledgerText, fp) -> [{id, round}] of open / reopened concerns last raised
// against a reviewed input other than fp (D8). A null fingerprint on either side never matches.
function olderInput(rows, ledgerText, fp) {
  if (!fp) return [];
  const s = summarizeRows(rows, 0);
  const out = [];
  for (const line of String(ledgerText).split(/\r?\n/)) {
    const f = line.split("|");
    if (!/^C\d+$/.test(f[0] || "") || !["open", "reopened"].includes(f[2])) continue;
    const round = Number(f[4]);
    const row = s.current_rows.find((r) => r.counter_round === round && isWrapperRow(r));
    if (row && row.fingerprint && row.fingerprint !== fp) out.push({ id: f[0], round });
  }
  return out;
}

module.exports = {
  NON_APPROVED_VERDICT, isNonApproved, fallbackVerdicts, classify, summarizeRows, summarize,
  deriveExtensions, stageRound, olderInput,
};
