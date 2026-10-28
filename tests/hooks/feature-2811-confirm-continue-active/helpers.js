"use strict";
// Private helpers of tests/hooks/feature-2811-confirm-continue-active.js: the Stop hook runner with
// the two fault preloads, receipt/mark readers and the notice reader. Builds on the #2771 helpers.
// Requires the caller's isolate() pins first.
const path = require("path");
const R = require("../feature-2729-presentation-receipt/fixture");
const H = require("../feature-2771-undecidable-receipt/helpers");
const { A, T } = R;

const MARK_FAULT = path.join(__dirname, "mark-fault-preload.js");
const REREAD = path.join(__dirname, "reread-preload.js");

// stopOf(s, tp, o) -> the Stop hook result. o.active -> stop_hook_active; o.last -> last_assistant_message;
// o.pre -> extra preloads; o.env -> extra child env (PLAN_LANG pinned to english unless given); o.cfg -> config root.
function stopOf(s, tp, o) {
  const x = o || {};
  const env = Object.assign({ PLAN_LANG: "english", CONV_LANG: "english", NODE_OPTIONS: R.nodeOptions([R.PRELOAD].concat(x.pre || [])) }, x.env || {});
  const input = Object.assign({ stop_hook_active: x.active === true }, x.last === undefined ? {} : { last_assistant_message: x.last });
  return R.stop(s.sid, tp, { cfg: x.cfg, env, input });
}
const faultEnv = (modes, stage) => Object.assign({ CC_MARK_FAULT: modes }, stage ? { CC_MARK_FAULT_STAGE: stage } : {});

// decidable(s, stages) -> {close, tp}: a turn whose last text entry closes on the stages' link lines.
function decidable(s, stages) {
  const close = H.closing(s, stages);
  return { close, tp: H.turn(s, stages, [A("a-anchor", T(close))]) };
}

// rereadRun(s, stages, kind, variant) -> the pieces of an undecidable Stop whose settle-time re-read is
// controlled: kind "both" (an anchored text entry also closes on the links) or "finalOnly"; variant
// "flushed" (re-read holds the final message, no tool_use), "tooluse" (flushed, tool_use in the last
// entry), "thinkonly" / "toolthink" (see below) or "unflushed" (the re-read never holds it). Returns {msg, opts(active)}.
function rereadRun(s, stages, kind, variant) {
  const close = H.closing(s, stages);
  const msg = H.relinked(close);
  const oldTp = H.turn(s, stages, kind === "both" ? [A("a-anchor", T(close))] : H.MID);
  const env = { CC_REREAD_OLD: oldTp };
  if (variant !== "unflushed") {
    const last = variant === "tooluse" ? A("a-final", T(msg), R.BASH("ls", "b-final")) : A("a-final", T(msg));
    // "thinkonly": text entry then a thinking-only entry; "toolthink": text entry, a tool_use entry, then a thinking-only entry.
    const tail = variant === "thinkonly" ? [last, H.THINK("a-think")]
      : variant === "redacted" ? [last, H.THINK("a-think", "redacted_thinking")]
      : variant === "toolthink" ? [last, A("a-tool", R.BASH("ls", "b-tool")), H.THINK("a-think")] : [last];
    env.CC_REREAD_NEW = H.turn(s, stages, tail);
  }
  // opts(active, more): more.env / more.pre / more.cfg add to the run (e.g. the receipt fault preload).
  const opts = (active, more) => {
    const m = more || {};
    return Object.assign({ active, last: msg, pre: [REREAD].concat(m.pre || []), env: Object.assign({}, env, m.env || {}) }, m.cfg ? { cfg: m.cfg } : {});
  };
  return { msg, tp: oldTp, opts };
}

const rcpt = (sid, stage) => R.readReceiptRaw(sid, stage);
const marked = (sid, stage) => { const r = rcpt(sid, stage); return r !== null && typeof r.continuedAt === "string" && r.continuedAt !== ""; };
const sysMsg = (st) => (typeof st.json.systemMessage === "string" ? st.json.systemMessage : "");
const noDecision = (st) => !("decision" in st.json);
const isContinue = (st, stage) => st.rc === 2 && st.continued && st.reason.includes(`WORKFLOW_CONFIRM_${stage.toUpperCase()}`);

module.exports = Object.assign({}, H, { MARK_FAULT, REREAD, stopOf, faultEnv, decidable, rereadRun, rcpt, marked, sysMsg, noDecision, isContinue });
