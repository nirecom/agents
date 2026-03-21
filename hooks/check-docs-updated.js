#!/usr/bin/env node
// Claude Code PreToolUse hook: block git commit if docs not updated
// Checks staged files — if source code is staged but no docs/ changes, blocks with guidance

const { execSync } = require("child_process");
const fs = require("fs");

function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  try {
    while (true) {
      const bytesRead = fs.readSync(0, buf, 0, buf.length);
      if (bytesRead === 0) break;
      chunks.push(buf.slice(0, bytesRead));
    }
  } catch (e) {
    // EOF or error
  }
  return Buffer.concat(chunks).toString("utf8");
}

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Parse stdin
let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  approve();
}

const toolName = input.tool_name;
const toolInput = input.tool_input || {};

if (toolName !== "Bash") approve();

const command = toolInput.command || "";
if (!command) approve();

// Only intercept git commit commands
const commitMatch = command.match(/git\s+(?:-C\s+\S+\s+)?commit\s/);
if (!commitMatch) approve();

// Determine the repo directory
const cPathMatch = command.match(/git\s+-C\s+(\S+)\s+commit/);
const repoDir = process.env.HOOK_CWD || (cPathMatch ? cPathMatch[1] : ".");

// Get staged files
let stagedFiles;
try {
  const output = execSync("git diff --cached --name-only", {
    cwd: repoDir,
    encoding: "utf8",
    timeout: 5000,
    stdio: ["pipe", "pipe", "pipe"],
  });
  stagedFiles = output.trim().split("\n").filter(Boolean);
} catch (e) {
  approve(); // Can't determine staged files — fail-open
}

if (stagedFiles.length === 0) approve();

// Categorize staged files
const DOC_DIRS = ["docs/"];
const EXEMPT_DIRS = ["tests/", "test/", ".claude/", "claude-global/"];
const EXEMPT_FILES = [
  /^\.gitignore$/,
  /^\.editorconfig$/,
  /^LICENSE/,
  /\.md$/i, // Markdown files are documentation, not code
];

const hasDocChanges = stagedFiles.some(
  (f) => DOC_DIRS.some((d) => f.startsWith(d)) || /\.md$/i.test(f)
);

const hasCodeChanges = stagedFiles.some((f) => {
  // Check if file is in an exempt directory
  if (EXEMPT_DIRS.some((d) => f.startsWith(d))) return false;
  // Check if file matches an exempt pattern
  if (EXEMPT_FILES.some((re) => re.test(f))) return false;
  // Check if file is in docs
  if (DOC_DIRS.some((d) => f.startsWith(d))) return false;
  return true;
});

if (hasCodeChanges && !hasDocChanges) {
  block(
    "Source code is staged but docs/ has no changes. " +
      "Run /update-docs to update documentation before committing, " +
      "or add docs changes to the staging area."
  );
}

approve();
