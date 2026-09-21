#!/usr/bin/env node
"use strict";
// bin/sweep-plan-headings.js — normalize existing plan artifacts against the
// plan-schema SSOT (#2339). Two passes: (1) rewrite localized H2 headings to
// their canonical English names (all artifact types); (2) reorder outline
// sections into canonical order (outline only), leaving unknown sections in
// place. Dry-run by default (preview only); --fix writes changes. --all sweeps
// every intent/outline/detail artifact in the workflow plans dir.
// Usage: sweep-plan-headings.js [--fix] [--all] [<file>...]

const fs = require("fs");
const path = require("path");
const { CANONICAL_SECTIONS, canonicalizeHeading } = require("../hooks/lib/plan-schema");
const { normalizeCwd } = require("../hooks/lib/path-normalize");
const { getWorkflowPlansDir } = require("../hooks/lib/workflow-plans-dir");

// H2 only: exactly two leading hashes (## ), never ### or deeper.
const H2_RE = /^##(?!#)\s+(.+?)\s*$/;
const FENCE_RE = /^\s*(```|~~~)/;
const ARTIFACT_RE = /-(intent|outline|detail)\.md$/;

// Resolve a file's artifact type from its basename, or null when unrecognized.
function artifactTypeOf(file) {
  const m = path.basename(file).match(ARTIFACT_RE);
  return m ? m[1] : null;
}

// Detected end-of-line for round-tripping a file's dominant style.
function eolOf(content) {
  return content.includes("\r\n") ? "\r\n" : "\n";
}

// Pass 1: rewrite each fence-free H2 whose text resolves to a canonical name
// that differs from what is written. Returns the new content and the renames.
function normalizeHeadings(content, eol) {
  const lines = content.split(/\r?\n/);
  const renames = [];
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    if (FENCE_RE.test(lines[i])) { inFence = !inFence; continue; }
    if (inFence) continue;
    const m = lines[i].match(H2_RE);
    if (!m) continue;
    const text = m[1];
    const canon = canonicalizeHeading(text);
    if (canon && canon !== text) {
      lines[i] = "## " + canon;
      renames.push({ line: i + 1, from: text, to: canon });
    }
  }
  return { content: lines.join(eol), renames };
}

// Split content into a preamble (everything before the first fence-free H2) and
// an ordered list of sections, each { canon, known, lines }. canon is the
// canonical name when the heading resolves and belongs to the outline schema.
function splitOutlineSections(content) {
  const lines = content.split(/\r?\n/);
  const order = CANONICAL_SECTIONS.outline;
  const heads = [];
  let inFence = false;
  for (let i = 0; i < lines.length; i++) {
    if (FENCE_RE.test(lines[i])) { inFence = !inFence; continue; }
    if (inFence) continue;
    const m = lines[i].match(H2_RE);
    if (m) heads.push({ index: i, text: m[1] });
  }
  if (heads.length === 0) return { preamble: lines, sections: [] };
  const preamble = lines.slice(0, heads[0].index);
  const sections = heads.map((h, k) => {
    const end = k + 1 < heads.length ? heads[k + 1].index : lines.length;
    const canon = canonicalizeHeading(h.text);
    const known = canon !== null && order.includes(canon);
    return { canon: known ? canon : null, known, lines: lines.slice(h.index, end) };
  });
  return { preamble, sections };
}

// Pass 2 (outline only): reorder the canonical sections into schema order while
// pinning unknown sections at their original slots. Returns new content, whether
// anything moved, and the unknown section headings left in place.
function reorderOutline(content, eol) {
  const order = CANONICAL_SECTIONS.outline;
  const { preamble, sections } = splitOutlineSections(content);
  if (sections.length === 0) return { content, moved: false, unknownKept: [] };

  const knownSlots = [];
  sections.forEach((s, idx) => { if (s.known) knownSlots.push(idx); });
  const sorted = knownSlots
    .map((slot) => ({ s: sections[slot], slot }))
    .sort((a, b) => (order.indexOf(a.s.canon) - order.indexOf(b.s.canon)) || (a.slot - b.slot))
    .map((x) => x.s);

  const result = sections.slice();
  let moved = false;
  knownSlots.forEach((slot, k) => {
    if (result[slot] !== sorted[k]) moved = true;
    result[slot] = sorted[k];
  });

  const unknownKept = sections.filter((s) => !s.known).map((s) => s.lines[0].replace(H2_RE, "$1"));
  if (!moved) return { content, moved: false, unknownKept };
  const out = preamble.concat(...result.map((s) => s.lines));
  return { content: out.join(eol), moved: true, unknownKept };
}

// Sweep one file: apply pass 1 (+ pass 2 for outline), report, and write when
// fix is set. Returns "changed", "clean", or "error".
function sweepFile(rawFile, fix) {
  const file = normalizeCwd(rawFile) || rawFile;
  const type = artifactTypeOf(file);
  if (!type) {
    process.stderr.write(`skip (unrecognized artifact type): ${rawFile}\n`);
    return "error";
  }
  let content;
  try {
    content = fs.readFileSync(file, "utf8");
  } catch (e) {
    process.stderr.write(`skip (cannot read): ${rawFile}: ${e.message}\n`);
    return "error";
  }
  const eol = eolOf(content);
  const p1 = normalizeHeadings(content, eol);
  let working = p1.content;
  let reorder = { moved: false, unknownKept: [] };
  if (type === "outline") {
    reorder = reorderOutline(working, eol);
    working = reorder.content;
  }
  const changed = p1.renames.length > 0 || reorder.moved;

  const label = fix ? "fix" : "dry-run";
  process.stdout.write(`${file} [${type}] (${label})\n`);
  for (const r of p1.renames) {
    process.stdout.write(`  rename L${r.line}: "${r.from}" -> "${r.to}"\n`);
  }
  if (reorder.moved) process.stdout.write("  reorder: outline sections moved to canonical order\n");
  if (type === "outline" && reorder.unknownKept.length > 0) {
    process.stdout.write(`  kept in place (unknown): ${reorder.unknownKept.join(", ")}\n`);
  }
  if (!changed) { process.stdout.write("  no changes\n"); return "clean"; }

  if (fix) {
    const tmp = file + ".sweep-tmp";
    try {
      fs.writeFileSync(tmp, working, "utf8");
      fs.renameSync(tmp, file);
    } catch (e) {
      try { fs.unlinkSync(tmp); } catch (_) { /* best-effort cleanup */ }
      process.stderr.write(`  write failed: ${e.message}\n`);
      return "error";
    }
  }
  return "changed";
}

// Collect the intent/outline/detail artifacts in the workflow plans dir.
function collectAll() {
  const dir = normalizeCwd(getWorkflowPlansDir()) || getWorkflowPlansDir();
  let entries;
  try {
    entries = fs.readdirSync(dir);
  } catch (e) {
    process.stderr.write(`--all: cannot read plans dir ${dir}: ${e.message}\n`);
    return null;
  }
  return entries.filter((f) => ARTIFACT_RE.test(f)).map((f) => path.join(dir, f));
}

function main() {
  const argv = process.argv.slice(2);
  let fix = false;
  let all = false;
  const files = [];
  for (const a of argv) {
    if (a === "--fix") fix = true;
    else if (a === "--all") all = true;
    else if (a.startsWith("--")) {
      process.stderr.write(`unknown option: ${a}\n`);
      process.exit(2);
    } else files.push(a);
  }

  let targets;
  if (all) {
    if (files.length > 0) process.stderr.write("--all set: ignoring explicit file arguments\n");
    targets = collectAll();
    if (targets === null) process.exit(1);
  } else if (files.length > 0) {
    targets = files;
  } else {
    process.stderr.write("usage: sweep-plan-headings.js [--fix] [--all] [<file>...]\n");
    process.exit(2);
  }

  let errors = 0;
  for (const f of targets) {
    if (sweepFile(f, fix) === "error") errors++;
  }
  if (!fix) process.stdout.write("\n(dry-run: no files written; pass --fix to apply)\n");
  process.exit(errors > 0 ? 1 : 0);
}

main();
