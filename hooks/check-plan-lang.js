"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { loadLangConfig, classifyPolicy } = require("./lib/lang-config");
const { lintPlanLang } = require("./lib/lint-plan-lang");

const TARGET_TOOLS = new Set(["Write", "Edit", "MultiEdit", "editFiles"]);
const ARTIFACT_RE = /^[0-9]{8}-[0-9]{6}-(intent|outline|detail)\.md$/;

// Read stdin, parse JSON, dispatch
let raw = "";
process.stdin.on("data", d => { raw += d; });
process.stdin.on("end", () => {
  let payload;
  try { payload = JSON.parse(raw); } catch { approve(); return; }

  if (!TARGET_TOOLS.has(payload.tool_name)) { approve(); return; }

  const filePath = payload.tool_input && payload.tool_input.file_path;
  if (!filePath) { approve(); return; }

  const plansDir = path.resolve(
    process.env.WORKFLOW_PLANS_DIR || path.join(os.homedir(), ".workflow-plans")
  );
  const resolved = path.resolve(filePath);
  const rel = path.relative(plansDir, resolved);
  if (rel.startsWith("..") || path.isAbsolute(rel)) { approve(); return; }

  if (!ARTIFACT_RE.test(path.basename(resolved))) { approve(); return; }

  const policy = loadLangConfig("plan");
  const tier = classifyPolicy(policy);
  if (tier === "noop") { approve(); return; }

  const rawContent = (payload.tool_input.content !== undefined)
    ? payload.tool_input.content
    : safeRead(resolved);
  if (typeof rawContent !== "string") { approve(); return; }

  if (tier === "hint") { hint(policy); return; }

  const violations = lintPlanLang(rawContent, policy);
  if (violations.length === 0) { approve(); return; }

  block(violations, policy);
});

function safeRead(p) {
  try { return fs.readFileSync(p, "utf8"); } catch { return ""; }
}

function approve() {
  process.stdout.write(JSON.stringify({ decision: "approve" }) + "\n");
  process.exit(0);
}

function hint(policy) {
  process.stdout.write(JSON.stringify({
    decision: "approve",
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext:
        `PLAN_LANG=${policy}: write planning artifact content in ${policy}. ` +
        `Hint only — this call is approved regardless of content language.`,
    },
  }));
}

function block(violations, policy) {
  const lines = violations.slice(0, 5).map(v =>
    `  line ${v.lineNumber}: ${v.line.slice(0, 80)}`
  );
  const msg = [
    `[check-plan-lang] PLAN_LANG=${policy} — ${violations.length} violation(s):`,
    ...lines,
    violations.length > 5 ? `  ... and ${violations.length - 5} more` : "",
  ].filter(Boolean).join("\n");
  process.stdout.write(JSON.stringify({ decision: "block", reason: msg }) + "\n");
  process.exit(0);
}
