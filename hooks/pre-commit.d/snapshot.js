"use strict";
// Staged snapshot of the commit (#2507, D3): the staged names, modes and blob ids from one
// `git diff --cached --raw -z`, and both blob sides read in one `git cat-file --batch`.
// git inherits GIT_INDEX_FILE, so a `git commit <paths>` temporary index is the one read.

const { spawnSync } = require("../lib/limited-child-process");
const { toWindowsPath } = require("../lib/branch-diff");

const GIT_TIMEOUT_MS = 60000;
const MAX_BUFFER = 1024 * 1024 * 1024;
const ZERO_OID = /^0+$/;

function git(repoTop, env, args, input) {
  const r = spawnSync("git", args, { cwd: repoTop, env, input, timeout: GIT_TIMEOUT_MS, maxBuffer: MAX_BUFFER, windowsHide: true });
  if (r.error) throw r.error;
  return { status: r.status, stdout: r.stdout || Buffer.alloc(0), stderr: r.stderr ? r.stderr.toString("utf8") : "" };
}

// parseRaw(buf) -> [{ path, status, oldMode, newMode, oldOid, newOid }] of a -z --raw listing.
function parseRaw(buf) {
  const parts = buf.toString("utf8").split("\0");
  const rows = [];
  for (let i = 0; i + 1 < parts.length; i += 2) {
    const head = parts[i];
    if (!head.startsWith(":")) break;
    const [oldMode, newMode, oldOid, newOid, status] = head.slice(1).split(" ");
    rows.push({ path: parts[i + 1], status: status.charAt(0), oldMode, newMode, oldOid, newOid });
  }
  return rows;
}

// readBlobs(oids) -> Map oid -> Buffer, from one cat-file --batch call. Every requested oid must
// come back as an intact blob reply; any other reply throws, so a scan never reads a gap as clean.
function readBlobs(repoTop, env, oids) {
  const blobs = new Map();
  if (oids.length === 0) return blobs;
  const r = git(repoTop, env, ["cat-file", "--batch"], `${oids.join("\n")}\n`);
  if (r.status !== 0) throw new Error(`git cat-file --batch rc=${r.status}: ${r.stderr.trim()}`);
  const buf = r.stdout;
  const bad = (oid, why) => new Error(`git cat-file --batch: ${oid}: ${why}`);
  let pos = 0;
  for (const oid of oids) {
    const nl = buf.indexOf(0x0a, pos);
    if (nl < 0) throw bad(oid, "no reply header (truncated batch)");
    const line = buf.subarray(pos, nl).toString("utf8");
    const header = line.split(" ");
    if (header[1] === "missing") throw bad(oid, "object missing");
    if (header.length !== 3) throw bad(oid, `malformed header ${JSON.stringify(line)}`);
    const [gotOid, type, sizeText] = header;
    if (gotOid !== oid) throw bad(oid, `reply is for ${gotOid}`);
    if (type !== "blob") throw bad(oid, `type ${type}, not blob`);
    if (!/^\d+$/.test(sizeText)) throw bad(oid, `invalid size ${JSON.stringify(sizeText)}`);
    const start = nl + 1;
    const end = start + Number(sizeText);
    if (end >= buf.length) throw bad(oid, `body shorter than size ${sizeText} or no LF after it`);
    // The LF must sit right after the body; a size off by one lands on a body byte instead.
    if (buf[end] !== 0x0a) throw bad(oid, `no LF after a body of size ${sizeText}`);
    blobs.set(oid, buf.subarray(start, end));
    pos = end + 1;
  }
  return blobs;
}

async function createSnapshot({ repoTop, env }) {
  const top = toWindowsPath(repoTop);
  const genv = env || process.env;
  let state = null;
  let blobs = null;
  let head = null;

  const load = () => {
    if (state) return state;
    const r = git(top, genv, ["diff", "--cached", "--raw", "-z", "--no-renames", "--no-abbrev", "--ignore-submodules=none"]);
    if (r.status !== 0) throw new Error(`git diff --cached rc=${r.status}: ${r.stderr.trim()}`);
    const rows = parseRaw(r.stdout);
    state = { rows, byPath: new Map(rows.map((row) => [row.path, row])) };
    return state;
  };
  const isBlob = (mode, oid) => mode && mode !== "160000" && mode !== "000000" && oid && !ZERO_OID.test(oid);
  const loadBlobs = () => {
    if (blobs) return blobs;
    const oids = new Set();
    for (const row of load().rows) {
      if (isBlob(row.newMode, row.newOid)) oids.add(row.newOid);
      if (isBlob(row.oldMode, row.oldOid)) oids.add(row.oldOid);
    }
    blobs = readBlobs(top, genv, [...oids]);
    return blobs;
  };
  const blobOf = (oid) => {
    const b = loadBlobs().get(oid);
    if (!b) throw new Error(`git cat-file --batch: ${oid}: not read`);
    return b;
  };

  const snapshot = {
    repoTop: top,
    rows: () => load().rows.slice(),
    files: () => load().rows.filter((row) => row.status !== "D").map((row) => row.path),
    status: (p) => (load().byPath.get(p) || {}).status || null,
    mode: (p) => {
      const row = load().byPath.get(p);
      return row && row.status !== "D" ? row.newMode : null;
    },
    content: (p) => {
      const row = load().byPath.get(p);
      if (!row || !isBlob(row.newMode, row.newOid)) return null;
      return blobOf(row.newOid);
    },
    headContent: (p) => {
      const row = load().byPath.get(p);
      if (!row || !isBlob(row.oldMode, row.oldOid)) return null;
      return blobOf(row.oldOid);
    },
    hasHead: () => {
      if (head === null) head = git(top, genv, ["rev-parse", "--verify", "-q", "HEAD"]).status === 0;
      return head;
    },
    invalidate: () => {
      state = null;
      blobs = null;
    },
  };
  load();
  return snapshot;
}

module.exports = { createSnapshot, parseRaw };
