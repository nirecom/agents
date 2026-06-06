#!/usr/bin/env node
// Stop hook: validate that the Final Report was emitted into assistant text
// with all 10 canonical section headings present and no unsubstituted
// `<PLACEHOLDER>` tokens remaining.
//
// Trigger: <plans-dir>/<sid>-final-report-env.json exists (written by
// worktree-end Step WE-9..WE-11). On any other turn the hook exits 0 silently.
//
// Contract (post-#771):
// - The previous renderer was abolished; the LLM now substitutes the skeleton
//   (from `final-report-schema.renderSkeleton`) and pastes the result verbatim
//   into assistant text.
// - Validation: find the LAST occurrence of `## Final Report — <sid>` in the
//   transcript, then check the post-header region contains all 9 remaining
//   `###` headings from `getSectionHeadings(sid)` and has no
//   `<TOKEN>` placeholders left.
// - Fail-open on uncertainty (missing/malformed env-file, no transcript).
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

function buildPostMergeReminder(env) {
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
  const lines = ["### Post-Merge Actions Required"];
  for (const cat of schema.CATEGORIES) {
    const v = catValue(cat);
    const reasonVal = safeEnvVal(cat.reasonKey);
    if (v === "required" && reasonVal !== "(none)") {
      lines.push(`- ${cat.label}: required (${reasonVal})`);
    } else {
      lines.push(`- ${cat.label}: ${v}`);
    }
  }
  return lines.join("\n");
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

  const transcriptPath = input.transcript_path;
  if (!transcriptPath) process.exit(0);
  let transcript;
  try {
    transcript = fs.readFileSync(transcriptPath, "utf8");
  } catch (_) {
    // Transcript unreadable → fail-open.
    process.exit(0);
  }

  const headings = schema.getSectionHeadings(sid);
  const h2Header = `## Final Report — ${sid}`;
  const lastIdx = transcript.lastIndexOf(h2Header);
  if (lastIdx === -1) {
    // Header not yet emitted → guard not applicable.
    process.exit(0);
  }
  const postHeader = transcript.slice(lastIdx + h2Header.length);

  const remainingHeadings = headings.filter((h) => h !== h2Header);
  const missing = remainingHeadings.filter((h) => !postHeader.includes(h));
  if (missing.length > 0) {
    const reason =
      `[final-report] Emit the Final Report with all 10 section headings present. ` +
      `The following headings were missing from your output: ${missing.join(", ")}. ` +
      `Re-emit the Final Report verbatim — do not reformat, summarize, reorder, or merge sections. ` +
      `(Hook: stop-final-report-guard.js)\n\n` +
      buildPostMergeReminder(env);
    process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
    process.exit(2);
  }

  const tokenRegex = /<[A-Z][A-Z0-9_]+>/g;
  const tokens = postHeader.match(tokenRegex);
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
