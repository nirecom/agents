"use strict";
// Node body of the pre-commit hook (#2507, D1): loads the settings .env, builds the commit context
// and the staged snapshot, starts the async visibility probe, and runs the registry in order.
// Exit code: 0 pass, 1 block, CONFIRM_WARN (10) asks hooks/pre-commit to confirm on /dev/tty.

const path = require("path");
const { spawnSync } = require("../lib/limited-child-process");
const { toWindowsPath } = require("../lib/branch-diff");
const output = require("./output");
const { RC_CONFIRM_WARN: CONFIRM_WARN } = require("./orchestrator");

function showToplevel(env) {
  const r = spawnSync("git", ["rev-parse", "--show-toplevel"], { cwd: process.cwd(), env, encoding: "utf8", timeout: 15000, windowsHide: true });
  const top = !r.error && r.status === 0 ? String(r.stdout || "").replace(/\r?\n$/, "") : "";
  return top ? toWindowsPath(top) : process.cwd();
}

function originUrl(repoTop, env) {
  const r = spawnSync("git", ["remote", "get-url", "origin"], { cwd: repoTop, env, encoding: "utf8", timeout: 15000, windowsHide: true });
  return !r.error && r.status === 0 ? String(r.stdout || "").trim() : "";
}

// loadSettings() — the settings .env into process.env (non-empty export wins, no .env.local).
function loadSettings() {
  const le = require("../lib/load-env");
  le.loadEnv(le.defaultEnvFilePath());
}

// loadCheck(entry) — checks/<name>.js; the file-size gate (#2631) rides on agents-repo-gates.
function loadCheck(entry) {
  const check = require(`./checks/${entry.name}`);
  return entry.name === "agents-repo-gates" ? require("./checks/size-gate").after(check) : check;
}

async function main() {
  const cfgDir = path.resolve(__dirname, "..", "..");
  loadSettings();
  const env = process.env;
  const registry = require("./registry");
  registry.validate(registry.CHECKS, registry.AGENTS_REPO_GATES);
  const repoTop = showToplevel(env);
  const { buildContext } = require("./context");
  const context = await buildContext({ cfgDir, repoTop, env, isTTY: process.stdout.isTTY });
  context.visibility = require("./checks/repo-visibility").start({ remoteUrl: originUrl(repoTop, env) });
  try {
    const { createSnapshot } = require("./snapshot");
    const snapshot = await createSnapshot({ repoTop, env });
    context.merge = require("../lib/merge-incoming").detectMergeIncoming(repoTop, await snapshot.files());
    return await require("./orchestrator").run({ entries: registry.CHECKS, context, snapshot, loadCheck });
  } finally {
    context.visibility.kill();
  }
}

if (require.main === module) {
  main().then((rc) => {
    process.exitCode = rc;
  }, (e) => {
    output.writeMessages([output.err(`pre-commit: ${(e && e.message) || e}. Commit blocked.`)]);
    process.exitCode = 1;
  });
}

module.exports = { CONFIRM_WARN, main };
