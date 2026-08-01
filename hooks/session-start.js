#!/usr/bin/env node
// Claude Code SessionStart hook: set CLAUDE_SESSION_ID env and clean up zombie state files

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");
const { cleanupZombies, createInitialState, writeState, readState,
        getCurrentContext, findLatestStateForContext, reconcileEffectiveState,
        VALID_STEPS } = require("./workflow-state");
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
let modelHint = null;
let transcriptPath = null;
try {
  const input = JSON.parse(readStdin());
  sessionId = input.session_id;
  // Layer① of model identification — kept as a bare value, not the whole input,
  // so nothing else in this hook can start depending on the payload shape.
  modelHint = input.model ?? null;
  // transcript_path → correct JSONL path for worktree sessions
  if (input.transcript_path) process.env.CLAUDE_SESSION_JSONL_PATH = input.transcript_path;
  if (typeof input.transcript_path === "string") transcriptPath = input.transcript_path;
} catch (e) {
  // Fail-open: malformed input — continue without setting session ID
}

// Persist the transcript path as a file (#1763). CLAUDE_SESSION_JSONL_PATH above
// never leaves this process, so the issue-provenance CLI — a separate Bash-tool
// subprocess — has no other way to find the transcript on the very first turn of
// a session. Keyed on the CC session UUID, like every other provenance marker.
if (sessionId && transcriptPath) {
  try {
    const { provenanceKeys, provenancePaths } = require("./lib/issue-provenance-keys");
    for (const key of provenanceKeys(sessionId)) {
      const target = provenancePaths(key).transcript;
      const tmp = target + ".tmp";
      fs.mkdirSync(require("path").dirname(target), { recursive: true });
      fs.writeFileSync(tmp, transcriptPath, { mode: 0o600 });
      fs.renameSync(tmp, target);
    }
  } catch (e) {
    // Fail-open: a SessionStart hook must never fail the session
  }
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
let stateWriteError = null;
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
        // #1133: the inherited steps may already show outline/detail `complete`.
        // writeState's completion-boundary invariant re-evaluates that as a
        // pending->complete transition for the NEW session, so the prior
        // session's approval records must travel with the steps — otherwise the
        // write throws no-approval-record and the new session gets NO state file.
        // Records stay bound to the artifact they were approved against via
        // artifact_session_id (artifacts are named <owner-sid>-<step>.md).
        if (inherited.plan_approvals && typeof inherited.plan_approvals === "object") {
          const carried = JSON.parse(JSON.stringify(inherited.plan_approvals));
          for (const step of Object.keys(carried)) {
            const rec = carried[step];
            if (rec && typeof rec === "object" && !rec.artifact_session_id) {
              rec.artifact_session_id = inherited.session_id || null;
            }
          }
          newState.plan_approvals = carried;
        }
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
      // Fail-open on the hook, but NEVER silently: a throw here means no state
      // file exists for this session at all (total workflow-state loss).
      try {
        writeState(sessionId, newState);
      } catch (e) {
        stateWriteError = (e && e.message) || String(e);
        try {
          process.stderr.write(`session-start: writeState failed for ${sessionId}: ${stateWriteError}\n`);
        } catch (_) {}
      }
    }
  } catch (e) {
    // Fail-open
  }
}

// Freeze which model drives this session, and with it the verbose-prompt flag.
// Must run AFTER the state file exists so the record lands in this session's own
// state rather than in a file created for it. Write-once — no-op when the hook
// payload carried no identifier.
if (sessionId) {
  try {
    const { resolveModelId } = require("./lib/model-identity");
    const { recordSessionModel } = require("./workflow-state");
    const resolved = resolveModelId({ model: modelHint });
    if (resolved) recordSessionModel(sessionId, resolved);
  } catch (e) { /* fail-open */ }
}

// Set VS Code session title from intent.md issue #.
// Delete CLAUDE_CODE_CHILD_SESSION so session-title.js write functions are
// not silently suppressed (hooks may inherit this env var from Claude Code).
delete process.env.CLAUDE_CODE_CHILD_SESSION;
if (sessionId) {
  try {
    const { writeSetIssue } = require("./lib/session-title");
    const plansDir = require("./lib/workflow-plans-dir").getWorkflowPlansDir();
    writeSetIssue(sessionId, process.cwd(), plansDir);
  } catch (e) { /* fail-open */ }
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
  let nextAction = "run /workflow-init to initialize the session state";

  if (state && state.steps) {
    // Display the derived view (#1681) so the status block agrees with what the
    // gates enforce. When derivation changes a step, the recorded value is shown
    // alongside it — the record is still the audit trail. Fail-open: any failure
    // falls back to the raw record.
    let snapshot = null;
    try {
      snapshot = reconcileEffectiveState(state, sessionId, {
        resolveAll: true,
        repoDir: process.env.CLAUDE_PROJECT_DIR,
        isWfMeta: state.workflow_type === "wf-meta",
      });
    } catch (e) { snapshot = null; }
    for (const step of VALID_STEPS) {
      const raw = (state.steps[step] || {}).status || "pending";
      const eff = (snapshot && snapshot.steps && snapshot.steps[step])
        ? snapshot.steps[step].status
        : raw;
      statusLines.push(
        eff === raw ? `- ${step}: ${eff}` : `- ${step}: ${eff} (recorded: ${raw})`
      );
    }
  } else {
    for (const step of VALID_STEPS) {
      statusLines.push(`- ${step}: pending`);
    }
  }

  // Call next-step for next-action hint (fail-open).
  if (sessionId) {
    try {
      const nextStepBin = path.join(__dirname, "..", "bin", "workflow", "next-step");
      if (fs.existsSync(nextStepBin)) {
        const r = spawnSync(process.execPath, [nextStepBin, "--session", sessionId], {
          encoding: "utf8", timeout: 3000, stdio: ["ignore", "pipe", "ignore"],
        });
        if (r.status === 0 && r.stdout) {
          let nextStepAction = "";
          let nextStepHint = "";
          for (const line of r.stdout.split("\n")) {
            const m = line.match(/^(\w+)=(?:'([^']*)'|(.*))$/);
            if (m) {
              if (m[1] === "ACTION") nextStepAction = m[2] !== undefined ? m[2] : (m[3] || "");
              if (m[1] === "NEXT_HINT") nextStepHint = m[2] !== undefined ? m[2] : (m[3] || "");
            }
          }
          if (nextStepAction === "done") {
            nextAction = "All steps complete. Run /session-close.";
          } else if (nextStepHint) {
            nextAction = nextStepHint;
          }
        }
      }
    } catch (e) { /* fail-open */ }
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
  if (stateWriteError) {
    lines.push(
      `WARNING: workflow state file could NOT be created for this session — ${stateWriteError}. ` +
      `Workflow step state is not persisted; run /workflow-init to re-establish it.`
    );
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
// The hardening line, only when the model is already known and matched.
try {
  const { getVerbosePromptInjection } = require("./lib/verbose-prompt");
  const verbosePrompt = getVerbosePromptInjection(sessionId);
  if (verbosePrompt) lines.push(verbosePrompt);
} catch (_e) { /* fail-open */ }
console.log(JSON.stringify({ additionalContext: lines.join("\n") }));
