"use strict";
// git reads of the test-gate CLIs (#2507 D7): the toplevel, and blobs by object name (":<rel>"
// the staged blob, "HEAD:<rel>" the HEAD one) through one `git cat-file --batch`.

const { toWindowsPath } = require("../branch-diff");

const TIMEOUT_MS = 60000;
const MAX_BUFFER = 1024 * 1024 * 1024;

function git(cwd, env, args, input) {
  const cp = require("node:child_process");
  return cp.spawnSync("git", args, { cwd: toWindowsPath(String(cwd)), env, input, timeout: TIMEOUT_MS, maxBuffer: MAX_BUFFER, windowsHide: true });
}

// toplevel(cwd, env) — the repository root (forward slashes), or "" outside a repository.
function toplevel(cwd, env) {
  const r = git(cwd, env, ["rev-parse", "--show-toplevel"]);
  if (r.error || r.status !== 0) return "";
  return String(r.stdout).replace(/\r?\n$/, "");
}

// blobs(cwd, env, names) -> Map name -> Buffer (blob objects only). A name with a newline is not
// asked; a missing object or a non-blob (tree, ...) is left out. Any other gap in the batch
// (spawn error, non-zero exit, signal, truncated or malformed reply) throws, so a caller never
// reads "blob absent" where git failed.
function blobs(cwd, env, names) {
  const out = new Map();
  const asked = [...new Set(names)].filter((n) => !n.includes("\n"));
  if (asked.length === 0) return out;
  const r = git(cwd, env, ["cat-file", "--batch"], `${asked.join("\n")}\n`);
  if (r.error) throw new Error(`git cat-file --batch: ${r.error.code || r.error.message}`);
  if (r.signal) throw new Error(`git cat-file --batch: killed by ${r.signal}`);
  if (r.status !== 0) {
    const why = r.stderr ? String(r.stderr).trim() : "";
    throw new Error(`git cat-file --batch rc=${r.status}${why ? `: ${why}` : ""}`);
  }
  const buf = r.stdout || Buffer.alloc(0);
  const bad = (name, why) => new Error(`git cat-file --batch: ${name}: ${why}`);
  let pos = 0;
  for (const name of asked) {
    const nl = buf.indexOf(0x0a, pos);
    if (nl < 0) throw bad(name, "no reply header (truncated batch)");
    const line = buf.subarray(pos, nl).toString("utf8");
    pos = nl + 1;
    if (line.endsWith(" missing")) continue;
    const header = line.split(" ");
    if (header.length !== 3) throw bad(name, `malformed header ${JSON.stringify(line)}`);
    const [, type, sizeText] = header;
    if (!/^[0-9]+$/.test(sizeText)) throw bad(name, `invalid size ${JSON.stringify(sizeText)}`);
    const end = pos + Number(sizeText);
    if (end > buf.length) throw bad(name, `body shorter than size ${sizeText}`);
    // The LF must sit right after the body; a size off by one lands on a body byte instead.
    if (buf[end] !== 0x0a) throw bad(name, `no LF after a body of size ${sizeText}`);
    if (type === "blob") out.set(name, buf.subarray(pos, end));
    pos = end + 1;
  }
  if (pos !== buf.length) throw new Error(`git cat-file --batch: ${buf.length - pos} bytes after the last reply`);
  return out;
}

module.exports = { toplevel, blobs };
