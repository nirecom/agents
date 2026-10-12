#!/usr/bin/env node
// Stop hook: structurally enforce the confirm-plan protocol. Fail-open everywhere.
// Layer 2 (every Stop, #2278): when CONFIRM_<STAGE> appears in the last assistant
// entry, block unless the confirmed artifact passes PLAN_LANG re-lint AND a
// stage-valid follow-up tool_use appears after the sentinel. A CONFIRM echo whose
// tool_result is an error (denied) needs no follow-up: closing the turn is right.
// Plan-link check (after Layer 2): a turn that wrote a plan (show-plan-link.js turn marker)
// must end its last text block with that stage's plan-link output. Blocks once.
// The transcript is read through hooks/lib/transcript-reader.js (#2610): an undecidable
// flush passes. Reason prefixes and the marker contract: docs/architecture/claude-code/settings.md.
"use strict";

const fs = require("fs");
const path = require("path");
const SP = require("./lib/sentinel-patterns");
const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

// The table's next skill for a plan suffix; detail may also branch straight to BRANCHING_COMPLETE.
function nextSkillFor(stage) {
  const { rowFor, stepForSuffix } = require("./workflow-state/plan-stage-table");
  const row = rowFor(stepForSuffix(stage));
  return row ? row.nextSkill : null;
}

// Whether the tool_result answering tool_use `id` reports an error (a denied echo).
function resultIsError(entries, id) {
  if (typeof id !== "string" || !id) return false;
  for (const e of entries) {
    const c = e && e.type === "user" && e.message && e.message.content;
    if (!Array.isArray(c)) continue;
    for (const it of c) {
      if (it && it.type === "tool_result" && it.tool_use_id === id) return it.is_error === true;
    }
  }
  return false;
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }));
  process.exit(2);
}

function layer2(sid, content, entries) {
  let confirmIdx = -1;
  let stage = null;
  for (let i = 0; i < content.length; i++) {
    const item = content[i];
    if (!item || item.type !== "tool_use" || item.name !== "Bash") continue;
    const c = item.input && item.input.command;
    if (typeof c !== "string") continue;
    stage = SP.CONFIRM_INTENT_RE_DQ.test(c) ? "intent" : SP.CONFIRM_OUTLINE_RE_DQ.test(c) ? "outline"
      : SP.CONFIRM_DETAIL_RE_DQ.test(c) ? "detail" : null;
    if (stage) { confirmIdx = i; break; }
  }
  if (confirmIdx === -1) return;
  if (resultIsError(entries, content[confirmIdx].id)) return;
  // Re-lint the confirmed artifact against PLAN_LANG before the follow-up
  // check: a non-compliant plan must be rewritten, not merely continued (#2278).
  const { relintPlanArtifact, formatPlanLangViolations } = require("./lib/plan-artifact-lang");
  const relint = relintPlanArtifact(sid, stage);
  if (relint.skipped === null && relint.violations.length > 0) {
    block("[confirm-plan] Layer 2/plan-lang: " + path.basename(relint.artifactPath) +
      " violates plan-artifact language/heading rules (PLAN_LANG=" + relint.policy + ", " +
      relint.violations.length + " line(s)) — fix body language and use canonical English schema headings before CONFIRM_" +
      stage.toUpperCase() + ":\n" + formatPlanLangViolations(relint.violations).join("\n"));
  }
  const nextSkill = nextSkillFor(stage);
  for (let i = confirmIdx + 1; i < content.length; i++) {
    const item = content[i];
    if (!item || item.type !== "tool_use") continue;
    if (item.name === "Skill" && item.input && typeof item.input.skill === "string" &&
        nextSkill && item.input.skill.includes(nextSkill)) return;
    if (stage === "detail" && item.name === "Bash" && item.input && typeof item.input.command === "string"
        && item.input.command.includes("WORKFLOW_BRANCHING_COMPLETE")) return;
  }
  // #871: a found follow-up may later markStep(sid, stage, "complete") here.
  const hint = nextSkill ? nextSkill + (stage === "detail" ? " or WORKFLOW_BRANCHING_COMPLETE" : "") : "";
  block("[confirm-plan] Layer 2/follow-up: stage-valid follow-up Skill not found after CONFIRM_" +
    stage.toUpperCase() + (hint ? " — invoke " + hint : ""));
}

function planLink(sid, markers, lastTextBlock) {
  const tc = require("./lib/plan-link-turn-check");
  // Stop judges only the stages this turn wrote; a CONFIRM turn is judged at PreToolUse.
  const stages = tc.stagesToCheck({ markers, includeConfirm: false });
  if (stages.length === 0) return;
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
  for (const stageName of stages) {
    for (const absPath of markerPaths[stageName] || [path.join(plansDir, `${sid}-${stageName}.md`)]) {
      const verdict = tc.checkPlanUrlInTurn({
        stages: [stageName],
        turnText: lastTextBlock || "",
        resolve: () => linkForFile(absPath, { plansDir }),
      });
      if (verdict.block) block(verdict.reason);
    }
  }
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
  // Markers feed only the plan-link check; Layer 2 must run on every Stop (#2278).
  const markers = readAndDeleteTurnMarkers(sid);

  let tail;
  try {
    const { readTurnTail, parseLines } = require("./lib/transcript-reader");
    tail = readTurnTail({ input });
    if (tail.undecidable) process.exit(0);
    tail.entries = parseLines(tail.lines);
  } catch (_) {
    process.exit(0);
  }

  try {
    const content = tail.lastAssistantEntry && tail.lastAssistantEntry.message &&
      tail.lastAssistantEntry.message.content;
    if (tail.lastAssistantEntry && !Array.isArray(content)) process.exit(0);
    if (Array.isArray(content)) layer2(sid, content, tail.entries);
  } catch (_) {
    process.exit(0);
  }

  try {
    planLink(sid, markers, tail.lastTextBlock);
  } catch (_) {
    process.exit(0);
  }

  process.exit(0);
}
