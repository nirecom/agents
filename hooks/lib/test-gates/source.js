"use strict";
// What the gates read (#2507 D7): a path on disk, or an in-memory file { name, text } (a staged
// or HEAD blob the pre-commit snapshot holds), so the in-process parts read no temp file.
// diskCopy is the one exception: a pester / pytest child can only open a path.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { toWindowsPath } = require("../branch-diff");

const isMem = (f) => f !== null && typeof f === "object" && typeof f.text === "string";
// mem(name, content) — content is a string, or a Buffer kept as `bytes` beside its utf8 text.
function mem(name, content) {
  if (Buffer.isBuffer(content)) return { name: String(name), text: content.toString("utf8"), bytes: content };
  return { name: String(name), text: String(content) };
}

// textOf(file, encoding) — the file's text; throws when a path cannot be read.
function textOf(file, encoding = "utf8") {
  if (isMem(file)) return file.text;
  return fs.readFileSync(toWindowsPath(String(file)), encoding);
}

// bytesOf(file) — the file's bytes (an in-memory file's own `bytes` when it carries them).
function bytesOf(file) {
  if (isMem(file)) return Buffer.isBuffer(file.bytes) ? file.bytes : Buffer.from(file.text, "utf8");
  return fs.readFileSync(toWindowsPath(String(file)));
}

// isFile(file) — an in-memory file, or a regular file on disk.
function isFile(file) {
  if (isMem(file)) return true;
  try {
    return fs.statSync(toWindowsPath(String(file))).isFile();
  } catch {
    return false;
  }
}

// diskCopy(file, fn) — fn(path): a path as is; an in-memory file written under a temp dir with
// its basename (the readers key on it), removed after fn.
function diskCopy(file, fn) {
  if (!isMem(file)) return fn(file);
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "test-gates-"));
  try {
    const abs = path.join(dir, path.posix.basename(file.name.replace(/\\/g, "/")) || "file");
    fs.writeFileSync(abs, bytesOf(file));
    return fn(abs);
  } finally {
    fs.rmSync(dir, { recursive: true, force: true });
  }
}

module.exports = { isMem, mem, textOf, bytesOf, isFile, diskCopy };
