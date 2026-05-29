#!/usr/bin/env node
// Build a minimal final-report-env.json for the ENFORCE_WORKTREE=off path.
// Fetches PR metadata for the current branch via gh CLI and writes the JSON file.
//
// Usage: node session-close-build-env.js <env-file-path>
//
// Exit 0 on success.
// Exit 1 when PR cannot be resolved (prints error to stderr).

"use strict";
const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

const outFile = process.argv[2];
if (!outFile) {
  process.stderr.write("Usage: session-close-build-env.js <env-file-path>\n");
  process.exit(1);
}

function run(cmd) {
  return execSync(cmd, { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim();
}

let branch;
try { branch = run("git rev-parse --abbrev-ref HEAD"); } catch (_) { branch = ""; }

let prJson;
try {
  prJson = run(`gh pr list --head ${JSON.stringify(branch)} --state all --limit 1 --json number,title,url,state`);
} catch (e) {
  process.stderr.write("session-close-build-env: gh pr list failed: " + e.message + "\n");
  process.exit(1);
}

let prs;
try { prs = JSON.parse(prJson); } catch (_) { prs = []; }
const pr = prs[0] || null;

if (!pr || !pr.number) {
  process.stderr.write(
    "ERROR: cannot resolve PR for branch " + branch + " — /session-close requires a merged PR\n"
  );
  process.exit(1);
}

const data = {
  PR_NUMBER: String(pr.number || ""),
  PR_TITLE:  pr.title || "",
  PR_URL:    pr.url   || "",
  PR_STATE:  pr.state || "",
  BRANCH: branch, WORKTREE_PATH: "", CREATED_DATE: "",
  BACKUP_MANIFEST_PATH: "", NOTES_BACKUP_PATH: "",
  CLAUDE_CODE_RESTART_REQUIRED: "",
  CC_RESTART_REQUIRED: "", CC_RESTART_REASON: "",
  VSCODE_RELOAD_REQUIRED: "", VSCODE_RELOAD_REASON: "",
  INSTALLER_RERUN_REQUIRED: "", INSTALLER_RERUN_REASON: "",
  OS_REBOOT_REQUIRED: "", OS_REBOOT_REASON: "",
};

fs.mkdirSync(path.dirname(outFile), { recursive: true });
fs.writeFileSync(outFile, JSON.stringify(data, null, 2));
process.stdout.write("ENV_FILE=" + outFile + "\n");
