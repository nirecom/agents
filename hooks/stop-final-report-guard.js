#!/usr/bin/env node
// Stop hook: validate that the Final Report was emitted into assistant text
// with all 13 canonical section headings present and no unsubstituted
// `<PLACEHOLDER>` tokens remaining.
//
// Triggers (#1611 — two independent lanes, CPR-3):
// - Lane A: <plans-dir>/<sid>-final-report-env.json exists (written by
//   worktree-end Step WE-9..WE-11 or session-close SC-2A/SC-2B/SC-2C) → validate
//   the Final Report shape (the whole validation section below is lane A only).
// - Lane B: that env file is ABSENT and `bin/workflow/next-step --session <sid>`
//   reports ACTION=invoke with REASON='pre_final_report_gate' → the close
//   procedure was never started. Block unconditionally WITHOUT scanning the
//   transcript, so a hand-written Final Report is rejected too. Lane B is a
//   "close procedure not executed" detector, not a shape validator.
// On any other turn the hook exits 0 silently.
//
// Contract (post-#830 fix):
// - Parse transcript JSONL; backward-scan for the latest type:"assistant" entry
//   containing `## Final Report — <sid>`; extract finalReportBody (heading to
//   next \n## or turn end). Check headings + token regex on finalReportBody only.
// - Fail-open on uncertainty (missing/malformed env-file, no transcript, no FR).
"use strict";

const fs = require("fs");
const path = require("path");
const schema = require("./lib/final-report-schema");

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

// Lane B (#1611): the env file is absent, so /session-close never reached
// SC-2A/SC-2B/SC-2C. Consult the workflow state via `bin/workflow/next-step`:
// ACTION=invoke + REASON='pre_final_report_gate' means every other step is done
// and only session close remains. Block unconditionally in that case — the
// transcript is NOT scanned, so a hand-written Final Report is rejected too.
// Escape hatches: session-close gate `yield`, `<sid>.workflow-off` marker, and
// the gate marked complete (which makes next-step stop returning invoke).
// Fail-open on every error path: the function simply returns and the caller
// exits 0.
function runCloseProcedureLane(sid, plansDir) {
  try {
    // Escape hatch (b): session-scoped workflow-off marker.
    try {
      const { isWorkflowOff } = require("./lib/session-markers");
      if (isWorkflowOff(sid)) return;
    } catch (_) {
      return;
    }

    // Escape hatch (a): the session-close gate yielded to the supervisor.
    try {
      const gate = JSON.parse(
        fs.readFileSync(path.join(plansDir, `${sid}-session-close-gate.json`), "utf8")
      );
      if (gate && gate.gate_action === "yield") return;
    } catch (_) { /* absent or malformed = no gate = keep evaluating */ }

    const agentsDir = process.env.AGENTS_CONFIG_DIR
      ? process.env.AGENTS_CONFIG_DIR
      : path.join(__dirname, "..");
    const nextStepPath = path.join(agentsDir, "bin", "workflow", "next-step");
    if (!fs.existsSync(nextStepPath)) return;

    // The current environment MUST be inherited: CLAUDE_WORKFLOW_DIR decides
    // where the workflow state lives. Passing a scrubbed env would lose it and
    // silently fail open.
    const { spawnSync } = require("child_process");
    const result = spawnSync(process.execPath, [nextStepPath, "--session", sid], {
      timeout: 3000,
      stdio: ["ignore", "pipe", "ignore"],
      encoding: "utf8",
    });
    if (!result || result.status !== 0 || !result.stdout) return;

    const lines = result.stdout.split("\n");
    const actionLine = lines.find((l) => l.startsWith("ACTION="));
    if (actionLine !== "ACTION=invoke") return;
    // REASON is single-quoted by next-step's emit().
    const reasonLine = lines.find((l) => l.startsWith("REASON="));
    const reasonValue = reasonLine ? reasonLine.slice("REASON=".length).replace(/^'|'$/g, "") : "";
    if (reasonValue !== "pre_final_report_gate") return;

    const hintLine = lines.find((l) => l.startsWith("NEXT_HINT="));
    const hint = hintLine
      ? hintLine.slice("NEXT_HINT=".length).replace(/^'|'$/g, "")
      : "Run /session-close from the main worktree.";

    let reason =
      `[final-report] Every workflow step is complete and only session close remains. ` +
      `${hint} A hand-written final report is not accepted — the close procedure has not ` +
      `produced its artifacts yet. Escape hatches: emit ` +
      `<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>, or turn workflow enforcement ` +
      `off for this session. (Hook: stop-final-report-guard.js)`;
    try {
      const { getConvLangInjection } = require("./lib/conv-lang");
      const convLang = getConvLangInjection();
      if (convLang) reason += `\n\n${convLang}`;
    } catch (_) { /* fail-open on CONV_LANG errors */ }

    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  } catch (_) { /* fail-open */ }
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

  const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
  let plansDir;
  try {
    plansDir = getWorkflowPlansDir();
  } catch (_) {
    process.exit(0);
  }

  const envFilePath = path.join(plansDir, `${sid}-final-report-env.json`);
  let envRaw;
  try {
    envRaw = fs.readFileSync(envFilePath, "utf8");
  } catch (_) {
    // No env-file → lane B: the close procedure never wrote its artifacts.
    runCloseProcedureLane(sid, plansDir);
    process.exit(0);
  }

  let env;
  try {
    env = JSON.parse(envRaw);
    if (!env || typeof env !== "object" || Array.isArray(env)) process.exit(0);
  } catch (_) {
    process.exit(0);
  }

  const transcriptPath = input.transcript_path;
  if (!transcriptPath) process.exit(0);

  const headings = schema.getSectionHeadings(sid);
  const h2Header = `## Final Report — ${sid}`;
  let finalReportBody = "";
  let headingFound = false;
  try {
    const raw = fs.readFileSync(transcriptPath, "utf8");
    const lines = raw.split("\n");
    for (let i = lines.length - 1; i >= 0; i--) {
      const line = lines[i];
      if (!line.trim()) continue;
      let entry;
      try { entry = JSON.parse(line); } catch (_) { continue; }
      if (!entry || entry.type !== "assistant") continue;
      const content = entry.message && entry.message.content;
      if (!Array.isArray(content)) continue;
      const texts = [];
      for (const item of content) {
        if (item && item.type === "text" && typeof item.text === "string") {
          texts.push(item.text);
        }
      }
      const assistantText = texts.join("\n");
      const headingIdx = assistantText.lastIndexOf(h2Header);
      if (headingIdx === -1) continue;
      const afterHeading = assistantText.slice(headingIdx + h2Header.length);
      const nextH2 = afterHeading.search(/\n## /);
      finalReportBody = nextH2 === -1 ? afterHeading : afterHeading.slice(0, nextH2);
      headingFound = true;
      break;
    }
  } catch (_) {
    process.exit(0);
  }
  if (!headingFound) {
    const gateFilePath = path.join(plansDir, `${sid}-session-close-gate.json`);
    let gateYielded = false;
    try {
      const gateRaw = fs.readFileSync(gateFilePath, "utf8");
      const gate = JSON.parse(gateRaw);
      if (gate && gate.gate_action === "yield") gateYielded = true;
    } catch (_) { /* absent or malformed = no gate = proceed to block */ }
    if (gateYielded) process.exit(0);
    const { getConvLangInjection } = require("./lib/conv-lang");
    let reason =
      `[final-report] ${h2Header} was not found in your output. ` +
      `Run /session-close to emit it now. (Hook: stop-final-report-guard.js)`;
    try {
      const convLang = getConvLangInjection();
      if (convLang) reason += `\n\n${convLang}`;
    } catch (_) { /* fail-open on CONV_LANG errors */ }
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  }

  const remainingHeadings = headings.filter((h) => h !== h2Header);
  const missing = remainingHeadings.filter((h) => !finalReportBody.includes(h));
  if (missing.length > 0) {
    const reason =
      `[final-report] Emit the Final Report with all 13 section headings present. ` +
      `The following headings were missing from your output: ${missing.join(", ")}. ` +
      `Re-emit the Final Report verbatim — do not reformat, summarize, reorder, or merge sections. ` +
      `(Hook: stop-final-report-guard.js)\n\n` +
      schema.buildPostMergeLines(env).join("\n");
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  }

  const tokenRegex = /<[A-Z][A-Z0-9_]+>/g;
  const tokens = finalReportBody.match(tokenRegex);
  if (tokens && tokens.length > 0) {
    const unique = Array.from(new Set(tokens));
    const reason =
      `[final-report] The Final Report contains unsubstituted placeholder tokens. ` +
      `Replace all \`<TOKEN>\` placeholders before emitting. ` +
      `Found: ${unique.join(", ")}. ` +
      `(Hook: stop-final-report-guard.js)`;
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  }

  process.exit(0);
}
