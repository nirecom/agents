"use strict";
// Composition of the PM instructions block (#3019): issues -> role -> sections -> rendered text.
// buildInjection throws (SectionError for the md, anything else for state); getPmInstructionsInjection
// is the fail-open face for the hooks: null on every failure, one stderr line for an md failure.

const { createDeadline } = require("../hook-deadline");
const { getClosesIssues } = require("../../workflow-state/session-facts");
const { TIMINGS, SectionError, loadSections, sectionsFor } = require("./sections");
const { resolveRole } = require("./role");
const { render } = require("./render");

const CLI_BUDGET_MS = 20000;

// buildInjection(sessionId, {timing, issues, deadline, reserveMs, cwd}) -> string | null.
function buildInjection(sessionId, opts) {
  const o = opts || {};
  const timing = o.timing || "session-start";
  if (!TIMINGS.includes(timing)) return null;
  const issues = Array.isArray(o.issues) ? o.issues : getClosesIssues(sessionId);
  const deadline = o.deadline || createDeadline({ hookTimeoutMs: CLI_BUDGET_MS });
  const role = resolveRole(sessionId, { issues, deadline, reserveMs: o.reserveMs, cwd: o.cwd });
  if (!role.role) return null;
  const loaded = loadSections();
  return render(role, timing, sectionsFor(role.role, timing, loaded));
}

function getPmInstructionsInjection(sessionId, opts) {
  try {
    return buildInjection(sessionId, opts);
  } catch (e) {
    if (e instanceof SectionError) {
      try { process.stderr.write(`pm-instructions: ${e.reason}\n`); } catch (_) { /* fail-open */ }
    }
    return null;
  }
}

module.exports = { buildInjection, getPmInstructionsInjection };
