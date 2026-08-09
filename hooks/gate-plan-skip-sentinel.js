#!/usr/bin/env node
"use strict";
const fs = require("fs");
try { require("./lib/load-env").loadDefaultEnv(); } catch (_e) { /* fail-open */ }
const { OUTLINE_NOT_NEEDED_RE_DQ, DETAIL_NOT_NEEDED_RE_DQ, WRITE_TESTS_NOT_NEEDED_RE_DQ } =
  require("./lib/sentinel-patterns");

// #1286: recorded-verdict allow-gate. Fail-open on any import error.
let resolveSessionId = null;
try {
  ({ resolveSessionId } = require("./workflow-state"));
} catch (_e) { /* fail-open */ }

// #1644: the allow rule itself lives in plan-skip-allowance.js, shared with the
// CLI door (bin/workflow --advance --status skipped). Only the WORDING of the
// allow reason belongs to this hook. Fail-open: an unimportable module simply
// never promotes to allow, exactly as before.
let hasRecordedSkipJudgment = null;
let isConfirmOffForStepSentinel = null;
try {
  ({ hasRecordedSkipJudgment, isConfirmOffForStepSentinel } =
    require("./workflow-state/plan-skip-allowance"));
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

function hasRecord(sid, step) {
  return !!sid && typeof hasRecordedSkipJudgment === "function"
    && hasRecordedSkipJudgment(sid, step) === true;
}

function isOff(step) {
  return typeof isConfirmOffForStepSentinel === "function"
    && isConfirmOffForStepSentinel(step) === true;
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
  if (hasRecord(resolvedSessionId, "outline"))
    allow("recorded-verdict: outline skip_judgment orchestrator+all_conditions_met — outline skip auto-approved.");
  if (isOff("outline"))
    allow("CONFIRM_OUTLINE=off — outline skip auto-approved.");
}
if (DETAIL_NOT_NEEDED_RE_DQ.test(cmd)) {
  if (hasRecord(resolvedSessionId, "detail"))
    allow("recorded-verdict: detail skip_judgment orchestrator+all_conditions_met — detail skip auto-approved.");
  if (isOff("detail"))
    allow("CONFIRM_DETAIL=off — detail skip auto-approved.");
}
if (WRITE_TESTS_NOT_NEEDED_RE_DQ.test(cmd) && isOff("write_tests"))
  allow("CONFIRM_TESTS=off — write-tests skip auto-approved.");

passThrough();
