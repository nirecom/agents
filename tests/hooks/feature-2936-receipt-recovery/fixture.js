"use strict";
// Private fixture of tests/hooks/feature-2936-receipt-recovery.js (and the hint fallback case of
// feature-2936-no-receipt-wording.js): the timestamped turn pair of a presentation whose Stop never
// ran, a CONFIRM echo that counts recoverReceipt calls (recovery-spy-preload.js), the receipt log's
// events, and the direct-driver.js runs. The caller pins the isolation before requiring it.
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const R = require("../feature-2729-presentation-receipt/fixture");
const K = require("../feature-2936-stop-budget-kill/fixture");

const SPY = path.join(__dirname, "recovery-spy-preload.js");
const DRIVER = path.join(__dirname, "direct-driver.js");
// The deny hint, verbatim from the detail plan (S7); the module under test must carry the same text.
const HINT = "the Stop hook records the presentation when the turn ends and may have timed out before it did; " +
  "to check, look in presentation-receipt-log.jsonl for a \"write\" record of this step after that turn — none means it was never recorded";
const TM = () => require(path.join(R.ROOT, "hooks/lib/turn-marker"));

// pair(s, o) -> {tp, entries, base, at, openerIso}: turn N (o.last, default the plan-link closing) whose
// Stop never ran, then turn N+1 opening with the CONFIRM echo, a minute in the past.
// o.markers: [[stage, ms]] turn markers (default [[s.stage, 1000]]); o.planMs: the plan mtime (-10000);
// o.anchorUuid: null drops it; o.anchorTs / o.openerTs: false drop the timestamp; o.sameTurn: the echo
// closes turn N itself after an older plain turn; o.onePrompt: the opener is the only real prompt.
function pair(s, o) {
  const opt = o || {};
  const base = Date.now() - 60 * 1000;
  const at = (ms) => new Date(base + ms).toISOString();
  const mtime = new Date(base + (opt.planMs === undefined ? -10000 : opt.planMs));
  for (const [stage, ms] of opt.markers || [[s.stage, 1000]]) {
    TM().writeTurnMarker(s.sid, { session_id: s.sid, absPath: R.linesFor(s.sid, stage).plan, suffix: stage, ts: base + ms, created_at: at(ms) });
  }
  const stamp = (e, ms, keep) => (keep === false ? e : Object.assign(e, { timestamp: at(ms) }));
  const last = opt.last === undefined ? K.closingOf(s) : opt.last;
  const entries = [];
  if (opt.sameTurn) entries.push(stamp(R.U("an older question", "u-old"), -20000), stamp(R.A("a-old", R.T("An older answer.")), -19000));
  if (!opt.onePrompt) entries.push(stamp(R.U("write the plan", "u-prompt"), -5000));
  entries.push(stamp(R.A("a-w1", R.W(s.plan, "w1")), -4000), stamp(R.TR("w1", "u-tr1"), -3000));
  entries.push(stamp(R.A(opt.anchorUuid === undefined ? "a-anchor" : opt.anchorUuid, R.T(last)), 0, opt.anchorTs));
  if (opt.onePrompt) entries.unshift(stamp(R.U("looks good, go ahead", "u-open"), -6000));
  else if (!opt.sameTurn) entries.push(stamp(R.U("looks good, go ahead", "u-open"), 2000, opt.openerTs));
  entries.push(stamp(R.A("a-echo", R.ECHO(s.stage, "e1")), 2500));
  const tp = R.writeTranscript(s.sid, entries);
  // After the transcript write: the plan file's mtime is what the recovery compares with the anchor.
  fs.utimesSync(s.plan, mtime, mtime);
  return { tp, entries, base, at, openerIso: at(2000) };
}

let seq = 0;
// confirm(s, o) -> R.echo's result plus calls (recoverReceipt calls) and written ([bool] per call).
// o.tp: transcript_path (omitted: none sent); o.cfg; o.env (merged over the language pin and the
// preloads); o.fault: CC_RECOVER_FAULT; o.contFail: CC_CONT_FAIL.
function confirm(s, o) {
  const opt = o || {};
  const log = path.join(R.TDIR, `recover-${s.sid}-${++seq}.log`);
  const env = Object.assign({}, K.LANG_ENV, { NODE_OPTIONS: R.nodeOptions([R.PRELOAD, SPY]), CC_RECOVER_LOG: log }, opt.env || {});
  if (opt.fault) env.CC_RECOVER_FAULT = opt.fault;
  if (opt.contFail) env.CC_CONT_FAIL = "1";
  const e = R.echo(s.sid, s.stage, { transcriptPath: opt.tp, cfg: opt.cfg, env });
  let lines = [];
  try { lines = fs.readFileSync(log, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch (_) { /* no call */ }
  return Object.assign(e, {
    calls: lines.filter((l) => "call" in l).length,
    written: lines.filter((l) => "written" in l).map((l) => l.written),
    text: JSON.stringify(e.json),
  });
}

// events(sid, step) -> the receipt log's event names for the step, in order.
function events(sid, step) {
  try {
    return require(path.join(R.ROOT, "hooks/lib/presentation-receipt")).readReceiptLog(sid).filter((l) => l && l.step === step).map((l) => l.event);
  } catch (_) { return []; }
}

// direct(args, o) -> direct-driver.js's JSON line, run in the hooks' child env (o.cfg, o.env).
function direct(args, o) {
  const opt = o || {};
  const env = R.envFor({ cfg: opt.cfg, env: Object.assign({}, K.LANG_ENV, opt.env || {}) });
  const r = spawnSync(process.execPath, [DRIVER, ...args], { env, encoding: "utf8", timeout: 60000, cwd: R.TDIR });
  try { return JSON.parse(String(r.stdout).trim().split("\n").pop()); } catch (_) { return { unparsed: `${r.stdout} ${String(r.stderr).slice(0, 300)}` }; }
}

// logEvent(sid, step, event, iso) -> appends one receipt-log line in the module's {event, step, path, at}
// shape, so a record can carry a time other than now (before the anchor, or a consume with no write).
function logEvent(sid, step, event, iso) {
  const { controlPath } = require(path.join(R.ROOT, "hooks/workflow-state/state-io/control-dir"));
  const line = { event, step, path: R.receiptPath(sid, step), at: iso };
  fs.appendFileSync(controlPath(sid, "presentation-receipt-log.jsonl", { forWrite: true }), `${JSON.stringify(line)}\n`, "utf8");
}

const recoveredFinding =(sid, step) => R.findings(sid).some((f) => String(f.detail || "").includes(`receipt for ${step} recovered from the previous turn`));
const markerTimes = (sid) => K.markersOf(sid).map((m) => m.created_at).sort();
// hardPlan(s) -> rewrites s's plan to 201 prose lines (over the outline HARD limit of 200).
const hardPlan = (s) => fs.writeFileSync(s.plan, Array.from({ length: 201 }, (_, i) => `This is prose line ${i + 1} of the plan.`).join("\n") + "\n");
const unpublishedLine = (s) => `${s.stage}: \`${s.fwd}\` (no URL: not-published)`;

module.exports = { HINT, SPY, pair, confirm, events, direct, logEvent, recoveredFinding, markerTimes, hardPlan, unpublishedLine, TM };
