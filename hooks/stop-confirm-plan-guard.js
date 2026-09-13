#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan protocol. Fail-open everywhere.
// Layer 1 (marker-gated): show-plan-link.js drops a per-turn marker; when one exists,
// block the turn if the last assistant message leaks a WORKFLOW_PLANS_DIR path form.
// Layer 2 (every Stop, #2278): when CONFIRM_<STAGE> appears in the last assistant
// turn, block unless the confirmed artifact passes PLAN_LANG re-lint AND a
// stage-valid follow-up tool_use appears after the sentinel.
// Reason prefixes and the marker contract: docs/architecture/claude-code/settings.md.
"use strict";

const fs = require("fs");
const path = require("path");
const {
  CONFIRM_INTENT_RE_DQ,
  CONFIRM_OUTLINE_RE_DQ,
  CONFIRM_DETAIL_RE_DQ,
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

  const { resolveSessionId } = require("./workflow-state");
  const sid = resolveSessionId({
    sessionIdFromInput: input.session_id,
    transcriptPath: input.transcript_path,
  });
  if (!sid) process.exit(0);

  const { readAndDeleteTurnMarkers } = require("./lib/turn-marker");
  // Markers gate only Layer 1; Layer 2 must run on every Stop (#2278).
  const markers = readAndDeleteTurnMarkers(sid);

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

  if (markers.length > 0) {
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
      }
      if (confirmIdx !== -1) {
        // Re-lint the confirmed artifact against PLAN_LANG before the follow-up
        // check: a non-compliant plan must be rewritten, not merely continued (#2278).
        const { relintPlanArtifact, formatPlanLangViolations } = require("./lib/plan-artifact-lang");
        const relint = relintPlanArtifact(sid, stage);
        if (relint.skipped === null && relint.violations.length > 0) {
          process.stdout.write(JSON.stringify({
            decision: "block",
            reason: "[confirm-plan] Layer 2/plan-lang: " + path.basename(relint.artifactPath) +
              " violates PLAN_LANG=" + relint.policy + " (" + relint.violations.length + " line(s)) — rewrite the artifact in " +
              relint.policy + " before CONFIRM_" + stage.toUpperCase() + ":\n" +
              formatPlanLangViolations(relint.violations).join("\n"),
          }));
          process.exit(2);
        }
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
        }
        if (followUpFound) {
          // #871: add markStep(sid, stage, "complete") here
        } else {
          const STAGE_NEXT_SKILL = { intent: "make-outline-plan", outline: "make-detail-plan", detail: "write-tests or WORKFLOW_BRANCHING_COMPLETE" };
          const nextSkillHint = STAGE_NEXT_SKILL[stage] ? " — invoke " + STAGE_NEXT_SKILL[stage] : "";
          process.stdout.write(JSON.stringify({
            decision: "block",
            reason: "[confirm-plan] Layer 2/follow-up: stage-valid follow-up Skill not found after CONFIRM_" + stage.toUpperCase() + nextSkillHint,
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
