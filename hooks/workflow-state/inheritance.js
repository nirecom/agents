"use strict";
// Cross-session workflow-state inheritance — donor resolution (#1305).
//
// WHY (CPR-WPH): the pre-#1305 rule was "a new session inherits the most recent
// state recorded on the same cwd+branch". Two sessions started in the same
// worktree are indistinguishable under that rule, so a session the user had
// abandoned (or explicitly /clear'd) silently handed its completed steps to an
// unrelated new one — and the commit gate then accepted completions nobody
// performed.
//
// The key is now PROVABLE DESCENT: the heir must be a fork / resume / compact
// continuation of the donor, evidenced by its own transcript. cwd+branch is
// demoted from selector to guard.
//
// Gate order (each short-circuits with its own decision string):
//   A subagent  → a subagent shares its parent's transcript; never inherits.
//   B source    → only `resume` / `compact` are continuations. `startup` is the
//                 true-crash-resume case: not inherited, but reported so the
//                 explicit adopt path can offer it.
//   C lineage   → ancestors read from the transcript. No evidence, no donor —
//                 there is deliberately NO fallback to the old cwd+branch scan.
//   D ancestor  → the NEAREST ancestor holding a state file is the SOLE
//                 decision-maker. Ancestors with no state file carry no
//                 information and are skipped; the walk never looks PAST a
//                 stateful ancestor to a healthier grandparent, whose steps the
//                 intervening session already superseded.
//   E context   → the guard (inheritance/context-match.js).
//   F resumable → effective-state.evaluateResumability (SSOT for the verdict).
//
// SD-3 conclusion, recorded here so it is not re-litigated: no active-concurrent
// -session detection is needed. Lineage already makes a donor the heir's own
// ancestor, and the donor's file is only ever READ.

const fs = require("fs");
const path = require("path");
const { readState } = require("./state-io");
const { readLineageAncestors } = require("./inheritance/lineage");
const { contextMatches } = require("./inheritance/context-match");
const { listRecentContextCandidates, transcriptDirFor } =
  require("./inheritance/candidates");
const { applyInheritance, INHERIT_ORIGIN } = require("./inheritance/apply");

// SessionStart `source` values that denote a continuation of an earlier session.
const CONTINUATION_SOURCES = ["resume", "compact"];

// An ancestor that itself has no state file may still name ITS OWN ancestors.
// Claude Code keeps every transcript for a cwd in one directory, so the sibling
// file is where that next hop is read from.
function siblingTranscriptPath(transcriptPath, sessionId) {
  try {
    return path.join(path.dirname(transcriptPath), sessionId + ".jsonl");
  } catch (e) {
    return null;
  }
}

// The payload's transcript_path is a HINT, not the address. Claude Code may omit
// it, and on Windows it can arrive in a shell-native form Node cannot open (an
// MSYS `/tmp/...` path never survives readFileSync). The address that always
// holds is derivable: every transcript for a cwd lives in one encoded directory,
// named <session-id>.jsonl. So the hint is used when it resolves and the derived
// location is used otherwise — never a silent "no evidence" (CPR-UNV).
function resolveTranscriptPath(transcriptPath, sessionId, ctx) {
  try {
    if (typeof transcriptPath === "string" && transcriptPath && fs.existsSync(transcriptPath)) {
      return transcriptPath;
    }
    const cwd = ctx && typeof ctx.cwd === "string" ? ctx.cwd : null;
    if (!cwd || !sessionId) return transcriptPath;
    const derived = path.join(transcriptDirFor(cwd), sessionId + ".jsonl");
    return fs.existsSync(derived) ? derived : transcriptPath;
  } catch (e) {
    return transcriptPath;
  }
}

// resolveInheritanceDonor({ sessionId, source, transcriptPath, ctx, agentId })
//   → { donor, decision, candidateSessionId, ancestors }
//
// decision ∈ "inherited" | "subagent" | "source-gated" | "startup-no-lineage"
//          | "no-lineage" | "unreadable-transcript" | "context-mismatch"
//          | "not-resumable:<reason>"
function resolveInheritanceDonor(opts) {
  const { sessionId, source, transcriptPath, ctx, agentId } = opts || {};
  const none = (decision, extra) =>
    Object.assign({ donor: null, decision, candidateSessionId: null, ancestors: [] }, extra || {});

  // Gate A — a subagent runs inside its parent's transcript, so every later gate
  // would happily hand it the parent's state. It must never own workflow state.
  if (agentId) return none("subagent");

  // Gate B — source.
  if (source === "startup") return none("startup-no-lineage");
  if (CONTINUATION_SOURCES.indexOf(source) === -1) return none("source-gated");

  // Gate C — lineage evidence.
  const tPath = resolveTranscriptPath(transcriptPath, sessionId, ctx);
  const { ancestors, readable } = readLineageAncestors(tPath, sessionId);
  if (!readable) return none("unreadable-transcript");
  if (ancestors.length === 0) return none("no-lineage", { ancestors: [] });

  // Gate D — walk outward until an ancestor with a state file is found. Expand
  // stateless ancestors through their own transcripts so a chain of
  // never-recorded sessions does not hide the session that did the work.
  const queue = ancestors.slice();
  const visited = new Set(queue);
  let candidateSessionId = null;
  let donorState = null;
  while (queue.length > 0) {
    const id = queue.shift();
    let state = null;
    try {
      state = readState(id);
    } catch (e) { state = null; }
    if (state) {
      candidateSessionId = id;
      // The canonical session ID is the one the lineage named, not
      // state.session_id — a migrated or compacted record may carry a stale or
      // placeholder value, and callers key plan artifacts off this id.
      donorState = state.session_id !== id
        ? Object.assign({}, state, { session_id: id })
        : state;
      break;
    }
    const sib = siblingTranscriptPath(tPath, id);
    if (!sib) continue;
    const next = readLineageAncestors(sib, id);
    for (const a of next.ancestors) {
      if (visited.has(a)) continue;
      visited.add(a);
      queue.push(a);
    }
  }

  if (!donorState) return none("no-lineage", { ancestors });

  const rejected = (decision) => ({
    donor: null, decision, candidateSessionId, ancestors,
  });

  // Gate E — context guard.
  if (!contextMatches(ctx, donorState)) return rejected("context-mismatch");

  // Gate F — resumability (SSOT: effective-state).
  // Lazy require keeps the load order acyclic (effective-state →
  // evidence-resolver → state-io, and this module is reached via the barrel).
  const { evaluateResumability } = require("./effective-state");
  let verdict;
  try {
    verdict = evaluateResumability(donorState);
  } catch (e) {
    verdict = { eligible: true, reason: null };
  }
  if (!verdict || !verdict.eligible) {
    return rejected("not-resumable:" + ((verdict && verdict.reason) || "unknown"));
  }

  return { donor: donorState, decision: "inherited", candidateSessionId, ancestors };
}

module.exports = {
  resolveInheritanceDonor,
  listRecentContextCandidates,
  applyInheritance,
  INHERIT_ORIGIN,
  CONTINUATION_SOURCES,
};
