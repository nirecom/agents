#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan protocol. Fail-open everywhere.
// Layer 1 (marker-gated): show-plan-link.js drops a per-turn marker; when one exists,
// block the turn if the last assistant message leaks a WORKFLOW_PLANS_DIR path form.
// Layer 2 (every Stop, #2278): when CONFIRM_<STAGE> appears in the last assistant
// turn, block unless the confirmed artifact passes PLAN_LANG re-lint AND a
// stage-valid follow-up tool_use appears after the sentinel.
// Layer 3 (#2513): a turn that wrote or CONFIRMed a plan stage must show its blob URL.
// Reason prefixes and the marker contract: docs/architecture/claude-code/settings.md.
"use strict";

const fs = require("fs");
const path = require("path");
const {
  CONFIRM_INTENT_RE_DQ,
  CONFIRM_OUTLINE_RE_DQ,
  CONFIRM_DETAIL_RE_DQ,
} = require("./lib/sentinel-patterns");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

// encodedFileUriFrom(dir) — the percent-encoded file:/// URI form of a local dir
// (drive-letter aware), one of the local path forms Layer 1 blocks.
function encodedFileUriFrom(dir) {
  if (typeof dir !== "string" || dir.length === 0) return "";
  const fwd = dir.replace(/\\/g, "/");
  const enc = (s) => s.split("/").map(encodeURIComponent).join("/");
  const m = fwd.match(/^([A-Za-z]:)\/(.*)/);
  return m ? "file:///" + m[1] + "/" + enc(m[2]) : "file:///" + enc(fwd.replace(/^\//, ""));
}

if (require.main === module) {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("stop-confirm-plan-guard", r, "confirm-plan check skipped") + "\n");
    } catch (_) {}
    process.exit(0);
  }
  const input = r.input;

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
  let lines = [];
  try {
    const raw = fs.readFileSync(input.transcript_path, "utf8");
    lines = raw.split("\n");
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
      encodedFileUriFrom(plansDir),
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
          reason: "[confirm-plan] Step 2 violation: orchestrator emitted a local `~/.workflow-plans/` path representation. Show a plan only by its GitHub blob URL (`$AGENTS_CONFIG_DIR/bin/plan-link` prints it); re-stating that blob URL is fine, a local path is not. Re-issue the response without the path. (Hook: stop-confirm-plan-guard.js)",
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
          // Violations may be body-language (strict policy only) or canonical
          // schema-heading (any policy, #2338); fix both before confirming.
          process.stdout.write(JSON.stringify({
            decision: "block",
            reason: "[confirm-plan] Layer 2/plan-lang: " + path.basename(relint.artifactPath) +
              " violates plan-artifact language/heading rules (PLAN_LANG=" + relint.policy + ", " +
              relint.violations.length + " line(s)) — fix body language and use canonical English schema headings before CONFIRM_" +
              stage.toUpperCase() + ":\n" +
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

  // Layer 3: a turn that wrote or CONFIRMed a plan stage must show that stage's blob URL
  // in its assistant text (hooks/lib/plan-link-turn-check.js). No URL -> nothing to check.
  try {
    const tc = require("./lib/plan-link-turn-check");
    const entries = tc.turnEntriesFromLines(lines);
    const stages = tc.stagesToCheck({ markers, turnEntries: entries });
    if (stages.length > 0) {
      const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
      const { resolvePlanLink } = require("./lib/plan-link");
      const plansDir = getWorkflowPlansDir();
      // A written artifact may carry another session's id (cross-session carry-in), and one call
      // may write several files of a stage: check every file a marker names, not only <sid>-<stage>.md.
      const markerPaths = {};
      for (const m of markers) {
        if (!m || typeof m.suffix !== "string" || typeof m.absPath !== "string") continue;
        (markerPaths[m.suffix] = markerPaths[m.suffix] || []).push(m.absPath);
      }
      const turnText = tc.collectTurnAssistantText(entries);
      for (const st of stages) {
        for (const absPath of markerPaths[st] || [undefined]) {
          const verdict = tc.checkPlanUrlInTurn({
            stages: [st],
            turnText,
            resolve: (s) => resolvePlanLink(sid, s, { plansDir, absPath }),
          });
          if (verdict.block) {
            process.stdout.write(JSON.stringify({ decision: "block", reason: verdict.reason }));
            process.exit(2);
          }
        }
      }
    }
  } catch (_) {
    process.exit(0);
  }

  process.exit(0);
}
