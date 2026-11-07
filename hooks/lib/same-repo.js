"use strict";
// Whether two directories belong to one git repository: same git common dir, so a linked worktree
// counts (#2473; moved out of hooks/pre-commit.d/context.js for the test-runner worker). git runs with
// GIT_DIR / GIT_WORK_TREE / GIT_PREFIX / GIT_INDEX_FILE / GIT_COMMON_DIR dropped: an inherited
// GIT_DIR overrides the directory a lookup starts from, so every directory would look like that repo.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("./limited-child-process");
const { toWindowsPath } = require("./branch-diff");

const GIT_TIMEOUT_MS = 15000;
const DISCOVERY_ENV_DROP = ["GIT_DIR", "GIT_WORK_TREE", "GIT_PREFIX", "GIT_INDEX_FILE", "GIT_COMMON_DIR"];

function discoveryEnv(env) {
  const out = { ...(env || process.env) };
  for (const k of DISCOVERY_ENV_DROP) delete out[k];
  return out;
}

function realDir(p) {
  try {
    return fs.realpathSync.native(p);
  } catch (_) {
    return path.resolve(p);
  }
}

// commonDir(dir, env) — the realpath of dir's git common dir, or "" when dir is no repo.
function commonDir(dir, env) {
  if (!dir) return "";
  const r = spawnSync("git", ["rev-parse", "--git-common-dir"], { cwd: toWindowsPath(dir), env, encoding: "utf8", timeout: GIT_TIMEOUT_MS, windowsHide: true });
  if (r.error || r.status !== 0) return "";
  const raw = String(r.stdout || "").replace(/\r?\n$/, "");
  if (!raw) return "";
  const key = realDir(path.resolve(toWindowsPath(dir), toWindowsPath(raw)));
  return process.platform === "win32" ? key.toLowerCase() : key;
}

// sameRepo(a, b, env) — true when a and b resolve to one git common dir; false when either is no repo.
function sameRepo(a, b, env) {
  const denv = discoveryEnv(env);
  const ka = commonDir(a, denv);
  const kb = commonDir(b, denv);
  return Boolean(ka) && ka === kb;
}

module.exports = { sameRepo, discoveryEnv, commonDir };
