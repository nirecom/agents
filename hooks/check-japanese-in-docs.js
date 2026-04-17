#!/usr/bin/env node
// Claude Code PreToolUse hook: block Japanese content in doc-append for public repos

const fs = require("fs");
const { isPrivateRepo, resolveRepoDir } = require("./lib/is-private-repo");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {}
  return Buffer.concat(chunks).toString("utf8");
}

function approve() { console.log(JSON.stringify({ decision: "approve" })); process.exit(0); }
function block(reason) { console.log(JSON.stringify({ decision: "block", reason })); process.exit(0); }

const input = JSON.parse(readStdin());
if (input.tool_name !== "Bash") approve();

const command = input.tool_input?.command || "";
if (!command.includes("doc-append.py")) approve();

// Hiragana, Katakana, Kanji, CJK symbols/punctuation, full-width
if (!/[\u3000-\u9FFF\uF900-\uFAFF\uFF00-\uFFEF]/.test(command)) approve();

const repoDir = resolveRepoDir(command);
if (isPrivateRepo(repoDir)) approve();

block(
  "Japanese text detected in doc-append command.\n" +
  "This is a public repository — history.md must be written in English.\n" +
  "Please rewrite the content in English."
);
