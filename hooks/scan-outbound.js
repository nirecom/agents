#!/usr/bin/env node
// Claude Code PreToolUse hook: check Edit/Write content for private information
// Skips scanning for private repos (detected dynamically via GitHub API)

const { execSync, spawnSync } = require("child_process");
const fs = require("fs");
const path = require("path");
const { isPrivateRepo, resolveRepoDir } = require("./lib/is-private-repo");

// Read stdin (cross-platform: fs.readSync for Windows compatibility)
function readStdin() {
  const chunks = [];
  const buf = Buffer.alloc(4096);
  let bytesRead;
  try {
    while (true) {
      bytesRead = fs.readSync(0, buf, 0, buf.length);
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

// Normalize path for shell commands (Windows backslashes → forward slashes)
function shellPath(p) {
  return p.split(path.sep).join("/");
}

// This script lives in agents/hooks/; scanner is at agents/bin/
const AGENTS_DIR = path.resolve(__dirname, "..");
const SCANNER = path.join(AGENTS_DIR, "bin", "scan-outbound.sh");

// Parse stdin
const input = JSON.parse(readStdin());
const toolName = input.tool_name;
const toolInput = input.tool_input || {};

// Only check Edit, Write, and Bash tools
if (toolName !== "Edit" && toolName !== "Write" && toolName !== "Bash") {
  approve();
}

// Extract file path and content to scan
const filePath = toolInput.file_path || "";
let content = "";

if (toolName === "Write") {
  content = toolInput.content || "";
} else if (toolName === "Edit") {
  content = toolInput.new_string || "";
} else if (toolName === "Bash") {
  const command = toolInput.command || "";
  // Only scan git commit messages, approve all other commands immediately
  const commitMatch = command.match(/git\s+(?:-C\s+\S+\s+)?commit\s/);
  if (!commitMatch) {
    approve();
  }
  // Extract commit message: support -m "msg", -m 'msg', and heredoc $(cat <<'EOF'...EOF)
  const heredocMatch = command.match(/<<'?EOF'?\s*\n([\s\S]*?)\nEOF/);
  if (heredocMatch) {
    content = heredocMatch[1];
  } else {
    const msgMatch = command.match(/(?:-m\s+)(["'])([\s\S]*?)\1/);
    content = msgMatch ? msgMatch[2] : "";
  }
  if (!content) {
    approve();
  }
}

if (!content) {
  approve();
}

// Check if the target repo is private (skip scanning for private repos)
{
  let repoDir = null;
  if (filePath) {
    // Edit/Write: resolve repo from file path
    try {
      repoDir = execSync(`git -C "${shellPath(path.dirname(filePath))}" rev-parse --show-toplevel`, {
        encoding: "utf8",
        timeout: 5000,
        stdio: ["pipe", "pipe", "pipe"],
      }).trim();
    } catch (e) {
      // Not in a git repo — continue with scan
    }
  } else if (toolName === "Bash") {
    // Bash: resolve repo from git -C <path> or HOOK_CWD
    repoDir = resolveRepoDir(toolInput.command || "");
  }
  if (isPrivateRepo(repoDir)) {
    approve();
  }
}

// Run scanner on the content
{
  const label = filePath || "stdin";
  const result = spawnSync("bash", [shellPath(SCANNER), "--stdin", shellPath(label)], {
    input: content,
    encoding: "utf8",
    timeout: 10000,
  });
  const SCAN_OUT = ((result.stdout || "") + (result.stderr || "")).trim();

  // Fail-closed: timeout / spawn error / unobservable status
  if (result.error || result.status === null) {
    block(`Scanner failed (${(result.error && result.error.message) || "no exit status"}):\n${SCAN_OUT}`);
    return; // defensive: block() exits, but make control flow explicit
  }

  switch (result.status) {
    case 0:
      approve();
      break;
    case 1:
      block(`Private information detected:\n${SCAN_OUT}`);
      break;
    case 2:
      // PreToolUse hook never prompts directly. Return block + reason so Claude
      // relays the question to the user. Re-display the matched lines so the
      // user can judge.
      block(
        `Possible private information detected (warn-only):\n${SCAN_OUT}\n\n` +
        `These patterns are flagged as likely false-positive-prone. ` +
        `Ask the user whether this content is safe to commit. ` +
        `If the user confirms it is safe, proceed. ` +
        `If genuinely safe long-term, suggest adding to .private-info-allowlist.`
      );
      break;
    case 3:
      block(`Scanner usage error (rc=3):\n${SCAN_OUT}`);
      break;
    default:
      block(`Scanner unexpected rc=${result.status}:\n${SCAN_OUT}`);
  }
}
