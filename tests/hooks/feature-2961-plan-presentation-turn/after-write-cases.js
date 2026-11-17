"use strict";
// #2961 after-write cases: the plan-link text show-plan-link adds after a plan write. A stage that is
// not-ready or approved is written in a mid-turn, so its entry gets the INTERIM duty (no link line
// now, the plan presentation turn comes after the gate answers ask / proceed) and no PUBLISH_NOTE;
// ready and unknown keep the legacy ON / OFF duty. Mixed duties print one _ONE text per entry.
// Called from ../feature-2961-plan-presentation-turn.js, which owns the case markers.
const path = require("path");
const assert = require("node:assert/strict");
const { spawnSync } = require("child_process");
const C = require("./common");

const { R, D, S, show } = C;
const PL = () => C.mod("hooks/lib/plan-link");
const render = (entries) => PL().renderModelContext(entries, { when: "after-write" });
const interim = () => C.need("hooks/lib/plan-link.js", "INTERIM_DUTY");
const interimOne = () => C.need("hooks/lib/plan-link.js", "INTERIM_DUTY_ONE");
const entry = (stage, gate, readiness) => Object.assign(
  { stage, gate, path: `/plans/fixture-${stage}.md`, reason: "not-published" }, readiness ? { readiness } : {});

// lineAfter(ctx, stage) -> the line printed right after the stage's entry line.
function lineAfter(ctx, stage) {
  const lines = String(ctx).split(/\r?\n/);
  const i = lines.findIndex((l) => l.startsWith(`${stage}: `));
  return i < 0 ? `NO ENTRY LINE FOR ${stage}` : String(lines[i + 1]);
}

function interimExported() {
  for (const [name, text] of [["INTERIM_DUTY", interim()], ["INTERIM_DUTY_ONE", interimOne()]]) {
    assert.equal(typeof text, "string", `${name} is a string`);
    assert.ok(text.length > 0, `${name} is not empty`);
    assert.ok(!text.includes(C.ON_ONE_HEAD) && !text.includes(C.ON_HEAD), `${name} asks for no link line: ${text}`);
  }
}

// An entry without readiness renders as before (legacy ON duty + PUBLISH_NOTE).
function legacyWithoutReadiness() {
  const ctx = render([entry("outline", "ON")]);
  assert.ok(ctx.includes(C.ON_HEAD), ctx);
  assert.ok(ctx.includes(C.PUBLISH_HEAD), ctx);
}

// Every entry not-ready or approved: the INTERIM duty only.
function allInterim() {
  const text = interim();
  for (const set of [[entry("outline", "ON", "not-ready")], [entry("intent", "ON", "approved"), entry("outline", "ON", "not-ready")]]) {
    const ctx = render(set);
    assert.ok(ctx.includes(text), `INTERIM_DUTY shown:\n${ctx}`);
    assert.ok(!ctx.includes(C.ON_HEAD) && !ctx.includes(C.ON_ONE_HEAD), `no link-line duty:\n${ctx}`);
    assert.ok(!ctx.includes(C.PUBLISH_HEAD), `no PUBLISH_NOTE:\n${ctx}`);
  }
}

// ready and unknown keep the gate's duty.
function readyAndUnknownKeepLegacy() {
  for (const st of ["ready", "unknown"]) {
    const on = render([entry("outline", "ON", st)]);
    assert.ok(on.includes(C.ON_HEAD) && on.includes(C.PUBLISH_HEAD), `${st} ON:\n${on}`);
    const off = render([entry("detail", "OFF", st)]);
    assert.ok(off.includes(C.OFF_HEAD) && !off.includes(C.PUBLISH_HEAD), `${st} OFF:\n${off}`);
  }
}

// Mixed gates x mixed readiness: one _ONE text per entry, INTERIM counted as its own duty.
function mixedPerEntry() {
  const one = interimOne();
  const ctx = render([entry("intent", "ON", "approved"), entry("outline", "ON", "ready"), entry("detail", "OFF", "ready")]);
  assert.equal(lineAfter(ctx, "intent"), one, ctx);
  assert.ok(lineAfter(ctx, "outline").startsWith(C.ON_ONE_HEAD), ctx);
  assert.ok(lineAfter(ctx, "detail").startsWith(C.OFF_ONE_HEAD), ctx);
  const two = render([entry("intent", "ON", "not-ready"), entry("outline", "ON", "ready")]);
  assert.equal(lineAfter(two, "intent"), one, `INTERIM + ON is mixed:\n${two}`);
  assert.ok(lineAfter(two, "outline").startsWith(C.ON_ONE_HEAD), two);
  assert.ok(!two.includes(interim()), `no shared INTERIM_DUTY when mixed:\n${two}`);
}

// emit(sid, stages, cfgOver) -> additionalContext of a child emitForArtifacts run on the stages' plans
// (sync reports a failed push, so a plan without a URL is not-published).
function emit(sid, stages, cfgOver) {
  const plans = stages.map((st) => R.linesFor(sid, st).plan);
  const scene = { root: C.ROOT, sid, plans, result: { status: "failed", reason: "fixture" }, cwd: R.TDIR };
  const env = R.envFor({ cfg: R.cfg(cfgOver), mode: "not-published", env: { F2961_EMIT: JSON.stringify(scene), CONV_LANG: "english" } });
  const r = spawnSync(process.execPath, [path.join(__dirname, "emit-driver.js")], { env, encoding: "utf8", timeout: 60000, cwd: R.TDIR });
  assert.equal(r.status, 0, `emit driver exit ${r.status}: ${r.stderr}`);
  let json = {};
  try { json = JSON.parse(r.stdout || "{}"); } catch (_) { json = {}; }
  return String((json.hookSpecificOutput || {}).additionalContext || "");
}

// The real hook path: an unsettled outline is a mid-turn, a settled one keeps the legacy duty.
function emitByReadiness() {
  const text = interim();
  const mid = emit(C.at("outline", { audit: false }).sid, ["outline"]);
  assert.ok(mid.includes(text), `not-ready: INTERIM_DUTY:\n${mid}`);
  assert.ok(!mid.includes(C.ON_HEAD) && !mid.includes(C.PUBLISH_HEAD), `not-ready: no link duty, no PUBLISH_NOTE:\n${mid}`);
  const ready = emit(C.at("outline").sid, ["outline"]);
  assert.ok(ready.includes(C.ON_HEAD) && ready.includes(C.PUBLISH_HEAD), `ready: legacy ON duty:\n${ready}`);
  assert.ok(!ready.includes(text), `ready: no INTERIM_DUTY:\n${ready}`);
}

// One write of three plans at detail with CONFIRM_DETAIL off: intent approved (INTERIM), outline
// edited and settled again (ready, ON), detail waived and settled (ready, OFF).
function emitMixed() {
  const one = interimOne();
  const s = C.at("detail");
  D.editPlan(s.sid, "outline", 51);
  S.trySettle(s.sid, "outline", "CONTINUE");
  S.trySettle(s.sid, "detail", "CONTINUE");
  const ctx = emit(s.sid, ["intent", "outline", "detail"], { CONFIRM_DETAIL: "off" });
  assert.equal(lineAfter(ctx, "intent"), one, ctx);
  assert.ok(lineAfter(ctx, "outline").startsWith(C.ON_ONE_HEAD), ctx);
  assert.ok(lineAfter(ctx, "detail").startsWith(C.OFF_ONE_HEAD), ctx);
}

// CONFIRM_INTENT=off: the clarify_intent gate is still ON, so a settled intent gets the ON duty.
function emitIntentOff() {
  const ctx = emit(C.at("intent").sid, ["intent"], { CONFIRM_INTENT: "off" });
  assert.ok(ctx.includes(C.ON_HEAD), `ON duty:\n${ctx}`);
  assert.ok(!ctx.includes(C.OFF_HEAD), `no OFF duty:\n${ctx}`);
  assert.ok(!ctx.includes(interim()), `no INTERIM_DUTY:\n${ctx}`);
}

module.exports = {
  interimExported, legacyWithoutReadiness, allInterim, readyAndUnknownKeepLegacy, mixedPerEntry,
  emitByReadiness, emitMixed, emitIntentOff, show,
};
