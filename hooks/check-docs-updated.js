#!/usr/bin/env node
// Claude Code PreToolUse hook: block git commit if docs not updated
// Checks staged files — if source code is staged but no docs/ changes, blocks with guidance
//
// Doc location priority:
//   1. Local docs/ or .md files in the repo's own staged files
//   2. Sibling ../ai-specs repo — find same-name directory, check for changes

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

// Find directories matching a name under a root (max depth 5)
function findDirs(root, dirName) {
  const results = [];
  function walk(dir, depth) {
    if (depth > 5) return;
    let entries;
    try {
      entries = fs.readdirSync(dir, { withFileTypes: true });
    } catch (e) {
      return;
    }
    for (const entry of entries) {
      if (!entry.isDirectory()) continue;
      if (entry.name.startsWith(".")) continue;
      const full = path.join(dir, entry.name);
      if (entry.name === dirName) results.push(full);
      walk(full, depth + 1);
    }
  }
  walk(root, 0);
  return results;
}

// Check if a directory in a git repo has any changes (staged, unstaged, or untracked)
function dirHasGitChanges(dir) {
  let gitRoot;
  try {
    gitRoot = execSync("git rev-parse --show-toplevel", {
      cwd: dir,
      encoding: "utf8",
      timeout: 5000,
      stdio: ["pipe", "pipe", "pipe"],
    }).trim();
  } catch (e) {
    return false;
  }

  const relPath = path.relative(gitRoot, dir).replace(/\\/g, "/");
  const prefix = relPath ? relPath + "/" : "";

  const checks = [
    `git diff --cached --name-only -- "${prefix}"`,
    `git diff --name-only -- "${prefix}"`,
    `git ls-files --others --exclude-standard -- "${prefix}"`,
  ];

  for (const cmd of checks) {
    try {
      const output = execSync(cmd, {
        cwd: gitRoot,
        encoding: "utf8",
        timeout: 5000,
        stdio: ["pipe", "pipe", "pipe"],
      }).trim();
      if (output) return true;
    } catch (e) {
      // ignore
    }
  }
  return false;
}

// Check sibling ../ai-specs for same-name directory with changes
function checkAiSpecsDocs(repoDir) {
  const resolvedRepo = path.resolve(repoDir);
  const aiSpecsDir = path.join(path.dirname(resolvedRepo), "ai-specs");

  if (!fs.existsSync(aiSpecsDir)) return false;

  const repoName = path.basename(resolvedRepo);
  const matchingDirs = findDirs(aiSpecsDir, repoName);

  for (const dir of matchingDirs) {
    if (dirHasGitChanges(dir)) return true;
  }
  return false;
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
  /\.code-workspace$/i, // VSCode workspace config, not code
];

const hasCodeChanges = stagedFiles.some((f) => {
  if (EXEMPT_DIRS.some((d) => f.startsWith(d))) return false;
  if (EXEMPT_FILES.some((re) => re.test(f))) return false;
  if (DOC_DIRS.some((d) => f.startsWith(d))) return false;
  return true;
});

if (!hasCodeChanges) approve();

// Priority 1: local docs/ or .md files staged in this commit
const hasLocalDocChanges = stagedFiles.some(
  (f) => DOC_DIRS.some((d) => f.startsWith(d)) || /\.md$/i.test(f)
);
if (hasLocalDocChanges) approve();

// Priority 2: sibling ../ai-specs with same-name directory
if (checkAiSpecsDocs(repoDir)) approve();

block(
  "Source code is staged but no doc changes found. " +
    "Update docs/ in this repo or the corresponding directory in ../ai-specs, " +
    "then stage the changes before committing."
);
