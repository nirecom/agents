"use strict";
// bin/lib/review-scope-header-targets.js — the staged-test → `Tests:` header map for the #2327
// re-review delta. Reads staged blobs (one `git cat-file --batch`), writes them to a temp dir and
// lets bin/review-scope-header-targets.sh (the bash SSOT tokenizer) parse them in one bash run.
// REVIEW_SCOPE_HEADER_TARGETS_BASH overrides the bash executable — a test seam only.
// Any failure yields { ok: false, error }, which the caller turns into a full review.

const fs = require("fs");
const os = require("os");
const path = require("path");
const { spawnSync } = require("child_process");
const { isReviewScopeExcludedPath, isReviewScopeTestPath } = require("../../hooks/workflow-gate/review-tests-evidence");
const { posixJoin } = require("../../hooks/lib/confirm-gate/probe");
const { toWindowsPath } = require("../../hooks/lib/branch-diff");

const SCRIPT = posixJoin(__dirname, "..", "review-scope-header-targets.sh");
const MAX_BUFFER = 8 * 1024 * 1024;
const TIMEOUT_MS = 20000;

function setKey(obj, key, value) {
  Object.defineProperty(obj, key, { value, enumerable: true, writable: true, configurable: true });
}

// <rel>\0<n>\0<tok>\0… records, one per expected path in order → { rel: [tok] }, or null.
function parseHeaderTargetsOutput(buf, expectedPaths) {
  const b = Buffer.from(buf || []);
  const targets = {};
  if (b.length === 0) return expectedPaths.length === 0 ? targets : null;
  if (b[b.length - 1] !== 0) return null;
  const fields = b.subarray(0, b.length - 1).toString("utf8").split("\0");
  let i = 0;
  for (const rel of expectedPaths) {
    if (fields[i] !== rel || !/^\d+$/.test(fields[i + 1] || "")) return null;
    const n = Number(fields[i + 1]);
    if (i + 2 + n > fields.length) return null;
    setKey(targets, rel, fields.slice(i + 2, i + 2 + n));
    i += 2 + n;
  }
  return i === fields.length ? targets : null;
}

// One `git cat-file --batch` for every OID → Buffer[] in order; throws on missing / non-blob.
function readBlobs(repoDir, oids) {
  const res = spawnSync("git", ["cat-file", "--batch"], {
    cwd: repoDir, input: oids.map((o) => `${o}\n`).join(""),
    timeout: TIMEOUT_MS, maxBuffer: MAX_BUFFER, windowsHide: true,
  });
  if (res.error) throw res.error;
  if (res.status !== 0) throw new Error(`git cat-file exited ${res.status}: ${String(res.stderr || "").trim()}`);
  const out = res.stdout;
  const blobs = [];
  let pos = 0;
  for (const oid of oids) {
    const nl = out.indexOf(0x0a, pos);
    if (nl < 0) throw new Error(`git cat-file: truncated reply for ${oid}`);
    const parts = out.subarray(pos, nl).toString("utf8").split(" ");
    if (parts.length !== 3 || parts[1] !== "blob" || !/^\d+$/.test(parts[2])) {
      throw new Error(`git cat-file: not a readable blob: ${parts.join(" ")}`);
    }
    const end = nl + 1 + Number(parts[2]);
    if (end > out.length) throw new Error(`git cat-file: truncated blob ${oid}`);
    blobs.push(out.subarray(nl + 1, end));
    pos = end + 1;
  }
  return blobs;
}

function defaultRunBash(exe, args, options) {
  return spawnSync(exe, args, options);
}

function bashFailure(res) {
  if (res.error) return `bash could not run: ${res.error.code || ""} ${res.error.message || res.error}`.trim();
  if (res.signal) return `bash killed by ${res.signal}`;
  if (res.status !== 0) return `bash exited ${res.status}: ${String(res.stderr || "").trim()}`;
  return null;
}

// files: the review-scope manifest's { path: blobOid }. → { ok: true, targets } | { ok: false, error }.
function buildHeaderTargets(repoDir, files, opts) {
  const runBash = (opts && opts.runBash) || defaultRunBash;
  const tests = Object.keys(files || {})
    .filter((p) => isReviewScopeTestPath(p) && !isReviewScopeExcludedPath(p)).sort();
  if (tests.length === 0) return { ok: true, targets: {} };
  let tmp = null;
  try {
    const blobs = readBlobs(toWindowsPath(repoDir), tests.map((p) => files[p]));
    tmp = fs.mkdtempSync(path.join(os.tmpdir(), "review-scope-header-targets-"));
    tests.forEach((rel, i) => {
      const dest = path.join(tmp, rel);
      fs.mkdirSync(path.dirname(dest), { recursive: true });
      fs.writeFileSync(dest, blobs[i]);
    });
    const bashExe = process.env.REVIEW_SCOPE_HEADER_TARGETS_BASH || "bash";
    const res = runBash(bashExe, [SCRIPT, posixJoin(tmp)], {
      input: Buffer.from(tests.map((p) => `${p}\0`).join(""), "utf8"),
      timeout: TIMEOUT_MS, maxBuffer: MAX_BUFFER, windowsHide: true,
    });
    const failure = bashFailure(res || { error: new Error("no result") });
    if (failure) return { ok: false, error: failure };
    const targets = parseHeaderTargetsOutput(res.stdout, tests);
    if (!targets) return { ok: false, error: "malformed header-targets output" };
    return { ok: true, targets };
  } catch (e) {
    return { ok: false, error: String((e && e.message) || e) };
  } finally {
    if (tmp) {
      try {
        fs.rmSync(tmp, { recursive: true, force: true });
      } catch { /* best effort; the decision does not depend on cleanup */ }
    }
  }
}

module.exports = { buildHeaderTargets, parseHeaderTargetsOutput };
