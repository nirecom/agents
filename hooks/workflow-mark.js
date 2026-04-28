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

const fs = require("fs");
const {
  VALID_STEPS,
  resolveSessionId,
  markStep,
  createInitialState,
  writeState,
  nextStepHint,
} = require("./lib/workflow-state");

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
const CLARIFY_INTENT_COMPLETE_RE_DQ = /^echo "<<WORKFLOW_CLARIFY_INTENT_COMPLETE>>"$/;
const BRANCHING_DECIDED_RE_DQ = /^echo "<<WORKFLOW_BRANCHING_DECIDED: ([^>]+)>>"$/;
const BRANCHING_DECIDED_LOOKSLIKE_RE = /^echo "<<WORKFLOW_BRANCHING_DECIDED([: ].*)?>>"$/;

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
    CLARIFY_INTENT_COMPLETE_RE_DQ.test(cmd) ||
    BRANCHING_DECIDED_RE_DQ.test(cmd) ||
    BRANCHING_DECIDED_LOOKSLIKE_RE.test(cmd)
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

// If the echo itself failed, don't apply any sentinel operation from this command.
const toolResponse = input.tool_response || {};
const exitCode =
  toolResponse.exit_code ??
  toolResponse.exitCode ??
  (toolResponse.success === false ? 1 : 0);
if (exitCode !== 0) {
  done(
    `workflow-mark: echo exited ${exitCode} — ${sentinelParts.length} sentinel operation(s) NOT applied.`
  );
}

// Resolve session ID from hook stdin (preferred), fall back to CLAUDE_ENV_FILE
const sessionId = input.session_id || resolveSessionId();

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
  const branchingDecidedMatch = cmd.match(BRANCHING_DECIDED_RE_DQ);
  const branchingDecidedLooksLike =
    !branchingDecidedMatch && BRANCHING_DECIDED_LOOKSLIKE_RE.test(cmd);

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

  // --- BRANCHING_DECIDED handler ---
  if (branchingDecidedLooksLike) {
    messages.push(
      `workflow-mark: malformed BRANCHING_DECIDED — ` +
        `expected: echo "<<WORKFLOW_BRANCHING_DECIDED: DECISION>>" ` +
        `(decision must be >=3 non-space chars, no '>')`
    );
    continue;
  }
  if (branchingDecidedMatch) {
    const v = validateSkipReason(branchingDecidedMatch[1]);
    if (!v.ok) {
      messages.push(
        `workflow-mark: BRANCHING_DECIDED rejected — ${v.msg} ` +
          `Re-run: echo "<<WORKFLOW_BRANCHING_DECIDED: <decision>>"`
      );
      continue;
    }
    if (!sessionId) {
      messages.push(
        `workflow-mark: could not resolve session_id — branching_decision NOT recorded. ` +
          `Re-run: echo "<<WORKFLOW_BRANCHING_DECIDED: ${v.reason}>>"`
      );
      continue;
    }
    try {
      markStep(sessionId, "branching_decision", "complete", { decision: v.reason });
      const hint = nextStepHint("branching_decision");
      if (hint) messages.push(hint);
    } catch (e) {
      messages.push(
        `workflow-mark: failed to write state — ${e.message}. branching_decision NOT recorded.`
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
