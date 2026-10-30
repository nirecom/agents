"use strict";
// The private-info lists of the outbound scanner: where they live and how they load.
// Anchor: the main worktree of the repository holding the scanner (the gitignored lists exist
// only there), never an environment variable. A copy outside any git repository reads its own
// tree; a git repository whose main worktree cannot be proven yields no lists (rc 4).

const fs = require("fs");
const path = require("path");
const { spawnSync } = require("../limited-child-process");
const { mainWorktreeOf } = require("../main-worktree");
const { toWindowsPath } = require("../branch-diff");

const GIT_TIMEOUT_MS = 20000;
const GIT_REPO_ENV = ["GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY", "GIT_COMMON_DIR"];
const ALLOW_NAME = ".private-info-allowlist";
const BLOCK_NAME = ".private-info-blocklist";

const BLOCKLIST_MISSING = "Error: blocklist not found in the main worktree of the scanner's repository (or that main worktree cannot be resolved) — cannot scan";

const slashed = (p) => p.replace(/\\/g, "/");

function isGitRepo(dir, env) {
  const genv = { ...(env || process.env) };
  for (const k of GIT_REPO_ENV) delete genv[k];
  const r = spawnSync("git", ["-C", toWindowsPath(dir), "rev-parse", "--git-dir"], { env: genv, encoding: "utf8", timeout: GIT_TIMEOUT_MS, windowsHide: true });
  return !r.error && r.status === 0;
}

// listPaths(binDir, env) -> { allowlist, blocklist }, both "" when the anchor cannot be resolved.
function listPaths(binDir, env) {
  const parent = `${slashed(binDir)}/..`;
  let anchor = mainWorktreeOf(path.resolve(toWindowsPath(binDir), ".."));
  anchor = anchor ? slashed(anchor) : "";
  if (!anchor && !isGitRepo(parent, env)) anchor = parent;
  if (!anchor) return { allowlist: "", blocklist: "" };
  return { allowlist: `${anchor}/${ALLOW_NAME}`, blocklist: `${anchor}/${BLOCK_NAME}` };
}

const isFile = (p) => {
  const st = fs.statSync(toWindowsPath(p), { throwIfNoEntry: false });
  return Boolean(st && st.isFile());
};

// Physical lines as bash `read -r` yields them: \n split, a final unterminated line kept,
// one trailing \r stripped.
function readRows(p) {
  const text = fs.readFileSync(toWindowsPath(p), "utf8");
  const rows = text.split("\n");
  if (rows[rows.length - 1] === "") rows.pop();
  return rows.map((l) => (l.endsWith("\r") ? l.slice(0, -1) : l));
}

const skipRow = (l) => l === "" || l.startsWith("#");

// loadLists({allowlist, blocklist}) -> { lists: {allow, blockHard, blockWarn}, warnings, error }
// warnings are stderr lines; error (a stderr line) means the scan cannot run (rc 4).
function loadLists({ allowlist, blocklist }) {
  const lists = { allow: [], blockHard: [], blockWarn: [] };
  const warnings = [];
  if (allowlist && !isFile(allowlist)) {
    warnings.push(`Warning: allowlist not found at ${allowlist} — proceeding without allowlist`);
  } else if (allowlist) {
    lists.allow = readRows(allowlist).filter((l) => !skipRow(l));
  }
  if (!blocklist || !isFile(blocklist)) return { lists, warnings, error: BLOCKLIST_MISSING };
  readRows(blocklist).forEach((l, i) => {
    if (skipRow(l)) return;
    if (!l.startsWith("warn:")) {
      lists.blockHard.push(l);
      return;
    }
    const pat = l.slice("warn:".length);
    if (pat === "") warnings.push(`Warning: empty warn pattern at ${blocklist} line ${i + 1} — skipped`);
    else lists.blockWarn.push(pat);
  });
  return { lists, warnings, error: null };
}

module.exports = { listPaths, loadLists, BLOCKLIST_MISSING };
