#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan Step 2 protocol.
//
// When show-plan-link.js emits a breadcrumb during a turn (regardless of
// CONFIRM_<STEP>), it drops a per-turn marker. On Stop, this hook
// reads+deletes those markers, then scans the last assistant message for any
// forbidden representation of the WORKFLOW_PLANS_DIR path (native,
// forward-slash, tilde, or file:/// URI). If found, the turn is blocked
// (decision:block + exit 2) so the orchestrator must re-issue the response
// without the path.
//
// Fail-open everywhere: missing markers, missing transcript, parse errors —
// all silently pass through. The guard activates only when (a) a marker
// exists AND (b) the assistant message clearly contains the path.
//
// Layer 2: order-aware CONFIRM-continuation guard
// When a CONFIRM_<STAGE> sentinel (INTENT / OUTLINE / DETAIL / PR_CREATED) is
// present in the latest assistant turn but no stage-valid follow-up tool_use
// appears AFTER it in the same turn, block the turn so the model restarts and
// invokes the correct next step. PR_CREATED accepts Skill(worktree-end) or
// Bash(WORKFLOW_USER_VERIFIED) unconditionally; mode-correctness (which form
// fits the current ENFORCE_WORKTREE value) is enforced by the commit-push
// SKILL.md prompt (Layer 1), not here.
"use strict";

const fs = require("fs");
const {
  CONFIRM_INTENT_RE_DQ,
  CONFIRM_OUTLINE_RE_DQ,
  CONFIRM_DETAIL_RE_DQ,
  CONFIRM_PR_CREATED_RE_DQ,
} = require("./lib/sentinel-patterns");

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

if (require.main === module) {
  let input = {};
  try {
    const raw = readStdin();
    if (!raw) process.exit(0);
    input = JSON.parse(raw);
  } catch (_) {
    process.exit(0);
  }

  if (input.stop_hook_active === true) process.exit(0);

  const { resolveSessionId } = require("./lib/workflow-state");
  const sid = resolveSessionId({
    sessionIdFromInput: input.session_id,
    transcriptPath: input.transcript_path,
  });
  if (!sid) process.exit(0);

  const { readAndDeleteTurnMarkers } = require("./lib/turn-marker");
  const markers = readAndDeleteTurnMarkers(sid);
  // Marker absence is no longer a blanket early-exit (#842): CONFIRM_PR_CREATED
  // turns from `commit-push` never write a plan artifact, so no turn marker exists.
  // Layer 2 detects CONFIRM_<STAGE> sentinels structurally; the marker gate is
  // preserved only for Layer 1 path-emission scan (bound to plan-artifact writes).
  const hasMarker = markers.length > 0;

  // Read transcript and scan backward for the most recent assistant message.
  // Capture both the joined text (Layer 1) and the full content array (Layer 2).
  let lastAssistantText = "";
  let lastAssistantContent = null;
  try {
    const raw = fs.readFileSync(input.transcript_path, "utf8");
    const lines = raw.split("\n");
    const tail = lines.slice(Math.max(0, lines.length - 50));
    for (let i = tail.length - 1; i >= 0; i--) {
      const line = tail[i];
      if (!line) continue;
      let entry;
      try {
        entry = JSON.parse(line);
      } catch (_) {
        continue;
      }
      if (!entry || entry.type !== "assistant") continue;
      const content = entry.message && entry.message.content;
      if (!Array.isArray(content)) process.exit(0);
      lastAssistantContent = content;
      const texts = [];
      for (const item of content) {
        if (item && item.type === "text" && typeof item.text === "string") {
          texts.push(item.text);
        }
      }
      lastAssistantText = texts.join("\n");
      break;
    }
  } catch (_) {
    process.exit(0);
  }

  if (hasMarker) {
    const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
    const { workspaceFolderUriFrom } = require("./show-plan-link");
    let plansDir;
    try {
      plansDir = getWorkflowPlansDir();
    } catch (_) {
      process.exit(0);
    }

    const patternsRaw = [
      plansDir,
      plansDir.replace(/\\/g, "/"),
      "~/.workflow-plans",
      workspaceFolderUriFrom(plansDir),
    ];
    const seen = new Set();
    const patterns = [];
    for (const p of patternsRaw) {
      if (typeof p !== "string" || p.length === 0) continue;
      if (seen.has(p)) continue;
      seen.add(p);
      patterns.push(p);
    }

    for (const pat of patterns) {
      if (lastAssistantText.includes(pat)) {
        process.stdout.write(JSON.stringify({
          decision: "block",
          reason: "[confirm-plan] Step 2 violation: orchestrator emitted a `~/.workflow-plans/` path representation. `show-plan-link.js` is the sole authoritative path surface. Re-issue the response without the path. (Hook: stop-confirm-plan-guard.js)",
        }));
        process.exit(2);
      }
    }
  }

  // Layer 2: order-aware CONFIRM-continuation guard. Fail-open on any error.
  try {
    if (Array.isArray(lastAssistantContent)) {
      let confirmIdx = -1;
      let stage = null;
      for (let i = 0; i < lastAssistantContent.length; i++) {
        const item = lastAssistantContent[i];
        if (!item || item.type !== "tool_use" || item.name !== "Bash") continue;
        const c = item.input && item.input.command;
        if (typeof c !== "string") continue;
        if (CONFIRM_INTENT_RE_DQ.test(c)) { confirmIdx = i; stage = "intent"; break; }
        if (CONFIRM_OUTLINE_RE_DQ.test(c)) { confirmIdx = i; stage = "outline"; break; }
        if (CONFIRM_DETAIL_RE_DQ.test(c)) { confirmIdx = i; stage = "detail"; break; }
        if (CONFIRM_PR_CREATED_RE_DQ.test(c)) { confirmIdx = i; stage = "pr-created"; break; }
      }
      if (confirmIdx !== -1) {
        let followUpFound = false;
        for (let i = confirmIdx + 1; i < lastAssistantContent.length; i++) {
          const item = lastAssistantContent[i];
          if (!item || item.type !== "tool_use") continue;
          if (item.name === "Skill" && item.input && typeof item.input.skill === "string") {
            if (stage === "intent" && item.input.skill.includes("make-outline-plan")) { followUpFound = true; break; }
            if (stage === "outline" && item.input.skill.includes("make-detail-plan")) { followUpFound = true; break; }
            if (stage === "detail" && item.input.skill.includes("write-tests")) { followUpFound = true; break; }
          }
          if (stage === "detail" && item.name === "Bash" && item.input && typeof item.input.command === "string"
              && item.input.command.includes("WORKFLOW_BRANCHING_COMPLETE")) {
            followUpFound = true; break;
          }
          if (stage === "pr-created" && item.name === "Skill" && item.input && typeof item.input.skill === "string"
              && item.input.skill.includes("worktree-end")) {
            followUpFound = true; break;
          }
          // pr-created off-mode: Bash(<<WORKFLOW_USER_VERIFIED: ...>>) accepted
          // Layer 2 accepts both follow-up forms unconditionally. Mode-correctness
          // is enforced by the commit-push SKILL.md prompt (Layer 1), not here.
          if (stage === "pr-created" && item.name === "Bash" && item.input && typeof item.input.command === "string"
              && item.input.command.includes("WORKFLOW_USER_VERIFIED")) {
            followUpFound = true; break;
          }
        }
        if (followUpFound) {
          // #871: add markStep(sid, stage, "complete") here
        } else {
          const { confirmNextStepHint } = require("./lib/workflow-state");
          process.stdout.write(JSON.stringify({
            decision: "block",
            reason: confirmNextStepHint(stage) || "[confirm-plan] Layer 2: stage-valid follow-up Skill not found after CONFIRM_" + stage.toUpperCase(),
          }));
          process.exit(2);
        }
      }
    }
  } catch (_) {
    process.exit(0);
  }

  process.exit(0);
}
