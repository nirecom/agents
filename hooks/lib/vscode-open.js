"use strict";
// Shared helper: open a file in the active VS Code window.
//
// Extracted from show-plan-link.js so multiple hooks (PostToolUse breadcrumb
// emit, PreToolUse confirm-checkpoint) can share the same open semantics.
//
// Env opts:
//   SHOW_PLAN_LINK_NO_AUTO_OPEN=1   — shouldOpenInVsCode gate (off when set)
//   SHOW_PLAN_LINK_NO_SPAWN=1       — test mode: skip spawn, write marker file instead
//   SHOW_PLAN_LINK_MARKER_FILE      — path to write spawn args (test mode only)

const fs = require("fs");
const { spawn } = require("child_process");
const { normalizeCwd } = require("./path-normalize");

function isVsCode() {
  return process.env.TERM_PROGRAM === "vscode"
      || process.env.CLAUDE_CODE_ENTRYPOINT === "claude-vscode";
}

function shouldOpenInVsCode() {
  if (process.env.SHOW_PLAN_LINK_NO_AUTO_OPEN === "1") return false;
  return isVsCode();
}

// Returns file:// URI for the given cwd, or null when cwd is missing/empty/root.
function workspaceFolderUriFrom(cwd) {
  cwd = normalizeCwd(cwd) || cwd;
  if (!cwd || typeof cwd !== "string") return null;
  if (cwd === "/" || /^[A-Za-z]:[\\/]?$/.test(cwd)) return null;
  const fwd = cwd.replace(/\\/g, "/");
  // UNC path (\\server\share or //server/share)
  if (fwd.startsWith("//")) {
    const rest = fwd.slice(2);
    const parts = rest.split("/");
    const server = parts.shift();
    const encodedTail = parts.map(encodeURIComponent).join("/");
    return "file://" + server + (encodedTail ? "/" + encodedTail : "");
  }
  // Windows drive path (C:/...)
  const driveMatch = fwd.match(/^([A-Za-z]:)\/(.*)/);
  if (driveMatch) {
    const encodedTail = driveMatch[2].split("/").map(encodeURIComponent).join("/");
    return "file:///" + driveMatch[1] + "/" + encodedTail;
  }
  // POSIX absolute path
  if (fwd.startsWith("/")) {
    const encodedTail = fwd.slice(1).split("/").map(encodeURIComponent).join("/");
    return "file:///" + encodedTail;
  }
  // Fallback
  return "file:///" + fwd.split("/").map(encodeURIComponent).join("/");
}

// Ladder: input.cwd → process.cwd() → null (bare code -r).
function resolveWorkspaceFolderUri(input) {
  const fromInput = workspaceFolderUriFrom(input && input.cwd);
  if (fromInput) return fromInput;
  return workspaceFolderUriFrom(process.cwd());
}

function spawnCode(args) {
  if (process.platform === "win32") {
    return spawn("cmd.exe", ["/d", "/s", "/c", "code", ...args], {
      stdio: "ignore", detached: true, windowsHide: true,
    });
  }
  return spawn("code", args, { stdio: "ignore", detached: true });
}

function openInVsCode(absPath, folderUri) {
  const args = folderUri
    ? ["--folder-uri", folderUri, absPath]
    : ["-r", absPath];
  if (process.env.SHOW_PLAN_LINK_NO_SPAWN === "1") {
    if (process.env.SHOW_PLAN_LINK_MARKER_FILE) {
      fs.writeFileSync(
        process.env.SHOW_PLAN_LINK_MARKER_FILE,
        args.join("\n")
      );
    }
    return;
  }
  spawnCode(args).unref();
}

module.exports = {
  isVsCode,
  shouldOpenInVsCode,
  workspaceFolderUriFrom,
  resolveWorkspaceFolderUri,
  spawnCode,
  openInVsCode,
};
