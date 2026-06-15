#!/usr/bin/env node
// Claude Code SessionStart hook: set CLAUDE_SESSION_ID env and clean up zombie state files

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");
const { cleanupZombies, createInitialState, writeState, readState,
        getCurrentContext, findLatestStateForContext,
        VALID_STEPS, STEP_HINT } = require("./lib/workflow-state");
const settingsDrift = require("./lib/settings-drift");
const { getConvLangInjection } = require("./lib/conv-lang");

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

let sessionId;
try {
  const input = JSON.parse(readStdin());
  sessionId = input.session_id;
} catch (e) {
  // Fail-open: malformed input — continue without setting session ID
}

// Write CLAUDE_SESSION_ID to env file if available (KEY=VALUE format, no export prefix)
if (sessionId && process.env.CLAUDE_ENV_FILE) {
  try {
    fs.appendFileSync(
      process.env.CLAUDE_ENV_FILE,
      `CLAUDE_SESSION_ID=${sessionId}\n`,
      "utf8"
    );
  } catch (e) {
    // Fail-open
  }
}

// Create initial state file if session_id is available (with inheritance logic)
let inheritedFromSessionId = null;
if (sessionId) {
  try {
    const existing = readState(sessionId);
    if (!existing) {
      let ctx;
      try { ctx = getCurrentContext(); }
      catch (e) { ctx = { cwd: process.cwd(), git_branch: null }; }

      let inherited = null;
      try { inherited = findLatestStateForContext(ctx); }
      catch (e) {}

      let newState;
      if (inherited) {
        newState = {
          version: 1,
          session_id: sessionId,
          created_at: new Date().toISOString(),
          cwd: ctx.cwd,
          git_branch: ctx.git_branch,
          steps: JSON.parse(JSON.stringify(inherited.steps)),
        };
        // Issue #772: never carry cleanup state across session boundaries.
        // cleanup is the terminal step of the prior session's task; a new session
        // represents a new task whose cleanup obligation has not yet been incurred.
        // "skipped" bypasses workflow-gate (cleanup is in SKIPPABLE_STEPS).
        // "pending" would re-block commits — that IS the original bug symptom.
        // Omitting the key does NOT work: readState() re-injects it as "pending".
        if (newState.steps && newState.steps.cleanup) {
          newState.steps.cleanup = {
            status: 'skipped',
            updated_at: new Date().toISOString(),
            skip_reason: 'inherited-from-prior-session',
          };
        }
        inheritedFromSessionId = inherited.session_id;
      } else {
        newState = createInitialState(sessionId, ctx);
      }
      try { writeState(sessionId, newState); } catch (e) {}
    }
  } catch (e) {
    // Fail-open
  }
}

// --- BEGIN temporary: .git/workflow/ → ~/.claude/projects/workflow/ migration ---
// Delete old per-repo state files left by the previous implementation.
// Safe to run on every session start — idempotent, only touches CLAUDE_PROJECT_DIR.
if (sessionId && process.env.CLAUDE_PROJECT_DIR) {
  try {
    const oldDir = require("path").join(process.env.CLAUDE_PROJECT_DIR, ".git", "workflow");
    const oldFile = require("path").join(oldDir, sessionId + ".json");
    const fs2 = require("fs");
    if (fs2.existsSync(oldFile)) fs2.unlinkSync(oldFile);
  } catch (e) {
    // Fail-open
  }
}
// --- END temporary: .git/workflow/ → ~/.claude/projects/workflow/ migration ---

// Clean up zombie state files (older than 7 days)
try {
  cleanupZombies(7);
} catch (e) {
  // Fail-open
}

// Build workflow status block for additionalContext
function buildWorkflowStatus(sessionId) {
  const state = sessionId ? readState(sessionId) : null;
  const statusLines = ["# Workflow status (this session)"];
  let nextAction = "clarify-intent (state unavailable)";

  if (state && state.steps) {
    for (const step of VALID_STEPS) {
      const s = (state.steps[step] || {}).status || "pending";
      statusLines.push(`- ${step}: ${s}`);
    }
    // Find first incomplete step
    for (const step of VALID_STEPS) {
      const s = (state.steps[step] || {}).status || "pending";
      if (s !== "complete" && s !== "skipped") {
        nextAction = STEP_HINT[step] || step;
        break;
      }
    }
    // All steps done
    if (nextAction === "clarify-intent (state unavailable)" &&
        VALID_STEPS.every(step => ["complete","skipped"].includes((state.steps[step]||{}).status))) {
      nextAction = "All steps complete. Run /commit-push to commit.";
    }
  } else {
    for (const step of VALID_STEPS) {
      statusLines.push(`- ${step}: pending`);
    }
    nextAction = STEP_HINT.workflow_init;
  }

  statusLines.push("");
  statusLines.push(`NEXT ACTION: ${nextAction}`);

  // Resume hint — non-fatal, fail-open.
  try {
    const detectBin = path.join(__dirname, "..", "bin", "resume-session-detect");
    if (fs.existsSync(detectBin)) {
      const r = spawnSync(
        process.execPath, [detectBin],
        { encoding: "utf8", timeout: 3000, stdio: ["ignore", "pipe", "ignore"] }
      );
      if (r.status === 0 && r.stdout) {
        let parsed = null;
        try { parsed = JSON.parse(r.stdout.trim()); } catch (_) { /* fail-open */ }
        if (parsed && parsed.type && parsed.type !== "none") {
          statusLines.push("");
          statusLines.push("RESUME HINT: Workflow may be mid-step. Run /resume-session to inspect and resume.");
        }
      }
    }
  } catch (e) { /* fail-open */ }

  return statusLines.join("\n");
}

// SessionStart hooks must output valid JSON
const lines = [];
if (sessionId) {
  const stateDir = process.env.CLAUDE_WORKFLOW_DIR ||
    path.join(os.homedir(), ".claude", "projects", "workflow");
  lines.push(`Current workflow session_id: ${sessionId}`);
  lines.push(`State file: ${path.join(stateDir, sessionId + ".json")}`);
  if (inheritedFromSessionId) {
    lines.push(`Inherited workflow steps from session ${inheritedFromSessionId} (cwd+branch match)`);
  }
}
lines.push("");
lines.push(buildWorkflowStatus(sessionId));
try {
  const d = settingsDrift.detectDrift({ homeDir: os.homedir() });
  if (d.drifted) {
    const r = d.missing ? "assembled file missing"
      : d.broken ? ("parse error: " + d.reason)
      : "missing entries (permissions or hooks)";
    lines.push("");
    lines.push("WARNING: ~/.claude/settings.json drift detected — run: node \"" + path.join(__dirname, "..", "install", "assemble-settings.js") + "\"");
    lines.push("  reason: " + r);
  }
} catch (_e) { /* fail-open */ }
try {
  const convLang = getConvLangInjection();
  if (convLang) lines.push(convLang);
} catch (_e) { /* fail-open */ }
console.log(JSON.stringify({ additionalContext: lines.join("\n") }));
