#!/usr/bin/env node
// Stop hook: verify the Final Report turn emits the canonical
// `### Post-Merge Actions Required` block in the last assistant message.
//
// Trigger: <plans-dir>/<sid>-final-report-env.json exists (written by
// worktree-end Step 5.5). On any other turn the hook exits 0 silently.
//
// On detection, the hook reads the last assistant text in the transcript
// (last 50 lines, scanned backwards), checks for the heading plus all four
// category lines, and on violation emits `decision:block` + exit 2 with the
// rebuilt block (from env-file JSON) as the reason. Fail-open on every
// uncertainty path (missing transcript, parse errors, malformed env-file,
// etc.) — the renderer remains the authoritative writer; this hook is a
// best-effort guard.
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

const REASON_INSTRUCTION_TEMPLATE =
  "[final-report] The Final Report (## Final Report — <sid>) is missing sections or is " +
  "incomplete in the last assistant message. Copy the renderer output verbatim — do not " +
  "reformat, summarize, or reorder any heading. Run the renderer via the Bash tool and " +
  "paste its stdout (excluding the sentinel line) directly into your response. " +
  "(Hook: stop-final-report-guard.js)";

function lastAssistantText(transcriptPath) {
  let raw;
  try {
    raw = fs.readFileSync(transcriptPath, "utf8");
  } catch (_) {
    return null;
  }
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
    if (!Array.isArray(content)) return null;
    const texts = [];
    for (const item of content) {
      if (item && item.type === "text" && typeof item.text === "string") {
        texts.push(item.text);
      }
    }
    return texts.join("\n");
  }
  return null;
}

function blockIsComplete(text, sessionId) {
  if (!text) return false;
  const headings = schema.getSectionHeadings(sessionId);
  if (!headings.every((h) => text.includes(h))) return false;
  if (!schema.getProbes().every((p) => text.includes(p))) return false;
  const outcomeSection = schema.SECTIONS.find((s) => s.id === "closed_issue_outcomes");
  if (!outcomeSection) return false;
  const outcomeHeading = outcomeSection.heading();
  const idx = text.indexOf(outcomeHeading);
  if (idx === -1) return false;
  const after = text.slice(idx + outcomeHeading.length);
  const nextHeadingIdx = after.search(/\n###? /);
  const sectionContent = nextHeadingIdx === -1 ? after : after.slice(0, nextHeadingIdx);
  if (!/^\s*- /m.test(sectionContent)) return false;
  return true;
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

  if (typeof input.transcript_path !== "string" || !input.transcript_path) {
    process.exit(0);
  }
  const text = lastAssistantText(input.transcript_path);
  if (text === null) process.exit(0);

  if (blockIsComplete(text, sid)) process.exit(0);

  // Render the canonical Post-Merge Actions block from env for the reason.
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
    REASON_INSTRUCTION_TEMPLATE.replace("<sid>", sid) +
    "\n\n" +
    postMergeLines.join("\n");
  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(2);
}
