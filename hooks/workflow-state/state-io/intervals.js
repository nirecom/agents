"use strict";

// Per-event elapsed time derived from the event stream (#1733).
//
// The stream records instants; duration is the gap between consecutive
// instants. Row i spans event i-1 -> event i, with row 0 spanning
// `created_at` -> event 1 (seq 0 denotes "session start", not an event).

// The step whose first status event closes the session's timeline. Events
// appended after it are out-of-band (post-report bookkeeping) and get no rows.
function terminalSteps() {
  return require("./core").TERMINAL_STEPS;
}

function computeIntervals(state) {
  const events = state && Array.isArray(state.events) ? state.events : [];
  if (events.length === 0) return [];

  const createdAt = state && typeof state.created_at === "string" ? state.created_at : null;
  const terminals = terminalSteps();

  let end = events.length;
  for (let i = 0; i < events.length; i++) {
    const e = events[i];
    if (e && e.kind === "step_status" && terminals.includes(e.step)) {
      end = i + 1;
      break;
    }
  }

  const rows = [];
  for (let i = 0; i < end; i++) {
    const event = events[i];
    const prev = i === 0 ? null : events[i - 1];
    const from_seq = prev && typeof prev.seq === "number" ? prev.seq : i === 0 ? 0 : i;
    const from_at = prev ? (prev.at !== undefined ? prev.at : null) : createdAt;
    const to_at = event && event.at !== undefined ? event.at : null;

    const fromMs = typeof from_at === "string" ? Date.parse(from_at) : NaN;
    const toMs = typeof to_at === "string" ? Date.parse(to_at) : NaN;

    let duration_ms = null;
    let out_of_order = false;
    if (Number.isFinite(fromMs) && Number.isFinite(toMs)) {
      if (toMs < fromMs) out_of_order = true;
      else duration_ms = toMs - fromMs;
    }

    rows.push({
      from_seq,
      to_seq: event && typeof event.seq === "number" ? event.seq : i + 1,
      from_at,
      to_at,
      duration_ms,
      out_of_order,
      // A duration computed against a reconstructed timestamp is an estimate,
      // and must never be presented as measured.
      estimated: !!(event && (event.at_estimated === true || event.provenance === "backfilled")),
      event,
    });
  }
  return rows;
}

module.exports = { computeIntervals };
