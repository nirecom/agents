"use strict";
// Refusal next-action cases of tests/hooks/feature-2941-pm-writer.js (#3152). No case markers.
// Every /pm-add refusal ends with forge-failure.js nextActionOf(reason): a reason retrying cannot fix
// (NOT_RETRYABLE) never tells the user to retry when the forge is back, and a failed field write names its own
// next action. Assumed (detail Step 7): assertOneOwner takes deps.readChainsAndTrees; a whole-call failure is
// {ok:false, reason}. The PM field goes in as deps.pmField (tests/lib/pm-s3-fixture.js withMany).
const assert = require("node:assert");
const { test } = require("node:test");
const W = require("./fixture");
const X = require("../../lib/pm-s3-fixture");
const { P } = W;

const OLD_RETRY = /retry when the forge is back/i;
const nextActionOf = (reason) => {
  const F = P.load("bin/lib/forge-failure.js");
  assert.strictEqual(typeof F.nextActionOf, "function", "bin/lib/forge-failure.js does not export nextActionOf (#3152)");
  const s = F.nextActionOf(reason);
  assert.ok(typeof s === "string" && s.length > 0, `nextActionOf(${reason}) is empty`);
  return s;
};

// addWith(nums, deps) -> {r, before, after}: /pm-add of nums by a PM alone in its state dir (no other PM).
function addWith(nums, deps) {
  return W.alone(() => {
    const sid = W.nextSid();
    const tag = W.nextTag("PM-na");
    P.seedPm(sid, P.pm({ tag, issues: [] }));
    const before = P.readPm(sid);
    const r = X.write(sid, P.wrapped("pm-add", `${nums.map((n) => `#${n}`).join(" ")} next action`), deps);
    return { r, before, after: P.readPm(sid) };
  });
}
// assertNextAction(x, reason, notRetryable, opts?) — opts.noParen: the message does not name the reason in parentheses.
function assertNextAction(x, reason, notRetryable, opts) {
  W.assertBlocked(x.r);
  assert.ok(x.r.block.includes(nextActionOf(reason)), `refusal lacks nextActionOf(${reason}): ${W.brief(x.r)}`);
  if (!(opts && opts.noParen)) assert.ok(x.r.block.includes(`(${reason})`), `refusal lacks the reason (${reason}): ${W.brief(x.r)}`);
  if (notRetryable) assert.doesNotMatch(x.r.block, OLD_RETRY, `a ${reason} refusal still asks for a retry: ${W.brief(x.r)}`);
  assert.doesNotMatch(x.r.block, /undefined/, `a ${reason} refusal names undefined: ${W.brief(x.r)}`);
  assert.deepStrictEqual(x.after, x.before, "a refused add changed the PM state");
}
const allNull = (refs) => ({ ok: true, values: Object.fromEntries(refs.map((r) => [X.refKey(r), null])) });

function nextAction() {
  for (const reason of ["sub-issue-depth-cap", "pm-field-ambiguous", "issue_not_found", "repo-unknown"]) {
    test(`N1 /pm-add whose owner check fails with ${reason} (not retryable): the refusal gives nextActionOf, no retry advice`, () => {
      const field = X.field();
      const x = addWith([8601], { pmField: field, readChainsAndTrees: () => ({ ok: false, reason }) });
      assertNextAction(x, reason, true);
      assert.deepStrictEqual(field.writes, [], "a refused add wrote the PM field");
    });
  }
  // N3: the whole call is ok, but one issue's chain or tree fails (ownership.js assertOneOwner, per-issue branches).
  const perIssue = [
    ["chain", "pm-field-ambiguous", (key, reason) => ({ chains: { [key]: { ok: false, reason } }, trees: {} })],
    ["tree", "sub-issue-depth-cap", (key, reason) => ({ chains: { [key]: { ok: true, chain: [] } }, trees: { [key]: { ok: false, reason } } })],
  ];
  for (const [part, reason, shape] of perIssue) {
    test(`N3 /pm-add whose ${part} of one issue fails with ${reason} under an ok read: the refusal gives nextActionOf, no retry advice`, () => {
      const field = X.field();
      const readChainsAndTrees = (adds) => Object.assign({ ok: true, cards: {} }, shape(X.refKey(adds[0]), reason));
      const x = addWith([8621], { pmField: field, readChainsAndTrees });
      assertNextAction(x, reason, true);
      assert.doesNotMatch(x.r.block, new RegExp(String.fromCharCode(0x518d, 0x8a66, 0x884c)), `a ${reason} refusal still asks for a retry: ${W.brief(x.r)}`);
      assert.deepStrictEqual(field.writes, [], "a refused add wrote the PM field");
    });
  }
  test("N2 /pm-add whose field write fails spawn-failed: the refusal gives nextActionOf(spawn-failed)", () => {
    const field = X.withMany({
      write: () => ({ result: "failed", reason: "spawn-failed" }),
      read: (refs) => ({ ok: true, values: Object.fromEntries(refs.map((r) => [X.refKey(r), null])) }),
    });
    const x = addWith([8611], { pmField: field });
    assertNextAction(x, "spawn-failed", false);
  });
  // N4: a write that is not retryable, refused at the write stage or at the prepare stage (ownership.js writeFields).
  const stages = [
    ["write", "pm-field-truncated", () => X.withMany({ write: () => ({ result: "failed", reason: "pm-field-truncated" }), read: allNull })],
    ["prepare", "pm-field-ambiguous", () => Object.assign(X.field(), { prepare: () => ({ ok: false, reason: "pm-field-ambiguous" }) })],
  ];
  for (const [stage, reason, make] of stages) {
    test(`N4 /pm-add whose ${stage} stage fails with ${reason} (not retryable): the refusal gives nextActionOf, no retry advice`, () => {
      const field = make();
      const x = addWith([8631], { pmField: field });
      assertNextAction(x, reason, true);
      if (field.writes) assert.deepStrictEqual(field.writes, [], "a refused prepare wrote the PM field");
    });
  }
  // N5: an unknown write whose readback fails or shows the write did not land (ownership.js writeFields readback).
  const unknownWrite = (read) => X.withMany({ write: () => ({ result: "unknown" }), read });
  test("N5 /pm-add whose write is unknown and readback is budget-exhausted: the refusal gives nextActionOf(budget-exhausted)", () => {
    const x = addWith([8641], { pmField: unknownWrite(() => ({ ok: false, reason: "budget-exhausted" })) });
    assertNextAction(x, "budget-exhausted", false);
  });
  test("N5 /pm-add whose write is unknown and readback returns nothing: the reason defaults to timeout", () => {
    const x = addWith([8642], { pmField: unknownWrite(() => null) });
    assertNextAction(x, "timeout", false);
  });
  test("N5 /pm-add whose write is unknown and readback shows another value: did-not-land gives nextActionOf(timeout)", () => {
    const x = addWith([8643], { pmField: unknownWrite((refs) => ({ ok: true, values: Object.fromEntries(refs.map((r) => [X.refKey(r), "PM-other"])) })) });
    assertNextAction(x, "timeout", false, { noParen: true });
    assert.match(x.r.block, /did not land/, W.brief(x.r));
  });
  // N6: a missing reason falls back to "failed" (whole call) or "missing" (one issue's chain); never "undefined".
  const missing = [
    ["the whole read has no reason", "failed", () => ({ ok: false })],
    ["one issue's chain is absent", "missing", () => ({ ok: true, cards: {}, chains: {}, trees: {} })],
  ];
  for (const [label, reason, readChainsAndTrees] of missing) {
    test(`N6 /pm-add whose owner check fails and ${label}: the refusal gives nextActionOf(${reason})`, () => {
      const field = X.field();
      const x = addWith([8651], { pmField: field, readChainsAndTrees });
      assertNextAction(x, reason, false);
      assert.deepStrictEqual(field.writes, [], "a refused add wrote the PM field");
    });
  }
  test("N7 /pm-init whose owner check fails with sub-issue-depth-cap: the refusal gives nextActionOf, the PM is not created", () => {
    W.alone(() => {
      const sid = W.nextSid();
      P.seedState(sid);
      const field = X.field();
      const deps = { pmField: field, readChainsAndTrees: () => ({ ok: false, reason: "sub-issue-depth-cap" }) };
      const r = X.write(sid, P.wrapped("pm-init", `${W.nextTag("PM-nai")} #8661 next action`), deps);
      assertNextAction({ r, before: undefined, after: P.readPm(sid) }, "sub-issue-depth-cap", true);
      assert.deepStrictEqual(field.writes, [], "a refused init wrote the PM field");
    });
  });
}

module.exports = { nextAction };
