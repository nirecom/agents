"use strict";
// Child-process driver for the #2849 review-docs-checker cases in
// feat-2529-glossary-provenance-accepted.js: arms the decision time limit as hooks/workflow-gate.js
// does (the limit read from this process's env), swaps bin/review-doc-gates for a hung node child,
// then runs checkReviewDocs once. argv: <repoDir>.
// stdout: the ask, or one JSON line {"result":...} when checkReviewDocs returned.
// The ask's reason must carry "review-doc-gates did not finish within the decision time limit" and
// not the wrapper's generic "reached before bash " form; the parent test asserts both.
const childProcess = require("child_process");
const path = require("path");

const REPO = path.resolve(__dirname, "..", "..", "..");
const repoDir = process.argv[2];

const realSpawnSync = childProcess.spawnSync;
childProcess.spawnSync = (command, args, options) => {
  if (Array.isArray(args) && args.some((a) => String(a).includes("review-doc-gates"))) {
    return realSpawnSync(process.execPath, ["-e", "setTimeout(() => {}, 60000)"], options);
  }
  return realSpawnSync(command, args, options);
};

const limit = require(path.join(REPO, "hooks", "lib", "decision-time-limit.js"));
limit.armDecisionTimeLimit({ hookName: "workflow-gate" });
const { checkReviewDocs } = require(path.join(REPO, "hooks", "workflow-gate", "review-docs-checker.js"));
const result = checkReviewDocs("review_docs", {}, { repoDir });
process.stdout.write(JSON.stringify({ result }) + "\n");
