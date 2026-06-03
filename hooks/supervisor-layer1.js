#!/usr/bin/env node
"use strict";

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");

function readStdin() {
  try { return fs.readFileSync(0).toString("utf8"); } catch (_) { return ""; }
}

function done(output) {
  console.log(JSON.stringify(output));
  process.exit(0);
}

const TOOL_MATCHER = new Set([
  "Bash",
  "runInTerminal",
  "runCommands",
  "Write",
  "Edit",
  "MultiEdit",
  "editFiles",
]);

const COMMON_WORDS = new Set([
  "the", "and", "must", "will", "with", "from", "into", "used",
  "this", "that", "have", "been", "when", "then", "each", "also",
  "note", "only", "file", "hook", "call", "code", "data", "json",
  "path", "type",
]);

function extractKeywords(text, cap) {
  const raw = text.match(/[a-zA-Z0-9]{4,}/g) || [];
  const seen = new Set();
  const result = [];
  for (const t of raw) {
    const lc = t.toLowerCase();
    if (COMMON_WORDS.has(lc)) continue;
    if (seen.has(lc)) continue;
    seen.add(lc);
    result.push(lc);
    if (result.length >= cap) break;
  }
  return result;
}

function extractSection(content, heading) {
  const re = new RegExp(`^## ${heading}[^\\n]*\\n([\\s\\S]*?)(?=\\n## |$)`, "m");
  const m = re.exec(content);
  return m ? m[1] : "";
}

let input;
try {
  const raw = readStdin();
  input = JSON.parse(raw || "{}");
} catch (_) {
  done({});
}

try {
  if (!input || !TOOL_MATCHER.has(input.tool_name)) done({});

  const { resolveSessionId } = require("./lib/workflow-state");
  const sid = resolveSessionId({
    sessionIdFromInput: input.session_id,
    transcriptPath: input.transcript_path,
  });
  if (!sid || !/^[A-Za-z0-9_-]+$/.test(sid)) done({});

  const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
  let plansDir;
  try { plansDir = getWorkflowPlansDir(); } catch (_) { done({}); }

  const { appendFinding } = require("./lib/supervisor-state-writer");
  const { SEVERITY_RANK } = require("./lib/supervisor-state-schema");
  const { isSentinel } = require("./lib/sentinel-patterns");

  const findings = [];

  const intentPath = path.join(plansDir, `${sid}-intent.md`);
  const intentExists = fs.existsSync(intentPath);
  if (!intentExists) {
    findings.push({ check: "plan_artifact", status: "warn", detail: "intent.md not found" });
  }

  let intentContent = null;
  if (intentExists) {
    try { intentContent = fs.readFileSync(intentPath, "utf8"); } catch (_) {}
  }

  if (intentContent !== null) {
    const scopeText = extractSection(intentContent, "Scope");
    const nonGoalText = extractSection(intentContent, "Confirmed non-goals");
    const scopeKws = extractKeywords(scopeText, 20);
    const nonGoalKws = extractKeywords(nonGoalText, 20);

    let diff = "";
    try {
      diff = execSync("git diff --cached", {
        timeout: 1500,
        stdio: ["pipe", "pipe", "pipe"],
        maxBuffer: 4 * 1024 * 1024,
        // Prevent malicious .git/config hooks (CVE-2022-24765 family)
        env: { ...process.env, GIT_CONFIG_NOSYSTEM: "1", GIT_CONFIG_COUNT: "0" },
      }).toString("utf8");
    } catch (_) {}
    const MAX_DIFF = 256 * 1024;
    if (diff.length > MAX_DIFF) diff = diff.slice(0, MAX_DIFF);
    const diffLower = diff.toLowerCase();

    if (scopeKws.length > 0 && diffLower.length > 0) {
      const matched = scopeKws.filter((k) => diffLower.includes(k));
      if (matched.length > 0) {
        findings.push({
          check: "scope_keyword",
          status: "warn",
          detail: "matched: " + matched.slice(0, 3).join(", "),
        });
      }
    }
    if (nonGoalKws.length > 0 && diffLower.length > 0) {
      const matched = nonGoalKws.filter((k) => diffLower.includes(k));
      if (matched.length > 0) {
        findings.push({
          check: "non_goal_keyword",
          status: "warn",
          detail: "matched: " + matched.slice(0, 3).join(", "),
        });
      }
    }
  }

  const cmdText = (input.tool_input && typeof input.tool_input.command === "string")
    ? input.tool_input.command
    : "";
  let responseText = "";
  try {
    responseText = typeof input.tool_response === "string"
      ? input.tool_response
      : JSON.stringify(input.tool_response || "");
  } catch (_) {
    responseText = "";
  }
  if ((cmdText && isSentinel(cmdText)) || (responseText && isSentinel(responseText))) {
    findings.push({ check: "sentinel", status: "warn", detail: "sentinel literal in payload" });
  }

  for (const f of findings) {
    appendFinding(sid, f);
  }

  let maxRank = 0;
  for (const f of findings) {
    const r = SEVERITY_RANK[f.status] || 0;
    if (r > maxRank) maxRank = r;
  }
  if (maxRank >= 1) {
    done({
      hookSpecificOutput: {
        hookEventName: "PostToolUse",
        additionalContext:
          "── EM Supervisor ────────────────────────────────────\n[layer1] " +
          findings.map((f) => f.check + ":" + f.status).join(", "),
      },
    });
  }
  done({});
} catch (_) {
  done({});
}
