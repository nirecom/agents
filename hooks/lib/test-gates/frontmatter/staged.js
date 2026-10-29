"use strict";
// --staged of the frontmatter check (#2507 D7; ports that mode of bin/check-test-frontmatter.sh
// and its self-impl.sh sibling). stagedCheck(files, io) -> { rc, lines } (every line for stderr).
// io: { repoRoot, relOf(f), staged(rel), work(f), head(rel), isFile(abs) }; staged / work / head
// give a Buffer or null (head null: HEAD lacks rel). Nothing is written to disk.

const path = require("path");
const R = require("../registry");
const S = require("../source");
const { readHeaders } = require("../headers");
const { judge } = require("../self-impl-judge");
const { isSupportedTest, isTestEntrypoint, isFlatTest } = require("./rules");
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

function flatLine(f, m) {
  const code = R.fieldValue(m.entry, "diagnostics.flatRejectCode") || "";
  const label = R.fieldValue(m.entry, "diagnostics.nameLabel") || "";
  return `${code}: ${f} (new ${label} tests must live under tests/<category>/; categories: ${R.CATEGORIES.join(" ")})`;
}

function stagedCheck(files, io) {
  const lines = [];
  const queue = [];
  let fail = false;
  for (const { f, rel } of selected(files, io)) {
    const head = io.head(rel);
    const flat = isFlatTest(rel);
    if (flat && !head) {
      lines.push(flatLine(f, flat));
      fail = true;
      continue;
    }
    const buf = io.staged(rel) || io.work(f);
    if (!buf) continue;
    const text = captured(buf);
    const h = readHeaders(text, f);
    const bad = checkContent(f, h.tests, h.tags);
    const ep = isTestEntrypoint(rel);
    if (ep && io.repoRoot && io.isFile(path.posix.join(io.repoRoot, ep.hlPath)) && !head && !harnessSourced(text, ep.hlRe)) {
      bad.push(`MISSING_HARNESS_SOURCE: ${f}`);
    }
    lines.push(...bad);
    if (bad.length) fail = true;
    const copy = Buffer.from(normalizeContent(text), "utf8");
    if (head && head.equals(copy)) continue;
    queue.push({ name: rel, file: S.mem(rel, copy), head: head ? S.mem(rel, head) : null });
  }
  for (const q of queue) {
    const j = judge(q);
    lines.push(...j.lines.map((l) => l.text));
    if (j.high) fail = true;
  }
  return { rc: fail ? 1 : 0, lines };
}

module.exports = { stagedCheck, selected, captured };
