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

const CATEGORIES = [
  { key: "Claude Code restart", req: "CC_RESTART_REQUIRED", legacy: "CLAUDE_CODE_RESTART_REQUIRED", reason: "CC_RESTART_REASON" },
  { key: "VS Code reload",      req: "VSCODE_RELOAD_REQUIRED",   reason: "VSCODE_RELOAD_REASON" },
  { key: "Installer rerun",     req: "INSTALLER_RERUN_REQUIRED", reason: "INSTALLER_RERUN_REASON" },
  { key: "OS reboot",           req: "OS_REBOOT_REQUIRED",       reason: "OS_REBOOT_REASON" },
];

// safeEnv mirrors bin/worktree-final-report.js safeEnv():
// returns the env-file value if present and non-empty, else "(none)".
// (Empty string is treated as missing, identical to the renderer.)
function safeEnv(env, key) {
  const v = env[key];
  if (v === undefined || v === null || v === "") return "(none)";
  return String(v);
}

// categoryValue mirrors bin/worktree-final-report.js categoryValue() exactly:
// - If primary key resolves to non-"(none)" → return its raw string verbatim.
// - Else if legacy alias resolves to non-"(none)":
//     - "yes" → "required"
//     - "no"  → "not_required"
//     - anything else → return raw verbatim.
// - Else default to "not_required".
function categoryValue(env, primary, legacy) {
  const v = safeEnv(env, primary);
  if (v !== "(none)") return v;
  if (legacy === undefined) return "not_required";
  const legacyVal = safeEnv(env, legacy);
  if (legacyVal !== "(none)") {
    if (legacyVal === "yes") return "required";
    if (legacyVal === "no") return "not_required";
    return legacyVal;
  }
  return "not_required";
}

function rebuildBlock(env) {
  const lines = ["### Post-Merge Actions Required"];
  for (const c of CATEGORIES) {
    const value = categoryValue(env, c.req, c.legacy);
    const reasonVal = safeEnv(env, c.reason);
    if (value === "required" && reasonVal !== "(none)") {
      lines.push(`- ${c.key}: required (${reasonVal})`);
    } else {
      lines.push(`- ${c.key}: ${value}`);
    }
  }
  return lines.join("\n");
}

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

function blockIsComplete(text) {
  if (!text) return false;
  if (!text.includes("### Post-Merge Actions Required")) return false;
  const probes = [
    "- Claude Code restart:",
    "- VS Code reload:",
    "- Installer rerun:",
    "- OS reboot:",
  ];
  return probes.every((p) => text.includes(p));
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

  if (blockIsComplete(text)) process.exit(0);

  const rebuilt = rebuildBlock(env);
  const reason =
    "[final-report] The `### Post-Merge Actions Required` block is missing " +
    "or incomplete in the final assistant message. Re-emit the response and " +
    "include this block verbatim:\n\n" +
    rebuilt +
    "\n\n(Hook: stop-final-report-guard.js)";

  process.stdout.write(JSON.stringify({ decision: "block", reason }) + "\n");
  process.exit(2);
}
