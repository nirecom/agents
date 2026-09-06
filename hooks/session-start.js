#!/usr/bin/env node
// Claude Code SessionStart hook: set CLAUDE_SESSION_ID env and clean up zombie state files

const fs = require("fs");
const path = require("path");
const os = require("os");
const { spawnSync } = require("child_process");
const { cleanupZombies, createInitialState, writeState, readState,
        getCurrentContext, resolveInheritanceDonor, listRecentContextCandidates,
        reconcileEffectiveState, getStatePath, VALID_STEPS } = require("./workflow-state");
const { applyInheritance } = require("./workflow-state/inheritance/apply");
const { SESSION_ID_ANNOUNCE_PREFIX } = require("./lib/session-announce");
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
// #1305: `source` and `transcript_path` are the two payload fields inheritance
// is keyed on — only a continuation may inherit, and the transcript is where its
// ancestry is read from. `agent_id` marks a subagent, which never inherits.
let sessionSource = null;
let transcriptPath = null;
let agentId = null;
try {
  const input = JSON.parse(readStdin());
  sessionId = input.session_id;
  // Layer① of model identification — kept as a bare value, not the whole input,
  // so nothing else in this hook can start depending on the payload shape.
  modelHint = input.model ?? null;
  sessionSource = input.source ?? null;
  transcriptPath = input.transcript_path ?? null;
  agentId = input.agent_id ?? null;
  // transcript_path → correct JSONL path for worktree sessions
  if (input.transcript_path) process.env.CLAUDE_SESSION_JSONL_PATH = input.transcript_path;
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
let stateWriteError = null;
// #1305 reporting surface — see the SD-4 block near the bottom of this file.
let inheritDecision = null;
let inheritCandidateSid = null;
let adoptCandidate = null;
if (sessionId) {
  try {
    const existing = readState(sessionId);
    if (!existing) {
      let ctx;
      try { ctx = getCurrentContext(); }
      catch (e) { ctx = { cwd: process.cwd(), git_branch: null }; }

      // #1305: inheritance is keyed on PROVABLE DESCENT, not on cwd+branch.
      // resolveInheritanceDonor owns every gate; this hook only reports.
      let inherited = null;
      try {
        const verdict = resolveInheritanceDonor({
          sessionId, source: sessionSource, transcriptPath, ctx, agentId,
        });
        inherited = verdict.donor;
        inheritDecision = verdict.decision;
        inheritCandidateSid = verdict.candidateSessionId;
      } catch (e) { inherited = null; }

      // A `startup` session is the true crash-resume case: nothing is inherited,
      // but a resumable same-context session is surfaced so the user can adopt it
      // explicitly.
      if (inheritDecision === "startup-no-lineage") {
        try {
          const candidates = listRecentContextCandidates(ctx) || [];
          adoptCandidate = candidates.length > 0 ? candidates[0] : null;
        } catch (e) { adoptCandidate = null; }
      }

      // The new session ALWAYS starts from a clean initial state: its own
      // session_start_context, its own created_at, and an empty stream (#1733).
      const newState = createInitialState(sessionId, ctx);
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

      if (inherited && !stateWriteError) {
        try {
          applyInheritance(sessionId, newState.created_at, inherited);
          inheritedFromSessionId = inherited.session_id;
        } catch (e) {
          stateWriteError = (e && e.message) || String(e);
          // A refused inheritance (e.g. artifact-hash mismatch on a carried
          // approval) must leave NO state file: the base file written above
          // would otherwise survive as an orphan asserting that this session
          // has a clean, legitimately-created state (#1133/#1148).
          try { fs.unlinkSync(getStatePath(sessionId)); } catch (_) {}
          try {
            process.stderr.write(`session-start: inheritance failed for ${sessionId}: ${stateWriteError}\n`);
          } catch (_) {}
        }
      }
    }
  } catch (e) {
    // Fail-open
  }
}

// Freeze which model drives this session, and with it the verbose-prompt flag.
// Must run AFTER the state file exists so the record lands in this session's own
// state rather than in a file created for it. Write-once — no-op when the hook
// payload carried no identifier. Skipped when the state file was refused:
// appendEvents would recreate the very file the refusal deleted.
if (sessionId && !stateWriteError) {
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
  // This line is itself lineage evidence: a compacted / forked transcript copies
  // the attachment forward, which is how readLineageAncestors recovers the
  // ancestor when no forkedFrom row exists. SSOT for the wording: lib/session-announce.
  lines.push(`${SESSION_ID_ANNOUNCE_PREFIX}${sessionId}`);
  lines.push(`State file: ${path.join(stateDir, sessionId + ".json")}`);
  const { buildInheritanceNotice } = require("./session-start/inheritance-notice");
  for (const line of buildInheritanceNotice({
    sessionId, sessionSource, inheritedFromSessionId,
    inheritCandidateSid, inheritDecision, adoptCandidate,
  })) {
    lines.push(line);
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
  // Independent of drift: the generated allow rules could not be produced, so the check above
  // silently covered less than it usually does. Say so rather than imply a clean bill of health.
  if (d.generatorUnavailable) {
    lines.push("");
    lines.push("WARNING: the generated allow rules are unavailable — settings.json was checked without them; run: node \"" + path.join(__dirname, "..", "install", "gen-settings-allow.js") + "\" --check");
    lines.push("  reason: " + d.generatorUnavailable);
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
