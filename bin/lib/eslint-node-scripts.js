"use strict";
// nodeShebangGlobs(root, dirs) — the extensionless node-shebang scripts under root/<dir>, as
// "/"-separated root-relative paths with glob special characters escaped, for the `files` of a
// flat config (ESLint's public type accepts strings only). node_modules and dot-directories are
// not entered; only the first line of the first 128 bytes of each file is read. Built-ins only.
const fs = require("fs");
const path = require("path");

const NODE_SHEBANG = /^#!.*\bnode\b/;
const HEAD_BYTES = 128;

const escapeGlob = (rel) => rel.replace(/[*?[\]{}()!+@\\]/g, (c) => `\\${c}`);

function firstLine(file) {
  let fd;
  try {
    fd = fs.openSync(file, "r");
    const buf = Buffer.alloc(HEAD_BYTES);
    const n = fs.readSync(fd, buf, 0, HEAD_BYTES, 0);
    return buf.subarray(0, n).toString("utf8").split(/\r?\n/)[0];
  } catch {
    return null;
  } finally {
    if (fd !== undefined) fs.closeSync(fd);
  }
}

function walk(root, relDir, out) {
  let entries;
  try {
    entries = fs.readdirSync(path.join(root, relDir), { withFileTypes: true });
  } catch {
    return;
  }
  for (const e of entries) {
    const rel = `${relDir}/${e.name}`;
    if (e.isDirectory()) {
      if (e.name !== "node_modules" && !e.name.startsWith(".")) walk(root, rel, out);
      continue;
    }
    if (!e.isFile() || path.extname(e.name) !== "") continue;
    const head = firstLine(path.join(root, rel));
    if (head !== null && NODE_SHEBANG.test(head)) out.push(escapeGlob(rel));
  }
}

function nodeShebangGlobs(root, dirs) {
  const out = [];
  for (const dir of dirs) walk(root, dir, out);
  return out;
}

module.exports = { nodeShebangGlobs };
