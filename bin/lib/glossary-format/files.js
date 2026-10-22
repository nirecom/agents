"use strict";
// Glossary file naming, enumeration and file-set checks (#2529). Paths are
// repo-relative (`docs/glossary/<name>.md`); `\` is folded to `/` before matching.
// The range split rule is owned by rules/docs/glossary.md.

const fs = require("fs");
const path = require("path");
const { parseGlossaryFile, checkGlossaryFile } = require("./entries");

const GLOSSARY_DIR = "docs/glossary";
const NAME_RE = /^docs\/glossary\/(user|internal)(?:-([a-z])-([a-z]))?\.md$/;
const CANDIDATE_RE = /^docs\/glossary\/[^/]+\.md$/;

function slash(p) {
  return String(p).replace(/\\/g, "/");
}

function rangeOf(m) {
  if (m[2] === undefined) return { category: m[1], range: null };
  if (m[2] > m[3]) return null;
  return { category: m[1], range: { from: m[2], to: m[3] } };
}

function parseGlossaryPath(p) {
  const m = NAME_RE.exec(slash(p));
  return m ? rangeOf(m) : null;
}

// True for any file directly under docs/glossary/, parseable or not.
function isGlossaryCandidate(p) {
  return CANDIDATE_RE.test(slash(p));
}

// Every *.md directly under <repoRoot>/docs/glossary/, sorted, repo-relative. A missing
// directory is an empty set; any other read failure throws. No old-path fallback.
function listGlossaryFiles(repoRoot) {
  let ents;
  try { ents = fs.readdirSync(path.join(String(repoRoot), GLOSSARY_DIR), { withFileTypes: true }); } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
  return ents.filter((d) => d.isFile() && d.name.endsWith(".md")).map((d) => GLOSSARY_DIR + "/" + d.name).sort();
}

function isDirectory(p) {
  try { return fs.statSync(p).isDirectory(); } catch (_) { return false; }
}

let legacyGlossaryFiles = () => [];

function unparseableNameMessage(p) {
  return p + ": unparseable glossary file name (use docs/glossary/<category>.md or docs/glossary/<category>-<from>-<to>.md)";
}

// The combined-glossary readers' file list: docs/glossary/ files, each as
// { label (repo-relative), path (on disk), category }. Writers use listGlossaryFiles.
// An unparseable name directly under docs/glossary/ throws, like an unreadable file: its
// terms would otherwise vanish from every reader without a trace. Mid-migration, a category
// with no docs/glossary/ file yet still reads its legacy files, whatever the other category holds.
function listMainGlossaryFiles(repoRoot) {
  const root = String(repoRoot);
  const labels = isDirectory(path.join(root, GLOSSARY_DIR)) ? listGlossaryFiles(root) : [];
  const files = [];
  const bad = [];
  for (const label of labels) {
    const parsed = parseGlossaryPath(label);
    if (parsed) files.push({ label, path: path.join(root, label), category: parsed.category });
    else bad.push(label);
  }
  if (bad.length > 0) throw new Error(bad.map(unparseableNameMessage).join("; "));
  const moved = new Set(files.map((f) => f.category));
  const legacy = legacyGlossaryFiles(root).filter((f) => !moved.has(f.category));
  return { files: files.concat(legacy), legacy: legacy.length > 0 };
}

function termBucket(term) {
  const c = String(term).toLowerCase().charAt(0);
  return c >= "a" && c <= "z" ? c : "a";
}

function checkRangeMembership(p, entries) {
  const parsed = parseGlossaryPath(p);
  if (!parsed || !parsed.range) return [];
  const { from, to } = parsed.range;
  return entries
    .filter((e) => { const b = termBucket(e.term); return b < from || b > to; })
    .map((e) => p + ": '" + e.term + "' is outside the file's range " + from + "-" + to);
}

function nextLetter(c) {
  return String.fromCharCode(c.charCodeAt(0) + 1);
}

function checkCategorySet(category, files) {
  const out = [];
  const unsplit = files.filter((f) => f.range === null);
  const ranged = files.filter((f) => f.range !== null).sort((a, b) => (a.range.from < b.range.from ? -1 : 1));
  if (unsplit.length > 0 && ranged.length > 0) {
    out.push(category + ": " + unsplit[0].path + " coexists with range-split files");
  }
  if (ranged.length === 0) return out;
  let expect = "a";
  for (const f of ranged) {
    const { from, to } = f.range;
    if (expect !== null && from > expect) out.push(category + ": letters " + expect + "-" + String.fromCharCode(from.charCodeAt(0) - 1) + " are not covered (gap before " + f.path + ")");
    if (expect === null || from < expect) out.push(category + ": " + f.path + " overlaps an earlier range");
    expect = to === "z" ? null : nextLetter(to);
  }
  if (expect !== null) out.push(category + ": letters " + expect + "-z are not covered");
  return out;
}

function checkFileSet(paths) {
  const out = [];
  const groups = new Map();
  for (const p of paths) {
    const parsed = parseGlossaryPath(p);
    if (!parsed) { out.push(unparseableNameMessage(p)); continue; }
    if (!groups.has(parsed.category)) groups.set(parsed.category, []);
    groups.get(parsed.category).push({ path: p, range: parsed.range });
  }
  for (const [category, files] of groups) out.push(...checkCategorySet(category, files));
  return out;
}

function fileForTerm(paths, category, term) {
  const bucket = termBucket(term);
  for (const p of paths) {
    const parsed = parseGlossaryPath(p);
    if (!parsed || parsed.category !== category) continue;
    if (parsed.range === null || (bucket >= parsed.range.from && bucket <= parsed.range.to)) return p;
  }
  return null;
}

// check-files <label> <path> [<label> <path> ...]: per-file form, name and range
// checks plus the cross-file duplicate and file-set checks. BLOCK lines on stdout.
function checkFiles(pairs) {
  const blocks = [];
  const seen = new Map();
  for (const { label, file } of pairs) {
    const text = fs.readFileSync(file, "utf8");
    for (const r of checkGlossaryFile(text)) blocks.push(label + ": " + r);
    const entries = parseGlossaryFile(text).entries;
    blocks.push(...checkRangeMembership(label, entries));
    for (const e of entries) {
      const key = e.term.toLowerCase();
      if (seen.has(key) && seen.get(key) !== label) blocks.push("term '" + e.term + "' is defined in both " + seen.get(key) + " and " + label);
      else seen.set(key, label);
    }
  }
  blocks.push(...checkFileSet(pairs.map((p) => p.label)));
  return blocks;
}

const INDEX_PATH = "docs/glossary.md";

// The index page holds no entries (rules/docs/glossary.md); no reader of the category files sees
// one there. An unclosed fence BLOCKs too: it would hide every heading after it.
function checkIndexFile(label, text) {
  const p = parseGlossaryFile(text);
  const out = p.entries.map((e) => label + ': the index holds no entries — move "### ' + e.term + '" to its category file');
  if (p.errors.length > 0) out.push(label + ": unclosed code fence (it would hide entries from this check)");
  return out;
}

module.exports = {
  GLOSSARY_DIR,
  INDEX_PATH,
  checkIndexFile,
  NAME_RE,
  CANDIDATE_RE,
  parseGlossaryPath,
  isGlossaryCandidate,
  listGlossaryFiles,
  listMainGlossaryFiles,
  termBucket,
  checkRangeMembership,
  checkCategorySet,
  checkFileSet,
  fileForTerm,
  checkFiles,
};

// --- BEGIN temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration added 2026-10-17 ---
// deletion-condition: remove once origin/main has no docs/glossary-user.md / docs/glossary-internal.md and no worktree in "git worktree list" still has them, together with the matching blocks in bin/lib/glossary-provenance.js, bin/lib/glossary-format/cli.js, bin/review-doc-glossary, bin/check-glossary-provenance and tests/bin/feat-2529-glossary-legacy-read.sh
// Readers only: until the move merges, the main worktree holds the old layout.
const LEGACY_NAME_RE = /^docs\/glossary-(user|internal)(?:-([a-z])-([a-z]))?\.md$/;
// A docs/glossary-<category>-*.md name that is not a valid entry file name (a reversed or
// malformed range) throws like an unparseable docs/glossary/ name; other docs files stay out.
const LEGACY_CANDIDATE_RE = /^docs\/glossary-(user|internal)(?:-[^/]*)?\.md$/;
legacyGlossaryFiles = (root) => {
  let names;
  try { names = fs.readdirSync(path.join(root, "docs")); } catch (e) {
    if (e.code === "ENOENT") return [];
    throw e;
  }
  const files = [];
  const bad = [];
  for (const name of names.sort()) {
    const label = "docs/" + name;
    const m = LEGACY_NAME_RE.exec(label);
    if (m && rangeOf(m)) files.push({ label, path: path.join(root, label), category: m[1] });
    else if (LEGACY_CANDIDATE_RE.test(label)) bad.push(label);
  }
  if (bad.length > 0) throw new Error(bad.map(unparseableNameMessage).join("; "));
  return files;
};
module.exports.LEGACY_NAME_RE = LEGACY_NAME_RE;
module.exports.LEGACY_CANDIDATE_RE = LEGACY_CANDIDATE_RE;
// Writers: no staged add / modify / rename-into of an old-layout name — no reader of the index
// sees its terms. `paths` are the non-deletion staged names; a deletion (the move away) passes.
// legacyLayoutBlocks(paths) -> ["<path>: ..."] (empty when none).
module.exports.legacyLayoutBlocks = (paths) => (paths || []).map(slash).flatMap((p) => {
  const m = LEGACY_CANDIDATE_RE.exec(p);
  return m ? [`${p}: old glossary layout — glossary entries live in docs/glossary/${m[1]}.md ` +
    `(or docs/glossary/${m[1]}-<from>-<to>.md); move the entries there and unstage this path`] : [];
});
// --- END temporary: docs/glossary-<category>.md -> docs/glossary/<category>.md migration ---
