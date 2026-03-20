#!/usr/bin/env node
// Claude Code PreToolUse hook: block git commit if tests not updated or reviewed
// Two-stage gate:
//   1. Source code staged but no tests/ changes → block
//   2. Tests staged but no review marker (.git/.test-reviewed) → block

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");

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
const TEST_DIRS = ["tests/", "test/"];
const EXEMPT_DIRS = ["docs/", ".claude/", "claude-global/", "claude-code/"];
const EXEMPT_FILES = [
  /^\.gitignore$/,
  /^\.editorconfig$/,
  /^README\.md$/,
  /^LICENSE/,
  /^CLAUDE\.md$/,
];

const hasTestChanges = stagedFiles.some((f) =>
  TEST_DIRS.some((d) => f.startsWith(d))
);

const hasCodeChanges = stagedFiles.some((f) => {
  if (TEST_DIRS.some((d) => f.startsWith(d))) return false;
  if (EXEMPT_DIRS.some((d) => f.startsWith(d))) return false;
  if (EXEMPT_FILES.some((re) => re.test(f))) return false;
  return true;
});

// Stage 1: source code changed but no tests
if (hasCodeChanges && !hasTestChanges) {
  block(
    "Source code is staged but tests/ has no changes. " +
      "Write or update tests before committing."
  );
}

// Stage 2: tests present but no review marker
if (hasTestChanges) {
  let gitDir;
  try {
    gitDir = execSync("git rev-parse --git-dir", {
      cwd: repoDir,
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    approve(); // Can't find .git dir — fail-open
  }

  const markerPath = path.join(repoDir, gitDir, ".test-reviewed");

  let headHash;
  try {
    headHash = execSync("git rev-parse --short HEAD", {
      cwd: repoDir,
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    // Initial commit (no HEAD) — skip marker check
    approve();
  }

  try {
    const marker = fs.readFileSync(markerPath, "utf8").trim();
    if (marker === headHash) {
      approve();
    }
  } catch (e) {
    // Marker file doesn't exist
  }

  block(
    "Tests are staged but have not been reviewed. " +
      "Run /review-tests to verify test coverage before committing."
  );
}

approve();
