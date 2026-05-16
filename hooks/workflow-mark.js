#!/usr/bin/env node
// Claude Code PostToolUse hook: intercept workflow markers from skill completions
//
// Supported markers (each marker must be a standalone echo, but multiple markers
// may be chained with ` && ` in a single Bash command — each part is evaluated
// independently):
//   echo "<<WORKFLOW_MARK_STEP_<step>_<status>>>"   — mark a step
//   echo "<<WORKFLOW_RESET_FROM_<step>>>"            — reset state from a step
//   echo "<<WORKFLOW_USER_VERIFIED>>"                — record user verification
//   echo "<<WORKFLOW_{RESEARCH,PLAN,WRITE_TESTS}_NOT_NEEDED: <reason>>"
//
// Bypasses CLAUDE_ENV_FILE propagation issue in Bash subprocesses (Anthropic bug #27987).
//   echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF[: <reason>]>>"  — session-scoped ENFORCE_WORKTREE bypass
//   echo "<<WORKFLOW_ENFORCE_WORKTREE_ON>>"               — restore enforcement (delete marker)

const fs = require("fs");
const path = require("path");
const {
  VALID_STEPS,
  resolveSessionId,
  markStep,
  createInitialState,
  writeState,
  nextStepHint,
  setLastPushedSha,
  setPremiseContradiction,
  clearPremiseContradiction,
  getWorkflowDir,
} = require("./lib/workflow-state");
const { isMergeToProtectedCommand } = require("./lib/merge-detect");

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

// Strict anchored regex: each sub-command must be exactly this echo.
// Rejects pipes, ;, redirects, prefixed cd, printf, etc. by construction.
// Chained `&&` is handled at the splitter layer — each part is matched individually.
const MARKER_RE_DQ =
  /^echo\s+"<<WORKFLOW_MARK_STEP_([a-z_]+)_(complete|skipped|pending|in_progress)>>"$/;
const MARKER_RE_SQ =
  /^echo\s+'<<WORKFLOW_MARK_STEP_([a-z_]+)_(complete|skipped|pending|in_progress)>>'$/;
const RESET_FROM_RE_DQ = /^echo\s+"<<WORKFLOW_RESET_FROM_([a-z_]+)>>"$/;
// USER_VERIFIED: DQ only, single literal space, strictly anchored — matches settings.json ask glob exactly
const USER_VERIFIED_RE_DQ = /^echo "<<WORKFLOW_USER_VERIFIED>>"$/;
const RESEARCH_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ([^>]+)>>"$/;
const RESEARCH_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_RESEARCH_NOT_NEEDED([: ].*)?>>"$/;
const PLAN_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_PLAN_NOT_NEEDED: ([^>]+)>>"$/;
const PLAN_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_PLAN_NOT_NEEDED([: ].*)?>>"$/;
const WRITE_TESTS_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: ([^>]+)>>"$/;
const WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED([: ].*)?>>"$/;
const REVIEW_SECURITY_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: ([^>]+)>>"$/;
const REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED([: ].*)?>>"$/;
// Looks-like fallback for removed DOCS_NOT_NEEDED — catches attempts and emits deprecation message.
const DOCS_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_DOCS_NOT_NEEDED([: ].*)?>>"$/;
const CLARIFY_INTENT_NOT_NEEDED_RE_DQ = /^echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: ([^>]+)>>"$/;
const CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED([: ].*)?>>"$/;
const CLARIFY_INTENT_COMPLETE_RE_DQ = /^echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"$/;
// New sentinel (preferred); old BRANCHING_DECIDED accepted for backward compat.
const BRANCHING_COMPLETE_RE_DQ = /^echo "<<WORKFLOW_BRANCHING_COMPLETE: ([^>]+)>>"$/;
const BRANCHING_COMPLETE_LOOKSLIKE_RE = /^echo "<<WORKFLOW_BRANCHING_COMPLETE([: ].*)?>>"$/;
const BRANCHING_DECIDED_RE_DQ = /^echo "<<WORKFLOW_BRANCHING_DECIDED: ([^>]+)>>"$/;
const BRANCHING_DECIDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_BRANCHING_DECIDED([: ].*)?>>"$/;
const PREMISE_FAIL_RE_DQ = /^echo "<<WORKFLOW_PREMISE_FAIL: ([^>]+)>>"$/;
const PREMISE_FAIL_LOOKSLIKE_RE = /^echo "<<WORKFLOW_PREMISE_FAIL([: ].*)?>>"$/;
const PREMISE_ACK_RE_DQ = /^echo "<<WORKFLOW_PREMISE_ACK>>"$/;
const PREMISE_ACK_LOOKSLIKE_RE = /^echo "<<WORKFLOW_PREMISE_ACK([: ].*)?>>"$/;
const ENFORCE_WORKTREE_OFF_RE_DQ =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF(?:: ([^>]+))?>>"$/;
const ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF([: ].*)?>>"$/;
const ENFORCE_WORKTREE_ON_RE_DQ =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_ON>>"$/;
const ENFORCE_WORKTREE_ON_LOOKSLIKE_RE =
  /^echo "<<WORKFLOW_ENFORCE_WORKTREE_ON([: ].*)?>>"$/;

function isSentinel(cmd) {
  return (
    MARKER_RE_DQ.test(cmd) ||
    MARKER_RE_SQ.test(cmd) ||
    RESET_FROM_RE_DQ.test(cmd) ||
    USER_VERIFIED_RE_DQ.test(cmd) ||
    RESEARCH_NOT_NEEDED_RE_DQ.test(cmd) ||
    RESEARCH_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    PLAN_NOT_NEEDED_RE_DQ.test(cmd) ||
    PLAN_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    WRITE_TESTS_NOT_NEEDED_RE_DQ.test(cmd) ||
    WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    REVIEW_SECURITY_NOT_NEEDED_RE_DQ.test(cmd) ||
    REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    DOCS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    CLARIFY_INTENT_NOT_NEEDED_RE_DQ.test(cmd) ||
    CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE.test(cmd) ||
    CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd) ||
    BRANCHING_COMPLETE_RE_DQ.test(cmd) ||
    BRANCHING_COMPLETE_LOOKSLIKE_RE.test(cmd) ||
    BRANCHING_DECIDED_RE_DQ.test(cmd) ||
    BRANCHING_DECIDED_LOOKSLIKE_RE.test(cmd) ||
    PREMISE_FAIL_RE_DQ.test(cmd) ||
    PREMISE_FAIL_LOOKSLIKE_RE.test(cmd) ||
    PREMISE_ACK_RE_DQ.test(cmd) ||
    PREMISE_ACK_LOOKSLIKE_RE.test(cmd) ||
    ENFORCE_WORKTREE_OFF_RE_DQ.test(cmd) ||
    ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE.test(cmd) ||
    ENFORCE_WORKTREE_ON_RE_DQ.test(cmd) ||
    ENFORCE_WORKTREE_ON_LOOKSLIKE_RE.test(cmd)
  );
}

const SKIP_REASON_DUDS = new Set([
  "none", "n/a", "na", "nope", "no", "nothing",
  "skip", "skipped", "not needed", "not required", "nil",
  "スキップ", "スキップする", "省略する", "特になし", "無し",
]);
function validateSkipReason(raw) {
  const trimmed = (raw || "").trim();
  const nonSpace = trimmed.replace(/\s+/g, "");
  if (nonSpace.length < 3) {
    return { ok: false, msg: "reason too short — provide at least 3 non-space characters explaining why this step is unnecessary in this task's context." };
  }
  if (SKIP_REASON_DUDS.has(trimmed.toLowerCase())) {
    return { ok: false, msg: `reason "${trimmed}" is a placeholder — explain why this step is unnecessary in this task's context.` };
  }
  if (/^(.)\1+$/u.test(nonSpace)) {
    return { ok: false, msg: "reason is a single repeated character — provide a real explanation." };
  }
  return { ok: true, reason: trimmed };
}

function done(additionalContext) {
  const out = additionalContext ? { additionalContext } : {};
  console.log(JSON.stringify(out));
  process.exit(0);
}

let input;
try {
  input = JSON.parse(readStdin());
} catch (e) {
  done(); // fail-open on malformed stdin
}

// Only handle Bash tool
if (input.tool_name !== "Bash") done();

const command = ((input.tool_input && input.tool_input.command) || "").trim();

// Hoist: needed by push-reset below and by sentinel logic further down.
const toolResponse = input.tool_response || {};
const exitCode =
  toolResponse.exit_code ??
  toolResponse.exitCode ??
  (toolResponse.success === false ? 1 : 0);
const sessionId = input.session_id || resolveSessionId();

// Reset user_verification only after a successful merge-class operation
// (push to a protected branch / gh pr merge). Feature-branch pushes leave
// verification state alone so the upcoming gh pr merge gate can pass.
//
// Order: pre-push gate (workflow-gate requires uv=complete) → push runs →
//   post-push (this hook resets uv to pending, stores sha for protected push)
//   → next user prompt → post-push-workflow-reset.js (sha change resets
//   branching_decision).
const mergeResult = isMergeToProtectedCommand(command);
if (mergeResult.hit) {
  let msg;
  if (exitCode === 0 && sessionId) {
    if (mergeResult.kind === "git-push-protected") {
      msg = "workflow-mark: protected push detected — user_verification reset to pending.";
      try { markStep(sessionId, "user_verification", "pending"); }
      catch (e) { msg = `workflow-mark: protected push detected — user_verification reset FAILED: ${e.message}`; }
      // Record last_pushed_sha for post-push-workflow-reset hook.
      try {
        const { execSync } = require("child_process");
        const { resolveRepoCwd } = require("./lib/path-normalize");
        const { readState } = require("./lib/workflow-state");
        const state = readState(sessionId);
        const repoCwd = resolveRepoCwd({
          command, input, stateCwd: state && state.cwd,
        });
        const sha = execSync("git rev-parse HEAD", {
          cwd: repoCwd, encoding: "utf8", timeout: 2000,
        }).trim();
        if (/^[0-9a-f]{40}$/.test(sha)) {
          setLastPushedSha(sessionId, sha);
        }
      } catch (e) { /* Fail-open */ }
    } else {
      // gh pr merge: reset verification but do not record a sha
      // (no local push happened in this command).
      msg = "workflow-mark: gh pr merge detected — user_verification reset to pending.";
      try { markStep(sessionId, "user_verification", "pending"); }
      catch (e) { msg = `workflow-mark: gh pr merge detected — user_verification reset FAILED: ${e.message}`; }
    }
    done(msg);
  }
  done();
}

// Feature-branch pushes (and other git pushes that don't target a protected
// branch) intentionally fall through — no state mutation. This lets the same
// session push WIP commits repeatedly without re-running user_verification.

// Split on `&&` so multiple sentinel echos chained in one Bash call are all processed.
// All-or-nothing: if any part is NOT a sentinel (e.g. `cd /tmp`, arbitrary shell
// commands), reject the whole command. This preserves the security property that a
// sentinel prefixed with untrusted commands does not update state.
const commandParts = command
  .split(/\s*&&\s*/)
  .map((s) => s.trim())
  .filter(Boolean);
if (commandParts.length === 0) done();
const allAreSentinels = commandParts.every(isSentinel);
if (!allAreSentinels) done(); // prefix-chained or mixed-content command — reject
const sentinelParts = commandParts;

if (exitCode !== 0) {
  done(
    `workflow-mark: echo exited ${exitCode} — ${sentinelParts.length} sentinel operation(s) NOT applied.`
  );
}

// Accumulate per-part messages; emit them together at end.
const messages = [];

for (const cmd of sentinelParts) {
  const markMatch = cmd.match(MARKER_RE_DQ) || cmd.match(MARKER_RE_SQ);
  const resetMatch = cmd.match(RESET_FROM_RE_DQ);
  const userVerifiedMatch = cmd.match(USER_VERIFIED_RE_DQ);
  const researchNotNeededMatch = cmd.match(RESEARCH_NOT_NEEDED_RE_DQ);
  const researchNotNeededLooksLike =
    !researchNotNeededMatch && RESEARCH_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const planNotNeededMatch = cmd.match(PLAN_NOT_NEEDED_RE_DQ);
  const planNotNeededLooksLike =
    !planNotNeededMatch && PLAN_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const writeTestsNotNeededMatch = cmd.match(WRITE_TESTS_NOT_NEEDED_RE_DQ);
  const writeTestsNotNeededLooksLike =
    !writeTestsNotNeededMatch && WRITE_TESTS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const reviewSecurityNotNeededMatch = cmd.match(REVIEW_SECURITY_NOT_NEEDED_RE_DQ);
  const reviewSecurityNotNeededLooksLike =
    !reviewSecurityNotNeededMatch && REVIEW_SECURITY_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const docsNotNeededLooksLike = DOCS_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  const clarifyIntentNotNeededMatch = cmd.match(CLARIFY_INTENT_NOT_NEEDED_RE_DQ);
  const clarifyIntentNotNeededLooksLike = !clarifyIntentNotNeededMatch && CLARIFY_INTENT_NOT_NEEDED_LOOKSLIKE_RE.test(cmd);
  // Accept both new (BRANCHING_COMPLETE) and legacy (BRANCHING_DECIDED) sentinel.
  const branchingDecidedMatch =
    cmd.match(BRANCHING_COMPLETE_RE_DQ) || cmd.match(BRANCHING_DECIDED_RE_DQ);
  const branchingDecidedLooksLike =
    !branchingDecidedMatch &&
    (BRANCHING_COMPLETE_LOOKSLIKE_RE.test(cmd) || BRANCHING_DECIDED_LOOKSLIKE_RE.test(cmd));

  // --- RESEARCH_NOT_NEEDED handler ---
  if (researchNotNeededLooksLike) {
    messages.push(
      `workflow-mark: malformed RESEARCH_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (researchNotNeededMatch) {
    const v = validateSkipReason(researchNotNeededMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: RESEARCH_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: <better reason>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — research NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ${v.reason}>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "research", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("research");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. research NOT recorded.`
      );
    }
    continue;
  }

  // --- PLAN_NOT_NEEDED handler ---
  if (planNotNeededLooksLike) {
    messages.push(
      `workflow-mark: malformed PLAN_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_PLAN_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (planNotNeededMatch) {
    const v = validateSkipReason(planNotNeededMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: PLAN_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_PLAN_NOT_NEEDED: <better reason>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — plan NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_PLAN_NOT_NEEDED: ${v.reason}>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "plan", "skipped", { skip_reason: v.reason });
      markStep(sessionId, "research", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("plan");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. plan NOT recorded.`
      );
    }
    continue;
  }

  // --- WRITE_TESTS_NOT_NEEDED handler ---
  if (writeTestsNotNeededLooksLike) {
    messages.push(
      `workflow-mark: malformed WRITE_TESTS_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (writeTestsNotNeededMatch) {
    const v = validateSkipReason(writeTestsNotNeededMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: WRITE_TESTS_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <better reason>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — write_tests NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: ${v.reason}>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "write_tests", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("write_tests");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. write_tests NOT recorded.`
      );
    }
    continue;
  }

  // --- REVIEW_SECURITY_NOT_NEEDED handler ---
  if (reviewSecurityNotNeededLooksLike) {
    messages.push(
      `workflow-mark: malformed REVIEW_SECURITY_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (reviewSecurityNotNeededMatch) {
    const v = validateSkipReason(reviewSecurityNotNeededMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: REVIEW_SECURITY_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: <better reason>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — review_security NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_REVIEW_SECURITY_NOT_NEEDED: ${v.reason}>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "review_security", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("review_security");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. review_security NOT recorded.`
      );
    }
    continue;
  }

  // --- DOCS_NOT_NEEDED deprecation handler ---
  if (docsNotNeededLooksLike) {
    messages.push(
      `workflow-mark: WORKFLOW_DOCS_NOT_NEEDED is not accepted — ` +
        `update docs/ or *.md files and stage them (no skip path).`
    );
    continue;
  }

  // --- CLARIFY_INTENT_NOT_NEEDED handler ---
  if (clarifyIntentNotNeededLooksLike) {
    messages.push(
      `workflow-mark: malformed CLARIFY_INTENT_NOT_NEEDED — ` +
        `expected: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: REASON>>" ` +
        `(reason must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (clarifyIntentNotNeededMatch) {
    const v = validateSkipReason(clarifyIntentNotNeededMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: CLARIFY_INTENT_NOT_NEEDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: <better reason>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — clarify_intent NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_NOT_NEEDED: ${v.reason}>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "clarify_intent", "skipped", { skip_reason: v.reason });
      const hint = nextStepHint("clarify_intent");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. clarify_intent NOT recorded.`
      );
    }
    continue;
  }

  // --- CLARIFY_INTENT_COMPLETE handler ---
  if (CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd)) {
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — clarify_intent NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "clarify_intent", "complete");
      const hint = nextStepHint("clarify_intent");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. clarify_intent NOT recorded.`
      );
    }
    continue;
  }

  // --- BRANCHING_COMPLETE handler (also accepts legacy BRANCHING_DECIDED) ---
  if (branchingDecidedLooksLike) {
    messages.push(
      `workflow-mark: malformed BRANCHING_COMPLETE — ` +
        `expected: echo "<<WORKFLOW_BRANCHING_COMPLETE: DECISION>>" ` +
        `(decision must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (branchingDecidedMatch) {
    const v = validateSkipReason(branchingDecidedMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: BRANCHING_COMPLETE rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_BRANCHING_COMPLETE: <decision>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — branching_complete NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_BRANCHING_COMPLETE: ${v.reason}>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "branching_complete", "complete", { decision: v.reason });
      const hint = nextStepHint("branching_complete");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. branching_complete NOT recorded.`
      );
    }
    continue;
  }

  // --- USER_VERIFIED handler ---
  if (userVerifiedMatch) {
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — user_verification NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_USER_VERIFIED>>" (ask dialog will re-trigger for user approval)`
      );
      continue;
    }
    try {
      markStep(sessionId, "user_verification", "complete");
      const hint = nextStepHint("user_verification");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. user_verification NOT recorded.`
      );
    }
    continue;
  }

  // --- MARK_STEP handler ---
  if (markMatch) {
    const [, stepName, status] = markMatch;

    // user_verification must go through the WORKFLOW_USER_VERIFIED echo path
    if (stepName === "user_verification") {
      messages.push(
        `workflow-mark: user_verification NOT recorded — MARK_STEP sentinel is rejected for this step. ` +
          `Ask the user for commit approval via: echo "<<WORKFLOW_USER_VERIFIED>>"`
      );
      continue;
    }

    // write_tests and docs must go through evidence (staged files) or NOT_NEEDED sentinels
    if (stepName === "write_tests") {
      messages.push(
        `workflow-mark: write_tests NOT recorded — MARK_STEP not accepted for this step. ` +
          `Stage tests/ changes (run /write-tests then git add tests/) ` +
          `OR declare not needed: echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: <reason>>"` +
          ` (reason must be >=3 non-space chars, no '>', not a placeholder)`
      );
      continue;
    }
    if (stepName === "docs") {
      messages.push(
        `workflow-mark: docs NOT recorded — MARK_STEP not accepted for this step. ` +
          `Update docs/ or *.md files and stage them ` +
          `(run /update-docs then git add docs/) — no skip path.`
      );
      continue;
    }

    // Validate step name (regex already constrains status values)
    if (!VALID_STEPS.includes(stepName)) {
      messages.push(`workflow-mark: unknown step "${stepName}" in marker — ignored.`);
      continue;
    }

    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — step "${stepName}" NOT recorded. ` +
          `Commit gate will block. Re-run: ` +
          `echo "<<WORKFLOW_MARK_STEP_${stepName}_${status}>>"`
      );
      continue;
    }

    try {
      markStep(sessionId, stepName, status);
      if (status === "complete" || status === "skipped") {
        const hint = nextStepHint(stepName);
        if (hint) messages.push(hint);
      }
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. Step "${stepName}" NOT recorded.`
      );
    }
    continue;
  }

  // --- PREMISE_FAIL handler ---
  const premiseFailLooksLike =
    !cmd.match(PREMISE_FAIL_RE_DQ) && PREMISE_FAIL_LOOKSLIKE_RE.test(cmd);
  const premiseFailMatch = cmd.match(PREMISE_FAIL_RE_DQ);
  if (premiseFailLooksLike) {
    messages.push(
      `workflow-mark: malformed PREMISE_FAIL — ` +
        `expected: echo "<<WORKFLOW_PREMISE_FAIL: SUMMARY>>" ` +
        `(summary must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (premiseFailMatch) {
    const v = validateSkipReason(premiseFailMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: PREMISE_FAIL rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_PREMISE_FAIL: <summary>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — premise contradiction NOT recorded.`
      );
      continue;
    }
    try {
      setPremiseContradiction(sessionId, v.reason);
      messages.push(`workflow-mark: premise contradiction recorded.`);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. Premise contradiction NOT recorded.`
      );
    }
    continue;
  }

  // --- PREMISE_ACK handler ---
  const premiseAckLooksLike =
    !PREMISE_ACK_RE_DQ.test(cmd) && PREMISE_ACK_LOOKSLIKE_RE.test(cmd);
  if (premiseAckLooksLike) {
    messages.push(
      `workflow-mark: malformed PREMISE_ACK — ` +
        `expected: echo "<<WORKFLOW_PREMISE_ACK>>" (no payload)`
    );
    continue;
  }
  if (PREMISE_ACK_RE_DQ.test(cmd)) {
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — premise acknowledgement NOT recorded.`
      );
      continue;
    }
    try {
      clearPremiseContradiction(sessionId);
      messages.push(`workflow-mark: premise contradiction cleared (acknowledged).`);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. Premise acknowledgement NOT recorded.`
      );
    }
    continue;
  }

  // --- ENFORCE_WORKTREE_OFF handler ---
  const enforceOffMatch = cmd.match(ENFORCE_WORKTREE_OFF_RE_DQ);
  const enforceOffLooksLike =
    !enforceOffMatch && ENFORCE_WORKTREE_OFF_LOOKSLIKE_RE.test(cmd);
  if (enforceOffLooksLike) {
    messages.push(
      `workflow-mark: malformed ENFORCE_WORKTREE_OFF — ` +
        `expected: echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF>>" or ` +
        `echo "<<WORKFLOW_ENFORCE_WORKTREE_OFF: REASON>>"`
    );
    continue;
  }
  if (enforceOffMatch) {
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — ENFORCE_WORKTREE override NOT applied.`
      );
      continue;
    }
    if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      messages.push(`workflow-mark: invalid session_id format — override NOT applied.`);
      continue;
    }
    let reasonStored = null;
    const rawReason = enforceOffMatch[1]; // undefined when no reason given
    if (rawReason !== undefined) {
      const v = validateSkipReason(rawReason);
      if (v.ok) {
        reasonStored = v.reason;
      } else {
        // Warn but still apply — reason quality must not block emergency recovery.
        messages.push(
          `workflow-mark: ENFORCE_WORKTREE_OFF reason rejected — ${v.msg} (override still applied)`
        );
      }
    }
    try {
      const dir = getWorkflowDir();
      fs.mkdirSync(dir, { recursive: true });
      const markerPath = path.join(dir, `${sessionId}.worktree-off`);
      const tmp = markerPath + ".tmp";
      fs.writeFileSync(
        tmp,
        JSON.stringify({ reason: reasonStored, set_at: new Date().toISOString() }),
        { mode: 0o600 }
      );
      fs.renameSync(tmp, markerPath);
      messages.push(
        `workflow-mark: ENFORCE_WORKTREE session override applied (marker: ${markerPath}). ` +
          `Delete the marker file to restore enforcement.`
      );
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write ENFORCE_WORKTREE override marker — ${e.message}. Override NOT applied.`
      );
    }
    continue;
  }

  // --- ENFORCE_WORKTREE_ON handler ---
  const enforceOnMatch = ENFORCE_WORKTREE_ON_RE_DQ.test(cmd);
  const enforceOnLooksLike =
    !enforceOnMatch && ENFORCE_WORKTREE_ON_LOOKSLIKE_RE.test(cmd);
  if (enforceOnLooksLike) {
    messages.push(
      `workflow-mark: malformed ENFORCE_WORKTREE_ON — ` +
        `expected: echo "<<WORKFLOW_ENFORCE_WORKTREE_ON>>"`
    );
    continue;
  }
  if (enforceOnMatch) {
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — ENFORCE_WORKTREE restore NOT applied.`
      );
      continue;
    }
    if (!/^[A-Za-z0-9_-]+$/.test(sessionId)) {
      messages.push(`workflow-mark: invalid session_id format — restore NOT applied.`);
      continue;
    }
    try {
      const dir = getWorkflowDir();
      const markerPath = path.join(dir, `${sessionId}.worktree-off`);
      try {
        fs.unlinkSync(markerPath);
        messages.push(
          `workflow-mark: ENFORCE_WORKTREE session override cleared (marker removed: ${markerPath}).`
        );
      } catch (e) {
        if (e.code !== "ENOENT") throw e;
        // Idempotent: silent no-op when marker is already absent.
      }
    } catch (e) {
      messages.push(
        `workflow-mark: failed to clear ENFORCE_WORKTREE override marker — ${e.message}. Restore NOT applied.`
      );
    }
    continue;
  }

  // --- RESET_FROM handler ---
  if (resetMatch) {
    const [, fromStep] = resetMatch;

    if (!VALID_STEPS.includes(fromStep)) {
      messages.push(
        `workflow-mark: unknown step "${fromStep}" for reset-from — ignored.`
      );
      continue;
    }

    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — reset-from "${fromStep}" NOT applied. ` +
          `Re-run: echo "<<WORKFLOW_RESET_FROM_${fromStep}>>"`
      );
      continue;
    }

    try {
      const newState = createInitialState(sessionId);
      const fromIndex = VALID_STEPS.indexOf(fromStep);
      const now = new Date().toISOString();
      for (let i = 0; i < fromIndex; i++) {
        newState.steps[VALID_STEPS[i]] = { status: "complete", updated_at: now };
      }
      writeState(sessionId, newState);
    } catch (e) {
      messages.push(`workflow-mark: reset-from failed — ${e.message}.`);
    }
    continue;
  }
}

done(messages.length > 0 ? messages.join("\n") : undefined);
