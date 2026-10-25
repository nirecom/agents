"use strict";
// detectMergeIncoming(repoDir, stagedPaths): which staged paths are merge-incoming files — paths whose
// index state (blob and mode, or absence) equals MERGE_HEAD's. Returns one of three states and never
// throws: not-merging | merging { mergeHead, paths ⊆ stagedPaths } | undecidable { reason }.
// MERGE_HEAD is decided only from the file `git rev-parse --git-path MERGE_HEAD` names; the ref name is
// never resolved, so a branch or tag called MERGE_HEAD does not count as a merge.
// git inherits GIT_DIR / GIT_INDEX_FILE from the environment, so the temporary index of a
// `git commit <paths>` pre-commit (#2507) is the index compared.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const { toWindowsPath } = require("./branch-diff");

const MERGE_INCOMING_STATE = Object.freeze({ NOT_MERGING: "not-merging", MERGING: "merging", UNDECIDABLE: "undecidable" });
const OID_RE = /^[0-9a-f]{40}$|^[0-9a-f]{64}$/i;

const undecidable = (reason) => ({ state: MERGE_INCOMING_STATE.UNDECIDABLE, reason });

function runGit(repoDir, args) {
  const r = spawnSync("git", ["-C", toWindowsPath(repoDir)].concat(args), { timeout: 15000, maxBuffer: 256 * 1024 * 1024 });
  return { ok: !r.error && r.status === 0, stdout: r.stdout ? r.stdout.toString("utf8") : "" };
}

function detect(repoDir, stagedPaths) {
  if (typeof repoDir !== "string" || repoDir === "" || !Array.isArray(stagedPaths)) return undecidable("invalid-argument");
  const gp = runGit(repoDir, ["rev-parse", "--git-path", "MERGE_HEAD"]);
  const rel = gp.stdout.replace(/\r?\n$/, "");
  if (!gp.ok || rel === "") return undecidable("git-path-failed");
  const file = path.resolve(toWindowsPath(repoDir), toWindowsPath(rel));
  let body;
  try {
    body = fs.readFileSync(file, "utf8");
  } catch (e) {
    if (e && e.code === "ENOENT") return { state: MERGE_INCOMING_STATE.NOT_MERGING };
    return undecidable("merge-head-unreadable");
  }
  const lines = body.split(/\r?\n/).map((l) => l.trim()).filter(Boolean);
  if (lines.length === 0) return undecidable("merge-head-malformed");
  if (lines.length > 1) return undecidable("octopus");
  const mergeHead = lines[0];
  if (!OID_RE.test(mergeHead)) return undecidable("merge-head-malformed");
  // --ignore-submodules=none: a user's diff.ignoreSubmodules must not hide a changed gitlink.
  const diff = runGit(repoDir, ["diff", "--cached", "--name-only", "-z", "--no-renames", "--ignore-submodules=none", mergeHead]);
  if (!diff.ok) return undecidable("diff-failed");
  const differing = new Set(diff.stdout.split("\0").filter(Boolean));
  return { state: MERGE_INCOMING_STATE.MERGING, mergeHead, paths: new Set(stagedPaths.filter((p) => !differing.has(p))) };
}

function detectMergeIncoming(repoDir, stagedPaths) {
  try {
    return detect(repoDir, stagedPaths);
  } catch {
    return undecidable("exception");
  }
}

module.exports = { detectMergeIncoming, MERGE_INCOMING_STATE };
