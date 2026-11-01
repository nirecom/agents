"use strict";
// askuser-jev-decide.js — whether Jev answers an AskUserQuestion dialog for the user (#2764).
// Each stage that does not hold returns null, so the dialog reaches the user. Only a dialog the
// model marked with metadata.source === AUTO_SKIP_MARKER is eligible (an allowlist): an unmarked
// dialog never reaches Jev and leaves no record, whatever language its question is written in.

const path = require("path");

const AUTO_SKIP_MARKER = "jev-auto-skip-askuser";
const JUDGED_IN = Object.freeze({ kind: "hook", name: "pre-tool-use-askuser-jev" });
const ADAPTER = path.join(__dirname, "jev", "adapters", "askuser-answer");
const APPROVAL_REASON = path.join(__dirname, "..", "..", "bin", "workflow", "lib", "next-step", "approval-reason");

function flagOn(name, dflt) {
  try {
    const r = require("./load-env").resolveConfigVar(name, dflt);
    return !r.loadFailed && String(r.value).trim().toLowerCase() === "on";
  } catch (_e) {
    return false;
  }
}

function isMarked(metadata) {
  return !!metadata && typeof metadata === "object" && metadata.source === AUTO_SKIP_MARKER;
}

// True while next-step waits for the user's plan approval or the step is user_verification.
function isApprovalWait(sid) {
  const ws = require("../workflow-state");
  const step = require("../workflow-state/current-step").resolveCurrentEffectiveStep(sid);
  if (step === "user_verification") return true;
  return require(APPROVAL_REASON).approvalWaitFor(sid, step, ws.readState(sid)) !== null;
}

// decide({sid, transcriptPath, questions, metadata, overrides}) -> Promise<{answers} | null>.
async function decide(input = {}) {
  const questions = input.questions;
  if (!Array.isArray(questions) || questions.length === 0 || typeof input.sid !== "string") return null;
  if (!isMarked(input.metadata)) return null;
  if (!flagOn("JEV", "off") || !flagOn("JEV_AUTO_SKIP_ASKUSER", "on")) return null;
  try { require(ADAPTER).keysFor({ extra: { questions } }); } catch (_e) { return null; }
  if (isApprovalWait(input.sid)) return null;
  if (questions.some((q) => q.multiSelect === true)) return null;
  const r = await require("./jev/conversation-point").judgeConversation({
    point: "askuser-answer",
    sessionId: input.sid,
    transcriptPath: input.transcriptPath,
    judgedIn: JUDGED_IN,
    extra: { questions },
    overrides: input.overrides,
  });
  if (!r || r.used !== true || !r.final || r.final.route !== "auto-answer") return null;
  return { answers: r.answers };
}

module.exports = { AUTO_SKIP_MARKER, decide };
