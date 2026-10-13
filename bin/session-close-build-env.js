#!/usr/bin/env node
// Build a minimal final-report-env.json for the ENFORCE_WORKTREE=off path.
// Fetches PR metadata for the current branch via gh CLI and writes the JSON file
// to <WORKFLOW_STATE_DIR>/<sid>.control/final-report-env.json.
//
// Usage: node session-close-build-env.js [--wf-meta | --direct] --session <sid>
//   --wf-meta: all-empty fields (no PR); --direct (#2527): PR optional, BRANCH always filled
//   A trailing legacy <env-file-path> is accepted only as the derived path or <sid>-final-report-env.json.
// Exit 0 on success. Exit 1 on usage / invalid session / rejected path, or (default mode)
// when the PR cannot be resolved (stderr).

"use strict";
const fs = require("fs");
const path = require("path");
const { execFileSync } = require("child_process");

const { resolveControlFile } = require(path.join(__dirname, "lib", "session-control-file"));

const ENV_NAME = "final-report-env.json";
const USAGE = "Usage: session-close-build-env.js [--wf-meta | --direct] --session <sid>\n";

function fail(msg) {
  process.stderr.write(msg);
  process.exit(1);
}

function parseArgs(argv) {
  const out = { wfMeta: false, direct: false, sid: undefined, legacy: undefined };
  for (let i = 0; i < argv.length; i++) {
    const a = argv[i];
    if (a === "--wf-meta") out.wfMeta = true;
    else if (a === "--direct") out.direct = true;
    else if (a === "--session") {
      if (i + 1 >= argv.length) fail(USAGE);
      out.sid = argv[++i];
    } else if (out.legacy === undefined) out.legacy = a;
    else fail(USAGE);
  }
  if (out.sid === undefined && out.legacy === undefined) fail(USAGE);
  if (out.wfMeta && out.direct) fail(USAGE);
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

// Shared no-PR builder (--wf-meta, and --direct when no PR is found).
function noPrEnv(branch) {
  return Object.assign(emptyEnv(), { BRANCH: branch || "" });
}

if (args.wfMeta) writeEnv(noPrEnv(""));

// argv only, no shell: the branch name is attacker-controllable (CWE-78).
function run(file, argv) {
  return execFileSync(file, argv, { encoding: "utf8", stdio: ["pipe", "pipe", "pipe"] }).trim();
}

let branch;
try { branch = run("git", ["rev-parse", "--abbrev-ref", "HEAD"]); } catch (_) { branch = ""; }

let headSha;
try { headSha = run("git", ["rev-parse", "HEAD"]); } catch (_) { headSha = ""; }

let prJson;
try {
  prJson = run("gh", ["pr", "list", "--head", branch, "--state", "all", "--limit", "20",
    "--json", "number,title,url,state,headRefOid"]);
} catch (e) {
  if (args.direct) writeEnv(noPrEnv(branch));
  fail("session-close-build-env: gh pr list failed: " + e.message + "\n");
}

let prs;
try { prs = JSON.parse(prJson); } catch (_) { prs = []; }
if (!Array.isArray(prs)) prs = [];
// A reused branch name lists unrelated historical PRs: only a PR whose head is this
// HEAD belongs to this work. --direct accepts nothing else; the PR-required mode
// falls back to the newest OPEN/MERGED one.
const headMatch = prs.find((p) => p && headSha && p.headRefOid === headSha) || null;
const pr = args.direct
  ? headMatch
  : headMatch || prs.find((p) => p && (p.state === "OPEN" || p.state === "MERGED")) || null;

if (!pr || !pr.number) {
  if (args.direct) writeEnv(noPrEnv(branch));
  fail("ERROR: cannot resolve PR for branch " + branch + " — /session-close requires a merged PR\n");
}

writeEnv(Object.assign(noPrEnv(branch), {
  PR_NUMBER: String(pr.number || ""),
  PR_TITLE: pr.title || "",
  PR_URL: pr.url || "",
  PR_STATE: pr.state || "",
}));
