"use strict";
// repo-visibility check (#2507, D4): a private or non-GitHub origin ends the hook before the
// visibilityGated checks. The rules are the former bash sed pipeline; gh runs asynchronously from
// the context build, has no time limit (as before), and any gh failure means "scan".

const { spawn } = require("child_process");

const HOST_1 = /^(ssh|https?):\/\/([^@]+@)?([^/:]+)[\s\S]*$/;
const HOST_2 = /^[^@]+@([^:]+):[\s\S]*$/;
const REPO_ID = /^[\s\S]*[:/]([^/]+\/[^/]+)$/;

// parseRemote(url) -> { host, repoId }, each the output of the former sed expression.
function parseRemote(url) {
  const s = String(url || "");
  const h1 = s.replace(HOST_1, "$3");
  const host = h1.replace(HOST_2, "$1");
  const repoId = s.replace(/\.git$/, "").replace(REPO_ID, "$1");
  return { host, repoId };
}

function defaultSpawnGh(args) {
  return spawn("gh", args, { stdio: ["ignore", "pipe", "ignore"], windowsHide: true });
}

// start({ remoteUrl, spawnGh }) -> { result(): Promise<"skip"|"scan">, kill() }.
function start({ remoteUrl, spawnGh = defaultSpawnGh } = {}) {
  const done = (v) => ({ result: async () => v, kill() {} });
  if (!remoteUrl) return done("scan");
  const { host, repoId } = parseRemote(remoteUrl);
  if (host && host !== "github.com") return done("skip");
  if (!repoId) return done("scan");
  let child;
  try {
    child = spawnGh(["api", `repos/${repoId}`, "--jq", ".private"]);
  } catch (_) {
    return done("scan");
  }
  const answer = new Promise((resolve) => {
    let text = "";
    if (child.stdout) child.stdout.on("data", (c) => { text += c; });
    child.once("error", () => resolve("scan"));
    child.once("close", (code) => resolve(code === 0 && text.trim() === "true" ? "skip" : "scan"));
  });
  return {
    result: () => answer,
    kill() {
      try {
        if (child.exitCode === null && child.signalCode === null) child.kill();
      } catch (_) {
        // The child is gone already.
      }
    },
  };
}

async function run({ context }) {
  const v = context.visibility;
  const answer = v && typeof v.result === "function" ? await v.result() : "scan";
  return { verdict: answer === "skip" ? "skip-rest" : "pass", messages: [] };
}

module.exports = { run, parseRemote, start };
