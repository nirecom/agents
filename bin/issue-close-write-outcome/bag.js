"use strict";
// The outcome bag {homeRepo?, issues: [entry]} of bin/issue-close-write-outcome.js: where it lives,
// how it is read, and the one upsert rule — entries match by outcomeKey (repo normalized by homeRepo, N).

const fs = require("fs");
const path = require("path");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const OUTCOME_NAME = "issue-close-outcome.json";
const { normalizeHome, outcomeKey } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "issue-identity"));

function outcomePathFor(sessionId) {
  const { controlPath } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "state-io", "control-dir"));
  return controlPath(sessionId, OUTCOME_NAME, { forWrite: true });
}

function plansDirOrEmpty() {
  try { return require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "workflow-plans-dir")).getWorkflowPlansDir(); } catch (_) { return ""; }
}

function resolveSessionId() {
  try {
    return require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state")).resolveSessionId() || "";
  } catch (_) {
    // session-id-ssot: waived (catch fallback) — reached only when the resolver above is unloadable
    const codeSid = process.env.CLAUDE_CODE_SESSION_ID;
    if (codeSid && /^[A-Za-z0-9_-]+$/.test(codeSid.trim())) return codeSid.trim();
    return "";
  }
}

function getClosesIssues(sessionId, plansDir) {
  const { getClosesIssues: get } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "workflow-state", "session-facts.js"));
  return get(sessionId, { plansDir }) || [];
}

function readBag(p) {
  try {
    const parsed = JSON.parse(fs.readFileSync(p, "utf8"));
    if (parsed && Array.isArray(parsed.issues)) return parsed;
  } catch (_) {}
  return { issues: [] };
}

const bagHome = (bag) => normalizeHome(bag && bag.homeRepo);

function upsertEntry(bag, entry, homeRepo) {
  const key = outcomeKey(entry, homeRepo);
  bag.issues = bag.issues.filter((e) => e && typeof e === "object" && outcomeKey(e, homeRepo) !== key);
  bag.issues.push(entry);
}

const hasKey = (bag, key, homeRepo) => bag.issues.some((e) => e && typeof e === "object" && outcomeKey(e, homeRepo) === key);

function writeBag(p, bag) {
  fs.writeFileSync(p, JSON.stringify(bag, null, 2));
}

module.exports = {
  SCRIPT_CHECKOUT_ROOT, outcomePathFor, plansDirOrEmpty, resolveSessionId, getClosesIssues,
  readBag, bagHome, upsertEntry, hasKey, writeBag,
};
