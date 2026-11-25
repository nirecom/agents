"use strict";
// hooks/lib/plan-sync/scan-gate.js
// The pre-push outbound scan of plan-sync (#3150): the target plan and the carried entries not
// yet passed go to bin/scan-outbound.sh --manifest in one launch, within the sync deadline.
// check(carried) -> {ok: true, scanSkipped?} | {ok: false, reason, findings}; reasons are
// scan-blocked (rc 1), scan-unavailable and scan-timeout. Findings carry {rel, line, kind} only.
// A user-approved skip (remote-state.js) lets an unavailable / timed-out scan through once.
const path = require("path");
const { spawnSync } = require("child_process");
const G = require("./git");
const RS = require("./remote-state");
const { toWindowsPath } = require("../branch-diff");

const DEFAULT_ENTRY = path.join(__dirname, "..", "..", "..", "bin", "scan-outbound.sh");
const MAX_BUFFER = 64 * 1024 * 1024;
const RS_BYTE = Buffer.from("\x1e");
const BLOB_ID = /^[0-9a-f]{40}([0-9a-f]{24})?$/;
const UNAVAILABLE = Object.freeze({ ok: false, reason: "scan-unavailable", findings: [] });
const TIMEOUT = Object.freeze({ ok: false, reason: "scan-timeout", findings: [] });

const shellPath = (p) => String(p).split(path.sep).join("/");
const timedOut = (r) => Boolean(r.error && r.error.code === "ETIMEDOUT");

// readBlobs(plansDir, ids, timeout) -> Map id -> Buffer | TIMEOUT | null (a blob not readable).
function readBlobs(plansDir, ids, timeout) {
  if (ids.length === 0) return new Map();
  if (!ids.every((id) => BLOB_ID.test(id))) return null;
  const r = spawnSync("git", ["-C", plansDir, "-c", `core.hooksPath=${G.NULL_DEV}`, "cat-file", "--batch"], {
    input: `${ids.join("\n")}\n`, env: G.buildEnv(), timeout, windowsHide: true, maxBuffer: MAX_BUFFER,
  });
  if (timedOut(r)) return TIMEOUT;
  if (r.error || r.status !== 0 || !Buffer.isBuffer(r.stdout)) return null;
  const out = new Map();
  let pos = 0;
  for (const id of ids) {
    const nl = r.stdout.indexOf(0x0a, pos);
    if (nl < 0) return null;
    const head = r.stdout.subarray(pos, nl).toString("utf8").split(" ");
    const size = Number(head[2]);
    if (head[0] !== id || head[1] !== "blob" || !Number.isInteger(size) || nl + 1 + size > r.stdout.length) return null;
    out.set(id, r.stdout.subarray(nl + 1, nl + 1 + size));
    pos = nl + 1 + size + 1;
  }
  return out;
}

const frame = (rel, bytes) => Buffer.concat([RS_BYTE, Buffer.from(rel, "utf8"), RS_BYTE, Buffer.from(`${bytes.length}\n`), bytes]);

// parseFindings(stdout, labels) -> [{rel, line, kind}] — each line is attributed to the longest
// label it starts with ("<label>:<line>: [kind] ..."); the matched text is dropped, warn lines too.
function parseFindings(stdout, labels) {
  const byLength = [...labels].sort((a, b) => b.length - a.length);
  const out = [];
  for (const row of String(stdout || "").split(/\r?\n/)) {
    const rel = byLength.find((l) => row.startsWith(`${l}:`));
    if (!rel) continue;
    const m = /^(\d+): \[([^\]]+)\]/.exec(row.slice(rel.length + 1));
    if (m && m[2] !== "blocklist-warn") out.push({ rel, line: Number(m[1]), kind: m[2] });
  }
  return out;
}

// scanEntries(plansDir, pending, entry, deadline) -> {ok: true} | a failed verdict.
function scanEntries(plansDir, pending, entry, deadline) {
  const remaining = () => Number(deadline) - Date.now();
  if (!(remaining() > 0)) return TIMEOUT;
  const ids = [...new Set(pending.filter((e) => !Buffer.isBuffer(e.bytes)).map((e) => e.blob))];
  const blobs = readBlobs(plansDir, ids, remaining());
  if (blobs === TIMEOUT) return TIMEOUT;
  if (blobs === null) return UNAVAILABLE;
  const input = Buffer.concat(pending.map((e) => frame(e.rel, Buffer.isBuffer(e.bytes) ? e.bytes : blobs.get(e.blob))));
  if (!(remaining() > 0)) return TIMEOUT;
  const r = spawnSync("bash", [shellPath(entry), "--manifest"], {
    input, cwd: toWindowsPath(plansDir), env: G.buildEnv(), timeout: remaining(), windowsHide: true, maxBuffer: MAX_BUFFER,
  });
  if (timedOut(r)) return TIMEOUT;
  if (r.error || r.signal || r.status === null) return UNAVAILABLE;
  if (r.status === 0 || r.status === 2) return { ok: true };
  if (r.status === 1) {
    const findings = parseFindings(r.stdout, new Set(pending.map((e) => e.rel)));
    return { ok: false, reason: "scan-blocked", findings };
  }
  return UNAVAILABLE;
}

// createScanGate(plansDir, {rel, bytes, blob}, {deadline, deps}) -> {check(carried)}.
// deps.scanEntry (a .sh path) is the test seam; production always runs bin/scan-outbound.sh.
function createScanGate(plansDir, target, opts) {
  const o = opts || {};
  const deps = o.deps || {};
  const entry = typeof deps.scanEntry === "string" && deps.scanEntry ? deps.scanEntry : DEFAULT_ENTRY;
  const passed = new Set();
  let skipped = false;
  const pass = (pending) => {
    for (const e of pending) passed.add(e.blob);
    return skipped ? { ok: true, scanSkipped: true } : { ok: true };
  };
  function check(carried) {
    const rest = (carried || []).filter((c) => c && c.rel !== target.rel);
    const pending = [target].concat(rest).filter((e) => !passed.has(e.blob));
    if (pending.length === 0) return pass(pending);
    const verdict = scanEntries(plansDir, pending, entry, o.deadline);
    if (verdict.ok) return pass(pending);
    if (verdict.reason !== "scan-blocked" && RS.takeScanSkip(plansDir, target.blob)) {
      skipped = true;
      return pass(pending);
    }
    return { ok: false, reason: verdict.reason, findings: verdict.findings.slice() };
  }
  return { check };
}

module.exports = { createScanGate };
