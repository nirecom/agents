#!/usr/bin/env node
// Claude Code PostCompact hook: re-inject session ID into conversation context

const fs = require("fs");
const path = require("path");
const os = require("os");
const { getConvLangInjection } = require("./lib/conv-lang");
const { readState } = require("./workflow-state");
const { SESSION_ID_ANNOUNCE_PREFIX } = require("./lib/session-announce");

const WORKFLOW_STEPS = [
  "workflow_init",
  "clarify_intent",
  "research",
  "outline",
  "detail",
  "write_tests",
  "review_security",
  "docs",
  "user_verification",
  "cleanup",
];

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

let sessionId = null;
try {
  const input = JSON.parse(readStdin());
  sessionId = input.session_id || null;
} catch (e) {}

if (!sessionId) {
  console.log("{}");
  process.exit(0);
}

// The one event the artifact exists for is also the one the compacted
// transcript can no longer describe, and PostCompact is the only code that runs
// at that instant. A lost breadcrumb must never cost the re-injection below.
try {
  const { appendHandoffEntry } = require("./lib/handoff-artifact");
  appendHandoffEntry(sessionId, {
    cls: "B",
    step: "-",
    key: "compaction",
    summary: `context compaction occurred at ${new Date().toISOString()}`,
    pointer: "-",
    origin: "flush",
  });
} catch (_e) { /* fail-open */ }

try {
  const stateDir = process.env.CLAUDE_WORKFLOW_DIR ||
    path.join(os.homedir(), ".claude", "projects", "workflow");
  const lines = [
    // Lineage evidence for #1305 — the compacted transcript carries this
    // attachment forward, naming the pre-compact session. SSOT: lib/session-announce.
    `${SESSION_ID_ANNOUNCE_PREFIX}${sessionId}`,
    `State file: ${path.join(stateDir, sessionId + ".json")}`,
  ];
  try {
    const state = readState(sessionId);
    lines.push("");
    lines.push("Workflow progress:");
    if (state && state.steps) {
      if (state.cwd)        lines.push(`Worktree: ${state.cwd}`);
      if (state.git_branch) lines.push(`Branch: ${state.git_branch}`);
      let pendingCount = 0;
      for (const step of WORKFLOW_STEPS) {
        const s = state.steps[step] || {};
        const status = s.status || "pending";
        const annotation =
          (step === "user_verification" && status === "pending" && s.reset_reason === "post-merge")
            ? " (reset after pr merge — expected)"
            : "";
        lines.push(`- ${step}: ${status}${annotation}`);
        if (status === "pending" && !(step === "user_verification" && s.reset_reason === "post-merge")) {
          pendingCount++;
        }
      }
      if (pendingCount > 0) {
        lines.push("→ Workflow is in progress. Run /resume-session to resume from the current step.");
      }
    } else {
      lines.push("(no state file found — run /workflow-init)");
    }
  } catch (_e) { /* fail-open */ }

  try {
    const convLang = getConvLangInjection();
    if (convLang) lines.push(convLang);
  } catch (_e) { /* fail-open */ }

  // Re-inject the model-conditional hardening line after compaction. Read-only:
  // the flag was frozen at SessionStart, so PostCompact never resolves the model
  // and never writes state.
  try {
    const { getVerbosePromptInjection } = require("./lib/verbose-prompt");
    const verbosePrompt = getVerbosePromptInjection(sessionId);
    if (verbosePrompt) lines.push(verbosePrompt);
  } catch (_e) { /* fail-open */ }

  console.log(JSON.stringify({ additionalContext: lines.join("\n") }));
} catch (e) {
  console.log("{}");
}
