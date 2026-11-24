"use strict";
// #3144 S2-4 / S4-2 — WORKFLOW_PM_REVIEW_ACCEPTED (plan form and PR form).
//
//   echo "<<WORKFLOW_PM_REVIEW_ACCEPTED: <intent|outline|detail|PR#<n>> <reason>>>"
// The user sends a plan stage's audit to the conventional supervisor audit instead of the assigned PM.
// settings.json `ask` puts every emission through the permission dialog. The handler arms a new counted
// run carrying the fallback finding (the in-flight run is replaced), so the gate gives it the subagent
// launch and the PM's verdict write on it is refused. At the cap nothing is armed and the stage's
// in-flight run is released, as the gate's own cap procedure does. The PR form writes the user's pm-review row.

const { PM_REVIEW_ACCEPTED_RE_DQ, PM_REVIEW_ACCEPTED_LOOKSLIKE_RE } = require("../lib/sentinel-patterns");
const { sanitizeLine } = require("../lib/output-sanitize");

const LABEL = "WORKFLOW_PM_REVIEW_ACCEPTED";
const FORM = `echo "<<${LABEL}: <intent|outline|detail|PR#<n>> <reason>>>"`;
// The verdict of the user's pm-review row; the gate reads the row by its source, never by this value.
const VERDICT_USER = "ACCEPTED";

function armFallback(ctx, step, reason) {
  const { sessionId, pushMessage, pushUnapplied, repoCwd } = ctx;
  let r;
  try {
    r = require("../lib/pre-confirm-audit").armStage(sessionId, step, { cwd: repoCwd }, { force: true, fallback: true }) || {};
  } catch (e) {
    pushUnapplied(`workflow-mark: ${LABEL} failed — ${sanitizeLine(e.message)}; no audit armed.`);
    return;
  }
  if (r.reason === "cap-reached") {
    pushMessage(`workflow-mark: ${LABEL} armed nothing — the ${step} stage is at its audit run cap` +
      (r.released ? " and its in-flight run was released" : "") + ". Rerun next-step --gate for the cap procedure.");
    return;
  }
  const runId = r.audit_run_id || r.run_id;
  if (r.ok !== true || !runId) {
    pushUnapplied(`workflow-mark: ${LABEL} refused — ${sanitizeLine(r.reason || "unknown")}; no audit armed.`);
    return;
  }
  pushMessage(`workflow-mark: ${LABEL} recorded — the ${step} stage audit ${runId} goes to the conventional ` +
    `supervisor audit (${reason}). Rerun next-step --gate and follow its GATE_ACTION.`);
}

// acceptPr(ctx, n, reason) — the PR form (S4-2): the user's row of the pm-review record for PR <n> at HEAD.
// A forge that names another PR refuses; a forge that does not answer writes user-pr-unconfirmed only when
// the last request row was for PR <n>. The row opens the next round while S3-4 allows one, else it stays on
// the current round (the cap procedure's choice), so no round beyond the cap is ever created.
function acceptPr(ctx, n, reason) {
  const { sessionId, pushMessage, pushUnapplied } = ctx;
  const refuse = (why) => pushUnapplied(`workflow-mark: ${LABEL} PR#${n} refused — ${sanitizeLine(why)}; NOT recorded.`);
  try {
    const W = require("../lib/pm-review-writer");
    const UV = require("../workflow-gate/user-verified-pm-review");
    const store = require("../../bin/lib/codex-review-loop/review-rounds-store");
    const cwd = ctx.repoCwd || ctx.toolCwd || process.cwd();
    const head = UV.headOf(cwd);
    if (!head) return refuse("the HEAD SHA cannot be read");
    const runId = W.PR_RUN_PREFIX + Number(n);
    const rows = W.readPmRows(sessionId);
    const pr = UV.currentPr(cwd);
    let source = W.SOURCE_USER;
    if (pr === null) {
      const reqs = rows.filter((r) => typeof r.source === "string" && r.source.startsWith(W.SOURCE_REQUEST_PREFIX));
      if (!reqs.length || reqs[reqs.length - 1].run_id !== runId) return refuse("the forge did not answer and the last Review request was not for this PR");
      source = W.SOURCE_USER_PR_UNCONFIRMED;
    } else if (pr !== String(Number(n))) {
      return refuse(`the current PR of the branch is ${pr ? `#${pr}` : "none"}`);
    }
    const roundOf = (rs) => { const x = W.nextRoundAllowed(rs); return x.ok ? x.round + 1 : x.round; };
    const round = roundOf(rows);
    const row = store.appendRow({
      sid: sessionId, format: W.FORMAT, exit: null, state_sid: sessionId, untilSeq: null, counter_round: round,
      verdict: VERDICT_USER, source, run_id: runId, fingerprint: head, writer_sid: sessionId,
      skipIf: (parsed) => (roundOf(parsed.filter((r) => r && typeof r === "object")) === round ? null : { skipped: "round-moved" }),
    });
    if (row.skipped) return refuse(row.skipped);
    pushMessage(`workflow-mark: ${LABEL} recorded — PR#${n} round ${round} (${source}) goes to the conventional audit (${reason}).`);
  } catch (e) {
    refuse(e.message);
  }
}

function handle(ctx) {
  const { cmd, sessionId, pushUnapplied } = ctx;
  const m = cmd.match(PM_REVIEW_ACCEPTED_RE_DQ);
  if (m) {
    if (!sessionId) {
      pushUnapplied(`workflow-mark: could not resolve session_id — ${LABEL} NOT recorded.`);
      return true;
    }
    const target = m[1];
    const reason = sanitizeLine(m[2].trim());
    if (/^PR#/.test(target)) {
      acceptPr(ctx, target.slice(3), reason);
      return true;
    }
    armFallback(ctx, target, reason);
    return true;
  }
  if (PM_REVIEW_ACCEPTED_LOOKSLIKE_RE.test(cmd)) {
    pushUnapplied(`workflow-mark: malformed ${LABEL} — expected: ${FORM}. NOT applied.`);
    return true;
  }
  return false;
}

module.exports = { handle };
