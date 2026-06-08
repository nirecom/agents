#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce workflow step completion before git commit
// Replaces check-tests-updated.js and check-docs-updated.js

const fs = require("fs");
const path = require("path");
const { execSync, spawnSync } = require("child_process");
const {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  readState,
} = require("./lib/workflow-state");

const { isMergeToProtectedCommand } = require("./lib/merge-detect");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");

// Steps tracked by the workflow but not enforced at commit time.
// The NEXT-hint mechanism (nextStepHint) handles guidance for these steps.
const NON_GATE_STEPS = ["research"];
const { parseGitConfigValues } = require("./lib/parse-git-args");

const { normalizeForWindows } = require("./workflow-gate/path-normalize");
const {
  hasStagedTestChanges,
  isDocsOnlyStaged,
  resolveExternalDocsRepo,
  hasStagedDocChanges,
  hasStagedChanges,
  hasUnstagedTrackedChanges,
} = require("./workflow-gate/staged-evidence");
const { hasOpenPrForBranch, isBranchDirectlyMerged } = require("./workflow-gate/gh-detect");
const {
  isWorktreeContext,
  isLinkedWorktree,
  hasWorktreeNotesDocEvidence,
} = require("./workflow-gate/worktree-context");
const {
  findAdditionalDirectories,
  resolveRepoDir,
} = require("./workflow-gate/repo-resolution");

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

  // WORKFLOW_OFF: bypass all workflow-gate checks (superset of WORKTREE_OFF per workflow-off.md).
  const { isWorkflowOff, isWorktreeOff } = require("./lib/session-markers");
  if (isWorkflowOff(sessionId)) approve();

  // EARLY GATE: 2-tier enforcement before Edit/Write tools.
  //   Tier 1: workflow_init must be complete/skipped first.
  //   Tier 2: clarify_intent must be complete/skipped (only checked once Tier 1 clears).
  // Fail-open precedence (do NOT reorder):
  //   1. No sessionId → fall through (cannot enforce)
  //   2. readState() returns null → fall through (no state to check)
  //   3. plans-path Write allowlist → fall through (skill output path)
  //   4. Tier 1 not clear → block (references /workflow-init)
  //   5. Tier 2 not clear → block (references /clarify-intent)
  //   6. Both clear → fall through (gate dormant)
  //
  // Multi-hook execution: Claude Code runs all PreToolUse hooks independently;
  // approve from this hook does NOT short-circuit block-dotenv etc.
  //
  // State inheritance: if findLatestStateForContext() inherited a state where both
  // steps are already complete, gate is dormant by design — inherited state represents
  // continuing prior work.
  const EARLY_GATE_TOOLS = new Set([
    "Edit", "Write", "MultiEdit", "editFiles", "NotebookEdit"
  ]);
  if (sessionId && EARLY_GATE_TOOLS.has(toolName)) {
    const earlyState = readState(sessionId);
    if (earlyState) {
      // Plans-path allowlist: Write tool only, to ~/.workflow-plans/**
      // (skill writes intent/outline/detail .md here while workflow_init is still pending).
      // Resolve the path so traversal sequences like "../" can't smuggle the write outside.
      const filePath = toolInput.file_path || toolInput.path || "";
      let isPlansAllowed = false;
      if (toolName === "Write" && filePath) {
        try {
          const resolved = path.resolve(filePath);
          const plansRoot = path.resolve(getWorkflowPlansDir()) + path.sep;
          isPlansAllowed = resolved.toLowerCase().startsWith(plansRoot.toLowerCase());
        } catch (e) { console.error(`workflow-gate: ${e.message}`); }
      }
      if (!isPlansAllowed) {
        // Tier 1: workflow_init
        const wi = earlyState.steps && earlyState.steps.workflow_init;
        const wiStatus = wi ? wi.status : "pending";
        if (wiStatus !== "complete" && wiStatus !== "skipped") {
          block(
            "workflow-gate: workflow_init has not been completed for this session.\n" +
            "Tool \"" + toolName + "\" is blocked until the workflow is routed.\n\n" +
            "To complete:\n" +
            "  1. Invoke the `workflow-init` skill via the Skill tool, OR\n" +
            "  2. For docs-only edits: echo \"<<WORKFLOW_MARK_STEP_workflow_init_complete>>\".\n\n" +
            "Note: Read, Grep, Glob, Bash, and AskUserQuestion remain available.\n\n" +
            "To reset workflow state: echo \"<<WORKFLOW_RESET_FROM_workflow_init>>\""
          );
        }
        // Tier 2: clarify_intent (only reached once workflow_init has cleared)
        const ci = earlyState.steps && earlyState.steps.clarify_intent;
        const ciStatus = ci ? ci.status : "pending";
        if (ciStatus !== "complete" && ciStatus !== "skipped") {
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

  // SENTINEL CHAIN GUARD (closes #382): reject `<<WORKFLOW_*>> && <non-sentinel>` chains.
  //
  // Policy: predict the cases that workflow-mark.js (PostToolUse) will silently
  // drop and surface them as PreToolUse errors. workflow-mark.js is unchanged
  // (issue #382 non-goal): it splits on /\s*&&\s*/ and applies #110 all-or-nothing
  // — every part must match isSentinel() or none of them are processed. So the
  // drop-prediction is exactly:
  //
  //     drop-predict := (split has >1 part) AND (not every part isSentinel)
  //                     AND (a real sentinel echo form is actually present)
  //
  // The last conjunct distinguishes a real sentinel chain from incidental
  // `<<WORKFLOW_` substrings (e.g. `grep '<<WORKFLOW_' file && wc -l`).
  //
  // Quote convention parity: CHAIN_BOUNDARY_SENTINEL_*_RE mirror isSentinel() exactly —
  //   - DQ form is accepted for every sentinel category.
  //   - SQ form is accepted ONLY for MARK_STEP_* (matching MARKER_RE_SQ).
  // If we accepted SQ for all categories, we would block chains like
  // `echo '<<WORKFLOW_USER_VERIFIED>>' && rm /tmp/x` (bare form retained as historical attack-vector example per #404) that workflow-mark.js
  // treats as a non-sentinel (no SQ regex for USER_VERIFIED), creating a
  // new asymmetry. Keeping the two recognizers symmetric eliminates that.
  if (/<<WORKFLOW_/.test(command)) {
    const {
      isSentinel,
      isStrictSentinel,
      USER_VERIFIED_RE_DQ,
      CHAIN_BOUNDARY_SENTINEL_DQ_RE,
      CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE,
    } = require("./lib/sentinel-patterns");
    // Step 1 — standalone sentinel (incl. reasons containing '&&'): approve.
    // Uses isStrictSentinel (not isSentinel) because LOOKSLIKE regexes use
    // greedy `.*` that can span across `>>` and match chained commands as if
    // they were single sentinels. Strict DQ regexes use `[^>]+` for reason
    // fields, which correctly rejects chained commands.
    if (!isStrictSentinel(command)) {
      // Step 2 — mirror workflow-mark.js naive split.
      const parts = command
        .split(/\s*&&\s*/)
        .map((s) => s.trim())
        .filter(Boolean);
      if (parts.length > 1) {
        const allSentinel = parts.every(isSentinel);
        if (!allSentinel) {
          // Step 3 — distinguish real chain-boundary sentinel involvement from
          // incidental occurrences (e.g. diagnostic grep patterns, or sentinel
          // text quoted inside another command's argument).
          if (
            CHAIN_BOUNDARY_SENTINEL_DQ_RE.test(command) ||
            CHAIN_BOUNDARY_SENTINEL_SQ_MARKER_RE.test(command)
          ) {
            block(
              "workflow-gate: sentinel command chained with non-sentinel via `&&` is blocked.\n" +
              "Sentinel echoes must be standalone Bash calls (or chained only with other sentinels).\n" +
              "Without this guard, workflow-mark.js (PostToolUse) splits on `&&` and applies\n" +
              "all-or-nothing dispatch (issue #110): when even one part is not a recognized\n" +
              "sentinel, ALL state updates are silently dropped. This includes the case where\n" +
              "a sentinel's reason text itself contains `&&` (the naive splitter fragments it).\n\n" +
              "Fix: split into separate Bash calls. Example:\n" +
              '  call 1: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: docs-only change>>"\n' +
              "  call 2: <the other command>"
            );
          }
          // else: incidental substring (no real sentinel echo present) — approve.
        }
        // else: all-sentinel chain — workflow-mark.js #110 will dispatch each.
      }
      // else parts.length == 1: not a chain; not a recognized standalone sentinel
      // either (Step 1 would have caught it). Pass through — nothing to gate here.
    }

    // PREMATURE USER_VERIFIED GUARD: block emission when ENFORCE_WORKTREE=on and
    // no OPEN/MERGED PR exists for the branch (i.e., before worktree-end Step WE-7 (local merge)).
    // Requires toolInput.cwd — without an explicit Bash cwd we cannot reliably
    // determine the worktree context (resolveRepoDir may return a stale path),
    // so we skip the guard and fail-open. Real Claude Code always supplies cwd.
    const rawSentinelCwd = typeof toolInput.cwd === "string" ? toolInput.cwd : null;
    if (
      rawSentinelCwd &&
      isStrictSentinel(command) &&
      USER_VERIFIED_RE_DQ.test(command) &&
      process.env.ENFORCE_WORKTREE !== "off" &&
      isWorktreeContext(normalizeForWindows(rawSentinelCwd)) &&
      !hasOpenPrForBranch(normalizeForWindows(rawSentinelCwd)) &&
      !isBranchDirectlyMerged(normalizeForWindows(rawSentinelCwd))
    ) {
      block(
        "workflow-gate: premature <<WORKFLOW_USER_VERIFIED>> emission blocked.\n\n" +
        "Under ENFORCE_WORKTREE=on, emit this sentinel only at /worktree-end Step WE-7 (local merge)\n" +
        "(after the PR is open and merge is imminent).\n\n" +
        "Defer: proceed to /worktree-end which emits the sentinel at the correct point.\n" +
        "Emergency bypass: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>>\"\n" +
        "See issue #577."
      );
    }
  }

  // MERGE GATE: hard-block gh pr merge / git push to protected branches when
  // user_verification is not complete. Runs unconditionally regardless of
  // ENFORCE_WORKTREE — protected branches are protected in all modes.
  const mergeHit = isMergeToProtectedCommand(command);
  if (mergeHit.hit) {
    if (!sessionId) {
      block(
        "workflow-gate: merge to protected branch blocked — session_id missing.\n" +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: <reason>>>" first (reason: >=3 non-space chars, no \'>\', not a placeholder).'
      );
    }
    const mergeState = readState(sessionId);
    if (!mergeState) {
      block(
        "workflow-gate: merge to protected branch blocked — no workflow state.\n" +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: <reason>>>" first (reason: >=3 non-space chars, no \'>\', not a placeholder).'
      );
    }
    const uv = mergeState.steps && mergeState.steps.user_verification;
    const uvStatus = uv ? uv.status : "missing";
    if (uvStatus !== "complete") {
      block(
        `workflow-gate: ${mergeHit.kind} blocked — user_verification is "${uvStatus}".\n\n` +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: <reason>>>"\n' +
        '(reason: >=3 non-space chars, no \'>\', not a placeholder; ' +
        'set Bash description: "User verification: approve if implementation is complete — approving unlocks the merge gate.")'
      );
    }
    approve();
  }

  if (!/^git\s/.test(command)) approve();
  if (!/\scommit(\s|$)/.test(command)) approve();

  const repoDir = resolveRepoDir(command, input);
  const docsOnly = isDocsOnlyStaged(repoDir);
  // WIP signal: `git -c workflow.wip=1 commit ...` skips ONLY user_verification.
  // run_tests, review_security, docs still fire. See docs/architecture/claude-code/workflow.md.
  const wipValues = parseGitConfigValues(command, "workflow.wip");
  const isWip = wipValues.some((v) => v === "1" || v.toLowerCase() === "true");

  // Gate 1 (issue #269): hard-block commits when tracked files have unstaged
  // working-tree changes. Docs-only short-circuit does NOT skip this — docs-only
  // staged + unstaged code is still a staging integrity violation (PR #767).
  // Skipped on isWip OR WORKTREE_OFF (recovery sessions bypass Gate 1 only;
  // WORKFLOW_OFF bypasses all gates via the early-return above).
  if (!isWip && !isWorktreeOff(sessionId)) {
    const unstagedResult = hasUnstagedTrackedChanges(repoDir);
    // Gate 1 fail-open on error (helper wrote stderr); CLI side is fail-safe.
    if (unstagedResult.error === null && unstagedResult.hasChanges) {
      const fileList = unstagedResult.files.map((f) => `  ${f}`).join("\n");
      block(
        [
          "workflow-gate: tracked-file modifications were not staged before commit.",
          `${unstagedResult.files.length} file(s) modified but not staged:`,
          fileList,
          "",
          "This usually means `git add` was skipped during the commit-push flow (see PR #767).",
          "",
          "Resolve by either:",
          "  - Stage the files: git add <file>",
          "  - Stash them: git stash push -u -- <file>",
          "  - Mark as WIP: git -c workflow.wip=1 commit -m \"...\"",
          "",
          "Emergency bypass (session-scoped): echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: <reason>>>\"",
        ].join("\n")
      );
    }
  }

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
    if (step === "docs" && (hasStagedDocChanges(repoDir) || hasWorktreeNotesDocEvidence(repoDir))) continue;
    incomplete.push(step);
  }

  if (incomplete.length === 0) approve();

  const SKILL_MAP = {
    workflow_init: '/workflow-init  OR for docs-only: echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"',
    clarify_intent: '/clarify-intent  OR if intent is clear: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    research: '/survey-code or /deep-research  OR if unnecessary: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    outline: '/make-outline-plan  OR if unnecessary: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    detail:  '/make-detail-plan   OR if unnecessary: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    branching_complete: 'consult rules/branch.md + rules/worktree.md, then: echo "<<WORKFLOW_BRANCHING_COMPLETE: main|branch: <name>|worktree: <path>>"',
    write_tests: '/write-tests (then git add tests/)  OR if unnecessary: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    run_tests: 'invoke `run-tests` skill via the Skill tool (emits sentinel automatically); or run tests directly via Bash — PostToolUse hook (workflow-run-tests.js) auto-marks based on exit code.',
    review_security: '/review-code-security  OR if unnecessary: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <reason>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    docs: '/update-docs (then either: git add docs/*.md / *.md, OR — inside a linked worktree — let /update-docs stage bullets into WORKTREE_NOTES.md ## History Notes / ## Changelog Notes per #436)',
    user_verification: 'ENFORCE_WORKTREE=on + linked worktree → SKIP (deferred to /worktree-end Step 4; premature emit without an open PR is hard-blocked by workflow-gate — see issue #577) | ENFORCE_WORKTREE=off or main worktree → emit immediately: echo "<<WORKFLOW_USER_VERIFIED: <reason>>>" (reason: >=3 non-space chars, no \'>\', not a placeholder) — set Bash description to "User verification: approve if implementation is complete — approving unlocks the commit gate."  (ask dialog IS the confirmation — do NOT wait for a prior text reply, do NOT use MARK_STEP)',
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

module.exports = { resolveRepoDir, hasStagedTestChanges, hasStagedDocChanges, hasWorktreeNotesDocEvidence, isWorktreeContext, isDocsOnlyStaged, resolveExternalDocsRepo, hasStagedChanges, hasUnstagedTrackedChanges, findAdditionalDirectories };
