"use strict";
// Inputs 2 (combined glossary) and 3 (intent `## Glossary` rows) of the glossary-check
// fingerprint (#2529 I-FP). The glossary is read from the main worktree, the first entry of
// `git worktree list`, the same root bin/lib/codex-glossary.sh uses.

const fs = require("fs");
const { toWindowsPath } = require("../../../lib/branch-diff");
const { parseIntentGlossary } = require("../../../lib/intent-glossary");
const { listMainGlossaryFiles } = require("../../../../bin/lib/glossary-format/files");
const { parseGlossaryFile } = require("../../../../bin/lib/glossary-format/entries");
const { normalizeDefinition } = require("../../../../bin/lib/glossary-provenance");
const { sha256, git } = require("./artifact");

function mainRootOf(repoDir) {
  const out = git(repoDir, ["worktree", "list", "--porcelain"]).toString("utf8");
  const first = out.split(/\r?\n/).find((l) => l.startsWith("worktree "));
  if (!first) throw new Error("git worktree list: no worktree line");
  return toWindowsPath(first.slice("worktree ".length).trim());
}

// combinedGlossary(opts) -> { ok, files: [{ label, category, sha }], terms, digest, legacy }.
function combinedGlossary(opts) {
  try {
    const listed = listMainGlossaryFiles(mainRootOf(opts.repoDir));
    const files = [];
    const terms = [];
    for (const f of listed.files) {
      const buf = fs.readFileSync(toWindowsPath(f.path));
      files.push({ label: f.label, category: f.category, sha: sha256(buf) });
      for (const e of parseGlossaryFile(buf.toString("utf8")).entries) terms.push(e.term);
    }
    files.sort((a, b) => (a.label < b.label ? -1 : a.label > b.label ? 1 : 0));
    const legacy = listed.legacy === true;
    const digest = sha256(JSON.stringify([files.map((f) => [f.label, f.sha]), legacy]));
    return { ok: true, files, terms, digest, legacy };
  } catch (e) {
    return { ok: false, error: "glossary-unavailable", detail: e && e.message ? e.message : String(e) };
  }
}

// The term stays case-exact: the drift scan (glossary-drift.js indexTerms) treats the exact
// spelling as the non-variant form, so a case-only change moves the scan and must move the digest.
function rowsDigest(rows) {
  const keys = rows.map((r) => JSON.stringify([String(r.term), r.category, r.operation,
    normalizeDefinition(r.definition)])).sort();
  return sha256(JSON.stringify(keys));
}

function rowsOfText(text) {
  const rows = typeof text === "string" ? parseIntentGlossary(text).rows : [];
  return { rows, digest: rowsDigest(rows) };
}

// intentRowsOf(sid, rangeText) -> { ok, rows, digest }. rangeText: the intent stage's own
// range; otherwise intent.md is read once here (absent = no rows).
function intentRowsOf(sid, rangeText) {
  if (typeof rangeText === "string") return Object.assign({ ok: true }, rowsOfText(rangeText));
  let text = null;
  try {
    const { resolvePlanArtifactOwner } = require("../../plan-artifact-owner");
    text = fs.readFileSync(toWindowsPath(resolvePlanArtifactOwner(sid, "intent").path), "utf8");
  } catch (e) {
    if (!e || e.code !== "ENOENT") {
      return { ok: false, error: "intent-unreadable", detail: e && e.message ? e.message : String(e) };
    }
  }
  return Object.assign({ ok: true }, rowsOfText(text));
}

module.exports = { mainRootOf, combinedGlossary, intentRowsOf };
