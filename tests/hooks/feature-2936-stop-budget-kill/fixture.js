"use strict";
// Private fixture of tests/hooks/feature-2936-stop-budget-kill.js: a ~40 MB transcript prefix built
// once, presentation turns appended to copies of it, a Stop guard run that times itself and counts
// its transcript reads (read-count-preload.js), and the timestamped turn pair of a killed Stop.
// The caller pins the isolation (isolate(), CLAUDE_TRANSCRIPT_BASE_DIR, cwd) before requiring it.
const fs = require("fs");
const path = require("path");
const R = require("../feature-2729-presentation-receipt/fixture");

const PRELOAD = path.join(__dirname, "read-count-preload.js");
const MB = 1024 * 1024;
// The guard's reply-language check is config-dependent: pinned to the closings' language.
const LANG_ENV = { CONV_LANG: "english" };

// bigPrefix(dir, mb) -> path of a JSONL file of past turns (a prompt, a Read call, a 1 MiB result
// and an answer each) of about `mb` MiB; no turn of it presents a plan.
function bigPrefix(dir, mb) {
  const p = path.join(dir, `prefix-${process.pid}.jsonl`);
  const body = "p".repeat(MB);
  const fd = fs.openSync(p, "w");
  try {
    for (let i = 0; i < mb; i++) {
      const turn = [
        { type: "user", uuid: `u-o${i}`, message: { role: "user", content: `old prompt ${i}` } },
        { type: "assistant", uuid: `a-o${i}`, message: { role: "assistant", content: [{ type: "tool_use", id: `t-o${i}`, name: "Read", input: { file_path: "C:/example/big.log" } }] } },
        { type: "user", uuid: `u-or${i}`, message: { role: "user", content: [{ type: "tool_result", tool_use_id: `t-o${i}`, content: body }] } },
        { type: "assistant", uuid: `a-oa${i}`, message: { role: "assistant", content: [{ type: "text", text: `old answer ${i}` }] } },
      ];
      fs.writeSync(fd, turn.map((e) => JSON.stringify(e)).join("\n") + "\n");
    }
  } finally {
    fs.closeSync(fd);
  }
  return p;
}

let seq = 0;
// onPrefix(prefix, sid, entries) -> a copy of the prefix with `entries` appended, in the fixture's
// transcript dir.
function onPrefix(prefix, sid, entries) {
  const p = path.join(R.TDIR, `big-${sid}-${++seq}.jsonl`);
  fs.copyFileSync(prefix, p);
  fs.appendFileSync(p, entries.map((e) => JSON.stringify(e)).join("\n") + "\n");
  return p;
}

// guard(s, tp, {message, offset}) -> R.stop's result plus {ms, reads: {bytes, fullReads}}.
function guard(s, tp, o) {
  const opt = o || {};
  const log = path.join(R.TDIR, `reads-${s.sid}-${++seq}.json`);
  const env = Object.assign({}, LANG_ENV, {
    NODE_OPTIONS: R.nodeOptions([R.PRELOAD, PRELOAD]), CC_READ_TARGET: tp, CC_READ_LOG: log,
  });
  if (opt.offset !== undefined) env.STOP_CONFIRM_CONTINUE_T0_OFFSET_MS = String(opt.offset);
  const input = typeof opt.message === "string" ? { last_assistant_message: opt.message } : {};
  const t0 = Date.now();
  const r = R.stop(s.sid, tp, { cfg: R.cfg(), env, input });
  const ms = Date.now() - t0;
  let reads = null;
  try { reads = JSON.parse(fs.readFileSync(log, "utf8")); } catch (_) { /* the preload wrote nothing */ }
  return Object.assign(r, { ms, reads });
}

const closingOf = (s) => "Here is the plan.\n\n" + s.urlLine;

// presentation(s, lastText, extra) -> the entries of one turn that rewrote s's plan and ended with
// the text `lastText` (then `extra` entries); writes the turn's marker.
function presentation(s, lastText, extra) {
  R.turnMarker(s.sid, s.stage, s.plan);
  return [
    R.U("write the plan", "u-prompt"), R.A("a-w1", R.W(s.plan, "w1")), R.TR("w1", "u-tr1"),
    R.A("a-anchor", R.T(lastText)), ...(extra || []),
  ];
}

// killedPair(s, o) -> {entries, base, openerIso}: turn N (the presentation, or a plain turn with
// o.plain) whose Stop never ran, then turn N+1 opening with the CONFIRM echo. Timestamps sit a
// minute in the past: plan mtime < turn N prompt < anchor < turn N marker < N+1 opener.
function killedPair(s, o) {
  const opt = o || {};
  const base = Date.now() - 60 * 1000;
  const at = (ms) => new Date(base + ms).toISOString();
  fs.utimesSync(s.plan, new Date(base - 10000), new Date(base - 10000));
  const TM = require(path.join(R.ROOT, "hooks/lib/turn-marker"));
  TM.writeTurnMarker(s.sid, { session_id: s.sid, absPath: s.plan, suffix: s.stage, ts: base + 1000, created_at: at(1000) });
  const stamp = (e, ms) => Object.assign(e, { timestamp: at(ms) });
  const last = opt.plain ? "I am still working on the plan." : closingOf(s);
  const entries = [
    stamp(R.U("write the plan", "u-prompt"), -5000), stamp(R.A("a-w1", R.W(s.plan, "w1")), -4000),
    stamp(R.TR("w1", "u-tr1"), -3000), stamp(R.A("a-anchor", R.T(last)), 0),
    stamp(R.U("looks good, go ahead", "u-open"), 2000), stamp(R.A("a-echo", R.ECHO(s.stage, "e1")), 2500),
  ];
  return { entries, base, at, openerIso: at(2000) };
}

const markersOf = (sid) => require(path.join(R.ROOT, "hooks/lib/turn-marker")).peekTurnMarkers(sid);

module.exports = { MB, LANG_ENV, bigPrefix, onPrefix, guard, closingOf, presentation, killedPair, markersOf };
