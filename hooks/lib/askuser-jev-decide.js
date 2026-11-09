"use strict";
// askuser-jev-decide.js — whether Jev answers an AskUserQuestion dialog for the user (#2764).
// The dialog carries metadata.source=<dialog ID>. Only an ID the classification table
// (askuser-dialog-levels.json) rates low, raised while the session's current workflow step is one
// the row declares, reaches Jev. Every other dialog reaches the user. Each stage that does not
// hold returns its route; only route "answered" carries answers. docs/architecture/jev.md owns
// the route list.

const path = require("path");
const levels = require("./askuser-dialog-levels");

const JUDGED_IN = Object.freeze({ kind: "hook", name: "pre-tool-use-askuser-jev" });
const ADAPTER = path.join(__dirname, "jev", "adapters", "askuser-answer");
const APPROVAL_REASON = path.join(__dirname, "..", "..", "bin", "workflow", "lib", "next-step", "approval-reason");

function isOn(r) {
  return !!r && !r.loadFailed && String(r.value).trim().toLowerCase() === "on";
}

// Stages 3-7: the flags, the dialog ID's level, the session, its state and its current step.
// Returns a route name when the dialog stops here, or {state} to go on.
function gate(input, ctx) {
  if (!isOn(require("./load-env").resolveConfigVar("JEV", "off"))) return "jev-off";
  if (!isOn(require("./temporary-migrations/jev-auto-clarifications-rename").resolveClarificationsFlag())) return "flag-off";
  if (ctx.dialogId === null) return "no-id";
  if (!levels.DIALOG_ID_RE.test(ctx.dialogId)) return "malformed-id";
  const row = levels.classify(ctx.dialogId);
  if (!row) return "unclassified";
  if (row.level !== "low") return "high";
  const sid = input.sid;
  if (typeof sid !== "string" || !sid) return "no-sid";
  const ws = require("../workflow-state");
  const state = ws.readState(sid);
  if (!state) return "no-state";
  const { resolveCurrentStep } = require("../workflow-state/current-step");
  const { resolveSessionProfile } = require("../workflow-state/session-profile");
  ctx.step = resolveCurrentStep(state, { profile: resolveSessionProfile(state, sid), sessionId: sid });
  if (!ctx.step) return "no-step";
  if (!Array.isArray(row.steps) || !row.steps.includes(ctx.step)) return "step-mismatch";
  if (ctx.step === "user_verification") return "approval-wait";
  if (require(APPROVAL_REASON).approvalWaitFor(sid, ctx.step, state) !== null) return "approval-wait";
  return null;
}

// decide({sid, transcriptPath, questions, metadata, overrides})
//   -> Promise<{route, dialogId, step, jevCalled, answers?}>; never null, never rejects.
async function decide(input = {}) {
  const ctx = { dialogId: null, step: null, jevCalled: false };
  const done = (route, extra) => Object.assign({ route }, ctx, extra || {});
  try {
    const md = input.metadata;
    ctx.dialogId = md && typeof md === "object" && !Array.isArray(md) ? levels.normalizeDialogId(md.source) : null;
    const questions = input.questions;
    if (!Array.isArray(questions) || questions.length === 0) return done("invalid-input");
    const stop = gate(input, ctx);
    if (stop) return done(stop);
    try { require(ADAPTER).keysFor({ extra: { questions } }); } catch (_e) { return done("adapter-reject"); }
    if (questions.some((q) => q && q.multiSelect === true)) return done("multiselect");
    ctx.jevCalled = true;
    const r = await require("./jev/conversation-point").judgeConversation({
      point: "askuser-answer",
      sessionId: input.sid,
      transcriptPath: input.transcriptPath,
      judgedIn: JUDGED_IN,
      extra: { questions },
      overrides: input.overrides,
    });
    if (!r || r.used !== true || !r.final || r.final.route !== "auto-answer") return done("jev-declined");
    return done("answered", { answers: r.answers });
  } catch (_e) {
    return done("error");
  }
}

module.exports = { decide };
