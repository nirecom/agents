"use strict";
// Commit context of the pre-commit body (#2507, D3): the normalized cfgDir / repoTop and whether
// the repo under commit IS the agents repo. The same-repo judgement lives in ../lib/same-repo (#2473).

const { toWindowsPath } = require("../lib/branch-diff");
const { sameRepo, discoveryEnv } = require("../lib/same-repo");

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
