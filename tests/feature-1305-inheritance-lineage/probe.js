"use strict";

// Test probe for the #1305 inheritance API (test asset — not production code).
//
// CONTRACT the implementation must honour (see the confirmed detail plan §2b/§2d):
//
//   resolveInheritanceDonor({ sessionId, source, transcriptPath, ctx, agentId })
//     -> { donor, decision, candidateSessionId, ancestors }
//   decision ∈ "inherited" | "subagent" | "source-gated" | "startup-no-lineage"
//            | "no-lineage" | "unreadable-transcript" | "context-mismatch"
//            | "not-resumable:<reason>"
//
//   readLineageAncestors(transcriptPath) -> { readable, ancestors }
//     ancestors: nearest-first, de-duplicated, self excluded.
//
//   listRecentContextCandidates(ctx) -> [{ session_id, ... }, ...]
//
// Emits flat `key=value` lines so the bash side needs no extra node process.

const path = require("path");

const AGENTS = process.env.AGENTS_DIR_NODE;
const args = JSON.parse(process.argv[2]);

function out(kv) {
  for (const [k, v] of Object.entries(kv)) console.log(`${k}=${v}`);
}

function loadFn(name) {
  const candidates = [
    path.join(AGENTS, "hooks", "workflow-state", "inheritance.js"),
    path.join(AGENTS, "hooks", "workflow-state", "inheritance", "lineage.js"),
    path.join(AGENTS, "hooks", "workflow-state", "inheritance", "context-match.js"),
    path.join(AGENTS, "hooks", "workflow-state", "inheritance", "candidates.js"),
  ];
  for (const p of candidates) {
    let mod;
    try {
      mod = require(p);
    } catch (e) {
      continue;
    }
    if (mod && typeof mod[name] === "function") return mod[name];
  }
  return null;
}

const fnName = args.fn || "resolveInheritanceDonor";
const fn = loadFn(fnName);
if (!fn) {
  out({ error: "MISSING_EXPORT:" + fnName });
  process.exit(0);
}

try {
  if (fnName === "resolveInheritanceDonor") {
    const r = fn({
      sessionId: args.sessionId,
      source: args.source,
      transcriptPath: args.transcriptPath,
      ctx: args.ctx,
      agentId: args.agentId,
    });
    out({
      decision: r && r.decision != null ? r.decision : "NONE",
      donor: r && r.donor && r.donor.session_id ? r.donor.session_id : "NONE",
      candidate: r && r.candidateSessionId != null ? r.candidateSessionId : "NONE",
      ancestors: r && Array.isArray(r.ancestors) ? r.ancestors.join(",") : "NONE",
    });
  } else if (fnName === "readLineageAncestors") {
    const r = fn(args.transcriptPath);
    out({
      readable: r && r.readable === true ? "true" : "false",
      ancestors: r && Array.isArray(r.ancestors) ? r.ancestors.join(",") : "NONE",
    });
  } else if (fnName === "listRecentContextCandidates") {
    const r = fn(args.ctx);
    const ids = (Array.isArray(r) ? r : []).map((c) =>
      typeof c === "string" ? c : (c && (c.session_id || c.sessionId)) || "?",
    );
    out({ candidates: ids.join(",") });
  }
} catch (e) {
  out({ error: String((e && e.message) || e) });
}
