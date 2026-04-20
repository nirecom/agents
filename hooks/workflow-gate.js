#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce workflow step completion before git commit
// Replaces check-tests-updated.js and check-docs-updated.js

const fs = require("fs");
const { execSync } = require("child_process");
const {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  readState,
} = require("./lib/workflow-state");
const { parseGitCArg } = require("./lib/parse-git-args");

// Evidence-based check: staged files contain tests/ changes
function hasStagedTestChanges(repoDir) {
  try {
    const out = execSync("git diff --cached --name-only", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    });
    return out.trim().split("\n").some((f) => f.startsWith("tests/") || f.startsWith("test/"));
  } catch (e) {
    process.stderr.write(`workflow-gate: hasStagedTestChanges failed (cwd=${repoDir}): ${e.message}\n`);
    return false;
  }
}

// Evidence-based check: staged files contain docs/*.md or *.md changes
function hasStagedDocChanges(repoDir) {
  try {
    const out = execSync("git diff --cached --name-only", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    });
    return out.trim().split("\n").some((f) => f.startsWith("docs/") || /\.md$/i.test(f));
  } catch (e) {
    process.stderr.write(`workflow-gate: hasStagedDocChanges failed (cwd=${repoDir}): ${e.message}\n`);
    return false;
  }
}

// Resolve repo dir from git -C flag in command, or process cwd.
// Normalizes Git Bash Unix-style drive paths: /<drive>/path/to → <DRIVE>:\path\to
// Handles bare, double-quoted, and single-quoted -C arguments.
function resolveRepoDir(command) {
  const p = parseGitCArg(command);
  if (!p) return process.env.CLAUDE_PROJECT_DIR || process.cwd();
  // Unix drive path: /<drive>/path → <DRIVE>:\path
  const driveMatch = p.match(/^\/([a-zA-Z])(\/.*)?$/);
  if (driveMatch) {
    const drive = driveMatch[1].toUpperCase();
    const rest = driveMatch[2] || "";
    return drive + ":\\" + rest.replace(/\//g, "\\").replace(/^\\/, "");
  }
  // Normalize Windows drive paths with forward slashes: c:/path → c:\path
  if (process.platform === "win32" && /^[a-zA-Z]:\//.test(p)) return p.replace(/\//g, "\\");
  return p;
}

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

function approve() {
  console.log(JSON.stringify({ decision: "approve" }));
  process.exit(0);
}

function block(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

if (require.main === module) {
  let input;
  try {
    input = JSON.parse(readStdin());
  } catch (e) {
    block("workflow-gate: failed to parse hook input — commit blocked (fail-safe).");
  }

  const toolName = input.tool_name;
  const toolInput = input.tool_input || {};
  const sessionId = input.session_id;

  if (toolName !== "Bash") approve();

  const command = toolInput.command || "";
  if (!command) approve();

  if (!/^git\s/.test(command)) approve();
  if (!/\scommit(\s|$)/.test(command)) approve();

  const repoDir = resolveRepoDir(command);

  // session_id is required — fail-safe if missing
  if (!sessionId) {
    block(
      "workflow-gate: session_id not found in hook input.\n" +
        "Cannot verify workflow state. Commit blocked (fail-safe).\n" +
        "To reset workflow state, run:\n" +
        '  echo "<<WORKFLOW_RESET_FROM_research>>"'
    );
  }

  const state = readState(sessionId);

  if (!state) {
    block(
      `workflow-gate: no workflow state found for session ${sessionId}.\n` +
        "Commit blocked (fail-safe). To initialize workflow state, run:\n" +
        '  echo "<<WORKFLOW_RESET_FROM_research>>"'
    );
  }

  // Check all steps
  const incomplete = [];
  for (const step of VALID_STEPS) {
    const stepState = state.steps && state.steps[step];
    const status = stepState ? stepState.status : "pending";

    if (status === "complete") continue;
    if (status === "skipped" && SKIPPABLE_STEPS.includes(step)) continue;
    // Evidence-based overrides: staged files are proof of completion
    if (step === "write_tests" && hasStagedTestChanges(repoDir)) continue;
    if (step === "docs" && hasStagedDocChanges(repoDir)) continue;
    incomplete.push(step);
  }

  if (incomplete.length === 0) approve();

  const SKILL_MAP = {
    research: '/survey-code or /deep-research  OR if unnecessary: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    plan: '/make-plan  OR if unnecessary: echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    write_tests: '/write-tests (then git add tests/)  OR if unnecessary: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    run_tests: 'run your test suite via Bash (touching tests/) — PostToolUse hook auto-marks based on exit code. Manual fallback: echo "<<WORKFLOW_MARK_STEP_run_tests_complete>>".',
    review_security: '/review-code-security  OR if unnecessary: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    docs: '/update-docs (then git add docs/)',
    user_verification: 'wait for the user to confirm, then run: echo "<<WORKFLOW_USER_VERIFIED>>"  (requires user approval — DO NOT use MARK_STEP for this step)',
  };

  const lines = [
    `workflow-gate: the following workflow steps are not complete: ${incomplete.join(", ")}`,
    "",
    "To mark a step complete:",
  ];

  for (const step of incomplete) {
    if (SKILL_MAP[step]) {
      lines.push(`  ${step}: run ${SKILL_MAP[step]}`);
    } else {
      lines.push(
        `  ${step}: echo "<<WORKFLOW_MARK_STEP_${step}_complete>>"`
      );
    }
  }

  block(lines.join("\n"));
}

module.exports = { resolveRepoDir, hasStagedTestChanges, hasStagedDocChanges };
