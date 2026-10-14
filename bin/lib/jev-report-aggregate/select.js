"use strict";
// bin/lib/jev-report-aggregate/select.js — which decision-log records each report section
// reads. Version routing: `version` equal to the current record version is v2, `v: 1` is the
// shadow-period v1 record (legacy section), anything else is only counted.
// selectV2Decisions is the one place that drops a repeated (ticket, record_type) and the
// decisions of superseded tickets; the adoption and retune sections read its result only.

const path = require("path");
const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..", "..");
const { DECISION_RECORD_VERSION } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "jev", "decision-record.js"));
const { bump } = require("./util");

function routeByVersion(records) {
  const v1 = [];
  const v2 = [];
  let unknown = 0;
  for (const r of records) {
    if (r.version === DECISION_RECORD_VERSION) v2.push(r);
    else if (r.v === 1) v1.push(r);
    else unknown++;
  }
  return { v1, v2, unknown_version: unknown };
}

const hasTicket = (r) => typeof r.ticket === "string" && r.ticket !== "";

// {decisions, duplicate_ticket_records, superseded_by_point, superseded_count, unknown_record_type}
// Of one (ticket, record_type) the first record in log order is kept. A ticket-less record
// (hook path) is never a duplicate. A ticket with a settle(superseded) record never reached
// the workflow state: its decision is left out and only counted, by the settle's point.
// Supersession is decided by the settle record alone, never by comparing contents.
function selectV2Decisions(records) {
  const seen = new Set();
  const decisions = [];
  const supersededTickets = new Set();
  const supersededByPoint = Object.create(null);
  let duplicates = 0;
  let unknownType = 0;
  for (const r of records) {
    const type = r.record_type;
    if (type !== "decision" && type !== "settle") { unknownType++; continue; }
    if (hasTicket(r)) {
      const key = JSON.stringify([r.ticket, type]);
      if (seen.has(key)) { duplicates++; continue; }
      seen.add(key);
    }
    if (type === "decision") {
      decisions.push(r);
    } else if (r.settle === "superseded" && hasTicket(r)) {
      supersededTickets.add(r.ticket);
      bump(supersededByPoint, r.point);
    }
  }
  return {
    decisions: decisions.filter((r) => !(hasTicket(r) && supersededTickets.has(r.ticket))),
    duplicate_ticket_records: duplicates,
    superseded_by_point: supersededByPoint,
    superseded_count: supersededTickets.size,
    unknown_record_type: unknownType,
  };
}

module.exports = { routeByVersion, selectV2Decisions };
