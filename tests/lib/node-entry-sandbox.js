#!/usr/bin/env node
"use strict";
// Copies an entry point and the Node code it runs into a test sandbox (#2507). A bash entry that
// became a thin adapter execs a Node module next to it; a sandbox holding only the bash file
// fails closed. Copied set: each named entry, every `.js` path a shell entry names, and the
// static require() closure of each JS file (a template-literal require copies its directory).
// Usage: node-entry-sandbox.js <src-root> <dest-root> <repo-relative entry>...
// Exit: 0 copied, 1 an entry or a resolved module is missing, 2 usage error.

const fs = require("fs");
const path = require("path");

const JS_EXT = /\.(c|m)?js$/;

function resolveModule(fromFile, spec) {
  const base = path.resolve(path.dirname(fromFile), spec);
  for (const c of [base, `${base}.js`, `${base}.json`, path.join(base, "index.js")]) {
    if (fs.existsSync(c) && fs.statSync(c).isFile()) return c;
  }
  return null;
}

function jsFilesUnder(dir) {
  if (!fs.existsSync(dir)) return [];
  return fs.readdirSync(dir, { withFileTypes: true }).flatMap((d) => {
    const p = path.join(dir, d.name);
    if (d.isDirectory()) return jsFilesUnder(p);
    return JS_EXT.test(d.name) ? [p] : [];
  });
}

// .js paths a shell adapter names ("$(dirname "$0")/x.d/cli.js", "$cfg/hooks/pre-commit.d/main.js").
function shellTargets(srcRoot, file) {
  const text = fs.readFileSync(file, "utf8");
  const out = [];
  for (const m of text.matchAll(/([A-Za-z0-9._-]+(?:\/[A-Za-z0-9._-]+)*\.js)\b/g)) {
    for (const cand of [path.resolve(path.dirname(file), m[1]), path.resolve(srcRoot, m[1])]) {
      if (fs.existsSync(cand) && fs.statSync(cand).isFile()) out.push(cand);
    }
  }
  return out;
}

function requireTargets(file) {
  const text = fs.readFileSync(file, "utf8");
  const out = [];
  for (const m of text.matchAll(/require\(\s*(['"`])(\.{1,2}\/[^'"`]*)\1\s*\)/g)) {
    const r = resolveModule(file, m[2]);
    if (r) out.push(r);
  }
  for (const m of text.matchAll(/require\(\s*`(\.{1,2}\/[^`$]*\/)\$\{/g)) {
    out.push(...jsFilesUnder(path.resolve(path.dirname(file), m[1])));
  }
  return out;
}

function closure(srcRoot, entries) {
  const seen = new Set();
  const stack = entries.map((e) => path.resolve(srcRoot, e));
  while (stack.length) {
    const f = stack.pop();
    if (seen.has(f)) continue;
    if (!fs.existsSync(f)) throw new Error(`missing: ${path.relative(srcRoot, f)}`);
    seen.add(f);
    if (JS_EXT.test(f)) stack.push(...requireTargets(f));
    else if (!f.endsWith(".json")) stack.push(...shellTargets(srcRoot, f));
  }
  return [...seen];
}

function main(argv) {
  if (argv.length < 3) {
    process.stderr.write("usage: node-entry-sandbox.js <src-root> <dest-root> <entry>...\n");
    return 2;
  }
  const [srcRoot, destRoot, ...entries] = argv.map((a, i) => (i < 2 ? path.resolve(a) : a));
  let files;
  try {
    files = closure(srcRoot, entries);
  } catch (e) {
    process.stderr.write(`node-entry-sandbox: ${e.message}\n`);
    return 1;
  }
  for (const f of files) {
    const dest = path.join(destRoot, path.relative(srcRoot, f));
    fs.mkdirSync(path.dirname(dest), { recursive: true });
    fs.copyFileSync(f, dest);
    fs.chmodSync(dest, fs.statSync(f).mode);
  }
  return 0;
}

if (require.main === module) process.exitCode = main(process.argv.slice(2));

module.exports = { closure };
