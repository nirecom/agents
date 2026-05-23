#!/usr/bin/env node
// PostToolUse hook: emit a systemMessage with the absolute path of any final
// plan artifact written under ~/.workflow-plans/ (basename *-(intent|outline|detail).md;
// drafts/ excluded). Always emits regardless of CONFIRM_<STEP> — breadcrumb is the sole
// path surface for orchestrators. When CONFIRM_<STEP>=on AND VS Code is detected,
// additionally spawns two sequenced `code` invocations: first `code --folder-uri file:///<cwd>`
// (raises the correct window), then `code -r <file>` (opens the file) — avoids the
// VS Code CLI bug where --folder-uri silently discards file-open args (#506).
//
// Output protocol: emits { "systemMessage": "..." } only.
// Sibling PostToolUse hooks emit `additionalContext` — different field, no collision.
"use strict";

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { normalizeSlashes } = require("./lib/path-match");
const { getSuffix, isConfirmOff } = require("./lib/plan-confirm-flag");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(65536);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_) {}
  return Buffer.concat(chunks).toString("utf8");
}

function noopExit() {
  process.stdout.write("");
  process.exit(0);
}

function isFinalPlanArtifact(filePath) {
  return getSuffix(filePath) !== null;
}

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
  const folderArgs = folderUri ? ["--folder-uri", folderUri] : null;
  const fileArgs = ["-r", absPath];
  if (process.env.SHOW_PLAN_LINK_NO_SPAWN === "1") {
    if (process.env.SHOW_PLAN_LINK_MARKER_FILE) {
      const blocks = [];
      if (folderArgs) blocks.push(folderArgs.join("\n"));
      blocks.push(fileArgs.join("\n"));
      fs.writeFileSync(process.env.SHOW_PLAN_LINK_MARKER_FILE, blocks.join("\n\n"));
    }
    return;
  }
  if (folderArgs) spawnCode(folderArgs).unref();
  spawnCode(fileArgs).unref();
}

if (require.main === module) {
  let input = {};
  try { input = JSON.parse(readStdin()); } catch { noopExit(); }

  if (input.tool_name !== "Write") noopExit();

  // Defensive tool_response check (mirrors workflow-run-tests.js pattern).
  const resp = input.tool_response || {};
  const exitCode = resp.exit_code ?? resp.exitCode ?? (resp.success === false ? 1 : 0);
  if (exitCode !== 0) noopExit();

  const filePath = (input.tool_input && input.tool_input.file_path) || "";
  if (!isFinalPlanArtifact(filePath)) noopExit();

  // Windows: native backslash absolute path (Explorer/cmd.exe compatible).
  // POSIX:   forward-slash (normalizeSlashes is a no-op on already-forward-slash strings).
  const resolved = path.resolve(filePath);
  const absPath = process.platform === "win32"
    ? resolved.replace(/\//g, "\\")
    : normalizeSlashes(resolved);

  if (!isConfirmOff(filePath) && shouldOpenInVsCode()) {
    try { openInVsCode(absPath, resolveWorkspaceFolderUri(input)); } catch (_) { /* fail-open */ }
  }
  process.stdout.write(JSON.stringify({ systemMessage: `Plan file written: ${absPath}` }));
  process.exit(0);
}

module.exports = { isFinalPlanArtifact };
