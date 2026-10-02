#!/usr/bin/env node
// Claude Code PreToolUse hook: block Japanese content in doc-append for public repos

const fs = require("fs");
const { isPrivateRepo, resolveRepoDir } = require("./lib/is-private-repo");
const { hasCommandHead } = require("./lib/command-head");
const { hasCJK } = require("./lib/detect-cjk");

const { readHookInput, readFailOpenDiagnostic } = require("./lib/read-stdin");

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

const hookInput = readHookInput();
if (hookInput.kind !== "ok") {
  try {
    fs.writeSync(2, readFailOpenDiagnostic("check-japanese-in-docs", hookInput, "check skipped") + "\n");
  } catch (e) {}
  approve();
}
const input = hookInput.input;
if (input.tool_name !== "Bash") approve();

const command = input.tool_input?.command || "";
const isDocAppend = (tokens) =>
  tokens[0] === "doc-append" || /(^|\/)doc-append(\.py)?$/.test(tokens[0] || "");
if (!hasCommandHead(command, isDocAppend)) approve();

// Hiragana, Katakana, Kanji, CJK symbols/punctuation, full-width
if (!hasCJK(command)) approve();

const repoDir = resolveRepoDir(command);
if (isPrivateRepo(repoDir)) approve();

block(
  "Japanese text detected in doc-append command.\n" +
  "This is a public repository — history.md must be written in English.\n" +
  "1. Rewrite the content in English.\n" +
  "2. Report to the user that Japanese was found in the doc-append arguments and show what was changed.\n" +
  "3. Re-run doc-append with the English-only content."
);
