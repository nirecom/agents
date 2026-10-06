"use strict";

// Source-inheritance graph (#2512 stage 4). A child inherits a pin only when every
// resolved parent edge carries it — the parent's effective pin precedes the source
// line. A file with no resolved parent is top-level; a cycle counts as unpinned.

const { before } = require("./classify");

const ORIGIN = { line: 0, idx: 0 };

// buildGraph(units) — units: Map<absPath, { facts, edges }> → { pinAt(file, kind) }.
function buildGraph(units) {
  const parents = new Map();
  for (const [file, u] of units) {
    for (const e of u.edges) {
      if (!units.has(e.target) || e.target === file) continue;
      if (!parents.has(e.target)) parents.set(e.target, []);
      parents.get(e.target).push({ from: file, at: e.at });
    }
  }

  // pinAt(file, kind, visiting) → earliest effective pin position, or null.
  function pinAt(file, kind, visiting = new Set()) {
    const own = units.get(file).facts.own[kind];
    const ps = parents.get(file) || [];
    if (ps.length === 0 || visiting.has(file)) return own;
    visiting.add(file);
    const inherited = ps.every((p) => {
      const pp = pinAt(p.from, kind, visiting);
      return pp !== null && before(pp, p.at);
    });
    visiting.delete(file);
    return inherited ? ORIGIN : own;
  }

  return { pinAt: (file, kind) => pinAt(file, kind) };
}

module.exports = { buildGraph };
