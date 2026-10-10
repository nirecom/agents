#!/usr/bin/env node
// PreToolUse hook: when Bash emits a <<WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL}>>
// sentinel, surface the relevant plan/PR context above the permission dialog so the
// user can Allow or Deny inline. Sentinel patterns: hooks/lib/sentinel-patterns.js.
// Output protocol: always a { "systemMessage" } for the user, plus a PreToolUse
// additionalContext carrying the plan's blob URL or reason (hooks/lib/plan-link.js) for the
// model. Always exit 0 (fail-open — we never block the user's approval flow).
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

const { readHookInput } = require("./lib/read-stdin");

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

// url: the published blob URL (plan-sync), shown in place of the local path when present.
function renderMessage(stage, absPath, url) {
  if (absPath) {
    return `[${stage}] Plan file: ${url || absPath}\nClick Allow to proceed, Deny to abort.`;
  }
  return `[${stage}] Plan ready (file path unavailable)\nClick Allow to proceed, Deny to abort.`;
}

if (require.main === module) {
  try { loadDefaultEnv(); } catch (_) {}
  const hookInput = readHookInput();
  if (hookInput.kind !== "ok") noopExit();
  const input = hookInput.input;

  if (!isCommandTool(input.tool_name)) noopExit();

  const command = commandTextOf(input.tool_name, input.tool_input);
  const parsed = parseSentinel(command);
  if (!parsed) noopExit();

  const stage = parsed.stage;

  // Plan-stage branch: resolve artifact, honor CONFIRM_<STAGE>=off, emit message.
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

  // The user-facing systemMessage may name the local path (only the user sees it); the
  // model-facing additionalContext carries the blob URL or a reason code, never a path.
  let url = null;
  let hso = null;
  try {
    const { resolvePlanLink, renderModelContext } = require("./lib/plan-link");
    const opts = { plansDir };
    if (absPath) opts.absPath = absPath;
    const link = resolvePlanLink(sid, stage, opts);
    if (link.url) url = link.url;
    hso = { hookEventName: "PreToolUse", additionalContext: renderModelContext([{ stage, ...link }], { when: "confirm" }) };
  } catch (_) { /* fail-open: the systemMessage alone is shown */ }
  const out = { systemMessage: renderMessage(stage, absPath, url) };
  if (hso) out.hookSpecificOutput = hso;
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

module.exports = { parseSentinel, renderMessage, resolveArtifact };
