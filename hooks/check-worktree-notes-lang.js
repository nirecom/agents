#!/usr/bin/env node
"use strict";

// Claude Code PostToolUse hook: block WORKTREE_NOTES.md writes whose
// History/Changelog Notes sections contain non-English content when
// language.md's docs-lang policy enforces english.
// Fail-open on any I/O or parsing error.

const fs = require("fs");
const path = require("path");
const { classifyPolicy } = require("./lib/lang-config");

const TARGET_TOOLS = new Set(["Write", "Edit", "MultiEdit", "editFiles"]);
const TARGET_BASENAME = "WORKTREE_NOTES.md";

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch (e) {
    return "";
  }
}

function done(output) {
  console.log(JSON.stringify(output));
  process.exit(0);
}

function approve() {
  done({ decision: "approve" });
}

function hint(hints) {
  done({
    decision: "approve",
    hookSpecificOutput: {
      hookEventName: "PostToolUse",
      additionalContext: hints.join("\n"),
    },
  });
}

function buildHints(config, isPriv) {
  const hints = [];
  const histPolicy = isPriv ? config.historyPrivate : config.historyPublic;
  const clPolicy = isPriv ? config.changelogPrivate : config.changelogPublic;
  if (classifyPolicy(histPolicy) === "hint") {
    hints.push(
      `DOCS_LANG_HISTORY_${isPriv ? "PRIVATE" : "PUBLIC"}=${histPolicy}: ` +
      `write ## History Notes in ${histPolicy}. Hint only — approved regardless of content language.`
    );
  }
  if (classifyPolicy(clPolicy) === "hint") {
    hints.push(
      `DOCS_LANG_CHANGELOG_${isPriv ? "PRIVATE" : "PUBLIC"}=${clPolicy}: ` +
      `write ## Changelog Notes in ${clPolicy}. Hint only — approved regardless of content language.`
    );
  }
  return hints;
}

function extractFilePath(toolInput) {
  if (!toolInput || typeof toolInput !== "object") return "";
  return toolInput.file_path || toolInput.path || "";
}

function safeIsPrivateRepo(cwd) {
  try {
    const { isPrivateRepo } = require("./lib/is-private-repo");
    return isPrivateRepo(cwd) === true;
  } catch (e) {
    return false;
  }
}

function formatMessage(violations) {
  const header = "WORKTREE_NOTES.md language check failed — content does not match the configured language policy:";
  const body = violations
    .map((v) => `  [${v.section}:${v.lineNumber}] (expected ${v.policy}) ${v.line}`)
    .join("\n");
  const footer =
    "Rewrite the offending bullets to match the policy before saving.\n" +
    "Policy comes from $AGENTS_CONFIG_DIR/.env (DOCS_LANG_HISTORY_*, DOCS_LANG_CHANGELOG_*).";
  return `${header}\n${body}\n${footer}`;
}

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  approve();
}

if (!input || !TARGET_TOOLS.has(input.tool_name)) approve();

const filePath = extractFilePath(input.tool_input);
if (!filePath) approve();
if (path.basename(filePath) !== TARGET_BASENAME) approve();

let content;
try {
  content = fs.readFileSync(filePath, "utf8");
} catch (e) {
  approve();
}

let config;
let lintFn;
try {
  const { loadDocsLangConfig } = require("./lib/lang-config");
  const { lintWorktreeNotesLang } = require("./lib/lint-worktree-notes-lang");
  config = loadDocsLangConfig();
  lintFn = lintWorktreeNotesLang;
} catch (e) {
  approve();
}

const isPriv = safeIsPrivateRepo(process.cwd());

let violations;
try {
  violations = lintFn(content, config, { isPrivateRepo: isPriv });
} catch (e) {
  approve();
}

if (!Array.isArray(violations) || violations.length === 0) {
  const hints = buildHints(config, isPriv);
  if (hints.length > 0) hint(hints);
  approve();
}

const message = formatMessage(violations);
done({
  decision: "block",
  reason: message,
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: message,
  },
});
