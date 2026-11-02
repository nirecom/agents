#!/usr/bin/env node
// Stop hook: the Final Report must carry all 13 canonical headings and no `<PLACEHOLDER>`.
// Lane A (#1611): <CONTROL_DIR>/final-report-env.json exists → validate the report shape
//   on the latest assistant entry holding `## Final Report — <sid>` (post-#830 contract).
// Lane B: env file absent and next-step reports REASON='pre_final_report_gate' → the close
//   procedure never ran; block without scanning the transcript.
// Both lanes honour the same exits first (stop-final-report-guard/exits.js, #1192).
// Fail-open on uncertainty. Full contract: docs/architecture/claude-code/settings/hooks.md.
"use strict";

const fs = require("fs");
const path = require("path");
const schema = require("./lib/final-report-schema");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

const { EXIT_HATCH_TEXT, shouldYieldOrBypass } = require("./stop-final-report-guard/exits");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..");

function controlFile(sid, name) {
  return require("./workflow-state/state-io/control-dir").controlPath(sid, name);
}

function diagnoseControlFile(e) {
  try {
    require("./workflow-state/state-io/control-dir").diagnoseControlMigration(e, "stop-final-report-guard");
  } catch (_) { /* fail-open */ }
}

function withConvLang(reason) {
  try {
    const convLang = require("./lib/conv-lang").getConvLangInjection();
    return convLang ? `${reason}\n\n${convLang}` : reason;
  } catch (_) {
    return reason;
  }
}

function block(reason) {
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(2);
}

// Lane B (#1611): the env file is absent, so /session-close never reached
// SC-2A/SC-2B/SC-2C. Consult the workflow state via `bin/workflow/next-step`:
// ACTION=invoke + REASON='pre_final_report_gate' means every other step is done
// and only session close remains. Block unconditionally in that case — the
// transcript is NOT scanned, so a hand-written Final Report is rejected too.
// Exits: the shared ones (exits.js), and the gate marked complete (which makes
// next-step stop returning invoke). Fail-open on every error path.
function runCloseProcedureLane(sid) {
  try {
    if (shouldYieldOrBypass(sid).exit) return;

    const nextStepPath = path.join(SCRIPT_CHECKOUT_ROOT, "bin", "workflow", "next-step");
    if (!fs.existsSync(nextStepPath)) return;

    // The current environment MUST be inherited: WORKFLOW_STATE_DIR decides
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

    block(withConvLang(
      `[final-report] Every workflow step is complete and only session close remains. ` +
      `${hint} A hand-written final report is not accepted — the close procedure has not ` +
      `produced its artifacts yet. ${EXIT_HATCH_TEXT} This lane also ends when you emit ` +
      `<<WORKFLOW_MARK_STEP_pre_final_report_gate_complete>>. (Hook: stop-final-report-guard.js)`
    ));
  } catch (_) { /* fail-open */ }
}

// Lane A's no-heading reason (#2337): the instruction, the exits, CONV_LANG, then the rendered
// Final Report to re-emit verbatim. A renderer failure degrades to the same block without the embed.
function noHeadingReason(sid, h2Header) {
  const reason = withConvLang(
    `[final-report] ${h2Header} was not found in your output. ` +
    `Run /session-close to emit it now. ${EXIT_HATCH_TEXT} (Hook: stop-final-report-guard.js)`
  );
  const rendered = require("./stop-final-report-guard/render-embed").renderFinalReportForReason(sid);
  if (rendered === null) return reason;
  return `${reason}\n\nOutput the following verbatim as your next assistant text:\n\n${rendered.trim()}`;
}

if (require.main === module) {
  const r = readHookInput();
  if (r.kind !== "ok") {
    try {
      fs.writeSync(2, readFailOpenDiagnostic("stop-final-report-guard", r, "final-report check skipped") + "\n");
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

  let envFilePath;
  try {
    envFilePath = controlFile(sid, "final-report-env.json");
  } catch (e) {
    diagnoseControlFile(e);
    process.exit(0);
  }
  let envRaw;
  try {
    envRaw = fs.readFileSync(envFilePath, "utf8");
  } catch (_) {
    // No env-file → lane B: the close procedure never wrote its artifacts.
    runCloseProcedureLane(sid);
    process.exit(0);
  }

  let env;
  try {
    env = JSON.parse(envRaw);
    if (!env || typeof env !== "object" || Array.isArray(env)) process.exit(0);
  } catch (_) {
    process.exit(0);
  }
  // #1192: the shared exits end every lane-A block, the shape checks below included.
  if (shouldYieldOrBypass(sid).exit) process.exit(0);

  const transcriptPath = input.transcript_path;
  if (!transcriptPath) process.exit(0);

  const headings = schema.getSectionHeadings(sid);
  const h2Header = `## Final Report — ${sid}`;
  let finalReportBody = "";
  let headingFound = false;
  try {
    // Wait for the final text to be flushed (#2610); an undecidable flush passes.
    const tail = require("./lib/transcript-reader").readTurnTail({ input });
    if (tail.undecidable || tail.lines.length === 0) process.exit(0);
    const lines = tail.lines;
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
  if (!headingFound) block(noHeadingReason(sid, h2Header));

  const remainingHeadings = headings.filter((h) => h !== h2Header);
  const missing = remainingHeadings.filter((h) => !finalReportBody.includes(h));
  if (missing.length > 0) {
    block(
      `[final-report] Emit the Final Report with all 13 section headings present. ` +
      `The following headings were missing from your output: ${missing.join(", ")}. ` +
      `Re-emit the Final Report verbatim — do not reformat, summarize, reorder, or merge sections. ` +
      `${EXIT_HATCH_TEXT} (Hook: stop-final-report-guard.js)\n\n` +
      schema.buildPostMergeLines(env).join("\n")
    );
  }

  const tokenRegex = /<[A-Z][A-Z0-9_]+>/g;
  const tokens = finalReportBody.match(tokenRegex);
  if (tokens && tokens.length > 0) {
    const unique = Array.from(new Set(tokens));
    block(
      `[final-report] The Final Report contains unsubstituted placeholder tokens. ` +
      `Replace all \`<TOKEN>\` placeholders before emitting. ` +
      `Found: ${unique.join(", ")}. ${EXIT_HATCH_TEXT} ` +
      `(Hook: stop-final-report-guard.js)`
    );
  }

  process.exit(0);
}
