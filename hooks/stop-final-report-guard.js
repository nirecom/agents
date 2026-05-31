#!/usr/bin/env node
// Stop hook: verify the Final Report renderer (bin/worktree-final-report.js)
// has successfully emitted the canonical Final Report for this session.
//
// Trigger: <plans-dir>/<sid>-final-report-env.json exists (written by
// worktree-end Step 5.5). On any other turn the hook exits 0 silently.
//
// Contract: the renderer stamps `reported: true` into the env-file after a
// successful stdout emission. This hook then verifies both: (a) the flag is
// set, and (b) at least one assistant text message in the transcript contains
// the Final Report heading (guards against the renderer running in a Bash
// tool result without the output being pasted verbatim — issue #700). Fail-
// open on all uncertainty paths (missing/malformed env-file, no transcript).
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

// Used when the renderer did not set the flag at all.
const REASON_INSTRUCTION_TEMPLATE =
  "[final-report] The Final Report renderer has not stamped the `reported` flag " +
  "in the env file for session <sid>, which means the renderer did not run to " +
  "completion in this turn. Re-run `bin/worktree-final-report.js` via the Bash " +
  "tool and paste its stdout verbatim (excluding the sentinel line) into your " +
  "response — do not reformat, summarize, or reorder any heading. " +
  "(Hook: stop-final-report-guard.js)";

// Used when the renderer ran and set the flag but the heading was not found in
// any assistant text message — the output likely appeared only in a Bash tool
// result without being pasted verbatim (issue #700).
const REASON_PASTE_TEMPLATE =
  "[final-report] The renderer has set `reported` in the env file but no assistant " +
  "message containing ‘## Final Report — <sid>’ was found in the " +
  "transcript. The renderer output may have appeared only in the Bash tool result " +
  "— paste its stdout verbatim (excluding the sentinel line) into your response. " +
  "(Hook: stop-final-report-guard.js)";

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
  if (!sid || !/^[A-Za-z0-9_-]+$/.test(sid)) process.exit(0);

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
    // No env-file → not a Final Report turn → silent pass-through.
    process.exit(0);
  }

  let env;
  try {
    env = JSON.parse(envRaw);
    if (!env || typeof env !== "object" || Array.isArray(env)) process.exit(0);
  } catch (_) {
    process.exit(0);
  }

  // Renderer stamped the flag → also verify the heading appears in at least one
  // assistant text message (not just a Bash tool result — issue #700).
  let instructionTemplate = REASON_INSTRUCTION_TEMPLATE;
  if (env.reported === true) {
    const transcriptPath = input.transcript_path;
    let verified = !transcriptPath; // no path in input → fail-open
    if (transcriptPath) {
      let raw;
      try {
        raw = fs.readFileSync(transcriptPath, "utf8");
        const HEADING = "## Final Report —";
        verified = raw.split("\n").some((line) => {
          if (!line.trim()) return false;
          try {
            const entry = JSON.parse(line);
            if (entry.type !== "assistant") return false;
            const content = entry.message && entry.message.content;
            if (!Array.isArray(content)) return false;
            return content.some(
              (b) =>
                b.type === "text" &&
                typeof b.text === "string" &&
                b.text.includes(HEADING)
            );
          } catch (_) {
            return false;
          }
        });
      } catch (_) {
        verified = true; // transcript missing → fail-open
      }
    }
    if (verified) process.exit(0);
    instructionTemplate = REASON_PASTE_TEMPLATE;
  }

  // Block — rebuild reason from env + chosen instruction template.
  function safeEnvVal(key) {
    const v = env[key];
    if (v === undefined || v === null || v === "") return "(none)";
    return String(v).replace(/[\r\n]/g, " ").slice(0, 200);
  }
  function catValue(cat) {
    const v = safeEnvVal(cat.newKey);
    if (v !== "(none)") return v;
    if (!cat.legacyKey) return "not_required";
    const legacy = safeEnvVal(cat.legacyKey);
    if (legacy !== "(none)") {
      if (legacy === cat.legacyYes) return "required";
      if (legacy === "no") return "not_required";
      return legacy;
    }
    return "not_required";
  }
  const postMergeLines = ["### Post-Merge Actions Required"];
  for (const cat of schema.CATEGORIES) {
    const v = catValue(cat);
    const reasonVal = safeEnvVal(cat.reasonKey);
    if (v === "required" && reasonVal !== "(none)") {
      postMergeLines.push(`- ${cat.label}: required (${reasonVal})`);
    } else {
      postMergeLines.push(`- ${cat.label}: ${v}`);
    }
  }
  const reason =
    instructionTemplate.replace("<sid>", sid) +
    "\n\n" +
    postMergeLines.join("\n");
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(2);
}
