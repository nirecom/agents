#!/usr/bin/env node
"use strict";
// check-test-frontmatter: the `# Tests:` / `# Tags:` frontmatter, flat placement, helper-library
// load and self-implemented harness checks of test entrypoints (#2507 D7; the logic lives in
// hooks/lib/test-gates/frontmatter.js). Exit 0 all OK, 1 a failure, 2 usage / registry unreadable
// / a failed staged or HEAD blob read.
//   check-test-frontmatter.sh --staged <file1> [<file2>...]
//   check-test-frontmatter.sh --all [<root>]

const fs = require("fs");
const path = require("path");
const R = require("../../hooks/lib/test-gates/registry");
const FM = require("../../hooks/lib/test-gates/frontmatter");
const G = require("../../hooks/lib/test-gates/git-blobs");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");

const USAGE = ["Usage:", "  check-test-frontmatter.sh --staged <file1> [<file2>...]", "  check-test-frontmatter.sh --all [<root>]"];

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

function stagedIo(files, cwd, env) {
  const repoRoot = G.toplevel(cwd, env);
  const relOf = (f) => {
    const s = fwd(f);
    return isAbs(s) && repoRoot && s.startsWith(`${repoRoot}/`) ? s.slice(repoRoot.length + 1) : s;
  };
  const rels = files.map(relOf);
  // Outside a repository there is no index or HEAD to ask: the files are judged as they are.
  const names = repoRoot ? [...rels.map((r) => `HEAD:${r}`), ...rels.filter((r) => !isAbs(r)).map((r) => `:${r}`)] : [];
  const blobs = G.blobs(cwd, env, names);
  return {
    repoRoot,
    relOf,
    staged: (rel) => (repoRoot && !isAbs(rel) ? blobs.get(`:${rel}`) || null : null),
    work: (f) => readFile(path.resolve(toWindowsPath(cwd), toWindowsPath(f))),
    head: (rel) => blobs.get(`HEAD:${rel}`) || null,
    isFile: (abs) => readFile(abs) !== null,
  };
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
    let io;
    try {
      io = stagedIo(rest, cwd, env);
    } catch (e) {
      // A failed blob read is no verdict: never fall back to the worktree copy.
      err([`check-test-frontmatter: ${e && e.message ? e.message : String(e)}`]);
      return 2;
    }
    res = FM.stagedCheck(rest, io);
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
