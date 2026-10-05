"use strict";
// hooks/lib/jev/registry.js — data only: the judgment points the broker may shadow.
// Paths resolve from __dirname, so a worktree's hooks load that worktree's adapter.
// normalizer: a module whose normalize(raw) the broker requires and calls in-process.

const path = require("path");

const REPO_ROOT = path.resolve(__dirname, "..", "..", "..");

const REGISTRY = Object.freeze({
  "complexity-judge": Object.freeze({
    adapter: path.join(REPO_ROOT, "bin", "workflow", "lib", "jev-complexity-adapter.js"),
    normalizer: path.join(REPO_ROOT, "bin", "workflow", "normalize-judge-signals"),
    confidence_threshold: 0.75,
    mode: "shadow",
    sampling_rate: 1,
    fallback: "S0-undecidable",
    subagent_type: "complexity-judge",
  }),
});

// The entry for a point name, or null. Own keys only: a name read from a file or a
// payload ("constructor", "__proto__") must not resolve to an inherited property.
function registryEntry(point) {
  return typeof point === "string" && Object.prototype.hasOwnProperty.call(REGISTRY, point) ? REGISTRY[point] : null;
}

module.exports = { REGISTRY, REPO_ROOT, registryEntry };
