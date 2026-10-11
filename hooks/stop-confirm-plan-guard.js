#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan protocol. Fail-open everywhere.
// Layer 2 (every Stop, #2278): when CONFIRM_<STAGE> appears in the last assistant
// turn, block unless the confirmed artifact passes PLAN_LANG re-lint AND a
// stage-valid follow-up tool_use appears after the sentinel.
// Plan-link check (after Layer 2): a turn that wrote a plan (show-plan-link.js turn marker)
// or CONFIRMed a plan stage must show its plan-link output — the blob URL when one
// exists, otherwise the plan's local path. Blocks once (stop_hook_active passes).
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
  // Markers feed only the plan-link check; Layer 2 must run on every Stop (#2278).
  const markers = readAndDeleteTurnMarkers(sid);

  // Read the transcript: the lines feed the plan-link check, and the most recent
  // assistant message's content array feeds Layer 2.
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
      break;
    }
  } catch (_) {
    process.exit(0);
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

  // Plan-link check: a turn that wrote or CONFIRMed a plan stage must show that stage's
  // plan-link output (hooks/lib/plan-link-turn-check.js). An unresolvable plan passes.
  try {
    const tc = require("./lib/plan-link-turn-check");
    const entries = tc.turnEntriesFromLines(lines);
    const stages = tc.stagesToCheck({ markers, turnEntries: entries });
    if (stages.length > 0) {
      const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
      const { linkForFile } = require("./lib/plan-link");
      const plansDir = getWorkflowPlansDir();
      // A written artifact may carry another session's id, and one call may write several
      // files of a stage: check every file a marker names, else <sid>-<stage>.md.
      const markerPaths = {};
      for (const m of markers) {
        if (!m || typeof m.suffix !== "string" || typeof m.absPath !== "string" || !m.absPath) continue;
        (markerPaths[m.suffix] = markerPaths[m.suffix] || []).push(m.absPath);
      }
      const turnText = tc.collectTurnAssistantText(entries);
      for (const stageName of stages) {
        for (const absPath of markerPaths[stageName] || [path.join(plansDir, `${sid}-${stageName}.md`)]) {
          const verdict = tc.checkPlanUrlInTurn({
            stages: [stageName],
            turnText,
            resolve: () => linkForFile(absPath, { plansDir }),
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
