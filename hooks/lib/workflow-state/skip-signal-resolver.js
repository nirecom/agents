"use strict";
// Skip-signal resolver (#485): advisory predicate that suggests when planning
// steps can be skipped for a trivial change. Read-only module: never mutates
// workflow state; never throws.
//
// isTrivial fails-open to FALSE (uncertain ⇒ run full workflow).
// Mirrors the read-only / fail-open shape of evidence-resolver.js.

const fs = require("fs");
const path = require("path");
const { getWorkflowPlansDir } = require("../workflow-plans-dir");
const { SESSION_ID_VALID_RE } = require("./state-io");

// ---- isTrivial keyword sets (module-level frozen, referenced by tests + describe) ----

// Mechanical-transformation keywords: at least one must be present.
const MECHANICAL_RE = Object.freeze([
  /\brename\b/,
  /\bfix typo\b/,
  /\btypo\b/,
  /\bremove unused\b/,
  /\bextract\b/,
  /\bmove\b/,
]);

// Broad-change keywords: none may be present.
const BROAD_RE = Object.freeze([
  /\bacross the codebase\b/,
  /\bredesign\b/,
  /\bnew interface\b/,
  /\bevery\b/,
  /\bentire\b/,
]);

// New-API-surface declarations: none may be present.
const NEW_API_RE = Object.freeze([
  /\bnew api\b/,
  /\bnew endpoint\b/,
  /\bpublic api\b/,
  /\bnew interface\b/,
  /\bnew command\b/,
  /\bnew sentinel\b/,
]);

// isTrivial(sessionId, plansDir): planning-stage predicate. Reads intent.md TEXT
// only (no staged files exist at planning time). fail-open direction = FALSE.
function isTrivial(sessionId, plansDir) {
  try {
    if (!sessionId || !SESSION_ID_VALID_RE.test(sessionId)) return false;
    const dir = (typeof plansDir === "string" && plansDir.length)
      ? plansDir
      : getWorkflowPlansDir();
    const intentPath = path.join(dir, sessionId + "-intent.md");
    if (!fs.existsSync(intentPath)) return false;
    const text = fs.readFileSync(intentPath, "utf8").toLowerCase();

    const hasMechanical = MECHANICAL_RE.some((re) => re.test(text));
    if (!hasMechanical) return false;
    if (BROAD_RE.some((re) => re.test(text))) return false;
    if (NEW_API_RE.some((re) => re.test(text))) return false;
    return true;
  } catch (e) {
    // fail-open: uncertain ⇒ not trivial ⇒ full workflow.
    return false;
  }
}

// describeSkipSignal(predicate): human-readable description of what a predicate
// checks (mirrors evidence-resolver.js describeEvidence, but returns a single
// joined string). For diagnostics/tests.
function describeSkipSignal(predicate) {
  if (predicate === "isTrivial") {
    return [
      "<PLANS_DIR>/<sessionId>-intent.md contains a mechanical-transformation keyword " +
        "(rename / fix typo / typo / remove unused / extract / move)",
      "AND contains no broad-change keyword (across the codebase / redesign / new interface / every / entire)",
      "AND contains no new-API-surface declaration (new api / new endpoint / public api / new interface / new command / new sentinel)",
      "fail-open direction = false (uncertain ⇒ not trivial ⇒ full workflow)",
    ].join("; ");
  }
  return "";
}

module.exports = {
  isTrivial,
  describeSkipSignal,
  MECHANICAL_RE,
  BROAD_RE,
  NEW_API_RE,
};
