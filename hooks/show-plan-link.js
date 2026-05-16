#!/usr/bin/env node
// PostToolUse hook: emit a systemMessage with the absolute path of any final
// plan artifact written under ~/.workflow-plans/, and when running inside the
// VS Code extension, refocus the file in the same window via `code -r`.
//
// Output protocol: emits { "systemMessage": "..." } only.
// Sibling PostToolUse hooks emit `additionalContext` — different field, no collision.
//
// NOTE on VS Code detection (shouldOpenInVsCode()):
// Two positive signals are checked; the first match wins:
//   1. TERM_PROGRAM === "vscode"  — integrated terminal (POSIX convention; cross-shell)
//   2. CLAUDE_CODE_ENTRYPOINT === "claude-vscode" — extension/webview session
//      (TERM_PROGRAM is not propagated into the VS Code extension webview)
// Opt-out: SHOW_PLAN_LINK_NO_AUTO_OPEN=1 short-circuits all detection.
// Rejected: VSCODE_IPC_HOOK_CLI — leaks into external terminals launched from VS Code;
//   false-positive risk; adds no coverage beyond the two primaries above.
//
// NOTE on Windows spawn: Node.js 20.12+ (CVE-2024-27980) refuses to spawn
// .cmd/.bat files without shell:true. We use cmd.exe directly with args as
// an array to avoid both the restriction and shell injection risk.
"use strict";

const fs = require("fs");
const path = require("path");
const { spawn } = require("child_process");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
const { normalizeSlashes, getBasename } = require("./lib/path-match");

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

function isDirectChild(filePath, plansDir) {
  const f = normalizeSlashes(filePath);
  const d = normalizeSlashes(plansDir).replace(/\/+$/, "");
  const parent = path.posix.dirname(f);
  return process.platform === "win32"
    ? parent.toLowerCase() === d.toLowerCase()
    : parent === d;
}

function isFinalPlanArtifact(filePath) {
  if (!filePath) return false;
  let plansDir;
  try { plansDir = normalizeSlashes(getWorkflowPlansDir()); } catch { return false; }
  const f = normalizeSlashes(filePath);
  if (!isDirectChild(f, plansDir)) return false;
  // Case-sensitive. Basename must be <non-empty>-(intent|outline|detail).md.
  return /^.+-(intent|outline|detail)\.md$/.test(getBasename(f));
}

function shouldOpenInVsCode() {
  if (process.env.SHOW_PLAN_LINK_NO_AUTO_OPEN === "1") return false;
  if (process.env.TERM_PROGRAM === "vscode") return true;
  if (process.env.CLAUDE_CODE_ENTRYPOINT === "claude-vscode") return true;
  return false;
}

function openInVsCode(absPath) {
  if (!shouldOpenInVsCode()) return;
  // --- BEGIN test-only: SHOW_PLAN_LINK_NO_SPAWN bypass (#326) ---
  // Added in #326: on Windows cmd.exe resolves "code" via PATHEXT and ignores
  // extensionless bash shims, so test shims cannot intercept the real code.cmd.
  // This flag lets tests skip the real VS Code spawn without PATH tricks.
  // Set SHOW_PLAN_LINK_MARKER_FILE to observe invocation. Never set in production.
  if (process.env.SHOW_PLAN_LINK_NO_SPAWN === "1") {
    const marker = process.env.SHOW_PLAN_LINK_MARKER_FILE;
    if (marker) {
      try { fs.writeFileSync(marker, "1"); } catch (_) {}
    }
    return;
  }
  // --- END test-only: SHOW_PLAN_LINK_NO_SPAWN bypass ---
  try {
    let child;
    if (process.platform === "win32") {
      // Use cmd.exe with argv array to avoid CVE-2024-27980 restriction on
      // spawning .cmd files and to avoid shell injection risk.
      child = spawn("cmd.exe", ["/d", "/s", "/c", "code", "-r", absPath], {
        stdio: "ignore",
        detached: true,
        windowsHide: true,
      });
    } else {
      child = spawn("code", ["-r", absPath], {
        stdio: "ignore",
        detached: true,
      });
    }
    // Register error handler synchronously before exit; if code is missing
    // from PATH, the error fires asynchronously but the handler is already
    // attached. The process exits immediately below — fire-and-forget.
    child.on("error", () => {});
    child.unref();
  } catch (_) {}
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

  openInVsCode(absPath);

  process.stdout.write(JSON.stringify({ systemMessage: `Plan file written: ${absPath}` }));
  process.exit(0);
}

module.exports = { isFinalPlanArtifact, shouldOpenInVsCode };
