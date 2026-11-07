"use strict";
// --staged of the frontmatter check (#2507 D7; ports that mode of bin/check-test-frontmatter.sh
// and its self-impl.sh sibling). stagedCheck(files, io) -> { rc, lines } (every line for stderr).
// io: { repoRoot, relOf(f), staged(rel), work(f), head(rel), isFile(abs), parents?(rel) }; staged /
// work / head give a Buffer or null. parents (#2812) gives { inParent, same, heads: [Buffer], base }:
// heads holds two (with base, or null when the merge-base lacks rel) only for a judgeable 3-way.

const path = require("path");
const R = require("../registry");
const S = require("../source");
const { readHeaders } = require("../headers");
const { judge } = require("../self-impl-judge");
const { isSupportedTest, isTestEntrypoint, isFlatTest, coversMismatch } = require("./rules");
const { normalizeContent, checkContent, harnessSourced } = require("./content");

const ARCHIVE = /(^|\/)tests\/_archive\//;
const UNDER_TESTS = /(^|\/)tests\//;

// selected(files, io) — [{ f, rel }] of the files the check covers.
function selected(files, io) {
  const out = [];
  for (const f of files) {
    if (ARCHIVE.test(f) || !UNDER_TESTS.test(f) || !isSupportedTest(f)) continue;
    out.push({ f, rel: io.relOf(f) });
  }
  return out;
}

// captured(buf) — the text `$(...)` captures: NULs dropped, trailing LFs cut.
const captured = (buf) => buf.toString("utf8").replace(/\0/g, "").replace(/\n+$/, "");

function flatLine(f, m, root) {
  const code = R.fieldValue(m.entry, "diagnostics.flatRejectCode") || "";
  const label = R.fieldValue(m.entry, "diagnostics.nameLabel") || "";
  return `${code}: ${f} (new ${label} tests must live under ${R.layoutFor(root).dir}/<category>/; categories: ${R.categoriesFor(root).join(" ")})`;
}

// harnessMode(io) — "on" / "off" from the repo's .agents.json testHarness (#2473), "legacy" for an
// uninitialized repo: the harness source is required only when the helper file exists, as before.
function harnessMode(io) {
  const l = R.layoutFor(io.repoRoot || null);
  return l.initialized ? l.testHarness : "legacy";
}

function missingHarness(io, mode, ep, text) {
  if (!ep || mode === "off") return false;
  if (mode === "legacy" && !(io.repoRoot && io.isFile(path.posix.join(io.repoRoot, ep.hlPath)))) return false;
  return !harnessSourced(text, ep.hlRe) && !(ep.hlShared && harnessSourced(text, ep.hlShared));
}

// parentsOf(io, rel) — { inParent, same, heads, base } (#2812); an io without parents() has HEAD alone.
function parentsOf(io, rel) {
  if (typeof io.parents === "function") return io.parents(rel);
  const head = io.head(rel);
  return { inParent: Boolean(head), same: false, heads: head ? [head] : [], base: null };
}

function stagedCheck(files, io) {
  const lines = [];
  const queue = [];
  let fail = false;
  const root = io.repoRoot || null;
  const mode = harnessMode(io);
  for (const { f, rel } of selected(files, io)) {
    const p = parentsOf(io, rel);
    const head = p.inParent;
    const flat = isFlatTest(rel, root);
    if (flat && !head) {
      lines.push(flatLine(f, flat, root));
      fail = true;
      continue;
    }
    const buf = io.staged(rel) || io.work(f);
    if (!buf) continue;
    const text = captured(buf);
    const h = readHeaders(text, f);
    const bad = checkContent(f, h.tests, h.tags);
    if (!head && missingHarness(io, mode, isTestEntrypoint(rel, root), text)) bad.push(`MISSING_HARNESS_SOURCE: ${f}`);
    lines.push(...bad);
    if (bad.length) fail = true;
    const warn = head ? null : coversMismatch(f, rel, root, h.tests);
    if (warn) lines.push(warn);
    // Equal to a parent's blob, or testHarness off: nothing to judge for a self-implemented harness.
    if (p.same || mode === "off") continue;
    const copy = Buffer.from(normalizeContent(text), "utf8");
    if (p.heads.some((b) => b.equals(copy))) continue;
    const heads = p.heads.map((b) => S.mem(rel, b));
    queue.push({ name: rel, file: S.mem(rel, copy), heads, base: heads[1] && p.base ? S.mem(rel, p.base) : null });
  }
  for (const q of queue) {
    const j = judge(q);
    lines.push(...j.lines.map((l) => l.text));
    if (j.high) fail = true;
  }
  return { rc: fail ? 1 : 0, lines };
}

module.exports = { stagedCheck, selected, captured };
