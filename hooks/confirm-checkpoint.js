#!/usr/bin/env node
// PreToolUse hook: when Bash emits a <<WORKFLOW_CONFIRM_{INTENT|OUTLINE|DETAIL}>> sentinel, surface
// the plan above the permission dialog so the user can Allow or Deny inline; never "allow".
// Output: { systemMessage } with facts only for the user plus additionalContext with the plan-link
// line for the model (hooks/lib/plan-link.js). Sentinel patterns: hooks/lib/confirm-sentinel.js.
// #2729: the echo reaches the dialog only on a presentation receipt the Stop hook wrote for this
// very plan, link and content (hooks/lib/presentation-receipt.js); the receipt is spent here.
// Fail-closed: anything it cannot verify denies with a present-again reason. The one exception is
// an unreadable hook input, where not even the sentinel is known: that stays a no-op.
// #2631: a plan over HARD, or one the size check cannot judge, is denied (uncounted) whatever
// CONFIRM_<STAGE> says; over WARN adds advice. Only an exempt session (size-session-gate.js) skips it.
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

function noopExit() { process.stdout.write(""); process.exit(0); }

// Resolve absolute path to <stage>.md artifact for the current session: a marker of this turn
// first, else <PLANS_DIR>/<first_session_id>-<stage>.md (the usual case: the Stop hook spent the markers).
function resolveArtifact(stage, sid, plansDir) {
  if (sid) {
    try {
      for (const m of peekTurnMarkers(sid)) {
        if (m && m.suffix === stage && typeof m.absPath === "string" && m.absPath.length > 0) return m.absPath;
      }
    } catch (_) { /* fall back to the plans dir */ }
  }
  if (sid && plansDir) {
    try {
      const owner = require("./workflow-state/plan-artifact-owner").resolvePlanArtifactOwner(sid, stage, undefined, { plansDir });
      if (owner.exists) return owner.path;
    } catch (_) { /* no artifact */ }
  }
  return null;
}

// url: the published blob URL (hooks/lib/plan-link.js), shown together with the local path.
function renderMessage(stage, absPath, url) {
  if (absPath) return url ? `[${stage}] ${url} (${absPath})` : `[${stage}] ${absPath}`;
  return `[${stage}] plan-file=none`;
}

// judge(sid, stage, absPath, plansDir) -> {pass:true, link} | {pass:false, cause}. Every check
// that cannot be completed denies: the dialog is reached only on a matching receipt.
function judge(sid, stage, absPath, plansDir) {
  if (!sid) return { pass: false, cause: "unverifiable-session" };
  if (!absPath || !fs.existsSync(absPath) || !PR.samePath(absPath, PR.approvalArtifactPath(sid, stage))) {
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
  const read = PR.readReceipt(sid, stage);
  if (!read.ok) {
    // A broken receipt is removed so the next presentation can write a fresh one.
    if (read.reason === "unreadable") PR.discardReceipt(sid, stage);
    return { pass: false, cause: read.reason === "unreadable" ? "unreadable-receipt" : "no-receipt" };
  }
  const m = PR.matchReceipt(read.receipt, { absPath, link: receiptLink, contentSha });
  return m.ok ? { pass: true, link } : { pass: false, cause: m.cause };
}

// receiptDiagnostic(sid, stage) -> the no-receipt detail suffix (#2804): the expected receipt, whether it
// exists, and the presentation-receipt log's last write and any consume after it; "" when it cannot be built.
function receiptDiagnostic(sid, stage) {
  try {
    const p = PR.receiptPath(sid, stage);
    const head = ` [receipt ${p} exists=${fs.existsSync(p)}`;
    const lines = PR.readReceiptLog(sid).filter((l) => l && l.stage === stage);
    let wi = -1;
    lines.forEach((l, i) => { if (l.event === "write") wi = i; });
    if (wi < 0) return `${head}; no write record]`;
    const at = lines[wi].at;
    const ms = Date.now() - Date.parse(at);
    const elapsed = Number.isNaN(ms) ? "elapsed unknown" : `elapsed ${ms}ms`;
    const consumed = lines.slice(wi + 1).some((l) => l.event === "consume");
    return `${head}; last write at ${at} (${elapsed}); ${consumed ? "a consume record follows it" : "no consume record follows it"}]`;
  } catch (_) {
    return "";
  }
}

// The Japanese "send back to the planner" is matched verbatim in plan text. lang-check: ignore
const SEND_BACK = "planner に差し戻す";

// #2631: the size verdict of the plan the approval would bind (<first_session_id>-<stage>.md), or
// null for an exempt session. Fail-closed: no sid or an unmeasured plan denies; a throw denies in
// main. Runs before the CONFIRM_*=off exit and records no deny finding.
function planSizeDeny(sid, stage) {
  if (!sid) {
    return { deny: `[${stage}] plan-size could not be verified: session id unresolved — not confirmable; ` +
      "the session cannot be identified (check the transcript and the session id)." };
  }
  if (require("./lib/size-session-gate").sizeCheckState(sid) === "exempt") return null;
  const relint = require("./lib/plan-artifact-lang").relintPlanArtifact(sid, stage);
  const size = relint.size;
  const artifactPath = relint.artifactPath;
  // A missing plan file is unjudgeable too: it denies here, before the judge and the OFF exit.
  if (!size) {
    return { artifactPath, deny: `[${stage}] plan-size could not be judged (${relint.skipped || "unmeasured"}) — not confirmable; ` +
      `make the plan readable again (the file exists and can be read: ${artifactPath || `the ${stage} plan`}), then present it again.` };
  }
  if (size.verdict !== "hard" && size.verdict !== "warn") return { artifactPath };
  // The full path, not the basename: a resumed session's plan is named after its first_session_id.
  const head = `${artifactPath} is ${size.value} ${size.unit}`;
  if (size.verdict === "hard") {
    return { artifactPath, deny: `[${stage}] plan-size: ${head}, over HARD ${size.hard} — not confirmable; ${SEND_BACK} ` +
      `(send it back to the planner to compress below HARD; limits: rules/coding/file-split.md).` };
  }
  return { artifactPath, advice: `[${stage}] plan-size WARN: ${head}, over WARN ${size.warn} (HARD ${size.hard}) — consider compressing it.\n` };
}

function emitSizeDeny(reason) {
  process.stdout.write(JSON.stringify({
    decision: "block",
    reason,
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
  }));
  process.exit(0);
}

function recordDenyFinding(sid, stage, cause) {
  if (!sid) return;
  try {
    const diag = cause === "no-receipt" ? receiptDiagnostic(sid, stage) : "";
    require("./lib/supervisor-state-writer").appendFinding(sid, {
      categories: ["workflow"],
      severity: "notice",
      detail: `confirm-checkpoint: CONFIRM_${stage.toUpperCase()} denied (${cause}) — the plan must be presented again${diag}`,
      reporter: "confirm-checkpoint",
    });
  } catch (_) { /* the finding is advisory */ }
}

function emitDeny(stage, cause) {
  let reason;
  try {
    reason = require("./lib/confirm-continuation").presentAgainReason(stage, cause);
  } catch (_) {
    reason = `[confirm-plan] CONFIRM_${stage.toUpperCase()} denied (${cause}): present the plan again (plan-link --stage ${stage}) and close the turn; ` +
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
  const stage = parsed.stage;

  let sid = null;
  try {
    sid = resolveSessionId({ sessionIdFromInput: input.session_id, transcriptPath: input.transcript_path });
  } catch (_) { /* planSizeDeny denies it (session id unresolved) */ }

  let sizeVerdict;
  try {
    sizeVerdict = planSizeDeny(sid, stage);
  } catch (e) {
    sizeVerdict = { deny: `[${stage}] plan-size check failed: ${e && e.message ? e.message : String(e)} — not confirmable; ` +
      "make the plan readable again (the file exists and can be read), then present it again." };
  }
  if (sizeVerdict && sizeVerdict.deny) emitSizeDeny(sizeVerdict.deny);
  const sizeAdvice = sizeVerdict && sizeVerdict.advice ? sizeVerdict.advice : "";

  // The shared plan gate (plan-gate.js) owns the classification: OFF waives the dialog, never the
  // size deny above; an error or an unloadable stage table shows the dialog path (the judge below).
  let gate = "ERROR";
  try { gate = require("./lib/confirm-gate/plan-gate").planGateState(stage); } catch (_) { /* judged below */ }
  if (gate === "OFF") {
    const skipped = { systemMessage: `[confirm-skipped: CONFIRM_${stage.toUpperCase()}=off]` };
    if (sizeAdvice) skipped.hookSpecificOutput = { hookEventName: "PreToolUse", additionalContext: sizeAdvice };
    process.stdout.write(JSON.stringify(skipped));
    process.exit(0);
  }

  let plansDir = null;
  try { plansDir = getWorkflowPlansDir(); } catch (_) { /* resolved from the session alone */ }
  const absPath = resolveArtifact(stage, sid, plansDir);

  let verdict;
  try {
    verdict = judge(sid, stage, absPath, plansDir);
  } catch (_) {
    verdict = { pass: false, cause: "check-threw" };
  }
  if (!verdict.pass) {
    recordDenyFinding(sid, stage, verdict.cause);
    emitDeny(stage, verdict.cause);
  }

  // The receipt admits one dialog: after a Deny there, the plan is presented again.
  let out = null;
  let failCause = null;
  try {
    if (PR.consumeReceipt(sid, stage)) {
      const link = verdict.link;
      const entry = { stage, url: link.url, path: link.path, reason: link.reason };
      const additionalContext = sizeAdvice + CL.withConvLang(PL.renderModelContext([entry], { when: "confirm" }));
      out = {
        systemMessage: renderMessage(stage, absPath, link.url || null),
        hookSpecificOutput: { hookEventName: "PreToolUse", additionalContext },
      };
    } else {
      failCause = "no-receipt"; // a concurrent CONFIRM spent it between the judgment and here
    }
  } catch (_) {
    failCause = "check-threw";
  }
  if (!out) {
    recordDenyFinding(sid, stage, failCause);
    emitDeny(stage, failCause);
  }
  process.stdout.write(JSON.stringify(out));
  process.exit(0);
}

if (require.main === module) main();

module.exports = { parseSentinel, renderMessage, resolveArtifact };
