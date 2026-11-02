"use strict";
// continue-on-stop (#2461): when the Stop guard would let a stop through, ask Jev whether
// work the assistant can do alone was left undone. Jev is never asked while a human or a delegated
// step is being waited on. A confident yes blocks the stop once per turn with a fixed reason;
// every other outcome, failures included, lets the stop pass.

const path = require("path");

const CONTROL_FILE = "continue-on-stop.json";
const CONTROL_VERSION = 1;
const DIRECTION = "continue-on-stop";
const JUDGED_IN = Object.freeze({ kind: "hook", name: "stop-premature-stop-guard" });
// null: next-step failed, timed out or printed no ACTION — Jev reads the transcript alone.
const CONSULT_ACTIONS = new Set([null, "done", "blocked", "abort"]);
const WAIT_ON_INVOKE = path.join(__dirname, "..", "..", "bin", "workflow", "lib", "next-step", "wait-on-invoke");

// shouldConsult({sessionExemption, inFlightStep, action, outputExemption}) -> boolean.
// In flight, only write_code is the main conversation's own work; a delegated step is waited on.
function shouldConsult(o = {}) {
  if (o.sessionExemption === "step-in-flight") return o.inFlightStep === "write_code";
  if (o.sessionExemption !== null && o.sessionExemption !== undefined) return false;
  if (o.outputExemption) return false;
  return CONSULT_ACTIONS.has(o.action === undefined ? null : o.action);
}

function controlPath(sid, forWrite) {
  return require("../workflow-state/state-io/control-dir").controlPath(sid, CONTROL_FILE, { forWrite });
}

// The turn already promoted once, or null; a corrupt file counts as absent.
function promotedTurn(sid) {
  try {
    const c = require("./jev/state-paths").readVersioned(controlPath(sid, false), CONTROL_VERSION);
    return c && typeof c.turn_id === "string" ? c.turn_id : null;
  } catch (_e) {
    return null;
  }
}

function blockReason(keys) {
  const why = require("./jev/adapters/continuation").reasonOf(keys) || "work remains";
  const { withConvLang } = require("./conv-lang");
  return withConvLang(
    `[jev continue-on-stop] This turn stopped early: ${why}. Continue the work now; if a user ` +
    "decision is needed, ask it with the AskUserQuestion tool. (Hook: stop-premature-stop-guard.js)");
}

// consult(route, {sid, transcriptPath, overrides}) -> {decision: "block", reason} or null.
async function consult(route, ctx) {
  if (!shouldConsult(route)) return null;
  if (!require("./jev/broker").isEnabled()) return null;
  const gen = require("./turn-generation").readTurnGeneration(ctx.sid);
  if (!gen || promotedTurn(ctx.sid) === gen.turnId) return null;
  if (require(WAIT_ON_INVOKE).hasAdviceInTurn(ctx.sid, gen.turnId)) return null;
  const r = await require("./jev/conversation-point").judgeConversation({
    point: "continuation",
    direction: DIRECTION,
    sessionId: ctx.sid,
    transcriptPath: typeof ctx.transcriptPath === "string" && ctx.transcriptPath ? ctx.transcriptPath : gen.transcriptPath,
    judgedIn: JUDGED_IN,
    overrides: ctx.overrides,
  });
  if (!r || r.used !== true || !r.final || r.final.intervene !== true) return null;
  require("./jev/state-paths").writeJsonAtomic(controlPath(ctx.sid, true), { version: CONTROL_VERSION, turn_id: gen.turnId });
  return { decision: "block", reason: blockReason(r.keys) };
}

// exitAfterConsult(route, ctx): the guard's exit where the stop would pass — exit 2 with the
// block when Jev says to continue, else exit 0.
async function exitAfterConsult(route, ctx) {
  let out = null;
  try { out = await consult(route, ctx); } catch (_e) { out = null; }
  if (out) {
    try { process.stdout.write(JSON.stringify(out) + "\n"); } catch (_e) { /* fail-open */ }
    process.exit(2);
  }
  process.exit(0);
}

module.exports = { CONTROL_FILE, shouldConsult, consult, exitAfterConsult };
