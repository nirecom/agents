"use strict";

// CLI for bin/check-plans-dir-isolation.sh (#2512 stage 4).
// Exit 0 = clean (N-candidate lines are informational), 1 = violation, 2 = usage error.
//   (no args)      isolation scan of <repo>/tests + residual token over tracked files
//   --staged       residual token over staged files; scan the index's tests/*.sh blobs
//                  only if a tests/*.sh is staged
//   --root <dir>   isolation scan of <dir> only
//   <file>...      isolation verdict for the named files only

const fs = require("fs");
const path = require("path");
const { parseShell } = require("./shell-lines");
const { analyze, verdict, isViolation } = require("./classify");
const { sourceEdges } = require("./source-resolve");
const { buildGraph } = require("./source-graph");
const { addDeclaredEdges } = require("./declared-parents");
const { listShellFiles, readIndexShellFiles } = require("./scan");
const residual = require("./residual-token");

// The module set may be copied into a throwaway repo, so the repo is located from here.
const REPO_ROOT = path.resolve(__dirname, "..", "..");
const TESTS_RE = /^tests\/.*\.sh$/;

class UsageError extends Error {}

// Git Bash may hand over /c/... paths; Node's fs needs C:/... on Windows.
function nativePath(p) {
  const m = process.platform === "win32" && /^\/([A-Za-z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

const slash = (p) => p.split(path.sep).join("/");

function parseArgs(argv) {
  const opts = { staged: false, root: null, files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--staged") opts.staged = true;
    else if (a === "--root") {
      if (i + 1 >= argv.length || argv[i + 1] === "") throw new UsageError("--root needs a directory");
      opts.root = argv[++i];
    } else if (a.startsWith("-")) throw new UsageError(`unknown option: ${a}`);
    else opts.files.push(a);
  }
  if (opts.files.length > 0 && (opts.staged || opts.root !== null)) {
    throw new UsageError("file arguments cannot be combined with --root or --staged");
  }
  if (opts.staged && opts.root !== null) throw new UsageError("--staged cannot be combined with --root");
  if (opts.root !== null && !fs.statSync(nativePath(opts.root), { throwIfNoEntry: false })?.isDirectory()) {
    throw new UsageError(`--root is not a directory: ${opts.root}`);
  }
  for (const f of opts.files) {
    if (!fs.statSync(nativePath(f), { throwIfNoEntry: false })?.isFile()) throw new UsageError(`no such file: ${f}`);
  }
  return opts;
}

const readWorktree = (file) => fs.readFileSync(file, "utf8");

// loadUnits(files, read) → Map<absPath, { text, lines, facts, edges }> (the files are read, never run).
function loadUnits(files, read) {
  const units = new Map();
  for (const file of files) {
    if (units.has(file)) continue;
    const text = read(file).replace(/\r\n/g, "\n");
    const lines = parseShell(text);
    units.set(file, { text, lines, facts: analyze(lines, text), edges: sourceEdges(file, lines, REPO_ROOT) });
  }
  addDeclaredEdges(units);
  return units;
}

// isolation(targets, universe, read) — targets: [{ abs, shown }]; universe adds parent candidates.
function isolation(targets, universe, read = readWorktree) {
  const units = loadUnits([...targets.map((t) => t.abs), ...universe], read);
  const graph = buildGraph(units);
  const out = [];
  for (const t of targets) {
    out.push(...verdict(t.shown, units.get(t.abs).facts, (kind) => graph.pinAt(t.abs, kind)));
  }
  return out;
}

function scanRoot(root, shownBase) {
  const files = listShellFiles(root);
  const targets = files.map((abs) => ({ abs, shown: slash(path.relative(shownBase, abs)) }));
  return isolation(targets, []);
}

function run(opts) {
  const testsRoot = path.join(REPO_ROOT, "tests");
  if (opts.root !== null) {
    const root = path.resolve(nativePath(opts.root));
    return scanRoot(root, root);
  }
  if (opts.files.length > 0) {
    const targets = opts.files.map((f) => ({ abs: path.resolve(nativePath(f)), shown: f.replace(/\\/g, "/") }));
    return isolation(targets, listShellFiles(testsRoot));
  }
  if (opts.staged) {
    const staged = residual.stagedPaths(REPO_ROOT);
    const out = residual.stagedHits(REPO_ROOT, staged);
    if (staged.some((p) => TESTS_RE.test(p))) {
      // The commit carries the index, so every tests/*.sh is judged by its staged blob.
      const blobs = readIndexShellFiles(REPO_ROOT, "tests");
      const targets = [...blobs.keys()].map((abs) => ({ abs, shown: slash(path.relative(REPO_ROOT, abs)) }));
      out.push(...isolation(targets, [], (file) => blobs.get(file)));
    }
    return out;
  }
  return [...scanRoot(testsRoot, REPO_ROOT), ...residual.trackedHits(REPO_ROOT)];
}

function main(argv) {
  let lines;
  try {
    lines = run(parseArgs(argv));
  } catch (e) {
    if (!(e instanceof UsageError)) throw e;
    process.stderr.write(`check-plans-dir-isolation: ${e.message}\n`);
    return 2;
  }
  lines.sort();
  if (lines.length > 0) process.stdout.write(lines.join("\n") + "\n");
  const violations = lines.filter(isViolation).length;
  if (violations === 0) return 0;
  process.stderr.write(
    `check-plans-dir-isolation: ${violations} violation(s). Pin WORKFLOW_STATE_DIR and ` +
      "WORKFLOW_PLANS_DIR once at top level before the first exec (rules/test/fixture-isolation.md).\n",
  );
  return 1;
}

process.exitCode = main(process.argv.slice(2));
