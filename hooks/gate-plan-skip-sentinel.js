#!/usr/bin/env node
"use strict";
const fs = require("fs");
try { require("./lib/load-env").loadDefaultEnv(); } catch (_e) { /* fail-open */ }
const { OUTLINE_NOT_NEEDED_RE_DQ, DETAIL_NOT_NEEDED_RE_DQ, WRITE_TESTS_NOT_NEEDED_RE_DQ } =
  require("./lib/sentinel-patterns");

// #1286: recorded-verdict allow-gate. Fail-open on any import error.
let hasValidSkipJudgment = null;
let resolveSessionId = null;
try {
  ({ hasValidSkipJudgment, resolveSessionId } = require("./lib/workflow-state"));
} catch (_e) { /* fail-open */ }

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const n = fs.readSync(0, buf, 0, buf.length);
      if (n === 0) break;
      chunks.push(buf.slice(0, n));
    }
  } catch (_e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function passThrough() { console.log("{}"); process.exit(0); }

function allow(reason) {
  console.log(JSON.stringify({
    hookSpecificOutput: {
      hookEventName: "PreToolUse",
      permissionDecision: "allow",
      permissionDecisionReason: reason,
    },
  }));
  process.exit(0);
}

const OFF_LITERALS = new Set(["off"]);

function isOff(name) {
  const raw = process.env[name];
  return raw != null && OFF_LITERALS.has(String(raw).trim().toLowerCase());
}

let input;
try { input = JSON.parse(readStdin()); } catch (_e) { passThrough(); }
if (!input || input.tool_name !== "Bash") passThrough();
const cmd = ((input.tool_input && input.tool_input.command) || "").trim();
if (!cmd) passThrough();

// Resolve session id fail-safe for the recorded-verdict check.
// Priority: WORKFLOW_SESSION_ID env var → resolveSessionId chain.
let resolvedSessionId = null;
try {
  const wsid = process.env.WORKFLOW_SESSION_ID;
  if (wsid && /^[A-Za-z0-9_-]+$/.test(wsid.trim())) {
    resolvedSessionId = wsid.trim();
  } else if (typeof resolveSessionId === "function") {
    resolvedSessionId = resolveSessionId({ sessionIdFromInput: input.session_id }) || null;
  }
} catch (_) { resolvedSessionId = null; }

// #1286: allow when a valid recorded verdict exists OR legacy CONFIRM_*=off.
if (OUTLINE_NOT_NEEDED_RE_DQ.test(cmd)) {
  const hasRecord = resolvedSessionId && typeof hasValidSkipJudgment === "function"
    && hasValidSkipJudgment(resolvedSessionId, "outline");
  if (hasRecord)
    allow("recorded-verdict: outline skip_judgment orchestrator+all_conditions_met — outline skip auto-approved.");
  if (isOff("CONFIRM_OUTLINE"))
    allow("CONFIRM_OUTLINE=off — outline skip auto-approved.");
}
if (DETAIL_NOT_NEEDED_RE_DQ.test(cmd)) {
  const hasRecord = resolvedSessionId && typeof hasValidSkipJudgment === "function"
    && hasValidSkipJudgment(resolvedSessionId, "detail");
  if (hasRecord)
    allow("recorded-verdict: detail skip_judgment orchestrator+all_conditions_met — detail skip auto-approved.");
  if (isOff("CONFIRM_DETAIL"))
    allow("CONFIRM_DETAIL=off — detail skip auto-approved.");
}
if (WRITE_TESTS_NOT_NEEDED_RE_DQ.test(cmd) && isOff("CONFIRM_TESTS"))
  allow("CONFIRM_TESTS=off — write-tests skip auto-approved.");

passThrough();
