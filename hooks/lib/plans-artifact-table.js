"use strict";
// hooks/lib/plans-artifact-table.js
// Reads one plans-artifact data file (plans-artifact-registry.json) into frozen tables.
// Shared by the registry (its own adjacent file) and bin/check-plans-artifacts (the judged
// tree's file), so a table is always data: nothing from the tree it sits in is executed.
// A source may name %FORMAT% (built from formatTokens) or a "fragments" key as %NAME%;
// substitution is one pass. retention / reason pass through unvalidated — the registry's
// retentionCoverageErrors and the lint report those by kind.
const fs = require("fs");

const PLANS_ARTIFACT_TABLE_REL = "hooks/lib/plans-artifact-registry.json";
const FORMAT_TOKEN_RE = /^[a-z0-9]+(?:-[a-z0-9]+)*$/;
const PLACEHOLDER_RE = /%([A-Z_]+)%/g;

const isObject = (v) => v !== null && typeof v === "object" && !Array.isArray(v);
const isText = (v) => typeof v === "string" && v.length > 0;

function loadPlansArtifactTable(file) {
  const bad = (reason) => new Error(`${file}: ${reason}`);
  let data;
  try { data = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { throw bad(e.message); }
  if (!isObject(data)) throw bad("top level is not an object");

  const tokens = data.formatTokens;
  if (!Array.isArray(tokens) || tokens.length === 0) throw bad("formatTokens is missing or empty");
  for (const t of tokens) {
    if (typeof t !== "string" || !FORMAT_TOKEN_RE.test(t)) throw bad(`invalid format token: ${JSON.stringify(t)}`);
  }
  const parts = new Map(Object.entries(isObject(data.fragments) ? data.fragments : {}));
  parts.set("FORMAT", `(?:${tokens.join("|")})`);

  const compile = (source, label, wrap) => {
    const expanded = source.replace(PLACEHOLDER_RE, (m, name) => (typeof parts.get(name) === "string" ? parts.get(name) : m));
    const left = expanded.match(PLACEHOLDER_RE);
    if (left) throw bad(`${label}: unresolved placeholder ${left[0]}`);
    try { return new RegExp(wrap ? `^${expanded}$` : expanded); } catch (e) { throw bad(`${label}: ${e.message}`); }
  };
  const list = (key, build) => {
    if (!Array.isArray(data[key])) throw bad(`${key} is missing or not an array`);
    return Object.freeze(data[key].map((entry, i) => Object.freeze(build(isObject(entry) ? entry : {}, `${key}[${i}]`))));
  };
  const kindEntry = (e, label) => {
    if (!isText(e.kind) || !isText(e.source)) throw bad(`${label}: kind and source must be non-empty strings`);
    return { kind: e.kind, re: compile(e.source, `${label} (${e.kind})`, true), retention: e.retention };
  };
  const exceptionEntry = (e, label) => {
    if (!isText(e.file) || !isText(e.pattern)) throw bad(`${label}: file and pattern must be non-empty strings`);
    return { file: e.file, pattern: compile(e.pattern, `${label} (${e.file})`, false), reason: e.reason };
  };

  return Object.freeze({
    formatTokens: Object.freeze([...tokens]),
    controlKinds: list("controlKinds", kindEntry),
    artifactKinds: list("artifactKinds", kindEntry),
    sourceLintExceptions: list("sourceLintExceptions", exceptionEntry),
  });
}

module.exports = { PLANS_ARTIFACT_TABLE_REL, loadPlansArtifactTable };
