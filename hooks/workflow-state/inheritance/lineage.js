"use strict";
// Transcript lineage reader (#1305).
//
// WHY: inheritance used to be keyed on "same cwd + same branch", which cannot
// tell a genuine continuation apart from an unrelated session that merely
// started in the same worktree. The replacement key is PROVABLE DESCENT, and
// this module is the only place that evidence is read.
//
// Two evidence shapes, both written by Claude Code itself:
//   1. `forkedFrom.sessionId` — stamped on every row carried over when a session
//      is forked / resumed / compacted out of an earlier one.
//   2. a copied SessionStart / PostCompact hook attachment whose stdout carries
//      the announce line (hooks/lib/session-announce.js).
//
// Fail-open per line (a malformed row is skipped), fail-closed per file (an
// unreadable transcript reports readable:false, never an empty ancestor list —
// the caller must be able to tell "no ancestors" from "no evidence available").

const fs = require("fs");
const { SESSION_ID_ANNOUNCE_RE } = require("../../lib/session-announce");
const { SESSION_ID_VALID_RE } = require("../state-io/core");

const LINEAGE_HOOK_EVENTS = ["SessionStart", "PostCompact"];

// readLineageAncestors(transcriptPath, selfSessionId?)
//   → { ancestors: string[], readable: boolean }
// `ancestors` is de-duplicated by first occurrence, nearest-first, and never
// contains the transcript's OWN session.
//
// Self-exclusion cannot depend on the caller passing selfSessionId: the id is
// carried by the transcript itself (`entry.sessionId` on every row it wrote),
// and the announce line the current session emitted is copied into the same
// file as the ancestors' ones. So the file is read in two passes — collect
// every sessionId the file claims as its own, then keep only the ids that are
// not one of them. selfSessionId, when given, is merely one more such id.
function readLineageAncestors(transcriptPath, selfSessionId) {
  if (typeof transcriptPath !== "string" || !transcriptPath) {
    return { ancestors: [], readable: false };
  }

  let content;
  try {
    content = fs.readFileSync(transcriptPath, "utf8");
  } catch (e) {
    return { ancestors: [], readable: false };
  }

  // Pass 1: parse once, and learn which ids this transcript claims as its own.
  const entries = [];
  const selfIds = new Set();
  if (typeof selfSessionId === "string" && selfSessionId) selfIds.add(selfSessionId);
  for (const line of content.split("\n")) {
    if (!line.trim()) continue;
    let entry;
    try {
      entry = JSON.parse(line);
    } catch (e) {
      continue; // fail-open: a malformed row is not evidence, nor an error
    }
    if (!entry || typeof entry !== "object") continue;
    entries.push(entry);
    if (typeof entry.sessionId === "string" && entry.sessionId) selfIds.add(entry.sessionId);
  }

  const seen = new Set();
  const ancestors = [];
  const add = (id) => {
    if (typeof id !== "string" || !id) return;
    if (!SESSION_ID_VALID_RE.test(id)) return; // not a well-formed session id — never used as a path segment
    if (selfIds.has(id)) return;
    if (seen.has(id)) return;
    seen.add(id);
    ancestors.push(id);
  };

  // Pass 2: collect the ancestry evidence, nearest-first by file order.
  for (const entry of entries) {
    if (entry.forkedFrom && typeof entry.forkedFrom === "object") {
      add(entry.forkedFrom.sessionId);
    }

    const att = entry.attachment;
    if (!att || typeof att !== "object") continue;
    if (att.exitCode !== 0) continue;
    if (LINEAGE_HOOK_EVENTS.indexOf(att.hookEvent) === -1) continue;
    const m = String(att.stdout || "").match(SESSION_ID_ANNOUNCE_RE);
    if (m) add(m[1]);
  }

  return { ancestors, readable: true };
}

module.exports = { readLineageAncestors, LINEAGE_HOOK_EVENTS };
