"use strict";
// wait-on-invoke (#2461): on ACTION=invoke, ask Jev once per session x step x turn
// whether the main conversation should hold the next skill back. The query runs in a child with
// a hard timeout so next-step stays bounded; any failure gives no advice (fail-open).
// A step advised once is never advised again, in any later turn: the advice cannot loop.

const path = require("path");
const HOOKS = path.join(__dirname, "..", "..", "..", "..", "hooks");
const { readVersioned, writeJsonAtomic } = require(path.join(HOOKS, "lib", "jev", "state-paths"));

const CACHE_FILE = "wait-on-invoke.json";
const CACHE_VERSION = 1;
const CHILD = path.join(__dirname, "wait-on-invoke-child.js");
const CHILD_TIMEOUT_MS = 3000;
const ADVICE = "wait-on-invoke";

// Set by cli.js (the setNoteLine pattern): --jev-cache-only reads the cache and never queries;
// the raw --session value resolves to the same sid verdict.js resolves.
let cacheOnly = false;
let sessionArg;
function setCacheOnly(v) {
  cacheOnly = v === true;
}
function setSessionArg(v) {
  sessionArg = v;
}

function cachePath(sid, forWrite) {
  return require(path.join(HOOKS, "workflow-state", "state-io", "control-dir")).controlPath(sid, CACHE_FILE, { forWrite });
}

// The cache: {version, turn: {turn_id, steps: {step: {intervene, keys}}}, advised: {step: turn_id}}.
// Only the current turn's verdicts are kept; advised keeps every step ever advised.
function readCache(sid) {
  let c = null;
  try { c = readVersioned(cachePath(sid, false), CACHE_VERSION); } catch (_e) { c = null; }
  const ok = (o) => o && typeof o === "object" && !Array.isArray(o);
  const turn = c && ok(c.turn) && typeof c.turn.turn_id === "string" && ok(c.turn.steps) ? c.turn : null;
  return { version: CACHE_VERSION, turn, advised: c && ok(c.advised) ? c.advised : {} };
}

// writeVerdict(sid, step, turnId, {intervene, keys}) — the child's write; best effort.
function writeVerdict(sid, step, turnId, verdict) {
  try {
    const c = readCache(sid);
    const turn = c.turn && c.turn.turn_id === turnId ? c.turn : { turn_id: turnId, steps: {} };
    turn.steps[step] = { intervene: verdict.intervene === true, keys: Array.isArray(verdict.keys) ? verdict.keys : [] };
    if (verdict.intervene === true && !c.advised[step]) c.advised[step] = turnId;
    writeJsonAtomic(cachePath(sid, true), { version: CACHE_VERSION, turn, advised: c.advised });
  } catch (_e) { /* best effort: a lost cache only means one more query */ }
}

function adviceOf(verdict) {
  if (!verdict || verdict.intervene !== true) return null;
  const reason = require(path.join(HOOKS, "lib", "jev", "adapters", "continuation")).reasonOf(verdict.keys);
  return reason ? { advice: ADVICE, reason } : null;
}

// The cached answer for this step and turn: {hit, advice}. A step advised in an earlier turn is a
// hit with no advice, so Jev is not asked again.
function fromCache(c, step, turnId) {
  if (c.advised[step] && c.advised[step] !== turnId) return { hit: true, advice: null };
  const v = c.turn && c.turn.turn_id === turnId ? c.turn.steps[step] : undefined;
  return v ? { hit: true, advice: adviceOf(v) } : { hit: false, advice: null };
}

// The step next-step is on, resolved against this process's repoDir as verdict.js does: without
// it the glossary check reads another checkout and can report an earlier step.
function currentStepOf(sid) {
  const { readState } = require(path.join(HOOKS, "workflow-state", "state-io"));
  const { resolveCurrentStep } = require(path.join(HOOKS, "workflow-state", "current-step"));
  const { resolveSessionProfile } = require(path.join(HOOKS, "workflow-state", "session-profile"));
  const state = readState(sid);
  if (!state || !state.steps) return null;
  const repoDir = require("./repo-dir").resolveRepoDir();
  return resolveCurrentStep(state, { profile: resolveSessionProfile(state, sid, { repoDir }), sessionId: sid, repoDir });
}

function isJevOn() {
  try { return require(path.join(HOOKS, "lib", "jev", "broker")).isEnabled() === true; } catch (_e) { return false; }
}

// adviseOnInvoke({sid, cacheOnly}) -> {advice: "wait-on-invoke", reason} or null.
function adviseOnInvoke(o = {}) {
  try {
    const sid = o.sid;
    if (!isJevOn()) return null;
    const gen = require(path.join(HOOKS, "lib", "turn-generation")).readTurnGeneration(sid);
    if (!gen) return null;
    const step = currentStepOf(sid);
    if (typeof step !== "string" || step === "") return null;
    const cached = fromCache(readCache(sid), step, gen.turnId);
    if (cached.hit || (o.cacheOnly === undefined ? cacheOnly : o.cacheOnly)) return cached.advice;
    // The caller's own env, not the .env-injected one: the child's test overrides must see exports only.
    const env = Object.assign({}, require(path.join(HOOKS, "lib", "load-env")).getPristineProcessEnv());
    const r = require("child_process").spawnSync(process.execPath, [CHILD, sid, step, gen.turnId, gen.transcriptPath], {
      timeout: CHILD_TIMEOUT_MS, stdio: ["ignore", "ignore", "ignore"], windowsHide: true, env,
    });
    if (!r || r.status !== 0) return null;
    return fromCache(readCache(sid), step, gen.turnId).advice;
  } catch (_e) {
    return null;
  }
}

// hasAdviceInTurn(sid, turnId) -> true when any step was advised in this turn (Step 4 reads it).
function hasAdviceInTurn(sid, turnId) {
  try {
    return typeof turnId === "string" && Object.values(readCache(sid).advised).includes(turnId);
  } catch (_e) {
    return false;
  }
}

// The two advice lines emit() appends on ACTION=invoke, or "".
function adviceLines() {
  let sid = null;
  try { sid = require(path.join(HOOKS, "workflow-state")).resolveSessionId({ sessionIdFromInput: sessionArg }); } catch (_e) { sid = null; }
  if (!sid) return "";
  const a = adviseOnInvoke({ sid });
  return a ? `JEV_ADVICE=${a.advice}\nJEV_ADVICE_REASON='${a.reason.replace(/'/g, "")}'\n` : "";
}

module.exports = {
  CACHE_FILE, CHILD_TIMEOUT_MS, setCacheOnly, setSessionArg, adviseOnInvoke, hasAdviceInTurn, adviceLines, writeVerdict,
};
