"use strict";
// Detector for the lint-* cases of tests/hooks/unit-read-stdin.sh.
//   node scan.js tree <agentsDir>     -> every in-scope file that matches, relative, one per line
//   node scan.js files <path>...      -> each given path that matches, as given, one per line
// Comments are NOT skipped: a detector that tells comments from code opens the
// commented-out-line and string-concatenation escape routes.
const fs = require("fs");
const path = require("path");

const PATTERNS = [
  /readSync\(\s*(0|process\.stdin\.fd)\s*,/,
  /readFileSync\(\s*(0|process\.stdin\.fd|["']\/dev\/stdin["'])/,
];
const SHARED_READER = "hooks/lib/read-stdin.js";

const matches = (file) => {
  let text;
  try { text = fs.readFileSync(file, "utf8"); } catch (_) { return false; }
  return PATTERNS.some((re) => re.test(text));
};

const walk = (dir, out) => {
  let entries;
  try { entries = fs.readdirSync(dir, { withFileTypes: true }); } catch (_) { return out; }
  for (const e of entries) {
    if (e.name === "node_modules" || e.name === ".git") continue;
    const p = path.join(dir, e.name);
    if (e.isDirectory()) walk(p, out);
    else if (e.isFile()) out.push(p);
  }
  return out;
};

const [mode, ...args] = process.argv.slice(2);
if (mode === "tree") {
  const root = args[0];
  const rel = (p) => path.relative(root, p).split(path.sep).join("/");
  // hooks: *.js only. bin: every file, extensionless included (bin/scan-offensive).
  const hooks = walk(path.join(root, "hooks"), []).filter((p) => p.endsWith(".js") && rel(p) !== SHARED_READER);
  const bin = walk(path.join(root, "bin"), []);
  const hits = hooks.concat(bin).filter(matches).map(rel).sort();
  if (hooks.length === 0 || bin.length === 0) { process.stderr.write("empty scan scope\n"); process.exit(4); }
  process.stdout.write(hits.map((h) => h + "\n").join(""));
} else if (mode === "files") {
  process.stdout.write(args.filter(matches).map((f) => f + "\n").join(""));
} else {
  process.stderr.write("usage: scan.js tree <agentsDir> | files <path>...\n");
  process.exit(2);
}
