"use strict";
// Recent same-context session listing (#1305).
//
// WHY this still exists after the cwd+branch SCAN was removed as the donor key:
// a true crash-resume — the process died and came back without its session id —
// has no lineage to prove descent with. It is the one case automatic resolution
// cannot serve, so the same walk survives here as an EXPLICIT DISCOVERY surface:
// it only ever produces a list of offers, never an applied inheritance.
//
// Consumers: bin/workflow/adopt-session-state --list, the /workflow-init
// `adopt-prior-state` phase, and session-start's startup-no-lineage notice.

const os = require("os");
const path = require("path");
const { readState } = require("../state-io");
const { _listJsonlByMtime } = require("../session-id");
const { readLineageAncestors } = require("./lineage");
const { contextMatches } = require("./context-match");

// The transcript directory Claude Code derives from a resolved cwd.
function transcriptDirFor(cwd) {
  const encoded = String(cwd).toLowerCase().replace(/[^a-zA-Z0-9]/g, "-");
  const base = process.env.CLAUDE_TRANSCRIPT_BASE_DIR ||
    path.join(os.homedir(), ".claude", "projects");
  return path.join(base, encoded);
}

// Last moment this session recorded anything (ISO string), for display only.
function lastActivityOf(state) {
  let latest = null;
  const events = (state && Array.isArray(state.events)) ? state.events : [];
  for (const e of events) {
    if (e && typeof e.at === "string" && (latest === null || e.at > latest)) latest = e.at;
  }
  return latest || (state && state.created_at) || null;
}

// listRecentContextCandidates(ctx, { limit }) → [{ sessionId, session_id, state,
//   git_branch, last_activity }, ...]
//
// The `.jsonl` files under the cwd's transcript directory are read newest-first;
// each announced session id is resolved to its state file and kept only when it
// would ALSO satisfy the automatic path's own guards — context match plus
// resumability. Offering a candidate resolveInheritanceDonor would refuse would
// invite the user to adopt state the workflow then rejects (CPR-E2E).
function listRecentContextCandidates(ctx, opts) {
  const limit = (opts && typeof opts.limit === "number") ? opts.limit : 10;
  if (!ctx || typeof ctx.cwd !== "string") return [];

  let files;
  try {
    files = _listJsonlByMtime(transcriptDirFor(ctx.cwd)).slice(0, limit);
  } catch (e) {
    return [];
  }

  // Lazy require: effective-state → evidence-resolver → state-io, and this
  // module is reached through the inheritance barrel. Deferring keeps the load
  // order acyclic.
  const { evaluateResumability } = require("../effective-state");

  const dir = transcriptDirFor(ctx.cwd);
  const out = [];
  const seen = new Set();
  for (const { name } of files) {
    // Both breadcrumb shapes are accepted here (announce line AND forkedFrom),
    // the same reader the lineage gate uses — no second parser (CPR-SSOT).
    const { ancestors: ids } = readLineageAncestors(path.join(dir, name), null);

    for (const id of ids) {
      if (seen.has(id)) continue;
      seen.add(id);
      let state;
      try {
        state = readState(id);
      } catch (e) { continue; }
      if (!state) continue;
      if (state.session_id !== id) state = Object.assign({}, state, { session_id: id });
      if (!contextMatches(ctx, state)) continue;
      let verdict;
      try {
        verdict = evaluateResumability(state);
      } catch (e) { continue; }
      if (!verdict || !verdict.eligible) continue;
      out.push({
        sessionId: id,
        session_id: id,
        state,
        git_branch: (state.current && state.current.git_branch) ?? state.git_branch ?? null,
        last_activity: lastActivityOf(state),
      });
    }
  }
  return out;
}

module.exports = { listRecentContextCandidates, transcriptDirFor, lastActivityOf };
