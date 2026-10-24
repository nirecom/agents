"use strict";
// Tests: hooks/stop-confirm-plan-guard.js
// Tags: TL2, hooks, stop-hook, confirm-plan, conv-lang, model-facing, scope:issue-specific
// #2731 R2: every block reason of the Stop hook starts with the CONV_LANG injection exactly once
// (withConvLang). layer2 / plan-link / plan-lang are wrapped in firstBlock; not-last / unpublished /
// continue are wrapped in lib/confirm-continuation.js and must not be wrapped twice.
// TL3 gap (what this test does NOT catch):
// - how the real Claude Code host feeds the Stop block reason back to the model
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
// preflight via bin/check-verification-gate.sh category: hook-registration.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

// The shared fixtures read WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR at load: pin them first.
const restore = isolate();
after(() => restore());
const R = require("./feature-2729-presentation-receipt/fixture");
const C = require("../lib/system-message-contract");
const { A, U, TR, BASH } = R;

const HOOK = path.join(R.ROOT, "hooks", "stop-confirm-plan-guard.js");
const CONV_LANG_LIB = path.join(R.ROOT, "hooks", "lib", "conv-lang.js");
const QUESTION = "Does this look right?";
// Japanese prose built from code points so the file stays ASCII-only.
const JA_BODY = String.fromCharCode(0x3053, 0x306e, 0x8a08, 0x753b, 0x306f, 0x65e5, 0x672c, 0x8a9e, 0x3067, 0x66f8, 0x304b, 0x308c, 0x305f, 0x672c, 0x6587, 0x3067, 0x3059, 0x3002);
const JA_OUTLINE = "# Outline\n\n## Approach\n\n" + JA_BODY + "\n\n## Issues\n\n- #1 fixture\n";

// injection(lang) -> getConvLangInjection() as the hook child resolves it (the fixture config root).
function injection(lang) {
  const saved = { CONV_LANG: process.env.CONV_LANG, AGENTS_MAIN_ROOT: process.env.AGENTS_MAIN_ROOT };
  process.env.CONV_LANG = lang;
  process.env.AGENTS_MAIN_ROOT = R.DEFAULT_CFG;
  try { return require(CONV_LANG_LIB).getConvLangInjection(); } finally {
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
}

// stop(sid, tpath, lang, opts) -> the Stop hook's result with CONV_LANG=lang in the child env.
function stop(sid, tpath, lang, opts) {
  const o = opts || {};
  const env = R.envFor(o);
  env.CONV_LANG = lang;
  // process.env wins over the fixture .env: pin PLAN_LANG so an ambient value cannot mask plan-lang.
  env.PLAN_LANG = "english";
  env.CLAUDE_TRANSCRIPT_BASE_DIR = R.TDIR;
  const input = { session_id: sid, transcript_path: tpath, hook_event_name: "Stop", stop_hook_active: false };
  const r = spawnSync(process.execPath, [HOOK], { input: JSON.stringify(input), env, encoding: "utf8", timeout: 60000, cwd: R.TDIR });
  let json = {};
  try { json = r.stdout ? JSON.parse(r.stdout) : {}; } catch (_) { json = { unparsed: r.stdout }; }
  const reason = typeof json.reason === "string" ? json.reason : "";
  return { rc: r.status, out: r.stdout || "", err: r.stderr || "", reason, blocked: r.status === 2 && json.decision === "block" };
}

const urlClose = (s) => "Here is the plan.\n\n" + s.urlLine;
const pathLine = (s, reason) => `${s.stage}: \`${s.fwd}\` (no URL: ${reason})`;

// Each scenario builds a fresh session and returns {res, body}: body is the bare-reason marker.
const SCENARIOS = {
  "layer2-follow-up": (lang) => {
    const s = R.sessionAt("outline", { tag: 1 });
    const tp = R.writeTranscript(s.sid, [U("go", "u-p"), A("a-echo", BASH(R.echoOf("outline"), "e1")), TR("e1", "u-e1")]);
    return { res: stop(s.sid, tp, lang), body: "[confirm-plan] Layer 2/follow-up" };
  },
  "layer2-plan-lang": (lang) => {
    const s = R.sessionAt("outline", { tag: 2, body: JA_OUTLINE });
    const tp = R.writeTranscript(s.sid, [U("go", "u-p"), A("a-echo", BASH(R.echoOf("outline"), "e1")), TR("e1", "u-e1")]);
    return { res: stop(s.sid, tp, lang), body: "[confirm-plan] Layer 2/plan-lang" };
  },
  "presented-plan-lang": (lang) => {
    const s = R.sessionAt("outline", { tag: 3, body: JA_OUTLINE });
    return { res: stop(s.sid, R.presentTurn(s, ["outline"], urlClose(s)), lang), body: "[confirm-plan] Layer 2/plan-lang" };
  },
  "plan-link": (lang) => {
    const s = R.sessionAt("outline", { tag: 4 });
    return { res: stop(s.sid, R.presentTurn(s, ["outline"], "I rewrote the outline; more to come."), lang), body: "[confirm-plan]" };
  },
  "not-last": (lang) => {
    const s = R.sessionAt("outline", { tag: 5 });
    const res = stop(s.sid, R.presentTurn(s, ["outline"], urlClose(s) + "\n\n" + QUESTION), lang);
    return { res, body: "[confirm-plan] present the outline plan again (not-last)" };
  },
  unpublished: (lang) => {
    const s = R.sessionAt("outline", { tag: 6 });
    const tp = R.presentTurn(s, ["outline"], "Here is the plan.\n\n" + pathLine(s, "not-published"));
    return { res: stop(s.sid, tp, lang, { mode: "not-published" }), body: "[confirm-plan] present the outline plan again (unpublished)" };
  },
  continuation: (lang) => {
    const s = R.sessionAt("outline", { tag: 7 });
    return { res: stop(s.sid, R.presentTurn(s, ["outline"], urlClose(s)), lang), body: "[confirm-plan] continue:" };
  },
};

const show = (res) => JSON.stringify({ rc: res.rc, out: res.out.slice(0, 400), err: res.err.slice(0, 200) });

// assertFixture(name, res, body): the scenario reached the intended block kind (not a harness error).
function assertFixture(name, res, body) {
  assert.ok(res.blocked, `fixture: ${name} blocks: ${show(res)}`);
  assert.ok(res.reason.includes(body), `fixture: ${name} reason carries "${body}":\n${res.reason}`);
}
function assertPrefixedOnce(name, res) {
  const inj = injection("japanese");
  assert.ok(typeof inj === "string" && inj.length > 0, "fixture: japanese resolves to an injection");
  assert.ok(res.reason.startsWith(inj + "\n"), `${name}: reason starts with the CONV_LANG injection:\n${res.reason}`);
  assert.ok(C.prefixedOnce(res.reason, "japanese"), `${name}: the injection appears exactly once:\n${res.reason}`);
}
function assertBare(name, res, body) {
  assert.strictEqual(C.countDirective(res.reason), 0, `${name}: no directive under english:\n${res.reason}`);
  assert.ok(res.reason.startsWith("[confirm-plan]"), `${name}: the reason is the unchanged bare text:\n${res.reason}`);
  assert.ok(res.reason.includes(body), `${name}: the body survives:\n${res.reason}`);
}

caseBegin("conv-lang-layer2-follow-up", "hooks/stop-confirm-plan-guard.js");
test("japanese: Layer 2/follow-up reason starts with the CONV_LANG injection once", () => {
  const { res, body } = SCENARIOS["layer2-follow-up"]("japanese");
  assertFixture("layer2-follow-up", res, body);
  assertPrefixedOnce("layer2-follow-up", res);
});
caseEnd();

caseBegin("conv-lang-plan-lang", "hooks/stop-confirm-plan-guard.js");
for (const name of ["layer2-plan-lang", "presented-plan-lang"]) {
  test(`japanese: ${name} reason starts with the CONV_LANG injection once`, () => {
    const { res, body } = SCENARIOS[name]("japanese");
    assertFixture(name, res, body);
    assertPrefixedOnce(name, res);
  });
}
caseEnd();

caseBegin("conv-lang-plan-link", "hooks/stop-confirm-plan-guard.js");
test("japanese: plan-link reason starts with the CONV_LANG injection once", () => {
  const { res, body } = SCENARIOS["plan-link"]("japanese");
  assertFixture("plan-link", res, body);
  assert.ok(/plan-link/.test(res.reason) && !res.reason.includes("continue:") && !res.reason.includes("Layer 2"),
    `fixture: plan-link kind:\n${res.reason}`);
  assertPrefixedOnce("plan-link", res);
});
caseEnd();

caseBegin("conv-lang-already-wrapped-once", "hooks/stop-confirm-plan-guard.js");
for (const name of ["not-last", "unpublished", "continuation"]) {
  test(`japanese: ${name} reason carries the injection exactly once (no double wrap)`, () => {
    const { res, body } = SCENARIOS[name]("japanese");
    assertFixture(name, res, body);
    assertPrefixedOnce(name, res);
  });
}
caseEnd();

caseBegin("conv-lang-english-bare", "hooks/stop-confirm-plan-guard.js");
for (const name of Object.keys(SCENARIOS)) {
  test(`english: ${name} reason is the bare text without the injection`, () => {
    assert.strictEqual(injection("english"), null, "fixture: english resolves to no injection");
    const { res, body } = SCENARIOS[name]("english");
    assertFixture(name, res, body);
    assertBare(name, res, body);
  });
}
caseEnd();
