#!/usr/bin/env node
// Claude Code PostToolUse hook: intercept workflow markers from skill completions
//
// Supported markers (must be the ENTIRE Bash command — no pipes, &&, redirects):
//   echo "<<WORKFLOW_MARK_STEP_<step>_<status>>>"   — mark a step
//   echo "<<WORKFLOW_RESET_FROM_<step>>>"            — reset state from a step
//
// Bypasses CLAUDE_ENV_FILE propagation issue in Bash subprocesses (Anthropic bug #27987).

const fs = require("fs");
const {
  VALID_STEPS,
  resolveSessionId,
  markStep,
  createInitialState,
  writeState,
} = require("./lib/workflow-state");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

// Strict anchored regex: the entire command must be exactly this echo.
// Rejects pipes, &&, ;, redirects, prefixed cd, printf, etc. by construction.
const MARKER_RE_DQ =
  /^echo\s+"<<WORKFLOW_MARK_STEP_([a-z_]+)_(complete|skipped|pending|in_progress)>>"$/;
const MARKER_RE_SQ =
  /^echo\s+'<<WORKFLOW_MARK_STEP_([a-z_]+)_(complete|skipped|pending|in_progress)>>'$/;
const RESET_FROM_RE_DQ = /^echo\s+"<<WORKFLOW_RESET_FROM_([a-z_]+)>>"$/;
// USER_VERIFIED: DQ only, single literal space, strictly anchored — matches settings.json ask glob exactly
const USER_VERIFIED_RE_DQ = /^echo "<<WORKFLOW_USER_VERIFIED>>"$/;
const WRITE_TESTS_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED>>"$/;
const DOCS_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_DOCS_NOT_NEEDED>>"$/;

function done(additionalContext) {
  const out = additionalContext ? { additionalContext } : {};
  console.log(JSON.stringify(out));
  process.exit(0);
}

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  done(); // fail-open on malformed stdin
}

// Only handle Bash tool
if (input.tool_name !== "Bash") done();

const command = ((input.tool_input && input.tool_input.command) || "").trim();
const markMatch = command.match(MARKER_RE_DQ) || command.match(MARKER_RE_SQ);
const resetMatch = command.match(RESET_FROM_RE_DQ);
const userVerifiedMatch = command.match(USER_VERIFIED_RE_DQ);
const writeTestsNotNeededMatch = command.match(WRITE_TESTS_NOT_NEEDED_RE_DQ);
const docsNotNeededMatch = command.match(DOCS_NOT_NEEDED_RE_DQ);
if (!markMatch && !resetMatch && !userVerifiedMatch && !writeTestsNotNeededMatch && !docsNotNeededMatch) done(); // not a marker command

// If the echo itself failed, don't apply (handle multiple possible response shapes)
const toolResponse = input.tool_response || {};
const exitCode =
  toolResponse.exit_code ??
  toolResponse.exitCode ??
  (toolResponse.success === false ? 1 : 0);
if (exitCode !== 0) {
  const label = markMatch ? markMatch[1] : resetMatch ? resetMatch[1] : "(special)";
  done(`workflow-mark: echo exited ${exitCode} — operation for "${label}" NOT applied.`);
}


// Resolve session ID from hook stdin (preferred), fall back to CLAUDE_ENV_FILE
const sessionId = input.session_id || resolveSessionId();

// --- WRITE_TESTS_NOT_NEEDED handler ---
if (writeTestsNotNeededMatch) {
  if (!sessionId) {
    done(
      `workflow-mark: could not resolve session_id — write_tests NOT recorded. ` +
        `Re-run: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED>>"`
    );
  }
  try {
    markStep(sessionId, "write_tests", "complete");
  } catch (e) {
    done(`workflow-mark: failed to write state — ${e.message}. write_tests NOT recorded.`);
  }
}

// --- DOCS_NOT_NEEDED handler ---
if (docsNotNeededMatch) {
  if (!sessionId) {
    done(
      `workflow-mark: could not resolve session_id — docs NOT recorded. ` +
        `Re-run: echo "<<WORKFLOW_DOCS_NOT_NEEDED>>"`
    );
  }
  try {
    markStep(sessionId, "docs", "complete");
  } catch (e) {
    done(`workflow-mark: failed to write state — ${e.message}. docs NOT recorded.`);
  }
}

// --- USER_VERIFIED handler ---
if (userVerifiedMatch) {
  if (!sessionId) {
    done(
      `workflow-mark: could not resolve session_id — user_verification NOT recorded. ` +
        `Re-run: echo "<<WORKFLOW_USER_VERIFIED>>" (ask dialog will re-trigger for user approval)`
    );
  }
  try {
    markStep(sessionId, "user_verification", "complete");
  } catch (e) {
    done(
      `workflow-mark: failed to write state — ${e.message}. user_verification NOT recorded.`
    );
  }
}

// --- MARK_STEP handler ---
if (markMatch) {
  const [, stepName, status] = markMatch;

  // user_verification must go through the WORKFLOW_USER_VERIFIED echo path
  if (stepName === "user_verification") {
    done(
      `workflow-mark: user_verification NOT recorded — MARK_STEP sentinel is rejected for this step. ` +
        `Ask the user for commit approval via: echo "<<WORKFLOW_USER_VERIFIED>>"`
    );
  }

  // write_tests and docs must go through evidence (staged files) or NOT_NEEDED sentinels
  if (stepName === "write_tests") {
    done(
      `workflow-mark: write_tests NOT recorded — MARK_STEP sentinel is rejected for this step. ` +
        `Stage tests/ changes (run /write-tests then git add tests/) ` +
        `OR declare not needed: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED>>"`
    );
  }
  if (stepName === "docs") {
    done(
      `workflow-mark: docs NOT recorded — MARK_STEP sentinel is rejected for this step. ` +
        `Stage doc changes (run /update-docs then git add docs/) ` +
        `OR declare not needed: echo "<<WORKFLOW_DOCS_NOT_NEEDED>>"`
    );
  }

  // Validate step name (regex already constrains status values)
  if (!VALID_STEPS.includes(stepName)) {
    done(`workflow-mark: unknown step "${stepName}" in marker — ignored.`);
  }

  if (!sessionId) {
    done(
      `workflow-mark: could not resolve session_id — step "${stepName}" NOT recorded. ` +
        `Commit gate will block. Re-run: ` +
        `echo "<<WORKFLOW_MARK_STEP_${stepName}_${status}>>"`
    );
  }

  try {
    markStep(sessionId, stepName, status);
  } catch (e) {
    done(
      `workflow-mark: failed to write state — ${e.message}. Step "${stepName}" NOT recorded.`
    );
  }
}

// --- RESET_FROM handler ---
if (resetMatch) {
  const [, fromStep] = resetMatch;

  if (!VALID_STEPS.includes(fromStep)) {
    done(`workflow-mark: unknown step "${fromStep}" for reset-from — ignored.`);
  }

  if (!sessionId) {
    done(
      `workflow-mark: could not resolve session_id — reset-from "${fromStep}" NOT applied. ` +
        `Re-run: echo "<<WORKFLOW_RESET_FROM_${fromStep}>>"`
    );
  }

  try {
    const newState = createInitialState(sessionId);
    const fromIndex = VALID_STEPS.indexOf(fromStep);
    const now = new Date().toISOString();
    for (let i = 0; i < fromIndex; i++) {
      newState.steps[VALID_STEPS[i]] = { status: "complete", updated_at: now };
    }
    writeState(sessionId, newState);
  } catch (e) {
    done(`workflow-mark: reset-from failed — ${e.message}.`);
  }
}

done();
