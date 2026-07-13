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
  markStep,
  hasCompletionEvidence,
  getSkippableSteps,
} = require("./lib/workflow-state");

const { isMergeToProtectedCommand, getProtectedBranches } = require("./lib/merge-detect");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
const { readState: readSupervisorState, writeAuditState } = require("./lib/supervisor-state-writer");
const { resolveWorkflowSessionId } = require("./lib/resolve-workflow-session-id");
const { formatPreMergeBlockReason } = require("./lib/supervisor-report-format");
const { AUDIT_SEVERITY_THRESHOLD, SEVERITY_RANK } = require("./lib/supervisor-state-schema");

// Steps tracked by the workflow but not enforced at commit time.
const NON_GATE_STEPS = ["research", "pre_final_report_gate"];
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

// Resolve supervisor state with wsid fallback.
function resolveSupervisorState(sessionId) {
  try {
    let state = readSupervisorState(sessionId);
    if (state) return { state, effectiveSid: sessionId, wsid: null };
    const wsid = resolveWorkflowSessionId();
    if (wsid) {
      state = readSupervisorState(wsid);
      if (state) return { state, effectiveSid: wsid, wsid };
    }
    return { state: null, effectiveSid: sessionId, wsid: null };
  } catch (e) {
    return { state: null, effectiveSid: sessionId, wsid: null };
  }
}

// Resolve branch diff (changed files relative to the merge base with a protected branch).
function resolveBranchDiff(repoDir) {
  try {
    if (!repoDir) return null;
    const branches = getProtectedBranches();
    let mergeBase = null;
    for (const b of branches) {
      const r = spawnSync("git", ["merge-base", "origin/" + b, "HEAD"], { cwd: repoDir, encoding: "utf8" });
      if (r.status === 0 && r.stdout && r.stdout.trim()) {
        mergeBase = r.stdout.trim();
        break;
      }
    }
    if (!mergeBase) return null;
    const r = spawnSync("git", ["diff", "--name-only", mergeBase + "...HEAD"], { cwd: repoDir, encoding: "utf8" });
    if (r.status !== 0) return null;
    return (r.stdout || "").split("\n").map(p => p.trim().replace(/\\/g, "/")).filter(Boolean);
  } catch (e) {
    return null;
  }
}

// Parse declared "Files to modify" from the detail plan.
function parseDetailFilesToModify(plansDir, wsid) {
  try {
    if (!plansDir || !wsid) return null;
    const detailPath = path.join(plansDir, wsid + "-detail.md");
    let text;
    try { text = fs.readFileSync(detailPath, "utf8"); } catch (e) { return null; }
    const lines = text.split(/\r?\n/);
    let inSection = false;
    const paths = [];
    for (const line of lines) {
      if (line.trim() === "## Files to modify") { inSection = true; continue; }
      if (inSection && /^## /.test(line)) break;
      if (inSection) {
        const m = line.match(/`([^`]+)`/);
        if (m) paths.push(m[1].replace(/\\/g, "/"));
      }
    }
    return paths;
  } catch (e) {
    return null;
  }
}

// Returns true when the audit has seen all current findings (audit_last_run_at >= newest
// finding timestamp) and the verdict is non-BLOCK. A fresh non-BLOCK verdict means the
// audit already reviewed everything and approved or warned without blocking — so the
// warning-flush path should be skipped (#1374).
function isAuditVerdictFresh(auditState, alertFindings) {
  if (!auditState) return false;
  const verdict = auditState.audit_verdict;
  if (!verdict || verdict === "BLOCK") return false;
  const lastRunAt = auditState.audit_last_run_at;
  if (lastRunAt == null) return false;
  const lastRunMs = new Date(lastRunAt).getTime();
  if (Number.isNaN(lastRunMs)) return false;
  const findings = Array.isArray(alertFindings) ? alertFindings : [];
  if (findings.length === 0) return true;
  const newestFindingMs = Math.max(
    ...findings.map((f) => (f && f.timestamp ? new Date(f.timestamp).getTime() : 0))
  );
  return Number.isFinite(newestFindingMs) && lastRunMs >= newestFindingMs;
}

// Returns true only for BLOCK verdict — the one verdict that always gates the merge (#1374).
function shouldBlockOnAuditVerdict(auditState, alertFindings) {
  if (!auditState) return false;
  return auditState.audit_verdict === "BLOCK";
}

// Supervisor pre-merge gate: warning-flush and scope-drift checks.
// hookCwd: resolved cwd from the hook payload (toolInput.cwd) — allows
// resolveBranchDiff to target the actual repo being merged, not process.cwd().
function checkSupervisorPreMerge(sessionId, mergeKind, hookCwd) {
  try {
    const { state, effectiveSid, wsid } = resolveSupervisorState(sessionId);

    // Path (i): warning flush — block when cumSev >= threshold and findings exist.
    // Dual-store (C5): when CC UUID state has no alert findings, also check wsid state.
    // CC UUID state may be empty while a wsid session has active warnings.
    let alertState = state;
    let alertEffectiveSid = effectiveSid;
    let alertWsid = wsid;
    const ccHasFindings = state && state.alert &&
      Array.isArray(state.alert.findings) && state.alert.findings.length > 0;
    if (!ccHasFindings) {
      const wsidToTry = wsid || (() => {
        const env = process.env.WORKFLOW_SESSION_ID;
        if (env && /^[A-Za-z0-9_-]+$/.test(env)) return env;
        try { return resolveWorkflowSessionId(); } catch (_) { return null; }
      })();
      if (wsidToTry && wsidToTry !== sessionId) {
        const wsidState = readSupervisorState(wsidToTry);
        if (wsidState) { alertState = wsidState; alertEffectiveSid = wsidToTry; alertWsid = wsidToTry; }
      }
    }
    if (alertState) {
      const cumSev = alertState.alert && alertState.alert.cumulative_severity;
      const findings = (alertState.alert && Array.isArray(alertState.alert.findings) ? alertState.alert.findings : []);
      if (cumSev && SEVERITY_RANK[cumSev] >= SEVERITY_RANK[AUDIT_SEVERITY_THRESHOLD] && findings.length > 0) {
        const au = alertState.audit || {};
        const skip = au.audit_phase === "pending" || au.audit_phase === "in_progress" ||
          (au.audit_last_run_at != null && au.audit_cause === "pre-merge-warning-flush") ||
          isAuditVerdictFresh(au, findings);
        if (!skip) {
          try {
            writeAuditState(alertEffectiveSid, {
              audit_phase: "pending",
              audit_cause: "pre-merge-warning-flush",
              audit_armed_at: new Date().toISOString(),
              audit_retry_count: 0,
            });
          } catch (_) {}
          blockWithoutError(formatPreMergeBlockReason("warning-flush", sessionId, alertWsid, null, null, alertEffectiveSid));
        }
      }
    }

    // Path (i-b): BLOCK verdict always gates the merge, regardless of findings (#1374).
    // Non-BLOCK verdicts (WARN, CONTINUE) skip warning-flush via isAuditVerdictFresh above.
    if (alertState) {
      const auditState = alertState.audit || {};
      const findings = (alertState.alert && Array.isArray(alertState.alert.findings) ? alertState.alert.findings : []);
      if (shouldBlockOnAuditVerdict(auditState, findings)) {
        blockWithoutError(formatPreMergeBlockReason("audit-verdict:" + auditState.audit_verdict, sessionId, alertWsid, null, null, alertEffectiveSid));
      }
    }

    // Path (ii): scope-drift — block when branch diff contains undeclared files.
    // repoDir deferred here (not needed for Path (i)): resolveRepoDir(null, null)
    // calls parseGitCArg(null) which throws — deferring avoids the fail-open catch.
    const repoDir = hookCwd || resolveRepoDir(null, null);
    // Resolve wsid independently: resolveSupervisorState sets wsid only when state was
    // found via wsid fallback. When state was found via CC sessionId, wsid is null but
    // WORKFLOW_SESSION_ID env or resolveWorkflowSessionId() can still provide it.
    // Priority: wsid → WORKFLOW_SESSION_ID env (tests inject this) → WORKTREE_NOTES.md.
    const resolvedWsid = wsid || (() => {
      const env = process.env.WORKFLOW_SESSION_ID;
      if (env && /^[A-Za-z0-9_-]+$/.test(env)) return env;
      try { return resolveWorkflowSessionId(); } catch (_) { return null; }
    })();
    if (!resolvedWsid) return;
    const branchFiles = resolveBranchDiff(repoDir);
    if (!branchFiles) return;
    const plansDir = process.env.WORKFLOW_PLANS_DIR || require("os").homedir() + "/.workflow-plans";
    const declaredFiles = parseDetailFilesToModify(plansDir, resolvedWsid);
    if (!declaredFiles || declaredFiles.length === 0) return;

    const undeclared = branchFiles.filter(p => {
      return !declaredFiles.some(d => p === d || p.startsWith(d.endsWith("/") ? d : d + "/"));
    });

    const au = (state && state.audit) || {};
    const skipDrift = au.audit_phase === "pending" || au.audit_phase === "in_progress" ||
      (au.audit_last_run_at != null && au.audit_cause === "scope-drift:pre-merge");
    // Arm audit unconditionally on first merge (pre-merge review cycle).
    // Block only when undeclared files are present (scope drift detected).
    if (!skipDrift && branchFiles.length > 0) {
      try {
        writeAuditState(effectiveSid, {
          audit_phase: "pending",
          audit_cause: "scope-drift:pre-merge",
          audit_armed_at: new Date().toISOString(),
          audit_retry_count: 0,
        });
      } catch (_) {}
      if (undeclared.length > 0) {
        blockWithoutError(formatPreMergeBlockReason("scope-drift:pre-merge", sessionId, resolvedWsid, null, null, effectiveSid));
      }
    }
  } catch (e) {
    // fail-open
  }
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

  // EARLY GATE: 2-tier enforcement before Edit/Write tools.
  //   Tier 1: workflow_init must be complete/skipped first.
  //   Tier 2: clarify_intent must be complete/skipped (only checked once Tier 1 clears).
  // Fail-open precedence (do NOT reorder):
  //   1. No sessionId → fall through (cannot enforce)
  //   2. readState() returns null → fall through (no state to check)
  //   3. plans-path Write/Edit/MultiEdit allowlist → fall through (skill output path)
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
      // Plans-path allowlist: Write/Edit/MultiEdit tools, targeting ~/.workflow-plans/**
      // (skill writes intent/outline/detail .md here while workflow_init is still pending).
      // Resolve the path so traversal sequences like "../" can't smuggle the write outside.
      const filePath = toolInput.file_path || toolInput.path || "";
      let isPlansAllowed = false;
      if ((toolName === "Write" || toolName === "Edit" || toolName === "MultiEdit") && filePath) {
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
            "To reset workflow state: echo \"<<WORKFLOW_RESET_FROM_workflow_init: {reason}>>\""
          );
        }
        // Tier 2: clarify_intent (only reached once workflow_init has cleared)
        const ci = earlyState.steps && earlyState.steps.clarify_intent;
        const ciStatus = ci ? ci.status : "pending";
        if (ciStatus !== "complete" && ciStatus !== "skipped") {
          // Evidence-based self-repair (#1094): if intent.md already exists,
          // mark clarify_intent complete and fall through (gate clears) instead
          // of hard-blocking. fail-open: markStep error leaves the gate dormant.
          if (hasCompletionEvidence("clarify_intent", sessionId)) {
            try { markStep(sessionId, "clarify_intent", "complete"); } catch (e) { /* fail-open */ }
          } else {
          block(
            "workflow-gate: clarify_intent has not been completed for this session.\n" +
            "Tool \"" + toolName + "\" is blocked until intent is locked in.\n\n" +
            "To complete:\n" +
            "  1. Invoke the `clarify-intent` skill via the Skill tool, OR\n" +
            "  2. If intent is already clear: echo \"<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {reason}>>>\".\n\n" +
            "Note: Read, Grep, Glob, Bash, and AskUserQuestion remain available.\n" +
            "For docs-only edits: echo \"<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: docs-only edit>>\"\n\n" +
            "To reset workflow state: echo \"<<WORKFLOW_RESET_FROM_clarify_intent: {reason}>>\""
          );
          }
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
    checkSupervisorPreMerge(sessionId, mergeHit.kind, normalizeForWindows(toolInput.cwd));
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

  // Check all steps
  const incomplete = [];
  // Annotates entries pushed to `incomplete` — currently used for review_tests
  // stale-token / no-staged-tests messaging (issue #833).
  const incompleteReasons = {};
  // Tracks whether write_tests was bypassed by evidence (staged tests/) in this
  // gate evaluation. Used to allow symmetric review_tests bypass (issue #833):
  // when write_tests itself needs evidence, review_tests should share it.
  let writeTestsEvidenceBypassed = false;
  // Session-specific skippable steps: BUGFIX sessions exclude write_tests/review_tests (#1147).
  const skippable = getSkippableSteps(sessionId);
  for (const step of VALID_STEPS) {
    if (NON_GATE_STEPS.includes(step)) continue;
    const stepState = state.steps && state.steps[step];
    const status = stepState ? stepState.status : "pending";

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
    if (status === "skipped" && skippable.includes(step)) continue;
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
    // Evidence-based overrides: staged files are proof of completion
    if (step === "write_tests" && hasStagedTestChanges(repoDir)) {
      writeTestsEvidenceBypassed = true;
      continue;
    }
    if (step === "docs" && (hasStagedDocChanges(repoDir) || hasWorktreeNotesDocEvidence(repoDir))) continue;
    incomplete.push(step);
  }

  if (incomplete.length === 0) approve();

  const SKILL_MAP = {
    workflow_init: '/workflow-init  OR for docs-only: echo "<<WORKFLOW_MARK_STEP_workflow_init_complete>>"',
    clarify_intent: '/clarify-intent  OR if intent is clear: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    research: '/survey-code or /deep-research  OR if unnecessary: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    outline: '/make-outline-plan  OR if unnecessary: echo "<<WORKFLOW_OUTLINE_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    detail:  '/make-detail-plan   OR if unnecessary: echo "<<WORKFLOW_DETAIL_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    branching_complete: 'consult rules/branch.md + rules/worktree.md, then: echo "<<WORKFLOW_BRANCHING_COMPLETE: main|branch: {name}|worktree: {path}>>"',
    write_tests: '/write-tests (then git add tests/)  OR if unnecessary: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: {reason}>>" (reason: >=3 non-space chars, no \'>\', not a placeholder)',
    review_tests: '/review-tests skill (emits <<WORKFLOW_REVIEW_TESTS_COMPLETE: token={hex}>> on adequate coverage; re-editing tests/ after a passing review invalidates the pairing — re-run /review-tests)',
    run_tests: 'invoke `run-tests` skill via the Skill tool (emits sentinel automatically); or run `bash tests/run-all.sh <files>` directly — the PostToolUse hook (workflow-run-tests.js) marks complete only from its RUN_CONTRACT line. Ad-hoc test commands (e.g. `pytest tests/`) no longer auto-complete: they demote run_tests to pending.',
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
