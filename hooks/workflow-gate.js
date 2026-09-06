#!/usr/bin/env node
// Claude Code PreToolUse hook: enforce workflow step completion before git commit
// Replaces check-tests-updated.js and check-docs-updated.js

const fs = require("fs");
const path = require("path");
const {
  VALID_STEPS,
  SKIPPABLE_STEPS,
  readState,
  getSkippableSteps,
  reconcileEffectiveState,
} = require("./workflow-state");

const { isMergeToProtectedCommand } = require("./lib/merge-detect");

// Steps tracked by the workflow but not enforced at commit time.
// `final_report` is a TERMINAL step (SSOT: state-io TERMINAL_STEPS) recorded
// AFTER the commit it would otherwise gate — demanding it here would make every
// commit unreachable.
const NON_GATE_STEPS = ["research", "pre_final_report_gate", "final_report"];
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
  isAgentsSessionRepo,
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

function block(reason, extras = undefined) {
  try {
    const { reportBlock } = require("./lib/supervisor-emit");
    // Axis A (#885): if no explicit extras passed but the parsed context has
    // a cwd we recorded, use it as a minimum extras payload so the supervisor
    // state finding always carries context.cwd (and git_root_resolved when
    // repoDir has been resolved).
    let effExtras = extras;
    if (effExtras === undefined) {
      if (_gateReportCtx.cwd !== undefined) {
        const ctx = { cwd: _gateReportCtx.cwd };
        if (_gateReportCtx.repoResolved !== undefined) {
          ctx.git_root_resolved = !!_gateReportCtx.repoResolved;
        }
        effExtras = { context: ctx };
      } else {
        effExtras = {};
      }
    }
    reportBlock("workflow-gate", _gateReportCtx.command || _gateReportCtx.toolName || "<unknown>", _gateReportCtx.sessionId, effExtras);
  } catch (_) { /* fail-open */ }
  try {
    const { recordGateBlock } = require("./workflow-gate/handoff-record");
    recordGateBlock(_gateReportCtx.sessionId, reason, { command: _gateReportCtx.command });
  } catch (_) { /* fail-open: a lost breadcrumb must never change the verdict */ }
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Populated at hook-input parse time so block() can self-report.
let _gateReportCtx = { sessionId: undefined, command: undefined, toolName: undefined, cwd: undefined };

// Block without recording a supervisor L1 finding (used for supervisor pre-merge gates).
function blockWithoutError(reason) {
  console.log(JSON.stringify({ decision: "block", reason }));
  process.exit(0);
}

// Supervisor pre-merge gate (warning-flush / audit-verdict / scope-drift):
// hooks/workflow-gate/supervisor-check.js. blockWithoutError is injected at the
// call site so the module stays free of this hook's stdout protocol.
const {
  checkSupervisorPreMerge,
  parseDetailFilesToModify,
  shouldBlockOnAuditVerdict,
  isAuditVerdictFresh,
} = require("./workflow-gate/supervisor-check");
const { runEarlyGate } = require("./workflow-gate/early-gate");

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
  _gateReportCtx = {
    sessionId,
    command: toolInput.command,
    toolName,
    cwd: typeof toolInput.cwd === "string" ? toolInput.cwd : undefined,
    repoResolved: undefined,
  };

  // WORKFLOW_OFF: bypass all workflow-gate checks (superset of WORKTREE_OFF per workflow-off.md).
  const { isWorkflowOff, isWorktreeOff } = require("./lib/session-markers");
  if (isWorkflowOff(sessionId)) approve();

  // EARLY GATE: 3-tier enforcement before Edit/Write tools (workflow_init /
  // clarify_intent / worktree-entry). Owned by workflow-gate/early-gate.js;
  // block() is injected so the module stays free of this hook stdout protocol.
  runEarlyGate(input, { block });

  if (toolName !== "Bash") approve();

  const command = toolInput.command || "";
  if (!command) approve();

  // SENTINEL CHAIN GUARD (closes #382): reject `<<WORKFLOW_*>> && <non-sentinel>` chains.
  // Predicts what workflow-mark.js (PostToolUse) silently drops — it splits on /\s*&&\s*/ and
  // applies #110 all-or-nothing, so every part must match isSentinel() or none are processed —
  // and surfaces that as a PreToolUse error instead. drop-predict := (split has >1 part) AND
  // (not every part isSentinel) AND (a real sentinel echo form is present); the last conjunct
  // keeps incidental `<<WORKFLOW_` substrings (e.g. `grep '<<WORKFLOW_' file && wc -l`) out.
  // Quote convention parity: CHAIN_BOUNDARY_SENTINEL_*_RE mirror isSentinel() exactly — DQ for
  // every category, SQ only for MARK_STEP_* (matching MARKER_RE_SQ). Accepting SQ everywhere
  // would block chains workflow-mark.js treats as non-sentinel (bare-form USER_VERIFIED,
  // retained as a historical attack-vector example per #404), creating a new asymmetry.
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
        "Emergency bypass: echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>\"\n" +
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
        'Run: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" first (reason: >=3 non-space chars, no \'>\', not a placeholder).'
      );
    }
    const mergeState = readState(sessionId);
    if (!mergeState) {
      block(
        "workflow-gate: merge to protected branch blocked — no workflow state.\n" +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" first (reason: >=3 non-space chars, no \'>\', not a placeholder).'
      );
    }
    const uv = mergeState.steps && mergeState.steps.user_verification;
    const uvStatus = uv ? uv.status : "missing";
    if (uvStatus !== "complete") {
      block(
        `workflow-gate: ${mergeHit.kind} blocked — user_verification is "${uvStatus}".\n\n` +
        'Run: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>"\n' +
        '(reason: >=3 non-space chars, no \'>\', not a placeholder; ' +
        'set Bash description: "User verification: approve if implementation is complete — approving unlocks the merge gate.")'
      );
    }
    checkSupervisorPreMerge(sessionId, mergeHit.kind, normalizeForWindows(toolInput.cwd), {
      blockFn: blockWithoutError,
      resolveRepoDirFn: resolveRepoDir,
    });
    approve();
  }

  if (!/^git\s/.test(command)) approve();
  if (!/\scommit(\s|$)/.test(command)) approve();

  const repoDir = resolveRepoDir(command, input);
  // Axis A (#885): record git_root_resolved for late-block extras.
  _gateReportCtx.repoResolved = !!repoDir;

  // Cross-repo bypass (#1138): skip agents workflow-state enforcement when the
  // commit targets a repo that is NOT the agents session repo. Fail-closed:
  // isAgentsSessionRepo() returns true on error, keeping enforcement in place.
  if (!isAgentsSessionRepo(repoDir)) approve();

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
          "Emergency bypass (session-scoped): echo \"<<WORKFLOW_ENFORCE_WORKFLOW_OFF: {reason}>>>\"",
        ].join("\n")
      );
    }
  }

  // Gate 3 (issue #1642): prompt extraction — §1.5 code fences and §1.3 inline
  // procedures in staged prompt files. bin/check-prompt-extraction --staged owns
  // detection and the allowlist ratchet (CPR-SSOT); this call site maps exit 1 -> block.
  //
  // Ordered BEFORE Gate 2 deliberately: Gate 3 self-limits to repos that carry a
  // .prompt-extraction-allowlist, so it stays silent everywhere it does not apply,
  // whereas Gate 2 applies repo-wide. Running the narrower gate first means an
  // infrastructure failure is reported by the gate that actually owns the repo.
  {
    const { checkPromptExtraction } = require("./workflow-gate/prompt-extraction-gate");
    const extractionVerdict = checkPromptExtraction(repoDir);
    if (extractionVerdict.action === "block") block(extractionVerdict.reason);
  }

  // Gate 2 (issue #1701): HARD file-size limit. bin/review-code-size --staged owns the
  // thresholds and line counting (CPR-SSOT); this call site only maps exit 1 -> block.
  {
    const { checkCodeSizeHardLimit } = require("./workflow-gate/code-size-gate");
    const sizeVerdict = checkCodeSizeHardLimit(repoDir);
    if (sizeVerdict.action === "block") block(sizeVerdict.reason);
  }

  // session_id is required — fail-safe if missing
  if (!sessionId) {
    block(
      "workflow-gate: session_id not found in hook input.\n" +
        "Cannot verify workflow state. Commit blocked (fail-safe).\n" +
        "To reset workflow state, run:\n" +
        '  echo "<<WORKFLOW_RESET_FROM_research: {reason}>>"'
    );
  }

  const state = readState(sessionId);

  if (!state) {
    block(
      `workflow-gate: no workflow state found for session ${sessionId}.\n` +
        "Commit blocked (fail-safe). To initialize workflow state, run:\n" +
        '  echo "<<WORKFLOW_RESET_FROM_research: {reason}>>"'
    );
  }

  // Derived view for the commit gate (#1681). resolveAll:true — every gated step
  // must be judged, not just those up to the current one. evidencePolicy
  // "staged-only" reproduces the gate's historical write_tests rule (staged
  // tests/ only; the post-merge committed-tests fallback must not satisfy a
  // commit-time gate). A veto-de-skipped or post-veto-reset step reads as
  // `pending` here and therefore blocks the commit.
  // Fail-open: on snapshot failure fall back to the raw record.
  let commitSnapshot = null;
  try {
    commitSnapshot = reconcileEffectiveState(state, sessionId, {
      repoDir,
      isWfMeta: state.workflow_type === "wf-meta",
      resolveAll: true,
      evidencePolicy: "staged-only",
    });
  } catch (e) { commitSnapshot = null; }

  // Check all steps
  const incomplete = [];
  // Annotates entries pushed to `incomplete` — currently used for review_tests
  // stale-token / no-staged-tests messaging (issue #833).
  const incompleteReasons = {};
  // Session-specific skippable steps: BUGFIX sessions exclude write_tests/review_tests (#1147).
  const skippable = getSkippableSteps(sessionId);
  // Tracks whether write_tests was bypassed by evidence (staged tests/) in this
  // gate evaluation. Used to allow symmetric review_tests bypass (issue #833).
  // Case 1: snapshot resolved write_tests from staged evidence (pending → evidenced).
  // Case 2: BUGFIX+skipped — write_tests excluded from skippable but staged tests/
  //         exist; staged evidence bypasses the block symmetrically (#1147 C11).
  const writeTestsEvidenceBypassed = (function () {
    const snapshotWt = commitSnapshot && commitSnapshot.steps && commitSnapshot.steps.write_tests;
    if (snapshotWt && snapshotWt.resolved_from === "evidence") return true;
    if (
      snapshotWt && snapshotWt.status === "skipped" &&
      !skippable.includes("write_tests") &&
      hasStagedTestChanges(repoDir)
    ) return true;
    return false;
  }());
  for (const step of VALID_STEPS) {
    if (NON_GATE_STEPS.includes(step)) continue;
    const stepState = state.steps && state.steps[step];
    const status = (commitSnapshot && commitSnapshot.steps && commitSnapshot.steps[step])
      ? commitSnapshot.steps[step].status
      : (stepState ? stepState.status : "pending");

    // --- review_tests special-case (delegated to review-tests-checker.js) ---
    if (step === "review_tests") {
      const { checkReviewTests } = require("./workflow-gate/review-tests-checker");
      const rt = checkReviewTests(step, stepState, { docsOnly, writeTestsEvidenceBypassed, repoDir, sessionId });
      if (rt.action === "skip") continue;
      if (rt.action === "block") {
        if (rt.reason) incompleteReasons[step] = rt.reason;
        incomplete.push(step);
        continue;
      }
    }

    if (status === "complete") continue;
    if (status === "skipped" && skippable.includes(step)) {
      // H1 (TOCTOU hardening): a recorded run_tests=skipped was only proven
      // docs-only at the moment the skip sentinel/advance was emitted. Nothing
      // demotes it if the staged set later grows to include non-docs files, so
      // re-verify the CURRENT staged set (docsOnly, computed above from the
      // same repoDir) before honoring the skip here. Scoped to run_tests only —
      // the other SKIPPABLE_STEPS have no staged-set-dependent legitimacy
      // condition (CPR-UNV: isolate the special case, don't widen the general path).
      if (step !== "run_tests" || docsOnly) continue;
      // else: fall through — treated the same as an unmet run_tests requirement.
    }
    // BUGFIX: write_tests skipped (excluded from skippable) but bypassed by staged tests/ evidence.
    if (step === "write_tests" && writeTestsEvidenceBypassed) continue;
    // docs-only short-circuit: skip all steps except user_verification
    if (docsOnly && step !== "user_verification") continue;
    // Worktree context: defer user_verification to merge-time gate.
    // Feature-branch commits/pushes are intermediate; verification fires
    // at gh pr merge / git push :main instead (see merge gate above).
    if (step === "user_verification" && isWorktreeContext(repoDir)) continue;
    if (step === "user_verification" && isWip) continue;
    // #1112: defer cleanup to /worktree-end boundary; intermediate worktree
    // commits must not be blocked by a pending cleanup step.
    if (step === "cleanup" && isWorktreeContext(repoDir)) continue;
    // Evidence-based overrides for write_tests are no longer inline: the snapshot
    // above already resolves pending write_tests (evidencePolicy "staged-only").
    // The skipped+BUGFIX case is handled by the writeTestsEvidenceBypassed check above.
    incomplete.push(step);
  }

  if (incomplete.length === 0) approve();

  const SKILL_MAP = {
    workflow_init: '/workflow-init  OR for docs-only: echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"',
    clarify_intent: '/clarify-intent  OR if intent is clear: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    research: '/survey-code or /deep-research  OR if unnecessary: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    outline: '/make-outline-plan  OR if unnecessary: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    detail:  '/make-detail-plan   OR if unnecessary: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    branching_complete: 'Read rules/branch.md + rules/worktree.md (on-demand-only), then: echo "<<WORKFLOW_BRANCHING_COMPLETE: main|branch: {name}|worktree: {path}>>"',
    write_tests: '/write-tests (then git add tests/)  OR if unnecessary: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    review_tests: '/review-tests skill (emits <<WORKFLOW_REVIEW_TESTS_COMPLETE: token={hex}>> on adequate coverage; re-editing tests/ after a passing review invalidates the pairing — re-run /review-tests)',
    run_tests: 'invoke `run-tests` skill via the Skill tool (emits sentinel automatically); or run `bash tests/run-all.sh <files>` directly — the PostToolUse hook (workflow-run-tests.js) marks complete only from its RUN_CONTRACT line. Ad-hoc test commands (e.g. `pytest tests/`) no longer auto-complete: they demote run_tests to pending. When every staged file is human-facing documentation: echo "<<WORKFLOW_RUN_TESTS_NOT_NEEDED: {reason}>>" (rejected otherwise).',
    review_security: '/review-code-security  OR if unnecessary: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    docs: '/update-docs (then either: git add docs/*.md / *.md, OR — inside a linked worktree — let /update-docs stage bullets into WORKTREE_NOTES.md ## History Notes / ## Changelog Notes per #436)',
    user_verification: 'ENFORCE_WORKTREE=on + linked worktree → SKIP (deferred to /worktree-end Step 4; premature emit without an open PR is hard-blocked by workflow-gate — see issue #577) | ENFORCE_WORKTREE=off or main worktree → emit immediately: echo "<<WORKFLOW_USER_VERIFIED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder) — set Bash description to "User verification: approve if implementation is complete — approving unlocks the commit gate."  (ask dialog IS the confirmation — do NOT wait for a prior text reply, do NOT use MARK_STEP)',
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
    if (step === "review_tests" && incompleteReasons[step] === "stale-token") {
      lines.push(
        "    (note: tests were re-edited after a passing review — staged-tests fingerprint changed; re-run /review-tests)"
      );
    }
    if (step === "review_tests" && incompleteReasons[step] === "stale-wsid") {
      lines.push(
        "    (note: stale-wsid — workflow session ID (wsid) changed since /review-tests was run; re-run /review-tests in the current session)"
      );
    }
    if (step === "review_tests" && incompleteReasons[step] === "warnings-pending") {
      lines.push(
        "    (note: /review-tests reported coverage warnings — re-run /write-tests to address gaps, then /review-tests again)"
      );
    }
  }

  block(lines.join("\n"));
}

module.exports = { resolveRepoDir, hasStagedTestChanges, hasStagedDocChanges, hasWorktreeNotesDocEvidence, isWorktreeContext, isDocsOnlyStaged, resolveExternalDocsRepo, hasStagedChanges, hasUnstagedTrackedChanges, findAdditionalDirectories, parseDetailFilesToModify, checkSupervisorPreMerge, shouldBlockOnAuditVerdict, isAuditVerdictFresh };
