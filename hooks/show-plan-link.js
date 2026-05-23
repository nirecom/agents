#!/usr/bin/env node
// PostToolUse hook: emit a systemMessage with the absolute path of any final
// plan artifact written under ~/.workflow-plans/ (basename *-(intent|outline|detail).md;
// drafts/ excluded). Always emits regardless of CONFIRM_<STEP> — breadcrumb is the sole
// path surface for orchestrators. When CONFIRM_<STEP>=on AND VS Code is detected,
// additionally spawns `code --folder-uri file:///<cwd> -r <file>` to open the artifact
// in the workspace window matching input.cwd (fixes #291; restored by #486).
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
  return fwd.startsWith("/") ? "file://" + fwd : "file:///" + fwd;
}

// Ladder: input.cwd → process.cwd() → null (bare code -r).
function resolveWorkspaceFolderUri(input) {
  const fromInput = workspaceFolderUriFrom(input && input.cwd);
  if (fromInput) return fromInput;
  return workspaceFolderUriFrom(process.cwd());
}

function buildCodeArgs(absPath, folderUri) {
  return folderUri ? ["--folder-uri", folderUri, "-r", absPath] : ["-r", absPath];
}

function openInVsCode(absPath, folderUri) {
  const args = buildCodeArgs(absPath, folderUri);
  if (process.env.SHOW_PLAN_LINK_NO_SPAWN === "1") {
    if (process.env.SHOW_PLAN_LINK_MARKER_FILE) {
      fs.writeFileSync(process.env.SHOW_PLAN_LINK_MARKER_FILE, args.join("\n"));
    }
    return;
  }
  if (process.platform === "win32") {
    spawn("cmd.exe", ["/d", "/s", "/c", "code", ...args], {
      stdio: "ignore", detached: true, windowsHide: true,
    }).unref();
  } else {
    spawn("code", args, { stdio: "ignore", detached: true }).unref();
  }
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
