"use strict";
// The merge parents of the staged tests/ paths (#2812), shared by the four tests-frontmatter gates:
// one resolution per snapshot (one commit), and the HEAD-only fallback note at most once.
//   parentsOf({ context, snapshot, files }) -> { state, record(rel), note() -> [message], blobs(oids) }

const MP = require("../../../lib/merge-parents");
const G = require("../../../lib/test-gates/git-blobs");
const { err } = require("../../output");

const CACHE = new WeakMap();

function parentsOf({ context, snapshot, files }) {
  const hit = CACHE.get(snapshot);
  if (hit) return hit;
  const rels = (files || []).filter((f) => f.startsWith("tests/"));
  const set = MP.loadParents(context.repoTop, rels);
  const p = {
    state: set.state,
    record: (rel) => MP.recordFor(set, rel, context.repoTop),
    note: () => {
      const l = MP.noteLine(set);
      return l ? [err(l)] : [];
    },
    // blobs(oids) -> Map oid -> Buffer; a failed batch throws (git-blobs.js).
    blobs: (oids) => G.blobs(context.repoTop, context.env || process.env, oids.filter(Boolean)),
  };
  CACHE.set(snapshot, p);
  return p;
}

module.exports = { parentsOf };
