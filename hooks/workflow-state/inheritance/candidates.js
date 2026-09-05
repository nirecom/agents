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

const path = require("path");
const { _encodeCwd, _getTranscriptBase } = require("../../lib/session-title");
const { readState } = require("../state-io");
const { _listJsonlByMtime } = require("../session-id");
const { readLineageAncestors } = require("./lineage");
const { contextMatches } = require("./context-match");

// The transcript directory Claude Code derives from a resolved cwd. The encoder
// is session-title.js's, not a second copy: the two used to disagree on a
// POSIX-style drive-letter cwd, so `--from` and `--list` resolved different
// directories for one session.
function transcriptDirFor(cwd) {
  return path.join(_getTranscriptBase(), _encodeCwd(cwd));
}

// A cwd recorded before any resolve step encodes differently from the resolved
// form on Windows, and old state files still carry that spelling — so the walk
// looks in both rather than silently finding nothing.
function transcriptDirsFor(cwd) {
  const dirs = [transcriptDirFor(cwd)];
  const raw = path.join(_getTranscriptBase(), String(cwd).toLowerCase().replace(/[^a-zA-Z0-9]/g, "-"));
  if (raw !== dirs[0]) dirs.push(raw);
  return dirs;
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

  const scan = [];
  for (const dir of transcriptDirsFor(ctx.cwd)) {
    let files;
    try {
      files = _listJsonlByMtime(dir).slice(0, limit);
    } catch (e) {
      continue;
    }
    for (const { name } of files) scan.push(path.join(dir, name));
  }
  if (scan.length === 0) return [];

  // Lazy require: effective-state → evidence-resolver → state-io, and this
  // module is reached through the inheritance barrel. Deferring keeps the load
  // order acyclic.
  const { evaluateResumability } = require("../effective-state");

  const out = [];
  const seen = new Set();
  for (const jsonlPath of scan) {
    // Both breadcrumb shapes are accepted here (announce line AND forkedFrom),
    // the same reader the lineage gate uses — no second parser (CPR-SSOT).
    const { ancestors: ids } = readLineageAncestors(jsonlPath, null);

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

module.exports = { listRecentContextCandidates, transcriptDirFor, transcriptDirsFor, lastActivityOf };
