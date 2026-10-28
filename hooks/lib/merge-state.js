"use strict";
// readMergeState(repoDir): whether a merge is in progress, decided only from the file
// `git rev-parse --git-path MERGE_HEAD` names (a ref called MERGE_HEAD does not count).
// → { state: "not-merging" } | { state: "merging", mergeHead } | { state: "undecidable", reason }.
// Shared by merge-incoming.js (#2761) and merge-parents.js (#2812). git inherits GIT_DIR /
// GIT_INDEX_FILE from the environment.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { toWindowsPath } = require("./branch-diff");

const MERGE_STATE = Object.freeze({ NOT_MERGING: "not-merging", MERGING: "merging", UNDECIDABLE: "undecidable" });
const OID_RE = /^[0-9a-f]{40}$|^[0-9a-f]{64}$/i;

const undecidable = (reason) => ({ state: MERGE_STATE.UNDECIDABLE, reason });

function runGit(repoDir, args) {
  const r = spawnSync("git", ["-C", toWindowsPath(repoDir)].concat(args), { timeout: 15000, maxBuffer: 256 * 1024 * 1024 });
  return { ok: !r.error && r.status === 0, stdout: r.stdout ? r.stdout.toString("utf8") : "" };
}

function readMergeState(repoDir) {
  const gp = runGit(repoDir, ["rev-parse", "--git-path", "MERGE_HEAD"]);
  const rel = gp.stdout.replace(/\r?\n$/, "");
  if (!gp.ok || rel === "") return undecidable("git-path-failed");
  const file = path.resolve(toWindowsPath(repoDir), toWindowsPath(rel));
  let body;
  try {
    body = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return { state: MERGE_STATE.NOT_MERGING };
    return undecidable("merge-head-unreadable");
  }
  const lines = body.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0) return undecidable("merge-head-malformed");
  if (lines.length > 1) return undecidable("octopus");
  const mergeHead = lines[0];
  if (!OID_RE.test(mergeHead)) return undecidable("merge-head-malformed");
  return { state: MERGE_STATE.MERGING, mergeHead };
}

module.exports = { readMergeState, runGit, MERGE_STATE, undecidable };
