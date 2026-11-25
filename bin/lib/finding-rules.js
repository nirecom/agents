"use strict";

// The #2019 rule table for WORKTREE_NOTES.md findings (SSOT): classify(), the reviewer agreement
// check the filing gate (bin/finding-filing-gate) uses, and the #2488 test-failure receiver contract.
// Receiver contract: HANDOFF_BIN (env FINDING_HANDOFF_BIN overrides) is run as `node <bin> <json-path>`;
// the JSON is {section, body, instance, loc}. It accepted the finding iff it exits 0 and prints a line
// `handoff: accepted`. Results: accepted | missing (no file) | failed (spawn error, non-zero, timeout) |
// rejected (exit 0 without the accepted line). The receiver counts as available iff the file exists.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");

const DEFAULT_HANDOFF_BIN = path.join(__dirname, "..", "test-failure-handoff");
const HANDOFF_TIMEOUT_MS = 60000;
const REVIEW_SEVERITIES = Object.freeze({ HIGH: "high", MEDIUM: "medium", LOW: "low", "NOT-DEFECT": "not-defect", "NOT-A-DEFECT": "not-defect" });

function handoffBin() {
  const v = process.env.FINDING_HANDOFF_BIN;
  return typeof v === "string" && v !== "" ? v : DEFAULT_HANDOFF_BIN;
}

function handoffAvailable() {
  try { return fs.statSync(handoffBin()).isFile(); } catch (_e) { return false; }
}

// entry: {severity, instance, testFailure, handoffRejected} as worktree-notes-sections parses it.
// pr-scope does not change the class (#3145): a this-pr finding is settled by openThisPrReason's exits.
function classify(entry, { handoffAvailable: available }) {
  if (entry.testFailure && available && !entry.handoffRejected) return "test-failure-handoff";
  if (entry.severity === "high") return "auto-high";
  if (entry.severity === "low" || entry.severity === "not-defect") return "discard";
  return "final-list";
}

// Why a this-pr finding still blocks write_code / push / release, or null when it is settled.
function openThisPrReason(entry, { fixedVerified }) {
  if (entry.userAccepted) return null;
  if (entry.prScope === "this-pr") {
    if (entry.disposed !== "fixed") return "this-pr-unfixed";
    return fixedVerified ? null : "fixed-unverified";
  }
  if (entry.rescopedFrom === "this-pr" && !Number.isInteger(entry.promotedNumber)) return "rescoped-unfiled";
  return null;
}

// The reviewer's severity in the notes vocabulary, or null when the review cannot be judged.
function reviewSeverity(review) {
  if (!review || typeof review !== "object") return null;
  if (review.status !== "upheld" && review.status !== "disputed") return null;
  if (typeof review.severity !== "string") return null;
  const s = REVIEW_SEVERITIES[review.severity.toUpperCase()];
  return s === undefined ? null : s;
}

// "agree" | "disagree" | "unavailable" — judged from the review JSON only, whoever wrote it.
function reviewerAgrees(review, claimed) {
  const s = reviewSeverity(review);
  if (s === null) return "unavailable";
  const c = typeof claimed === "string" ? REVIEW_SEVERITIES[claimed.toUpperCase()] : undefined;
  return c !== undefined && c === s ? "agree" : "disagree";
}

function runHandoff(entry) {
  const bin = handoffBin();
  if (!handoffAvailable()) return "missing";
  let dir = null;
  try {
    dir = fs.mkdtempSync(path.join(os.tmpdir(), "finding-handoff-"));
    const input = path.join(dir, "finding.json");
    fs.writeFileSync(input, JSON.stringify({
      section: entry.section, body: entry.body, instance: entry.instance || null, loc: entry.loc || null,
    }));
    const r = spawnSync(process.execPath, [bin, input], { encoding: "utf8", timeout: HANDOFF_TIMEOUT_MS, windowsHide: true });
    if (r.error || r.status !== 0) return "failed";
    return /^handoff: accepted\r?$/m.test(String(r.stdout || "")) ? "accepted" : "rejected";
  } catch (_e) {
    return "failed";
  } finally {
    if (dir) { try { fs.rmSync(dir, { recursive: true, force: true }); } catch (_e) { /* best-effort */ } }
  }
}

module.exports = {
  DEFAULT_HANDOFF_BIN,
  REVIEW_SEVERITIES,
  handoffBin,
  handoffAvailable,
  classify,
  openThisPrReason,
  reviewSeverity,
  reviewerAgrees,
  runHandoff,
};
