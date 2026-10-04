#!/usr/bin/env node
// Build a minimal final-report-env.json for the ENFORCE_WORKTREE=off path.
// Fetches PR metadata for the current branch via gh CLI and writes the JSON file
// to <WORKFLOW_STATE_DIR>/<sid>.control/final-report-env.json.
//
// Usage: node session-close-build-env.js [--wf-meta] --session <sid>
//   --wf-meta: write env JSON with all empty-string fields (no PR needed)
//   A trailing legacy <env-file-path> is accepted only as the derived path or <sid>-final-report-env.json.
//
// Exit 0 on success.
// Exit 1 on usage / invalid session / rejected path, or when PR cannot be resolved (stderr).

"use strict";
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const { resolveControlFile } = require(path.join(__dirname, "lib", "session-control-file"));

const ENV_NAME = "final-report-env.json";
const USAGE = "Usage: session-close-build-env.js [--wf-meta] --session <sid>\n";

function fail(msg) {
  process.stderr.write(msg);
  process.exit(1);
}

function parseArgs(argv) {
  const out = { wfMeta: false, sid: undefined, legacy: undefined };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--wf-meta") out.wfMeta = true;
    else if (a === "--session") {
      if (i + 1 >= argv.length) fail(USAGE);
      out.sid = argv[++i];
    } else if (out.legacy === undefined) out.legacy = a;
    else fail(USAGE);
  }
  if (out.sid === undefined && out.legacy === undefined) fail(USAGE);
  return out;
}

const args = parseArgs(process.argv.slice(2));
let outFile;
try {
  outFile = resolveControlFile({ sid: args.sid, legacy: args.legacy, name: ENV_NAME, forWrite: true });
} catch (e) {
  fail(`session-close-build-env: ${e.message}\n`);
}

function emptyEnv() {
  return {
    PR_NUMBER: "", PR_TITLE: "", PR_URL: "", PR_STATE: "",
    BRANCH: "", WORKTREE_PATH: "", CREATED_DATE: "",
    BACKUP_MANIFEST_PATH: "", NOTES_BACKUP_PATH: "",
    CLAUDE_CODE_RESTART_REQUIRED: "",
    CC_RESTART_REQUIRED: "", CC_RESTART_REASON: "",
    VSCODE_RELOAD_REQUIRED: "", VSCODE_RELOAD_REASON: "",
    INSTALLER_RERUN_REQUIRED: "", INSTALLER_RERUN_REASON: "",
    OS_REBOOT_REQUIRED: "", OS_REBOOT_REASON: "",
  };
}

function writeEnv(data) {
  fs.writeFileSync(outFile, JSON.stringify(data, null, 2));
  process.stdout.write("ENV_FILE=" + outFile + "\n");
  process.exit(0);
}

if (args.wfMeta) writeEnv(emptyEnv());

function run(cmd) {
  return execSync(cmd, { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim();
}

let branch;
try { branch = run("git rev-parse --abbrev-ref HEAD"); } catch (_) { branch = ""; }

let prJson;
try {
  prJson = run(`gh pr list --head ${JSON.stringify(branch)} --state all --limit 1 --json number,title,url,state`);
} catch (e) {
  fail("session-close-build-env: gh pr list failed: " + e.message + "\n");
}

let prs;
try { prs = JSON.parse(prJson); } catch (_) { prs = []; }
const pr = prs[0] || null;

if (!pr || !pr.number) {
  fail("ERROR: cannot resolve PR for branch " + branch + " — /session-close requires a merged PR\n");
}

writeEnv(Object.assign(emptyEnv(), {
  PR_NUMBER: String(pr.number || ""),
  PR_TITLE: pr.title || "",
  PR_URL: pr.url || "",
  PR_STATE: pr.state || "",
  BRANCH: branch,
}));
