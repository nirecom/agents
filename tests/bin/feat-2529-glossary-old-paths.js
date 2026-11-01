#!/usr/bin/env node
"use strict";
// Tests: bin/lib/glossary-format.js, bin/lib/codex-glossary.sh, bin/review-doc-glossary, bin/glossary-promote
// Tags: TL2, bin, glossary, migration, paths, scope:issue-specific
// #2529 S2 T1 — the glossary entry files moved to docs/glossary/<category>.md.
// T1-1: no tracked file still names the old paths (outside append-only records, the
// migration blocks and the migration fixtures). T1-2: the three readers find the moved
// files. T1-3: the path rule is repo-relative (docs/glossary/misc.md is a candidate that
// BLOCKs; the docs/glossary.md index is not a candidate).

// TL3 gap: a real codex review run is not driven; codex_glossary_block is sourced and called.

const { caseBegin, caseEnd } = require("../lib/harness");
const { noNewFailures } = require("../lib/case-verdict");
const { spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { after, test } = require("node:test");
const c = require("./feat-2529-glossary-provenance/common");

const { check, eq, ok, ROOT, TMP, fwd, totals, mod } = c;
const fails = () => totals.failed;
after(() => process.stdout.write(`Total: ${totals.passed} passed, ${totals.failed} failed\n`));
const SELF = "tests/bin/feat-2529-glossary-old-paths.js";

// --- T1-1 -------------------------------------------------------------------
const OLD_PATTERNS = [/docs\/glossary-user/, /docs\/glossary-internal/, /glossary-(user|internal)[-.]/];
// Exclusions: append-only records (history / changelog / _archive), this test, and the
// migration fixtures. Lines inside a migration block are excluded line by line below.
const EXCLUDED_FILES = new Set([
  SELF,
  "tests/bin/feat-2529-glossary-legacy-read.sh",
  "tests/bin/feat-2529-glossary-provenance/split.js",
  "tests/hooks/feat-2529-glossary-fingerprint-inputs/glossary.js",
]);
// Lines the later update-docs step rewrites; matched by exact text, so an edited line no
// longer matches and a new stale line in the same file is still a hit.
const PENDING_DOC_LINES = new Map([
  ["rules/docs/glossary.md", new Set([
    "The category decides the file: `user` goes to `docs/glossary-user.md`, `internal` to `docs/glossary-internal.md`.",
  ])],
]);
const pendingDocLine = (p, line) => !!(PENDING_DOC_LINES.get(p) && PENDING_DOC_LINES.get(p).has(line));
function excludedPath(p) {
  return EXCLUDED_FILES.has(p) || p === "docs/history.md" || p.startsWith("docs/history/") ||
    p === "CHANGELOG.md" || p.startsWith("changelog/") || /(^|\/)_archived?(\/|$)/.test(p);
}
const BEGIN_RE = /--- BEGIN temporary: docs\/glossary-<category>\.md -> docs\/glossary\/<category>\.md migration/;
const END_RE = /--- END temporary: docs\/glossary-<category>\.md -> docs\/glossary\/<category>\.md migration/;

function oldPathHits() {
  const r = spawnSync("git", ["-C", ROOT, "ls-files", "-z"], { encoding: "utf8", maxBuffer: 64 * 1024 * 1024 });
  if (r.status !== 0) throw new Error(`git ls-files failed: ${r.stderr}`);
  const hits = [];
  for (const p of r.stdout.split("\0").filter(Boolean)) {
    if (excludedPath(p)) continue;
    let text;
    try { text = fs.readFileSync(path.join(ROOT, p), "utf8"); } catch (_) { continue; }
    if (text.includes("\0")) continue;
    let inBlock = false;
    text.split(/\r?\n/).forEach((line, i) => {
      if (BEGIN_RE.test(line)) { inBlock = true; return; }
      if (END_RE.test(line)) { inBlock = false; return; }
      if (!inBlock && !pendingDocLine(p, line) && OLD_PATTERNS.some((re) => re.test(line))) hits.push(`${p}:${i + 1}`);
    });
  }
  return hits;
}

function noOldPaths() {
  check("T1-1 git ls-files has no docs/glossary-user / docs/glossary-internal / glossary-(user|internal)[-.] left", () => {
    const hits = oldPathHits();
    eq(hits.length, 0, `old-path references (${hits.slice(0, 12).join(", ")}${hits.length > 12 ? ", ..." : ""})`);
  });
  check("T1-1 the old entry files themselves are no longer tracked", () => {
    const r = spawnSync("git", ["-C", ROOT, "ls-files", "--", "docs/glossary-user.md", "docs/glossary-internal.md"], { encoding: "utf8" });
    eq(r.stdout.trim(), "", "tracked old files");
  });
}

// --- T1-2 -------------------------------------------------------------------
function codexCfg() {
  const dir = path.join(TMP, "codex-cfg");
  fs.mkdirSync(path.join(dir, "rules"), { recursive: true });
  fs.cpSync(path.join(ROOT, "bin", "lib"), path.join(dir, "bin", "lib"), { recursive: true });
  fs.copyFileSync(path.join(ROOT, "rules", "core-principles.md"), path.join(dir, "rules", "core-principles.md"));
  fs.writeFileSync(path.join(dir, ".env"), "CODE_LANG=english\n");
  return fwd(dir);
}
function codexBlock(projectRoot) {
  const script = 'source "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 3; ' +
    'source "$1/bin/lib/codex-glossary.sh" >/dev/null 2>&1 || exit 3; ' +
    'declare -F codex_glossary_block >/dev/null || exit 4; codex_glossary_block "$2"';
  const r = spawnSync("bash", ["-c", script, "_", fwd(ROOT), fwd(projectRoot)], {
    cwd: TMP, encoding: "utf8", timeout: 60000, env: c.childEnv({ AGENTS_MAIN_ROOT: codexCfg() }),
  });
  return { code: r.status, out: (r.stdout || "").replace(/\r/g, "") };
}

function readersFindMovedFiles() {
  const repo = c.mkRepo("t1-2");
  check("T1-2 codex_glossary_block reads the docs/glossary/ entries (non-zero, both categories)", () => {
    const b = codexBlock(repo);
    eq(b.code, 0, "probe exit (3 = not sourceable, 4 = function absent)");
    ok(/### alpha/.test(b.out) && /### kilo/.test(b.out), `block: ${c.clip(b.out)}`);
    ok(/glossary\/user\.md/.test(b.out) && /glossary\/internal\.md/.test(b.out), `labels: ${c.clip(b.out)}`);
  });
  check("T1-2 review-doc-glossary --all checks the 2 moved files", () => {
    const r = c.runBash("bin/review-doc-glossary", ["--all"], { cwd: repo });
    eq(r.code, 0, `exit (out: ${r.all})`);
    ok(/OK: 2 file\(s\)/.test(r.out), `out: ${r.out}`);
  });
  check("T1-2 glossary-promote adds into docs/glossary/user.md (ADDED=1)", () => {
    const v1 = "| Term | Category | Definition |\n|---|---|---|\n| beta | user | A new-path term. |\n";
    const sid = c.approvedSession("t1-2-promote", [], { glossary: v1, cwd: repo });
    const r = c.runNode("bin/glossary-promote", [fwd(c.intentPath(sid)), repo], { cwd: repo });
    eq(r.code, 0, `exit (out: ${r.all})`);
    ok(/\bADDED=1\b/.test(r.out), `out: ${r.out}`);
    ok(/### beta/.test(c.readFile(repo, "docs/glossary/user.md") || ""), "beta not written to docs/glossary/user.md");
  });
}

// --- T1-3 -------------------------------------------------------------------
function repoRelativePathRule() {
  const fmt = () => mod("bin/lib/glossary-format.js");
  check("T1-3 isGlossaryCandidate: docs/glossary/misc.md and docs/glossary/user.md are candidates", () => {
    eq(fmt().isGlossaryCandidate("docs/glossary/misc.md"), true, "docs/glossary/misc.md");
    eq(fmt().isGlossaryCandidate("docs/glossary/user.md"), true, "docs/glossary/user.md");
  });
  check("T1-3 isGlossaryCandidate: the docs/glossary.md index and the old paths are not candidates", () => {
    eq(fmt().isGlossaryCandidate("docs/glossary.md"), false, "docs/glossary.md");
    eq(fmt().isGlossaryCandidate("docs/glossary-user.md"), false, "docs/glossary-user.md");
  });
  check("T1-3 isGlossaryCandidate accepts a backslash-separated path the same way", () => {
    eq(fmt().isGlossaryCandidate("docs\\glossary\\misc.md"), true, "docs\\glossary\\misc.md");
  });
  const dir = path.join(TMP, "t1-3");
  fs.mkdirSync(dir, { recursive: true });
  const file = (name, body) => { const p = path.join(dir, name); fs.writeFileSync(p, body); return p; };
  const pairs = [
    { label: "docs/glossary/user.md", file: file("user.md", c.BASE["docs/glossary/user.md"]) },
    { label: "docs/glossary/internal.md", file: file("internal.md", c.BASE["docs/glossary/internal.md"]) },
  ];
  check("T1-3 checkFiles: the valid docs/glossary/ pair has no BLOCK (control)", () => {
    eq(fmt().checkFiles(pairs), [], "blocks");
  });
  check("T1-3 checkFiles: docs/glossary/misc.md is a BLOCK", () => {
    const misc = { label: "docs/glossary/misc.md", file: file("misc.md", c.glossaryText("misc", [["zulu", "A misplaced term."]])) };
    const blocks = fmt().checkFiles(pairs.concat([misc]));
    ok(blocks.some((b) => /docs\/glossary\/misc\.md/.test(b)), `blocks: ${JSON.stringify(blocks)}`);
  });
}

caseBegin("t1-1-no-old-glossary-paths", "bin/lib/glossary-format.js");
test("t1-1-no-old-glossary-paths", () => noNewFailures(fails, noOldPaths));
caseEnd();

caseBegin("t1-2-readers-find-moved-files", "bin/lib/codex-glossary.sh");
test("t1-2-readers-find-moved-files", () => noNewFailures(fails, readersFindMovedFiles));
caseEnd();

caseBegin("t1-3-repo-relative-path-rule", "bin/lib/glossary-format.js");
test("t1-3-repo-relative-path-rule", () => noNewFailures(fails, repoRelativePathRule));
caseEnd();
