"use strict";

// Shared listPrivateRepoNames core for codehostGithub / codehostGitlab (#2513, CPR-ORTH):
// ONE CLI listing whose rows are "<visibility>\t<name>", so the scan-outbound hook pays a
// single spawn timeout. private/internal rows are kept (any case), deduped first-seen;
// public, unknown and malformed rows are dropped; any spawn failure -> [].
const WIN32 = process.platform === "win32";
const KEEP = new Set(["private", "internal"]);

function parseVisibilityRows(stdout) {
  const names = [];
  for (const line of String(stdout || "").split(/\r?\n/)) {
    const row = line.trim();
    const tab = row.indexOf("\t");
    // jq @tsv escapes tabs inside values, so a row with a second tab is malformed.
    if (tab < 0 || row.indexOf("\t", tab + 1) >= 0) continue;
    const visibility = row.slice(0, tab).trim().toLowerCase();
    const name = row.slice(tab + 1).trim();
    if (KEEP.has(visibility) && name && !names.includes(name)) names.push(name);
  }
  return names;
}

// cmd.exe (shell on Windows) splits an unquoted `|` / `&`, so such args are quoted there.
function shellArg(arg) {
  return WIN32 ? '"' + arg + '"' : arg;
}

function listVisibilityTagged(cmd, args) {
  try {
    // Must finish under the 5 s scan-outbound PreToolUse hook timeout (settings.json).
    const r = require("child_process").spawnSync(cmd, args, { encoding: "utf8", timeout: 4000, shell: WIN32 });
    if (r.error || r.status !== 0) return [];
    return parseVisibilityRows(r.stdout);
  } catch (e) {
    return [];
  }
}

module.exports = { listVisibilityTagged, parseVisibilityRows, shellArg };
