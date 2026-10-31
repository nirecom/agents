#!/usr/bin/env node
"use strict";
// check-test-frontmatter: the `# Tests:` / `# Tags:` frontmatter, flat placement, helper-library
// load and self-implemented harness checks of test entrypoints (#2507 D7; the logic lives in
// hooks/lib/test-gates/frontmatter.js). Exit 0 all OK, 1 a failure, 2 usage / registry unreadable
// / a failed staged blob read. A test any parent commit has (HEAD, or MERGE_HEAD during a merge,
// #2812) is not a new one; --merge-parents takes the bin/merge-parents record file.
//   check-test-frontmatter.sh --staged [--merge-parents <file>] <file1> [<file2>...]
//   check-test-frontmatter.sh --all [<root>]

const fs = require("fs");
const path = require("path");
const R = require("../../hooks/lib/test-gates/registry");
const FM = require("../../hooks/lib/test-gates/frontmatter");
const FP = require("../../hooks/lib/test-gates/frontmatter/parents");
const G = require("../../hooks/lib/test-gates/git-blobs");
const MP = require("../../hooks/lib/merge-parents");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");

const USAGE = ["Usage:", "  check-test-frontmatter.sh --staged [--merge-parents <file>] <file1> [<file2>...]", "  check-test-frontmatter.sh --all [<root>]"];

const isAbs = (p) => p.startsWith("/") || /^[A-Za-z]:\//.test(p);
const fwd = (p) => String(p).replace(/\\/g, "/");

function readFile(abs) {
  try {
    const p = toWindowsPath(abs);
    return fs.statSync(p).isFile() ? fs.readFileSync(p) : null;
  } catch {
    return null;
  }
}

// parentsSet(mpFile, repoRoot, rels, cwd) — the merge parents (#2812): the record file when given
// (its producer noted an undecidable state; only a malformed file is noted here), else one
// resolution here.
function parentsSet(mpFile, repoRoot, rels, cwd) {
  if (mpFile) return MP.parseRecords(readFile(path.resolve(toWindowsPath(cwd), toWindowsPath(mpFile))));
  return MP.loadParents(repoRoot, rels);
}

// stagedBlobs(cwd, env, names, oids) -> { blobs, preloaded } — the staged blobs and the parent
// baselines through one `git cat-file --batch`; a failed batch re-reads the staged ones alone (a
// throw there is the caller's) and leaves the baselines to the per-oid fallback of FP.readAll.
function stagedBlobs(cwd, env, names, oids) {
  try {
    return { blobs: G.blobs(cwd, env, [...names, ...oids]), preloaded: new Set(oids) };
  } catch {
    return { blobs: G.blobs(cwd, env, names), preloaded: new Set() };
  }
}

function stagedIo(files, cwd, env, mpFile, err) {
  const repoRoot = G.toplevel(cwd, env);
  const relOf = (f) => {
    const s = fwd(f);
    return isAbs(s) && repoRoot && s.startsWith(`${repoRoot}/`) ? s.slice(repoRoot.length + 1) : s;
  };
  const rels = files.map(relOf);
  // Outside a repository there is no index or parent to ask: the files are judged as they are.
  const names = repoRoot ? rels.filter((r) => !isAbs(r)).map((r) => `:${r}`) : [];
  const inRepo = repoRoot ? rels.filter((r) => !isAbs(r) && r.includes("tests/")) : [];
  const set = repoRoot ? parentsSet(mpFile, repoRoot, inRepo, cwd) : null;
  const recordOf = (rel) => MP.recordFor(set, rel, repoRoot);
  const recs = new Map(inRepo.map((rel) => [rel, recordOf(rel)]));
  const { blobs, preloaded } = stagedBlobs(cwd, env, names, [...new Set([...recs.values()].flatMap(FP.slotsOf))]);
  const note = repoRoot ? MP.noteLine(set, { fallbackOnly: Boolean(mpFile) }) : "";
  if (note) err([note]);
  const io = {
    repoRoot,
    relOf,
    staged: (rel) => (repoRoot && !isAbs(rel) ? blobs.get(`:${rel}`) || null : null),
    work: (f) => readFile(path.resolve(toWindowsPath(cwd), toWindowsPath(f))),
    head: () => null,
    isFile: (abs) => readFile(abs) !== null,
  };
  if (repoRoot) {
    const readBlobs = (oids) => {
      const map = new Map(oids.filter((o) => preloaded.has(o) && blobs.has(o)).map((o) => [o, blobs.get(o)]));
      const rest = oids.filter((o) => !preloaded.has(o));
      for (const [o, b] of rest.length ? G.blobs(cwd, env, rest) : []) map.set(o, b);
      return map;
    };
    io.parents = FP.parentsIo(inRepo, (rel) => (recs.has(rel) ? recs.get(rel) : recordOf(rel)), readBlobs);
  }
  return io;
}

// stagedArgs(rest) -> { mpFile, files } or null for a --merge-parents without its file.
function stagedArgs(rest) {
  if (rest[0] !== "--merge-parents") return { mpFile: "", files: rest };
  if (rest.length < 2 || !rest[1]) return null;
  return { mpFile: rest[1], files: rest.slice(2) };
}

function allRoot(arg, cwd, env) {
  if (arg) return fwd(path.resolve(toWindowsPath(cwd), toWindowsPath(arg)));
  if (env.REPO_ROOT) return fwd(path.resolve(toWindowsPath(cwd), toWindowsPath(env.REPO_ROOT)));
  return G.toplevel(cwd, env);
}

// Every line of this CLI goes to stderr, as the bash one printed them.
function main({ argv, cwd, env, stderr }) {
  const err = (lines) => lines.forEach((l) => stderr.write(`${l}\n`));
  if (!R.tryReg()) {
    err(["ERROR: test language registry not readable"]);
    return 2;
  }
  if (argv.length === 0) {
    err(USAGE);
    return 2;
  }
  const [mode, ...rest] = argv;
  let res;
  if (mode === "--staged") {
    const a = stagedArgs(rest);
    if (!a) {
      err(["ERROR: --merge-parents needs a file"]);
      return 2;
    }
    let io;
    try {
      io = stagedIo(a.files, cwd, env, a.mpFile, err);
    } catch (e) {
      // A failed blob read is no verdict: never fall back to the worktree copy.
      err([`check-test-frontmatter: ${e && e.message ? e.message : String(e)}`]);
      return 2;
    }
    res = FM.stagedCheck(a.files, io);
  } else if (mode === "--all") {
    const root = allRoot(rest[0], cwd, env);
    if (!root) {
      err(["ERROR: not inside a git repository"]);
      return 2;
    }
    res = FM.allCheck(root);
  } else {
    err([`Unknown mode: ${mode}`, ...USAGE]);
    return 2;
  }
  err(res.lines);
  return res.rc;
}

function run({ argv = [], cwd = process.cwd(), env = process.env, stderr = process.stderr } = {}) {
  return R.withEnv(env, () => main({ argv, cwd, env, stderr }));
}

if (require.main === module) process.exitCode = run({ argv: process.argv.slice(2) });

module.exports = { run };
