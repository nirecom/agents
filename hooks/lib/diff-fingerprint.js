"use strict";

// #2256 S2-e / round-2 C2+C4 — content-hash fingerprints.
// The version hashes file CONTENT, never diff text: `Binary files ... differ`,
// `.gitattributes -diff` and textconv holes must all still move it.
// Every digest is the full 64-hex sha256 — truncation is what let a moved input
// look fresh, so nothing here ever slices a digest.

const fs = require("fs");
const path = require("path");
const crypto = require("crypto");
const { spawnSync } = require("child_process");
const { computeWorkingTreeDiff, toWindowsPath } = require("./branch-diff");
const { getWorkflowPlansDir } = require("./workflow-plans-dir");

const CHUNK_BYTES = 64 * 1024;
const ARTIFACT_NAMES = ["intent", "outline", "detail"];

function streamFileInto(hash, absPath) {
  const fd = fs.openSync(absPath, "r");
  try {
    const buf = Buffer.allocUnsafe(CHUNK_BYTES);
    for (;;) {
      const read = fs.readSync(fd, buf, 0, CHUNK_BYTES, null);
      if (read <= 0) break;
      hash.update(buf.subarray(0, read));
    }
  } finally {
    fs.closeSync(fd);
  }
}

function gitlinkShaMap(rawRecords) {
  const map = new Map();
  for (const rec of rawRecords || []) {
    if (rec.dstMode === "160000" && rec.paths.length > 0) {
      map.set(rec.paths[rec.paths.length - 1], rec.dstSha || "");
    }
  }
  return map;
}

function submoduleHead(absPath, fallback) {
  const r = spawnSync("git", ["rev-parse", "HEAD"], { cwd: absPath, encoding: "utf8" });
  if (r.status === 0 && r.stdout && r.stdout.trim()) return r.stdout.trim();
  return fallback || "";
}

// Two named exceptions to the "hash the bytes" rule (S2-e):
// a gitlink has no bytes — its object sha stands in; an unreadable path yields
// its errno string so the failure itself is part of the version.
function hashOnePath(hash, cwd, rel, gitlinks) {
  hash.update(rel);
  hash.update("\0");
  const abs = path.join(cwd, rel);
  if (gitlinks.has(rel)) {
    hash.update("gitlink");
    hash.update("\0");
    hash.update(submoduleHead(abs, gitlinks.get(rel)));
    hash.update("\0");
    return;
  }
  let st = null;
  try {
    st = fs.lstatSync(abs);
  } catch (err) {
    const kind = err && err.code === "ENOENT" ? "deleted" : "unreadable";
    hash.update(kind);
    hash.update("\0");
    hash.update(kind === "deleted" ? "" : String((err && err.code) || "EUNKNOWN"));
    hash.update("\0");
    return;
  }
  try {
    if (st.isSymbolicLink()) {
      hash.update("symlink");
      hash.update("\0");
      hash.update(fs.readlinkSync(abs));
    } else if (st.isDirectory()) {
      hash.update("gitlink");
      hash.update("\0");
      hash.update(submoduleHead(abs, ""));
    } else {
      hash.update("blob");
      hash.update("\0");
      streamFileInto(hash, abs);
    }
  } catch (err) {
    hash.update("unreadable");
    hash.update("\0");
    hash.update(String((err && err.code) || "EUNKNOWN"));
  }
  hash.update("\0");
}

// Full-content fingerprint of a working tree. null when the code side cannot be
// resolved at all (no git, not a repo, no merge base) — callers fail closed.
function computeInputVersion(cwd) {
  try {
    const diff = computeWorkingTreeDiff(cwd);
    if (!diff) return null;
    const hash = crypto.createHash('sha256');
    hash.update(diff.mergeBase);
    hash.update("\0");
    for (const rec of diff.rawRecords) {
      hash.update(rec.raw);
      hash.update("\0");
    }
    const gitlinks = gitlinkShaMap(diff.rawRecords);
    for (const rel of diff.changedFiles) hashOnePath(hash, diff.cwd, rel, gitlinks);
    return hash.digest("hex");
  } catch (_) {
    return null;
  }
}

// Digest over the named plan artifacts, in the order the caller listed them.
// null when any named artifact is missing — a partial digest would let a
// half-written plan set look reviewed.
function computeArtifactKey(plansDir, sessionId, artifactNames) {
  try {
    if (!sessionId || !Array.isArray(artifactNames) || artifactNames.length === 0) return null;
    const dir = toWindowsPath(plansDir || getWorkflowPlansDir());
    const hash = crypto.createHash('sha256');
    for (const name of artifactNames) {
      const abs = path.join(dir, `${sessionId}-${name}.md`);
      if (!fs.existsSync(abs)) return null;
      hash.update(name);
      hash.update("\0");
      streamFileInto(hash, abs);
      hash.update("\0");
    }
    return hash.digest("hex");
  } catch (_) {
    return null;
  }
}

// Code side + plan side in one key. Any null component collapses the whole key.
function computeFreshnessKey(cwd, plansDir, sessionId) {
  const inputVersion = computeInputVersion(cwd);
  const artifactKeys = {};
  for (const name of ARTIFACT_NAMES) {
    artifactKeys[name] = computeArtifactKey(plansDir, sessionId, [name]);
  }
  const parts = [inputVersion].concat(ARTIFACT_NAMES.map((n) => artifactKeys[n]));
  if (parts.some((p) => typeof p !== "string" || p.length === 0)) {
    return { input_version: inputVersion, artifact_keys: artifactKeys, freshness_key: null };
  }
  const hash = crypto.createHash('sha256');
  for (const p of parts) {
    hash.update(p);
    hash.update("\0");
  }
  return { input_version: inputVersion, artifact_keys: artifactKeys, freshness_key: hash.digest("hex") };
}

module.exports = {
  ARTIFACT_NAMES,
  computeInputVersion,
  computeArtifactKey,
  computeFreshnessKey,
};
