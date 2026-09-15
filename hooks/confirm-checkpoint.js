#!/usr/bin/env node
// PreToolUse hook: when Bash emits a <<WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL}>>
// sentinel, surface the relevant plan/PR context above the permission dialog so the
// user can Allow or Deny inline. Sentinel patterns: hooks/lib/sentinel-patterns.js.
// Output protocol: emits { "systemMessage": "..." } only, always exit 0 (fail-open —
// we never block the user's approval flow).
"use strict";

const fs = require("fs");
const path = require("path");

const sentinelPatterns = require("./lib/sentinel-patterns");
// #2256 S5-a2: Bash/runInTerminal/runCommands normalization (SSOT: hooks/lib/tool-command-text.js).
// The CONFIRM patterns are unanchored, so the joined command text finds the sentinel in any element.
const { isCommandTool, commandTextOf } = require("./lib/tool-command-text");
const { peekTurnMarkers } = require("./lib/turn-marker");
const { resolveSessionId } = require("./workflow-state");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
const { loadDefaultEnv } = require("./lib/load-env");
const { isVsCode, shouldOpenInVsCode, toVsCodeFileUri, openInVsCode, resolveWorkspaceFolderUri } = require("./lib/vscode-open");

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

function noopExit() { process.stdout.write(""); process.exit(0); }

// #2256 S1-a: the CONFIRM patterns are owned by hooks/lib/sentinel-patterns.js.
// This hook inspects a raw Bash command, not a lone echo, so the SSOT regex is
// reused with its `^echo "` / `"$` anchors dropped rather than re-spelled here.
function unanchoredEcho(re) {
  return new RegExp(re.source.replace(/^\^echo "/, "").replace(/"\$$/, ""));
}

const CONFIRM_STAGE_PATTERNS = [
  { stage: "intent", re: unanchoredEcho(sentinelPatterns.CONFIRM_INTENT_LOOKSLIKE_RE) },
  { stage: "outline", re: unanchoredEcho(sentinelPatterns.CONFIRM_OUTLINE_LOOKSLIKE_RE) },
  { stage: "detail", re: unanchoredEcho(sentinelPatterns.CONFIRM_DETAIL_LOOKSLIKE_RE) },
];

// Returns { stage } or null if no sentinel matches.
function parseSentinel(command) {
  if (typeof command !== "string" || command.length === 0) return null;
  for (const entry of CONFIRM_STAGE_PATTERNS) {
    if (entry.re.test(command)) return { stage: entry.stage };
  }
  return null;
}

// Resolve absolute path to <stage>.md artifact for the current session.
// Multi-turn scenario: Stop hook deletes markers at turn end. When user emits
// sentinel after a follow-up message, marker peek returns nothing → PLANS_DIR
// fallback is the primary resolution path, not a degraded path.
function resolveArtifact(stage, sid, plansDir) {
  // 1. Turn-marker peek (only valid within the same turn that wrote the marker).
  if (sid) {
    try {
      const markers = peekTurnMarkers(sid);
      for (const m of markers) {
        if (m && m.suffix === stage && typeof m.absPath === "string" && m.absPath.length > 0) {
          return m.absPath;
        }
      }
    } catch (_) { /* fail-open */ }
  }
  // 2. PLANS_DIR fallback: <PLANS_DIR>/<sid>-<stage>.md
  if (sid && plansDir) {
    const candidate = path.join(plansDir, `${sid}-${stage}.md`);
    try {
      if (fs.existsSync(candidate)) return candidate;
    } catch (_) { /* fail-open */ }
  }
  return null;
}

function renderMessage(stage, absPath, url) {
  if (absPath) {
    const fileRef = url
      ? `[${path.basename(absPath)}](${url})`
      : absPath;
    return `[${stage}] Plan file: ${fileRef}\nClick Allow to proceed, Deny to abort.`;
  }
  return `[${stage}] Plan ready (file path unavailable)\nClick Allow to proceed, Deny to abort.`;
}

if (require.main === module) {
  try { loadDefaultEnv(); } catch (_) {}
  let input = {};
  try { input = JSON.parse(readStdin()); } catch { noopExit(); }

  if (!isCommandTool(input.tool_name)) noopExit();

  const command = commandTextOf(input.tool_name, input.tool_input);
  const parsed = parseSentinel(command);
  if (!parsed) noopExit();

  const stage = parsed.stage;

  // Plan-stage branch: resolve artifact, honor CONFIRM_<STAGE>=off, open VS Code, emit message.
  let sid = null;
  try {
    sid = resolveSessionId({
      sessionIdFromInput: input.session_id,
      transcriptPath: input.transcript_path,
    });
  } catch (_) { /* fail-open */ }

  let plansDir = null;
  try { plansDir = getWorkflowPlansDir(); } catch (_) { /* fail-open */ }

  const absPath = resolveArtifact(stage, sid, plansDir);

  // Check CONFIRM_<STAGE>=off directly from env var — works even when absPath is null.
  const OFF_LITERALS = new Set(["off"]);
  const flagName = `CONFIRM_${stage.toUpperCase()}`;
  const rawFlag = process.env[flagName];
  const confirmOff = rawFlag != null && OFF_LITERALS.has(rawFlag.toLowerCase().trim());
  if (confirmOff) {
    process.stdout.write(JSON.stringify({ systemMessage: `[confirm-skipped: ${flagName}=off]` }));
    process.exit(0);
  }

  if (absPath) {
    try {
      if (shouldOpenInVsCode()) {
        openInVsCode(absPath, resolveWorkspaceFolderUri(input.tool_input || {}));
      }
    } catch (_) { /* fail-open */ }
  }

  const url = (absPath && isVsCode()) ? toVsCodeFileUri(absPath) : null;
  const msg = renderMessage(stage, absPath, url);
  process.stdout.write(JSON.stringify({ systemMessage: msg }));
  process.exit(0);
}

module.exports = { parseSentinel, renderMessage, resolveArtifact };
