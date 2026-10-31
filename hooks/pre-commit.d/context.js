"use strict";
// Commit context of the pre-commit body (#2507, D3): the normalized cfgDir / repoTop and whether
// the repo under commit IS the agents repo (same git common dir, so a linked worktree counts).
// git runs with GIT_DIR / GIT_WORK_TREE / GIT_PREFIX dropped: an inherited GIT_DIR overrides the
// directory a lookup starts from, which would make every repo look like the committing one.

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("../lib/limited-child-process");
const { toWindowsPath } = require("../lib/branch-diff");

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
  const r = spawnSync("git", ["rev-parse", "--git-common-dir"], { cwd: dir, env, encoding: "utf8", timeout: GIT_TIMEOUT_MS, windowsHide: true });
  if (r.error || r.status !== 0) return "";
  const raw = String(r.stdout || "").replace(/\r?\n$/, "");
  if (!raw) return "";
  const key = realDir(path.resolve(dir, toWindowsPath(raw)));
  return process.platform === "win32" ? key.toLowerCase() : key;
}

function sameRepo(cfgDir, repoTop, env) {
  const denv = discoveryEnv(env);
  const a = commonDir(cfgDir, denv);
  const b = commonDir(repoTop, denv);
  return Boolean(a) && a === b;
}

async function buildContext({ cfgDir, repoTop, env, isTTY }) {
  const cfg = toWindowsPath(cfgDir);
  const top = toWindowsPath(repoTop);
  const e = env || process.env;
  return {
    cfgDir: cfg,
    repoTop: top,
    env: e,
    isTTY: Boolean(isTTY),
    isAgentsRepo: sameRepo(cfg, top, e),
    merge: { state: "not-merging" },
    visibility: { kill() {}, result: async () => "scan" },
  };
}

module.exports = { buildContext, sameRepo, discoveryEnv };
