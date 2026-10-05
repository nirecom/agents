#!/usr/bin/env node
"use strict";
// Residue check (#2500): language knowledge left outside the test language registry.
// Usage: node scan.js --root <repo> [--table <json>] [--allowlist <tsv>] [--print-words]
// Exit: 0 clean / 1 violation or allowlist error / 2 usage error or unreadable table.
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const TABLE_FILES = new Set([
  "hooks/lib/test-language-registry.json", "hooks/lib/test-language-registry.js",
  "bin/test-language-registry", "bin/lib/test-language-registry.sh",
]);
const NAME_CHAR = /[A-Za-z0-9_-]/;
const ALNUM = /[A-Za-z0-9]/;
const PREFIX_FOLLOW = new Set(["*", "[", "$", "{"]);
const LOCATION_RE = /(?<![A-Za-z0-9_])(?:tests|TESTS_DIR|tests_dir)(?![A-Za-z0-9_])/;
// `*` opens a comment line only as a block-comment continuation (`* text`, a lone `*/`):
// a case arm such as `*/test_*.py)` is code.
const COMMENT_RE = /^(?:#|\/\/|\/\*|\*(?:\s|$)|\*\/\s*$)/;

function die(msg) {
  process.stderr.write(`scan: ${msg}\n`);
  process.exit(2);
}

function parseArgs(argv) {
  const a = { printWords: false };
  for (let i = 0; i < argv.length; i++) {
    const k = argv[i];
    if (k === "--print-words") a.printWords = true;
    else if (["--root", "--table", "--allowlist"].includes(k) && i + 1 < argv.length) a[k.slice(2)] = argv[++i];
    else die(`unknown argument: ${k}`);
  }
  if (!a.root) die("--root is required");
  a.root = path.resolve(a.root);
  a.table = a.table || path.join(a.root, "hooks/lib/test-language-registry.json");
  return a;
}

// Pattern words: `*`-split fragments of 3+ chars (prefix = a pattern's leading fragment).
// Name words: single-word ids of 4+ chars.
function deriveWords(table) {
  if (!table || !Array.isArray(table.entries)) die("table has no entries array");
  const patternWords = new Map();
  const nameWords = new Set();
  const ids = [];
  const heads = new Set();
  for (const e of table.entries) {
    const launch = e.launch || {};
    if (Array.isArray(launch.command) && launch.command.length > 0) heads.add(launch.command[0]);
    if (typeof launch.requires === "string") heads.add(launch.requires);
  }
  for (const e of table.entries) {
    ids.push(e.id);
    if (/^[a-z0-9]{4,}$/.test(e.id)) nameWords.add(e.id);
    for (const p of e.patterns || []) {
      p.split("*").forEach((frag, i) => {
        if (frag.length < 3) return;
        // A bare extension (`.sh`, `.py`) also names source files; any other word names tests only.
        const w = patternWords.get(frag) || { owners: new Set(), prefix: false, testOnly: !/^\.[A-Za-z0-9]+$/.test(frag) };
        w.owners.add(e.id);
        if (i === 0) w.prefix = true;
        patternWords.set(frag, w);
      });
    }
  }
  const interpIds = new Set(ids.filter((id) => heads.has(id)));
  return { patternWords, nameWords, ids, interpIds, elementRes: elementRes(nameWords) };
}

function esc(s) {
  return s.replace(/[.*+?^${}()|[\]\\/]/g, "\\$&");
}

// Any comparison against an id is residue, except an id that is also a launch head (`bash`):
// that one counts only when the operand names a test language/kind (`entry.id`, `kind`, `lang`),
// since `interp === "bash"` compares a command head, not a test language.
const LANG_KEY_RE = /(?:^|[._])(?:id|kind|lang|language)$/i;
const OPERAND = `["']?\\$?\\{?(?<op>[A-Za-z_][\\w.]*)\\}?["']?`;
function compareRes(ids) {
  const alt = ids.map(esc).join("|");
  return [
    new RegExp(`${OPERAND}\\s*(?:===?|!==?)\\s*(["']?)(?<id>${alt})\\2(?![A-Za-z0-9_-])`, "g"),
    new RegExp(`(["'])(?<id>${alt})\\1\\s*(?:===?|!==?)\\s*${OPERAND}`, "g"),
    new RegExp(`\\[\\[?\\s(?:[^\\]]*\\s)?${OPERAND}\\s+!?=\\s*(["']?)(?<id>${alt})\\2(?=\\s)`, "g"),
  ];
}
const DISPATCH_RES = [/\bcase\s+"?\$\{?TLR_ID\}?"?\s+in\b/, /\bswitch\s*\(\s*[\w.]*\bid\s*\)/];

function idCompare(text, cmpRes, interpIds) {
  if (DISPATCH_RES.some((re) => re.test(text))) return true;
  return cmpRes.some((re) => [...text.matchAll(re)].some((m) => !interpIds.has(m.groups.id) || LANG_KEY_RE.test(m.groups.op)));
}

// A line that names a non-test top-level source tree (`hooks/*.js`, `find skills -name`) and
// no tests location globs source files: its extension words are not test discovery, but a
// test-only word (`hooks/*.Tests.ps1` after `cd "$TESTS_DIR"`) still is.
function sourceRootRe(files) {
  const roots = new Set(files.filter((f) => f.includes("/")).map((f) => f.split("/")[0]));
  roots.delete("tests");
  if (roots.size === 0) return null;
  return new RegExp(`(?<![A-Za-z0-9_.-])(?:${[...roots].map(esc).join("|")})(?=[/\\s"']|$)`);
}

// Only bin/lib/test-language-parts/ holds pure per-language parts; a part registered from
// anywhere else (a case-marker reader) is ordinary code and is scanned.
function inScope(p) {
  if (TABLE_FILES.has(p)) return false;
  if (p.startsWith("bin/lib/test-language-parts/") || p.startsWith("skills/synced/")) return false;
  if (p === "rules/test.md" || /^rules\/test\/[^/]+\.md$/.test(p)) return true;
  if (p.endsWith(".md")) return false;
  return p.startsWith("bin/") || p.startsWith("hooks/") || p === "tests/run-all.sh"
    || p.startsWith("tests/lib/") || /^skills\/[^/]+\/scripts\//.test(p);
}

// The lines to scan: [{n, raw, text}] — a rules .md contributes only its front matter.
function scanLines(p, content) {
  const all = content.replace(/\r\n/g, "\n").split("\n");
  let lines = all.map((raw, i) => ({ n: i + 1, raw }));
  if (p.endsWith(".md")) {
    if (all[0] !== "---") return [];
    const end = all.indexOf("---", 1);
    lines = end < 0 ? [] : lines.slice(1, end);
  }
  return lines
    .map((l) => ({ ...l, text: l.raw.replace(/\\/g, "") }))
    .filter((l) => !COMMENT_RE.test(l.text.trim()));
}

function patternHits(text, words) {
  const hits = [];
  for (const [word, info] of words) {
    for (let i = text.indexOf(word); i >= 0; i = text.indexOf(word, i + 1)) {
      const prev = text[i - 1] || "";
      const next = text[i + word.length] || "";
      // A suffix word standing alone between spaces (`no .sh files`) names a file kind in prose.
      const ok = info.prefix
        ? !NAME_CHAR.test(prev) && PREFIX_FOLLOW.has(next)
        : !NAME_CHAR.test(prev) && !ALNUM.test(next) && !(/\s/.test(prev) && /\s/.test(next));
      if (ok) { hits.push(word); break; }
    }
  }
  return hits;
}

function nameHits(text, names) {
  return [...names].filter((w) => new RegExp(`(?<![A-Za-z0-9_-])${esc(w)}(?![A-Za-z0-9_-])`).test(text));
}

// An element line of a multi-line enumeration starts with a name word: an array item
// (`"pester",`), a key (`pytest: {`), a case arm (`pester)`) or a bare list word.
const LIST_GAP = 8;
function elementRes(names) {
  return [...names].map((w) => ({
    w, re: new RegExp(`^(?:[\\[({,|]\\s*)?(["'\`]?)${esc(w)}\\1\\s*(?:[,|)\\]}]|;;|:|=>?|$)`),
  }));
}

// Element lines no more than LIST_GAP lines apart form one list; 2+ distinct names in it hit.
function listHits(p, lines, res, mine, out) {
  const elems = [];
  for (const l of lines) {
    const hit = res.find((r) => r.re.test(l.text.trim()));
    if (hit) elems.push({ l, w: hit.w });
  }
  let group = [];
  const flush = () => {
    const names = [...new Set(group.map((e) => e.w))];
    if (names.length >= 2) {
      const allowed = mine.filter((r) => group.some((e) => e.l.raw.includes(r.s)));
      allowed.forEach((r) => { r.used = true; });
      const last = group[group.length - 1].l.n;
      if (allowed.length === 0) out.push(`a-name ${p}:${group[0].l.n} ${names.join(",")} (multi-line to ${last})`);
    }
    group = [];
  };
  for (const e of elems) {
    if (group.length > 0 && e.l.n - group[group.length - 1].l.n > LIST_GAP) flush();
    group.push(e);
  }
  flush();
}

function readAllowlist(file, errors) {
  if (!file) return [];
  const rows = [];
  fs.readFileSync(file, "utf8").replace(/\r\n/g, "\n").split("\n").forEach((line, i) => {
    if (line.trim() === "" || line.startsWith("#")) return;
    const [p, s, reason] = line.split("\t");
    if (!p || !s || !reason || reason.trim() === "") errors.push(`ALLOWLIST no-reason line ${i + 1}: ${line}`);
    else rows.push({ p, s, line: i + 1, used: false });
  });
  return rows;
}

function scanFile(p, lines, w, cmpRes, srcRe, allow, out) {
  const mine = allow.filter((r) => r.p === p);
  const located = lines.some((l) => LOCATION_RE.test(l.text));
  const used = [];
  for (const l of lines) {
    const srcGlob = srcRe !== null && srcRe.test(l.text) && !LOCATION_RE.test(l.text);
    const allPat = patternHits(l.text, w.patternWords);
    const pat = srcGlob ? allPat.filter((x) => w.patternWords.get(x).testOnly) : allPat;
    const names = nameHits(l.text, w.nameWords);
    const cmp = idCompare(l.text, cmpRes, w.interpIds);
    if (pat.length === 0 && names.length < 2 && !cmp) continue;
    const allowed = mine.filter((r) => l.raw.includes(r.s));
    if (allowed.length > 0) { allowed.forEach((r) => { r.used = true; }); continue; }
    if (pat.length > 0) used.push({ l, pat });
    if (names.length >= 2) out.push(`a-name ${p}:${l.n} ${names.join(",")}`);
    if (cmp) out.push(`c-id-compare ${p}:${l.n} ${l.raw.trim()}`);
  }
  listHits(p, lines, w.elementRes, mine, out);
  const words = [...new Set(used.flatMap((u) => u.pat))];
  const oneOwner = [...w.ids].some((id) => words.every((x) => w.patternWords.get(x).owners.has(id)));
  for (const u of used) {
    if (!oneOwner) out.push(`a-pattern ${p}:${u.l.n} ${u.pat.join(",")} (file words: ${words.join(",")})`);
    if (located) out.push(`b-location ${p}:${u.l.n} ${u.pat.join(",")}`);
  }
}

function main() {
  const a = parseArgs(process.argv.slice(2));
  let table;
  try { table = JSON.parse(fs.readFileSync(a.table, "utf8")); } catch (e) { die(`table not readable: ${a.table}`); }
  const w = deriveWords(table);
  if (a.printWords) {
    for (const [word, info] of w.patternWords) console.log(`pattern\t${word}\t${[...info.owners].join(",")}`);
    for (const n of w.nameWords) console.log(`name\t${n}`);
    return 0;
  }
  const errors = [];
  const allow = readAllowlist(a.allowlist, errors);
  let files;
  try {
    files = execFileSync("git", ["-C", a.root, "ls-files", "-z"], { encoding: "utf8", maxBuffer: 64 << 20 }).split("\0").filter(Boolean);
  } catch (e) { die(`git ls-files failed under ${a.root}`); }
  const out = [];
  const cmpRes = compareRes(w.ids);
  const srcRe = sourceRootRe(files);
  for (const p of files.filter((f) => inScope(f)).sort()) {
    let content;
    try { content = fs.readFileSync(path.join(a.root, p), "utf8"); } catch (e) { continue; }
    if (content.includes("\0")) continue;
    scanFile(p, scanLines(p, content), w, cmpRes, srcRe, allow, out);
  }
  for (const r of allow) if (!r.used) errors.push(`ALLOWLIST stale line ${r.line}: ${r.p}\t${r.s}`);
  [...out, ...errors].forEach((l) => console.log(l));
  console.log(`scan: ${out.length} violation(s), ${errors.length} allowlist error(s)`);
  return out.length + errors.length > 0 ? 1 : 0;
}

process.exitCode = main();
