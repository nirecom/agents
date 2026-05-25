#!/usr/bin/env node
"use strict";

// Claude Code PostToolUse hook: block WORKTREE_NOTES.md writes whose
// History/Changelog Notes sections contain non-English content when
// language.md's docs-lang policy enforces english.
// Fail-open on any I/O or parsing error.

const fs = require("fs");
const path = require("path");

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
  const header = "WORKTREE_NOTES.md language check failed — non-English content in english-enforced section(s):";
  const body = violations
    .map((v) => `  [${v.section}:${v.lineNumber}] ${v.line}`)
    .join("\n");
  const footer =
    "Rewrite the offending bullets in English before saving.\n" +
    "Policy comes from $AGENTS_CONFIG_DIR/rules/language.md (docs-lang block).";
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

const agentsDir = process.env.AGENTS_CONFIG_DIR || "";
const langFile = agentsDir ? path.join(agentsDir, "rules", "language.md") : "";

let config;
let lintFn;
try {
  const { loadDocsLangConfig } = require("./lib/docs-lang-config");
  const { lintWorktreeNotesLang } = require("./lib/lint-worktree-notes-lang");
  config = loadDocsLangConfig(langFile);
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

if (!Array.isArray(violations) || violations.length === 0) approve();

const message = formatMessage(violations);
done({
  decision: "block",
  reason: message,
  hookSpecificOutput: {
    hookEventName: "PostToolUse",
    additionalContext: message,
  },
});
