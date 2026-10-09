"use strict";

// CLI for bin/check-root-names.sh (#2561): the root-name gate.
// Exit 0 = clean, 1 = violation, 2 = usage error or unreadable input (never "clean").
//   (no args)      every check over the tracked files of this checkout
//   --staged       the staged files, the retired-name list and the table, all from the index
//   --root <dir>   the tracked files of <dir> (working-tree content)
//   <file>...      the named files only
//   --repo agents|dotfiles   which rule set classifies the files (default agents)
//   --only <check>           one of the checks below
//   --scope <prefix>         keep the files at or below a repo-relative prefix
//   --retired-names-from <file>   read the retired-name list from another file

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const residue = require("./residue");
const tableMatch = require("./table-match");

// The module set may be copied into a throwaway repo, so the checkout is located from here.
const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const LIST_REL = "tests/bin/feature-2561-root-names-residue.sh";
const TABLE_REL = "bin/check-root-names/classification.json";
const CHECKS = {
  residue,
  "table-match": tableMatch,
  structural: require("./structural"),
  "script-root-form": require("./script-root-form"),
  "env-name": require("./env-name"),
};
const REPOS = ["agents", "dotfiles"];
const VALUE_FLAGS = { "--root": "root", "--repo": "repo", "--only": "only", "--scope": "scope", "--retired-names-from": "listFile" };

class UsageError extends Error {}

// Git Bash may hand over /c/... paths; Node's fs needs C:/... on Windows.
function nativePath(p) {
  const m = process.platform === "win32" && /^\/([A-Za-z])(\/.*)?$/.exec(p);
  return m ? `${m[1].toUpperCase()}:${m[2] || "/"}` : p;
}

const slash = (p) => p.split(path.sep).join("/");
const statOf = (p) => fs.statSync(p, { throwIfNoEntry: false });

function parseArgs(argv) {
  const opts = { staged: false, root: null, repo: "agents", only: null, scope: null, listFile: null, files: [] };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--staged") opts.staged = true;
    else if (Object.hasOwn(VALUE_FLAGS, a)) {
      if (i + 1 >= argv.length || argv[i + 1] === "") throw new UsageError(`${a} needs a value`);
      opts[VALUE_FLAGS[a]] = argv[++i];
    } else if (a.startsWith("-")) throw new UsageError(`unknown option: ${a}`);
    else opts.files.push(a);
  }
  const inputs = [opts.staged, opts.root !== null, opts.files.length > 0].filter(Boolean).length;
  if (inputs > 1) throw new UsageError("--staged, --root and file arguments exclude each other");
  if (!REPOS.includes(opts.repo)) throw new UsageError("--repo must be agents or dotfiles");
  if (opts.only !== null && !Object.hasOwn(CHECKS, opts.only)) throw new UsageError("--only names no known check");
  if (opts.root !== null && !statOf(nativePath(opts.root))?.isDirectory()) throw new UsageError("--root is not a directory");
  for (const f of opts.files) {
    if (!statOf(nativePath(f))?.isFile()) throw new UsageError(`no such file: ${f}`);
  }
  return opts;
}

function git(root, args) {
  const r = spawnSync("git", ["-C", root, ...args], { maxBuffer: 1 << 30, windowsHide: true });
  return r.status === 0 ? r.stdout : null;
}

const nulList = (buf) => buf.toString("utf8").split("\0").filter((s) => s !== "");

// A file with a NUL byte is binary: its path is still judged, its content is not.
const textOf = (buf) => (buf.subarray(0, 8000).includes(0) ? null : buf.toString("utf8"));

function walk(root, dir, out) {
  for (const entry of fs.readdirSync(path.join(root, dir), { withFileTypes: true })) {
    const rel = dir === "" ? entry.name : `${dir}/${entry.name}`;
    if (entry.isDirectory()) {
      if (entry.name !== ".git" && entry.name !== "node_modules") walk(root, rel, out);
    } else if (entry.isFile()) out.push(rel);
  }
  return out;
}

// treeFiles(root) → the tracked files of the tree (every file when it is not a git tree).
function treeFiles(root) {
  const listed = git(root, ["rev-parse", "--show-prefix"]) === null ? null : git(root, ["ls-files", "-z"]);
  const rels = listed === null ? walk(root, "", []) : nulList(listed);
  const files = [];
  for (const rel of rels) {
    const abs = path.join(root, rel);
    if (fs.lstatSync(abs, { throwIfNoEntry: false })?.isFile()) files.push({ rel, text: textOf(fs.readFileSync(abs)) });
  }
  return files;
}

function stagedFiles(root) {
  const listed = git(root, ["diff", "--cached", "--name-only", "-z", "--diff-filter=ACMR"]);
  if (listed === null) throw new UsageError("cannot read the index");
  const entries = git(root, ["ls-files", "-s", "-z"]);
  if (entries === null) throw new UsageError("cannot read the index");
  // A gitlink (mode 160000) has no blob; every other staged path must be readable.
  const gitlinks = new Set(nulList(entries).filter((e) => e.startsWith("160000 ")).map((e) => e.slice(e.indexOf("\t") + 1)));
  const files = [];
  for (const rel of nulList(listed)) {
    if (gitlinks.has(rel)) continue;
    const blob = git(root, ["show", `:${rel}`]);
    if (blob === null) throw new UsageError(`cannot read the staged content of ${rel}`);
    files.push({ rel, text: textOf(blob) });
  }
  return files;
}

function namedFiles(names) {
  return names.map((name) => {
    const abs = path.resolve(nativePath(name));
    const rel = slash(path.relative(SCRIPT_CHECKOUT_ROOT, abs));
    const outside = rel.startsWith("..") || path.isAbsolute(rel);
    return { rel: outside ? name.replace(/\\/g, "/") : rel, text: textOf(fs.readFileSync(abs)) };
  });
}

// ownInput(rel, staged) → the gate's own data file, from the index when judging the index.
function ownInput(rel, staged) {
  if (staged) {
    const blob = git(SCRIPT_CHECKOUT_ROOT, ["show", `:${rel}`]);
    if (blob === null) throw new UsageError(`the index does not hold ${rel}`);
    return blob.toString("utf8");
  }
  return readInput(path.join(SCRIPT_CHECKOUT_ROOT, rel), rel);
}

function readInput(abs, shown) {
  try {
    return fs.readFileSync(abs, "utf8");
  } catch {
    throw new UsageError(`cannot read ${shown}`);
  }
}

function inScope(rel, scope) {
  const prefix = scope.replace(/\\/g, "/").replace(/\/+$/, "");
  return rel === prefix || rel.startsWith(`${prefix}/`);
}

function run(opts) {
  let files;
  if (opts.staged) files = stagedFiles(SCRIPT_CHECKOUT_ROOT);
  else if (opts.files.length > 0) files = namedFiles(opts.files);
  else files = treeFiles(opts.root === null ? SCRIPT_CHECKOUT_ROOT : path.resolve(nativePath(opts.root)));
  if (opts.scope !== null) files = files.filter((f) => inScope(f.rel, opts.scope));
  // An empty index is a real answer; an empty tree or scope means the gate looked at nothing.
  if (!opts.staged && files.length === 0) throw new UsageError("no file to check");
  let list = null;
  let table = null;
  const ctx = {
    files,
    repo: opts.repo,
    list: () => {
      if (list === null) {
        const text = opts.listFile === null ? ownInput(LIST_REL, opts.staged) : readInput(path.resolve(nativePath(opts.listFile)), "the retired-name list");
        list = residue.parseList(text, LIST_REL);
      }
      return list;
    },
    table: () => {
      if (table === null) table = tableMatch.parseTable(ownInput(TABLE_REL, opts.staged));
      return table;
    },
  };
  const names = opts.only === null ? Object.keys(CHECKS) : [opts.only];
  return names.flatMap((name) => CHECKS[name].check(ctx));
}

function main(argv) {
  let lines;
  try {
    lines = run(parseArgs(argv));
  } catch (e) {
    // Anything that stops a check from finishing is an error, never a clean verdict.
    process.stderr.write(`check-root-names: ${e instanceof Error ? e.message : String(e)}\n`);
    return 2;
  }
  lines = [...new Set(lines)].sort();
  if (lines.length === 0) return 0;
  process.stdout.write(lines.join("\n") + "\n");
  process.stderr.write(`check-root-names: ${lines.length} violation(s). See docs or the classification table next to this gate.\n`);
  return 1;
}

process.exitCode = main(process.argv.slice(2));
