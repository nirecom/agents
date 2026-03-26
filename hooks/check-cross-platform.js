#!/usr/bin/env node
// Claude Code PreToolUse hook: block git commit if platform-specific changes lack counterpart
// Platform pairs:
//   install/win/ ↔ install/linux/
//   config/win/  ↔ config/mac/
//
// Skip mechanisms:
//   1. Permanent: .cross-platform-skiplist (base tool names, one per line)
//   2. One-time:  .git/.cross-platform-reviewed (HEAD hash, like .test-reviewed)

const { execSync } = require("child_process");
const fs = require("fs");
const path = require("path");
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

// Platform pairs: [dirA, dirB]
const PLATFORM_PAIRS = [
  ["install/win/", "install/linux/"],
];

// Extract base tool name from a platform-specific file path
// e.g., "install/win/starship.ps1" → "starship"
function baseName(filePath) {
  const file = path.basename(filePath);
  return file.replace(/\.[^.]+$/, "");
}

// Load .cross-platform-skiplist from repo root
function loadSkiplist(repoDir) {
  const skiplistPath = path.join(repoDir, ".cross-platform-skiplist");
  try {
    const content = fs.readFileSync(skiplistPath, "utf8");
    return new Set(
      content
        .split("\n")
        .map((line) => line.trim())
        .filter((line) => line && !line.startsWith("#"))
    );
  } catch (e) {
    return new Set();
  }
}

// Check one-time marker .git/.cross-platform-reviewed
function hasValidMarker(repoDir) {
  let gitDir;
  try {
    gitDir = execSync("git rev-parse --git-dir", {
      cwd: repoDir,
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    return false;
  }

  const markerPath = path.join(repoDir, gitDir, ".cross-platform-reviewed");

  let headHash;
  try {
    headHash = execSync("git rev-parse --short HEAD", {
      cwd: repoDir,
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    return false;
  }

  try {
    const marker = fs.readFileSync(markerPath, "utf8").trim();
    return marker === headHash;
  } catch (e) {
    return false;
  }
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
const repoDir = resolveRepoDir(command);

// Skip private repos
if (isPrivateRepo(repoDir)) approve();

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

// For each platform pair, check if one side has staged files without the other
const missingPairs = []; // [{staged: "install/win/", missing: "install/linux/", files: [...]}]

for (const [dirA, dirB] of PLATFORM_PAIRS) {
  const filesA = stagedFiles.filter((f) => f.startsWith(dirA));
  const filesB = stagedFiles.filter((f) => f.startsWith(dirB));

  if (filesA.length > 0 && filesB.length === 0) {
    missingPairs.push({ staged: dirA, missing: dirB, files: filesA });
  }
  if (filesB.length > 0 && filesA.length === 0) {
    missingPairs.push({ staged: dirB, missing: dirA, files: filesB });
  }
}

if (missingPairs.length === 0) approve();

// Check skiplist — remove files whose base names are exempted
const skiplist = loadSkiplist(repoDir);
const remaining = missingPairs.filter((pair) => {
  const nonExempt = pair.files.filter((f) => !skiplist.has(baseName(f)));
  if (nonExempt.length === 0) return false;
  pair.files = nonExempt;
  return true;
});

if (remaining.length === 0) approve();

// Check one-time marker
if (hasValidMarker(repoDir)) approve();

// Build block message
const details = remaining
  .map((p) => `  ${p.staged} staged → ${p.missing} has no changes`)
  .join("\n");

block(
  "Cross-platform check: platform-specific files are staged but counterpart platform has no changes.\n" +
    details +
    "\n\nTo resolve:\n" +
    "  1. Add corresponding changes to the counterpart platform, OR\n" +
    "  2. Add tool names to .cross-platform-skiplist (permanent), OR\n" +
    "  3. Write HEAD hash to .git/.cross-platform-reviewed (one-time skip)"
);
