"use strict";
const fs = require("fs");
const path = require("path");
const { loadLangConfig, classifyPolicy } = require("./lib/lang-config");
const { lintPlanLang } = require("./lib/lint-plan-lang");
const { isPlanArtifactPath, formatPlanLangViolations } = require("./lib/plan-artifact-lang");
const { TARGET_TOOLS } = require("./lib/pretool-lang-gate");

// Read stdin, parse JSON, dispatch
let raw = "";
process.stdin.on("data", d => { raw += d; });
process.stdin.on("end", () => {
  let payload;
  try { payload = JSON.parse(raw); } catch { approve(); return; }

  if (!TARGET_TOOLS.has(payload.tool_name)) { approve(); return; }

  const filePath = payload.tool_input && payload.tool_input.file_path;
  if (!filePath) { approve(); return; }

  const resolved = path.resolve(filePath);
  let isArtifact = false;
  try { isArtifact = isPlanArtifactPath(resolved); } catch { isArtifact = false; }
  if (!isArtifact) { approve(); return; }

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
  const lines = formatPlanLangViolations(violations).map(s => `  ${s}`);
  const msg = [
    `[check-plan-lang] PLAN_LANG=${policy} — ${violations.length} violation(s):`,
    ...lines,
  ].join("\n");
  process.stdout.write(JSON.stringify({ decision: "block", reason: msg }) + "\n");
  process.exit(0);
}
