"use strict";
// Human-readable lines for /resume-session. The inheritance sentence is NOT
// composed here — describeGranularInheritance owns it, so adopt-session-state
// and this command can never describe one adoption differently (CPR-SSOT).

const { describeGranularInheritance } =
  require("../../../hooks/workflow-state/inheritance/apply");

const AVAILABILITY_NOTE = Object.freeze({
  "state-and-artifacts": "State file and plan artifacts are both present.",
  "state-only": "The plan artifacts are gone; only the workflow state file remains.",
  "artifacts-only": "The state file aged out; the plan artifacts are still readable.",
  none: "Nothing survives for this session id.",
});

const SUPERVISOR_NOTE = Object.freeze({
  copied: "Supervisor state copied from the session upstream (findings and audit verdicts carry over).",
  absent: "Supervisor state absent upstream — nothing to copy.",
  failed: "Supervisor state copy failed — this session starts without the upstream audit record; expect a fresh audit.",
});

// The two facts the inheritance sentence does not carry: the supervisor copy outcome and
// that plan artifacts stay named after the session upstream (#2304).
function inheritanceSideLines(inheritance, fallbackUpstreamSid) {
  const inh = inheritance || {};
  const upstreamSid = inh.upstream_session_id || fallbackUpstreamSid || "(unknown)";
  const lines = [];
  if (typeof inh.supervisor_state === "string") {
    lines.push(SUPERVISOR_NOTE[inh.supervisor_state] || `Supervisor state: ${inh.supervisor_state}.`);
  }
  lines.push(`Each plan artifact is still named after upstream ${upstreamSid}; it is read from there, not renamed.`);
  return lines;
}

function renderUpstreamView(view) {
  if (!view || view.availability === "none") {
    return `No upstream evidence for ${(view && view.upstream_session_id) || "(unknown)"}.`;
  }
  const lines = [
    `Upstream ${view.upstream_session_id}: ${view.availability}.`,
    AVAILABILITY_NOTE[view.availability] || "",
  ];
  const r = view.inherit_result || {};
  if (r.attempted === false) {
    lines.push(`No state was adopted (${r.reason}).`);
  } else if (r.ok === true) {
    lines.push(describeGranularInheritance(r.inheritance));
    lines.push(...inheritanceSideLines(r.inheritance, view.upstream_session_id));
  } else {
    lines.push(`Adoption was refused: ${r.error}`);
  }
  const t = view.transcript_tail || {};
  lines.push(
    t.available === true
      ? `Transcript tail saved to ${t.path} — summarize it before acting on it.`
      : `No transcript tail (${t.reason}).`
  );
  return lines.filter((l) => l.length > 0).join("\n");
}

function renderCandidateList(records) {
  const rows = Array.isArray(records) ? records : [];
  if (rows.length === 0) return "No upstream sessions found.";
  return rows
    .map((r) => {
      const mark = r.adoptable ? "adoptable" : "reference-only";
      const when = r.last_activity || "unknown";
      const what = r.title || (r.issues && r.issues.length ? "#" + r.issues.join(", #") : "(untitled)");
      return `${r.sid}  ${when}  [${mark}]  ${what}`;
    })
    .join("\n");
}

module.exports = { AVAILABILITY_NOTE, inheritanceSideLines, renderUpstreamView, renderCandidateList };
