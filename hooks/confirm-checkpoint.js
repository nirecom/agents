#!/usr/bin/env node
// PreToolUse hook: when Bash emits a <<WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL}>> sentinel, surface
// the plan above the permission dialog so the user can Allow or Deny inline; never "allow".
// Output: { systemMessage } with facts only for the user plus additionalContext with the plan-link
// line for the model (hooks/lib/plan-link.js). Sentinel patterns: hooks/lib/confirm-sentinel.js.
// #2729: the echo reaches the dialog only on a presentation receipt the Stop hook wrote for this
// very plan, link and content (hooks/lib/presentation-receipt.js); the receipt is spent here. With
// none, confirm-checkpoint/receipt-recovery.js may record it from the previous turn (#2936).
// Fail-closed: what it cannot verify denies (present again), but an unreadable hook input is a no-op.
// #2631: a plan over HARD, or one the size check cannot judge, is denied (uncounted) whatever
// the step's CONFIRM_* flag says; over WARN adds advice. Only an exempt session (size-session-gate.js) skips it.
"use strict";

const fs = require("fs");

// #2256 S5-a2: Bash/runInTerminal/runCommands normalization (SSOT: hooks/lib/tool-command-text.js).
// The CONFIRM patterns are unanchored, so the joined command text finds the sentinel in any element.
const { isCommandTool, commandTextOf } = require("./lib/tool-command-text");
const { parseSentinel } = require("./lib/confirm-sentinel");
const { peekTurnMarkers } = require("./lib/turn-marker");
const { resolveSessionId } = require("./workflow-state");
const { getWorkflowPlansDir } = require("./lib/workflow-plans-dir");
const { loadDefaultEnv } = require("./lib/load-env");

// Loaded on use, never at startup: a throw at load would crash the hook (exit 1 is non-blocking,
// i.e. fail-open); inside judge() or the guarded post-pass it becomes a deny instead.
const lazy = (p) => { let m = null; return new Proxy({}, { get: (_, k) => (m || (m = require(p)))[k] }); };
const PR = lazy("./lib/presentation-receipt");
const PL = lazy("./lib/plan-link");
const CL = lazy("./lib/conv-lang");

const { readHookInput } = require("./lib/read-stdin");
// The sentinel names a step; the plan file, link line and size check use its artifact name.
// A table that cannot be loaded must not crash the hook (exit 1 is fail-open): the flag comes from
// step-gate-map (no table dependency) and the artifact name is the step's, but for clarify_intent.
function rowOf(step) {
  try {
    const row = require("./workflow-state/plan-step-table").rowFor(step);
    if (row) return row;
  } catch (_) { /* the fallback below keeps the gate and the deny working */ }
  const suffix = step === "clarify_intent" ? "intent" : step;
  let confirmFlag = `CONFIRM_${String(suffix).toUpperCase()}`; // last resort: the later gate lookup fails closed on its own
  try { confirmFlag = require("./lib/confirm-gate/step-gate-map").confirmGateForStep(step) || confirmFlag; } catch (_) { /* name above */ }
  return { suffix, confirmFlag };
}

function noopExit() { process.stdout.write(""); process.exit(0); }

// Resolve absolute path to the <artifact>.md plan for the current session: a marker of this turn
// first, else <PLANS_DIR>/<first_session_id>-<artifact>.md (the usual case: the Stop hook spent the markers).
function resolveArtifact(artifact, sid, plansDir) {
  if (sid) {
    try {
      for (const m of peekTurnMarkers(sid)) {
        if (m && m.suffix === artifact && typeof m.absPath === "string" && m.absPath.length > 0) return m.absPath;
      }
    } catch (_) { /* fall back to the plans dir */ }
  }
  if (sid && plansDir) {
    try {
      const owner = require("./workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, artifact, undefined, { plansDir });
      if (owner.exists) return owner.path;
    } catch (_) { /* no artifact */ }
  }
  return null;
}

// url: the published blob URL (hooks/lib/plan-link.js), shown together with the local path.
function renderMessage(artifact, absPath, url) {
  if (absPath) return url ? `[${artifact}] ${url} (${absPath})` : `[${artifact}] ${absPath}`;
  return `[${artifact}] plan-file=none`;
}

// judge(sid, step, artifact, absPath, plansDir, recover) -> {pass:true, link} | {pass:false, cause}. Every
// check that cannot be completed denies: the dialog is reached only on a matching receipt. The
// receipt is keyed by the step, the plan file by its artifact name. An absent receipt is read
// again once recover() reports it wrote one (#2936); the match and the spend are unchanged.
function judge(sid, step, artifact, absPath, plansDir, recover) {
  if (!sid) return { pass: false, cause: "unverifiable-session" };
  if (!absPath || !fs.existsSync(absPath) || !PR.samePath(absPath, PR.approvalArtifactPath(sid, artifact))) {
    return { pass: false, cause: "unverifiable-artifact" };
  }
  let link;
  try {
    link = PL.linkForFile(absPath, plansDir ? { plansDir } : {});
  } catch (_) {
    return { pass: false, cause: "unverifiable-link" };
  }
  const receiptLink = PL.receiptLinkOf(link);
  if (!receiptLink) return { pass: false, cause: "unpublished" };
  const { computeContentSha } = require("./workflow-state/completion-approval");
  const contentSha = computeContentSha(absPath);
  if (!contentSha) return { pass: false, cause: "unverifiable-content" };
  let read = PR.readReceipt(sid, step);
  if (!read.ok && read.reason === "absent" && recover && recover()) read = PR.readReceipt(sid, step);
  if (!read.ok) {
    // A broken receipt is removed so the next presentation can write a fresh one.
    if (read.reason === "unreadable") PR.discardReceipt(sid, step);
    return { pass: false, cause: read.reason === "unreadable" ? "unreadable-receipt" : "no-receipt" };
  }
  const m = PR.matchReceipt(read.receipt, { absPath, link: receiptLink, contentSha });
  return m.ok ? { pass: true, link } : { pass: false, cause: m.cause };
}

// The Japanese "send back to the planner" is matched verbatim in plan text. lang-check: ignore
const SEND_BACK = "planner に差し戻す";

// #2631: the size verdict of the plan the approval would bind (<first_session_id>-<artifact>.md), or
// null for an exempt session. Fail-closed: no sid or an unmeasured plan denies; a throw denies in
// main. Runs before the CONFIRM_*=off exit and records no deny finding.
function planSizeDeny(sid, artifact) {
  if (!sid) {
    return { deny: `[${artifact}] plan-size could not be verified: session id unresolved — not confirmable; ` +
      "the session cannot be identified (check the transcript and the session id)." };
  }
  if (require("./lib/size-session-gate").sizeCheckState(sid) === "exempt") return null;
  const relint = require("./lib/plan-artifact-lang").relintPlanArtifact(sid, artifact);
  const size = relint.size;
  const artifactPath = relint.artifactPath;
  // A missing plan file is unjudgeable too: it denies here, before the judge and the OFF exit.
  if (!size) {
    return { artifactPath, deny: `[${artifact}] plan-size could not be judged (${relint.skipped || "unmeasured"}) — not confirmable; ` +
      `make the plan readable again (the file exists and can be read: ${artifactPath || `the ${artifact} plan`}), then present it again.` };
  }
  if (size.verdict !== "hard" && size.verdict !== "warn") return { artifactPath };
  // The full path, not the basename: a resumed session's plan is named after its first_session_id.
  const head = `${artifactPath} is ${size.value} ${size.unit}`;
  if (size.verdict === "hard") {
    return { artifactPath, deny: `[${artifact}] plan-size: ${head}, over HARD ${size.hard} — not confirmable; ${SEND_BACK} ` +
      `(send it back to the planner to compress below HARD; limits: rules/coding/file-split.md).` };
  }
  return { artifactPath, advice: `[${artifact}] plan-size WARN: ${head}, over WARN ${size.warn} (HARD ${size.hard}) — consider compressing it.\n` };
}

function emitSizeDeny(reason) {
  process.stdout.write(JSON.stringify({
    decision: "block",
    reason,
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }));
  process.exit(0);
}

function recordDenyFinding(sid, step, cause) {
  if (!sid) return;
  try {
    const diag = cause === "no-receipt" ? require("./confirm-checkpoint/receipt-diagnostic").receiptDiagnostic(sid, step) : "";
    require("./lib/supervisor-state-writer").appendFinding(sid, {
      categories: ["workflow"],
      severity: "notice",
      detail: `confirm-checkpoint: ${rowOf(step).confirmFlag} denied (${cause}) — the plan must be presented again${diag}`,
      reporter: "confirm-checkpoint",
    });
  } catch (_) { /* the finding is advisory */ }
}

function emitDeny(step, cause) {
  const row = rowOf(step);
  let reason;
  try {
    reason = require("./lib/confirm-continuation").presentAgainReason(row.suffix, cause);
  } catch (_) {
    let hint = "";
    if (cause === "no-receipt") {
      try { hint = ` (${require("./lib/no-receipt-hint").NO_RECEIPT_HINT})`; } catch (_) { /* the bare reason still denies */ }
    }
    reason = `[confirm-plan] ${row.confirmFlag} denied (${cause})${hint}: present the plan again (plan-link --step ${step}) and close the turn; ` +
      `on a "[confirm-plan] continue:" prompt emit only the echo, otherwise echo after the user's reply.`;
    try { reason = CL.withConvLang(reason); } catch (_) { /* the bare reason still denies */ }
  }
  process.stdout.write(JSON.stringify({
    decision: "block",
    reason,
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }));
  process.exit(0);
}

function main() {
  try { loadDefaultEnv(); } catch (_) {}
  const hookInput = readHookInput();
  if (hookInput.kind !== "ok") noopExit();
  const input = hookInput.input;

  if (!isCommandTool(input.tool_name)) noopExit();

  const parsed = parseSentinel(commandTextOf(input.tool_name, input.tool_input));
  if (!parsed) noopExit();
  const step = parsed.step;
  const row = rowOf(step);
  const artifact = row.suffix;
  const flag = row.confirmFlag;

  let sid = null;
  try {
    sid = resolveSessionId({ sessionIdFromInput: input.session_id, transcriptPath: input.transcript_path });
  } catch (_) { /* planSizeDeny denies it (session id unresolved) */ }

  let sizeVerdict;
  try {
    sizeVerdict = planSizeDeny(sid, artifact);
  } catch (e) {
    sizeVerdict = { deny: `[${artifact}] plan-size check failed: ${e && e.message ? e.message : String(e)} — not confirmable; ` +
      "make the plan readable again (the file exists and can be read), then present it again." };
  }
  if (sizeVerdict && sizeVerdict.deny) emitSizeDeny(sizeVerdict.deny);
  const sizeAdvice = sizeVerdict && sizeVerdict.advice ? sizeVerdict.advice : "";

  // The shared plan gate (plan-gate.js) owns the classification: OFF waives the dialog, never the
  // size deny above; an error or an unloadable step table shows the dialog path (the judge below).
  let gate = "ERROR";
  try { gate = require("./lib/confirm-gate/plan-gate").planGateState(step); } catch (_) { /* judged below */ }
  if (gate === "OFF") {
    const skipped = { systemMessage: `[confirm-skipped: ${flag}=off]` };
    if (sizeAdvice) skipped.hookSpecificOutput = { hookEventName: "PreToolUse", additionalContext: sizeAdvice };
    process.stdout.write(JSON.stringify(skipped));
    process.exit(0);
  }

  // #2853: a plan step's dialog waits for its pre-confirm audit; a deny here keeps the receipt.
  let auditDeny;
  try {
    auditDeny = require("./confirm-checkpoint/pre-confirm-audit-deny").auditDenyReason(sid, step);
  } catch (e) {
    auditDeny = `[pre-confirm-audit] ${flag} denied: the audit check failed (${e && e.message ? e.message : String(e)}).`;
  }
  if (auditDeny) {
    recordDenyFinding(sid, step, "pre-confirm-audit");
    let reason = auditDeny;
    try { reason = CL.withConvLang(auditDeny); } catch (_) { /* the bare reason still denies */ }
    emitSizeDeny(reason);
  }

  let plansDir = null;
  try { plansDir = getWorkflowPlansDir(); } catch (_) { /* resolved from the session alone */ }
  const absPath = resolveArtifact(artifact, sid, plansDir);

  // A recovery that cannot load or run reads as nothing written: today's no-receipt deny (fail-closed).
  const recover = () => {
    try {
      return require("./confirm-checkpoint/receipt-recovery").recoverReceipt({ sid, step, artifact, input, plansDir, gate }).written === true;
    } catch (_) { return false; }
  };
  let verdict;
  try {
    verdict = judge(sid, step, artifact, absPath, plansDir, recover);
  } catch (_) {
    verdict = { pass: false, cause: "check-threw" };
  }
  if (!verdict.pass) {
    recordDenyFinding(sid, step, verdict.cause);
    emitDeny(step, verdict.cause);
  }

  // The receipt admits one dialog: after a Deny there, the plan is presented again.
  let out = null;
  let failCause = null;
  try {
    if (PR.consumeReceipt(sid, step)) {
      const link = verdict.link;
      const entry = { stage: artifact, url: link.url, path: link.path, reason: link.reason };
      const additionalContext = sizeAdvice + CL.withConvLang(PL.renderModelContext([entry], { when: "confirm" }));
      out = {
        systemMessage: renderMessage(artifact, absPath, link.url || null),
        hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext },
      };
    } else {
      failCause = "no-receipt"; // a concurrent CONFIRM spent it between the judgment and here
    }
  } catch (_) {
    failCause = "check-threw";
  }
  if (!out) {
    recordDenyFinding(sid, step, failCause);
    emitDeny(step, failCause);
  }
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

if (require.main === module) main();

module.exports = { parseSentinel, renderMessage, resolveArtifact };
