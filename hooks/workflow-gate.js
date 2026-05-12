#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce workflow step completion before git commit
// Replaces check-tests-updated.js and check-docs-updated.js

const fs = require("fs");
const path = require("path");
const { execSync } = require("child_process");
const {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  readState,
} = require("./lib/workflow-state");

const { isMergeToProtectedCommand } = require("./lib/merge-detect");

// Steps tracked by the workflow but not enforced at commit time.
// The NEXT-hint mechanism (nextStepHint) handles guidance for these steps.
const NON_GATE_STEPS = ["research"];
const { parseGitCArg, parseGitConfigValues } = require("./lib/parse-git-args");

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

// Allowlist of file patterns treated as human-facing documentation (not behavior code).
// Matches:
//   - any .md under docs/ (including nested: docs/architecture/foo.md)
//   - root-level human-facing .md files: README / CHANGELOG / CONTRIBUTING / LICENSE
// Intentionally excludes CLAUDE.md, SKILL.md, subdirectory README.md, etc. —
// those are behavior/prompt code that require the full workflow gate.
const DOCS_ONLY_ALLOWLIST = /^(docs\/.+\.md|(README|CHANGELOG|CONTRIBUTING|LICENSE)\.md)$/i;

// Evidence-based check: ALL staged files are human-facing docs (no behavior code)
function isDocsOnlyStaged(repoDir) {
  try {
    const out = execSync("git diff --cached --name-only", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    });
    const files = out.trim().split("\n").filter(Boolean);
    return files.length > 0 && files.every((f) => DOCS_ONLY_ALLOWLIST.test(f));
  } catch (e) {
    process.stderr.write(`workflow-gate: isDocsOnlyStaged failed (cwd=${repoDir}): ${e.message}\n`);
    return false;
  }
}

// Detect whether docs/ points to a separate git repository (junction / symlink pattern).
// Returns the external repo root if docs/ resolves to a different git tree, else null.
function resolveExternalDocsRepo(repoDir) {
  const docsPath = path.join(repoDir, "docs");
  try {
    const out = execSync("git rev-parse --show-toplevel", {
      cwd: docsPath, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    const norm = (p) => p.replace(/\\/g, "/").replace(/\/$/, "").toLowerCase();
    if (norm(out) !== norm(repoDir)) return out;
  } catch (e) {}
  return null;
}

// Evidence-based check: staged files contain docs/*.md or *.md changes
function hasStagedDocChanges(repoDir) {
  const hasDocs = (dir) => {
    try {
      const out = execSync("git diff --cached --name-only", {
        cwd: dir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
      });
      return out.trim().split("\n").some((f) => f.startsWith("docs/") || /\.md$/i.test(f));
    } catch (e) {
      return false;
    }
  };
  if (hasDocs(repoDir)) return true;
  const externalRepo = resolveExternalDocsRepo(repoDir);
  return externalRepo !== null && hasDocs(externalRepo);
}

// Returns true when the commit is happening inside a linked worktree on a
// non-protected branch. Used to skip user_verification at commit time —
// verification is enforced later at the merge boundary instead.
function isWorktreeContext(repoDir) {
  try {
    const common = execSync("git rev-parse --git-common-dir", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    const dir = execSync("git rev-parse --git-dir", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    const norm = (p) => path.resolve(repoDir, p).toLowerCase();
    if (norm(common) === norm(dir)) return false;  // main worktree
    const branch = execSync("git rev-parse --abbrev-ref HEAD", {
      cwd: repoDir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    }).trim();
    if (!branch || branch === "HEAD") return false;  // detached HEAD
    const envBranches = (process.env.DEFAULT_BRANCHES || "").split(",")
      .map((s) => s.trim()).filter(Boolean);
    const protectedBranches = envBranches.length ? envBranches : ["main", "master"];
    return !protectedBranches.includes(branch);
  } catch (e) {
    return false;
  }
}

// Return true if dir has any staged changes.
function hasStagedChanges(dir) {
  try {
    const out = execSync("git diff --cached --name-only", {
      cwd: dir, encoding: "utf8", timeout: 5000, stdio: ["pipe", "pipe", "pipe"],
    });
    return out.trim().length > 0;
  } catch (e) {
    return false;
  }
}

// Read additionalDirectories from the assembled ~/.claude/settings.json, falling back
// to agents/settings.json so the hook works before the first install run.
function findAdditionalDirectories() {
  try {
    const agentsRoot = path.resolve(__dirname, "..");
    const claudePath = path.join(require("os").homedir(), ".claude", "settings.json");
    const agentsPath = path.join(agentsRoot, "settings.json");
    const settingsPath = fs.existsSync(claudePath) ? claudePath : agentsPath;
    const settings = JSON.parse(fs.readFileSync(settingsPath, "utf8"));
    const dirs = (settings.permissions || settings).additionalDirectories || [];
    return dirs.map((d) => path.isAbsolute(d) ? d : path.resolve(agentsRoot, d));
  } catch (e) {
    return [];
  }
}

// Resolve repo dir from git -C flag in command, or detect from staged changes.
// When no -C is given, checks CLAUDE_PROJECT_DIR first; if it has no staged
// changes, scans additionalDirectories from settings.json. This allows committing
// to sibling repos (e.g. agents) from a dotfiles-primary session without requiring
// explicit git -C in every commit command, and works across all Claude clients.
// Normalizes Git Bash Unix-style drive paths: /<drive>/path/to → <DRIVE>:\path\to
function resolveRepoDir(command) {
  const raw = parseGitCArg(command);
  const p = raw ? raw.replace(/\$\{(\w+)\}|\$(\w+)/g, (_, a, b) => process.env[a || b] || '') : raw;
  if (p) {
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

  const primary = process.env.CLAUDE_PROJECT_DIR || process.cwd();
  const norm = (p) => p.replace(/\\/g, "/").replace(/\/$/, "").toLowerCase();
  if (hasStagedChanges(primary)) return primary;
  for (const dir of findAdditionalDirectories()) {
    if (norm(dir) === norm(primary)) continue;
    if (hasStagedChanges(dir)) return dir;
  }
  return primary;
}

function readStdin() {
  try {
    return fs.readFileSync(0, "utf8");
  } catch (e) {
    return "";
  }
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

  // EARLY GATE: enforce clarify_intent before Edit/Write tools.
  // Fail-open precedence (do NOT reorder):
  //   1. No sessionId → fall through (cannot enforce)
  //   2. readState() returns null → fall through (no state to check)
  //   3. clarify_intent already complete or skipped → fall through (gate dormant)
  //   4. otherwise → block (with plans-path allowlist for skill output)
  //
  // Multi-hook execution: Claude Code runs all PreToolUse hooks independently;
  // approve from this hook does NOT short-circuit block-dotenv etc.
  //
  // State inheritance: if findLatestStateForContext() inherited a state where
  // clarify_intent is already complete, gate is dormant by design — inherited
  // state represents continuing prior work.
  const EARLY_GATE_TOOLS = new Set([
    "Edit", "Write", "MultiEdit", "editFiles", "NotebookEdit"
  ]);
  if (sessionId && EARLY_GATE_TOOLS.has(toolName)) {
    const earlyState = readState(sessionId);
    if (earlyState) {
      const ci = earlyState.steps && earlyState.steps.clarify_intent;
      const ciStatus = ci ? ci.status : "pending";
      if (ciStatus !== "complete" && ciStatus !== "skipped") {
        // Allowlist: Write tool only, to ~/.claude/plans/** (skill writes intent/outline/detail .md here).
        // Resolve the path so traversal sequences like "../" can't smuggle the write outside.
        const filePath = toolInput.file_path || toolInput.path || "";
        let isPlansAllowed = false;
        if (toolName === "Write" && filePath) {
          try {
            const resolved = path.resolve(filePath);
            const plansRoot = path.join(require("os").homedir(), ".claude", "plans") + path.sep;
            isPlansAllowed = resolved.toLowerCase().startsWith(plansRoot.toLowerCase());
          } catch (e) { /* fall through — block */ }
        }
        if (!isPlansAllowed) {
          block(
            "workflow-gate: clarify_intent has not been completed for this session.\n" +
            "Tool \"" + toolName + "\" is blocked until intent is locked in.\n\n" +
            "To complete:\n" +
            "  1. Invoke the `clarify-intent` skill via the Skill tool, OR\n" +
            "  2. If intent is already clear: echo \"<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <reason>>\".\n\n" +
            "Note: Read, Grep, Glob, Bash, and AskUserQuestion remain available.\n" +
            "For docs-only edits: echo \"<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: docs-only edit>>\"\n\n" +
            "To reset workflow state: echo \"<<WORKFLOW_RESET_FROM_clarify_intent>>\""
          );
        }
      }
    }
  }

  if (toolName !== "Bash") approve();

  const command = toolInput.command || "";
  if (!command) approve();

  // MERGE GATE: hard-block gh pr merge / git push to protected branches when
  // user_verification is not complete. Runs unconditionally regardless of
  // ENFORCE_WORKTREE — protected branches are protected in all modes.
  const mergeHit = isMergeToProtectedCommand(command);
  if (mergeHit.hit) {
    if (!sessionId) {
      block(
        "workflow-gate: merge to protected branch blocked — session_id missing.\n" +
        'Run: echo "<<WORKFLOW_USER_VERIFIED>>" first.'
      );
    }
    const mergeState = readState(sessionId);
    if (!mergeState) {
      block(
        "workflow-gate: merge to protected branch blocked — no workflow state.\n" +
        'Run: echo "<<WORKFLOW_USER_VERIFIED>>" first.'
      );
    }
    const uv = mergeState.steps && mergeState.steps.user_verification;
    const uvStatus = uv ? uv.status : "missing";
    if (uvStatus !== "complete") {
      block(
        `workflow-gate: ${mergeHit.kind} blocked — user_verification is "${uvStatus}".\n\n` +
        'Run: echo "<<WORKFLOW_USER_VERIFIED>>"\n' +
        '(Set Bash description: "User verification: approve if implementation is complete — approving unlocks the merge gate.")'
      );
    }
    approve();
  }

  if (!/^git\s/.test(command)) approve();
  if (!/\scommit(\s|$)/.test(command)) approve();

  const repoDir = resolveRepoDir(command);
  const docsOnly = isDocsOnlyStaged(repoDir);
  // WIP signal: `git -c workflow.wip=1 commit ...` skips ONLY user_verification.
  // run_tests, review_security, docs still fire. See docs/architecture/claude-code/workflow.md.
  const wipValues = parseGitConfigValues(command, "workflow.wip");
  const isWip = wipValues.some((v) => v === "1" || v.toLowerCase() === "true");

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
    if (NON_GATE_STEPS.includes(step)) continue;
    const stepState = state.steps && state.steps[step];
    const status = stepState ? stepState.status : "pending";

    if (status === "complete") continue;
    if (status === "skipped" && SKIPPABLE_STEPS.includes(step)) continue;
    // docs-only short-circuit: skip all steps except user_verification
    if (docsOnly && step !== "user_verification") continue;
    // Worktree context: defer user_verification to merge-time gate.
    // Feature-branch commits/pushes are intermediate; verification fires
    // at gh pr merge / git push :main instead (see merge gate above).
    if (step === "user_verification" && isWorktreeContext(repoDir)) continue;
    if (step === "user_verification" && isWip) continue;
    // Evidence-based overrides: staged files are proof of completion
    if (step === "write_tests" && hasStagedTestChanges(repoDir)) continue;
    if (step === "docs" && hasStagedDocChanges(repoDir)) continue;
    incomplete.push(step);
  }

  if (incomplete.length === 0) approve();

  const SKILL_MAP = {
    clarify_intent: '/clarify-intent  OR if intent is clear: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    research: '/survey-code or /deep-research  OR if unnecessary: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    plan: '/make-outline-plan → /make-detail-plan  OR if unnecessary: echo "<<WORKFLOW_PLAN_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    branching_complete: 'consult rules/branch.md + rules/worktree.md, then: echo "<<WORKFLOW_BRANCHING_COMPLETE: main|branch: <name>|worktree: <path>>"',
    write_tests: '/write-tests (then git add tests/)  OR if unnecessary: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    run_tests: 'invoke `run-tests` skill via the Skill tool (emits sentinel automatically); or run tests directly via Bash — PostToolUse hook (workflow-run-tests.js) auto-marks based on exit code.',
    review_security: '/review-code-security  OR if unnecessary: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    docs: '/update-docs (then git add docs/)',
    user_verification: 'run immediately: echo "<<WORKFLOW_USER_VERIFIED>>" — set Bash description to "User verification: approve if implementation is complete — approving unlocks the commit gate."  (ask dialog IS the confirmation — do NOT wait for a prior text reply, do NOT use MARK_STEP)',
  };

  const lines = [
    docsOnly && incomplete.length === 1 && incomplete[0] === "user_verification"
      ? "workflow-gate: docs-only commit — only user_verification is required."
      : `workflow-gate: the following workflow steps are not complete: ${incomplete.join(", ")}`,
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

module.exports = { resolveRepoDir, hasStagedTestChanges, hasStagedDocChanges, isDocsOnlyStaged, resolveExternalDocsRepo, hasStagedChanges, findAdditionalDirectories };
