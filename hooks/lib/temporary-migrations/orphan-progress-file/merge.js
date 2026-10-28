"use strict";
// Temporary (#2748): deleted with this folder per the deletion-condition in bin/migrate-orphan-progress-files.
// Folds every orphan progress file into the first generation's progress file text. Pure text work:
// a base the orphans add nothing to comes back byte-identical, so a re-run never rewrites it.

const path = require("path");
const { isFile } = require("./discover");

const STAGE_LINE_RE = /^\s*- (intent|outline|detail):\s*(.*?)\s*$/;

function toLines(text) {
  const eol = String(text).includes("\r\n") ? "\r\n" : "\n";
  return { eol, lines: String(text).split(/\r?\n/) };
}

const headingLevel = (line) => {
  const m = /^(#{1,6}) /.exec(line);
  return m ? m[1].length : 0;
};

// sectionRange(lines, heading, from, to) -> { at, end } | null; end is the next heading of the same or higher level.
function sectionRange(lines, heading, from, to) {
  const level = headingLevel(heading);
  const stop = to === undefined ? lines.length : to;
  for (let i = from || 0; i < stop; i++) {
    if (lines[i].trimEnd() !== heading) continue;
    let end = i + 1;
    while (end < stop && !(headingLevel(lines[end]) && headingLevel(lines[end]) <= level)) end++;
    return { at: i, end };
  }
  return null;
}

function lastNonEmpty(lines, from, to) {
  for (let i = to - 1; i >= from; i--) if (lines[i].trim()) return i;
  return -1;
}

// bodyLines(lines) -> the lines with blank edges dropped; blank lines inside keep paragraphs and code blocks apart.
function bodyLines(lines) {
  const out = lines.map((l) => l.trimEnd());
  while (out.length && !out[0]) out.shift();
  while (out.length && !out[out.length - 1]) out.pop();
  return out;
}

const FENCE_RE = /^\s*(```|~~~)/;
const ITEM_RE = /^\s*([-*+]|\d+[.)])\s/;

// blocks(lines) -> the lines grouped into top-level list items (with their nested items, continuation
// lines and fenced code, blank lines between them included), paragraphs, whole fenced code blocks,
// and blank separators ([""]).
function blocks(lines) {
  const out = [];
  let cur = null;
  let fence = false;
  let blanks = 0;
  for (const l of lines) {
    if (fence) {
      cur.push(l);
      if (FENCE_RE.test(l)) {
        fence = false;
        if (!ITEM_RE.test(cur[0])) cur = null;
      }
      continue;
    }
    if (!l.trim()) {
      blanks++;
      continue;
    }
    // An indented line belongs to the list item above it, even across blank lines (a loose list).
    const inItem = cur !== null && ITEM_RE.test(cur[0]) && /^\s/.test(l);
    if (blanks) {
      if (inItem) cur.push(...Array(blanks).fill(""));
      else {
        cur = null;
        for (let i = 0; i < blanks; i++) out.push([""]);
      }
      blanks = 0;
    }
    if (inItem) {
      cur.push(l);
      fence = FENCE_RE.test(l);
    } else if (FENCE_RE.test(l)) {
      cur = [l];
      out.push(cur);
      fence = true;
    } else if ((ITEM_RE.test(l) && !/^\s/.test(l)) || !cur) {
      cur = [l];
      out.push(cur);
    } else cur.push(l);
  }
  for (let i = 0; i < blanks; i++) out.push([""]);
  return out;
}

// Indentation is part of the key: it carries the nesting.
const blockKey = (b) => b.map((l) => l.trimEnd()).join("\n");

// newLines(body, baseLines) -> the body blocks the base lacks. A block is deduped only whole, so a
// line repeated inside another fact or code block is kept; a blank line is kept only between two kept blocks.
function newLines(body, baseLines) {
  const have = new Set(blocks(baseLines).map(blockKey));
  const add = [];
  for (const b of blocks(body)) {
    const key = blockKey(b);
    if (!key) {
      if (add.length && add[add.length - 1]) add.push("");
      continue;
    }
    if (have.has(key)) continue;
    have.add(key);
    add.push(...b);
  }
  return bodyLines(add);
}

// subsections(lines, range) -> [{ heading, body: [lines] }] for the ### headings in range.
function subsections(lines, range) {
  const out = [];
  for (let i = range.at + 1; i < range.end; i++) {
    if (headingLevel(lines[i]) !== 3) continue;
    const sub = sectionRange(lines, lines[i].trimEnd(), i, range.end);
    out.push({ heading: lines[i].trimEnd(), body: bodyLines(lines.slice(i + 1, sub.end)) });
  }
  return out;
}

const FACTS = "## Facts to carry over";

function firstSubsectionAt(lines, range) {
  for (let i = range.at + 1; i < range.end; i++) if (headingLevel(lines[i]) === 3) return i;
  return range.end;
}

function ensureFacts(lines) {
  if (!sectionRange(lines, FACTS)) lines.push("", FACTS, "");
  return sectionRange(lines, FACTS);
}

// Text under the Facts heading before its first ### subsection goes to the same place in the base, once.
function addPreamble(lines, orphanLines, src) {
  const body = bodyLines(orphanLines.slice(src.at + 1, firstSubsectionAt(orphanLines, src)));
  if (body.length === 0) return;
  const facts = ensureFacts(lines);
  const add = newLines(body, lines.slice(facts.at + 1, firstSubsectionAt(lines, facts)));
  if (add.length === 0) return;
  const stop = firstSubsectionAt(lines, facts);
  const last = lastNonEmpty(lines, facts.at + 1, stop);
  const next = lines[facts.at + 1];
  if (last < 0) lines.splice(facts.at + 1, 0, "", ...add, ...(next !== undefined && next.trim() ? [""] : []));
  else lines.splice(last + 1, 0, ...add);
}

function addFacts(lines, orphanLines) {
  const src = sectionRange(orphanLines, FACTS);
  if (!src) return;
  addPreamble(lines, orphanLines, src);
  for (const { heading, body } of subsections(orphanLines, src)) {
    const facts = ensureFacts(lines);
    const sub = sectionRange(lines, heading, facts.at + 1, facts.end);
    const add = newLines(body, sub ? lines.slice(sub.at + 1, sub.end) : []);
    if (sub) {
      if (add.length === 0) continue;
      const last = lastNonEmpty(lines, sub.at + 1, sub.end);
      if (last < 0) lines.splice(sub.at + 1, 0, "", ...add);
      else lines.splice(last + 1, 0, ...add);
    } else {
      if (add.length === 0) continue;
      const last = Math.max(lastNonEmpty(lines, facts.at, facts.end), facts.at);
      lines.splice(last + 1, 0, "", heading, "", ...add);
    }
  }
}

function replaceCurrentState(lines, sourceLines) {
  const src = sectionRange(sourceLines, "## Current state");
  const dst = sectionRange(lines, "## Current state");
  if (!src || !dst) return;
  lines.splice(dst.at + 1, dst.end - dst.at - 1, ...sourceLines.slice(src.at + 1, src.end));
}

// linkTarget("- intent: `<p>`" | "[x](<p>)" | "<p>") -> the path the Plan files line points at.
function linkTarget(raw, plansDir) {
  let t = String(raw).trim();
  const md = /\]\((.+)\)$/.exec(t);
  if (md) t = md[1].trim().replace(/^<(.*)>$/, "$1");
  t = t.replace(/^`|`$/g, "").trim().replace(/^<(.*)>$/, "$1").trim();
  if (!t) return null;
  return path.isAbsolute(t) ? t : path.join(plansDir, t);
}

// existingPlanLines(text, plansDir) -> stages of the Plan files lines whose link target exists now.
function existingPlanLines(text, plansDir) {
  const { lines } = toLines(text);
  const range = sectionRange(lines, "## Plan files");
  if (!range) return [];
  const out = [];
  for (const l of lines.slice(range.at + 1, range.end)) {
    const m = STAGE_LINE_RE.exec(l);
    if (!m) continue;
    const target = linkTarget(m[2], plansDir);
    if (target && isFile(target)) out.push(m[1]);
  }
  return out;
}

// A base without a Plan files section gets one before the Facts section, as the template lays it out.
function ensurePlanFiles(lines) {
  if (!sectionRange(lines, "## Plan files")) {
    const facts = sectionRange(lines, FACTS);
    if (facts) lines.splice(facts.at, 0, "## Plan files", "");
    else lines.push("", "## Plan files");
  }
  return sectionRange(lines, "## Plan files");
}

function setPlanLine(lines, stage, line) {
  const range = ensurePlanFiles(lines);
  let lastStage = -1;
  for (let i = range.at + 1; i < range.end; i++) {
    const m = STAGE_LINE_RE.exec(lines[i]);
    if (!m) continue;
    if (m[1] === stage) {
      lines[i] = line;
      return;
    }
    lastStage = i;
  }
  const at = lastStage >= 0 ? lastStage : lastNonEmpty(lines, range.at + 1, range.end);
  if (at >= 0) lines.splice(at + 1, 0, line);
  else lines.splice(range.at + 1, 0, "", line);
}

// buildMerged({ base, orphans: [{ text, stages }], currentState, planPathFor(stage) }) -> text.
// orphans are oldest first; currentState is the text whose Current state wins, or null to keep the base's.
function buildMerged(o) {
  const { eol, lines } = toLines(o.base);
  if (o.currentState !== null && o.currentState !== o.base) replaceCurrentState(lines, toLines(o.currentState).lines);
  for (const orphan of o.orphans) {
    const orphanLines = toLines(orphan.text).lines;
    addFacts(lines, orphanLines);
    for (const stage of orphan.stages) setPlanLine(lines, stage, `- ${stage}: ${o.planPathFor(stage)}`);
  }
  return lines.join(eol);
}

module.exports = { buildMerged, existingPlanLines, sectionRange };
