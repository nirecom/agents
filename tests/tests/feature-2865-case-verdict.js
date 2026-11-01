"use strict";
// Tests: tests/lib/case-verdict.js
// Tags: TL1, tests, case-verdict, node-test, scope:issue-specific
// #2865 unit layer: noNewFailures(count, fn) turns a counter-style case (checks that tally failures
// instead of throwing) into a node:test verdict: it rejects when the tally grew while fn ran, awaits an
// async fn before the second count, and passes a throw or rejection of fn through unchanged.
const { caseBegin, caseEnd } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");

// Loaded per call so that a missing module fails each case, not the whole file at load time.
const verdict = () => require("../lib/case-verdict");
const noNewFailures = async (...args) => verdict().noNewFailures(...args);

// counter() — a failure tally { count, bump(n) } the way a fixture's failureCount() behaves.
function counter(start = 0) {
  let n = start;
  return { count: () => n, bump: (by = 1) => { n += by; } };
}
const tick = () => new Promise((resolve) => setImmediate(resolve));

caseBegin("sync-increase-rejects", "tests/lib/case-verdict.js");
test("a sync fn that adds failures makes noNewFailures reject, naming the increase", async () => {
  const c = counter();
  const p = verdict().noNewFailures(c.count, () => c.bump(2));
  assert.ok(p && typeof p.then === "function", "a sync fn still gets a Promise back");
  await assert.rejects(p, (e) => e instanceof Error && e.code !== "MODULE_NOT_FOUND" && e.message.includes("2"));
});
caseEnd();

caseBegin("sync-increase-message-names-counts", "tests/lib/case-verdict.js");
test("the rejection is an Error whose message names the delta (4) and the counts before (3) and after (7)", async () => {
  const c = counter(3);
  await assert.rejects(verdict().noNewFailures(c.count, () => c.bump(4)), (e) => e instanceof Error
    && e.code !== "MODULE_NOT_FOUND" && /\b3\b\D+\b7\b/.test(e.message) && /\b4\b/.test(e.message));
});
caseEnd();

caseBegin("sync-plus-one-boundary-rejects", "tests/lib/case-verdict.js");
test("a sync fn that takes the tally from 2 to 3 (exactly +1) rejects", async () => {
  const c = counter(2);
  await assert.rejects(verdict().noNewFailures(c.count, () => c.bump(1)), (e) => e instanceof Error && e.code !== "MODULE_NOT_FOUND");
});
caseEnd();

caseBegin("async-plus-one-boundary-rejects", "tests/lib/case-verdict.js");
test("an async fn that takes the tally from 2 to 3 (exactly +1) rejects", async () => {
  const c = counter(2);
  await assert.rejects(noNewFailures(c.count, async () => {
    await tick();
    c.bump(1);
  }), (e) => e instanceof Error && e.code !== "MODULE_NOT_FOUND");
});
caseEnd();

caseBegin("sync-decrease-resolves", "tests/lib/case-verdict.js");
test("a tally that goes down while fn runs (a reset) is not a new failure: it resolves", async () => {
  const c = counter(5);
  await assert.doesNotReject(noNewFailures(c.count, () => c.bump(-3)));
});
caseEnd();

caseBegin("sync-no-increase-resolves", "tests/lib/case-verdict.js");
test("a sync fn that adds no failures resolves, also when earlier failures were already tallied", async () => {
  await assert.doesNotReject(noNewFailures(counter().count, () => {}));
  const c = counter(5);
  await assert.doesNotReject(noNewFailures(c.count, () => {}));
});
caseEnd();

caseBegin("count-taken-around-fn", "tests/lib/case-verdict.js");
test("count is read once before fn and once after it, and fn runs exactly once", async () => {
  const log = [];
  await noNewFailures(() => { log.push("count"); return 0; }, () => { log.push("fn"); });
  assert.deepStrictEqual(log, ["count", "fn", "count"]);
});
caseEnd();

caseBegin("async-increase-after-await-rejects", "tests/lib/case-verdict.js");
test("an async fn whose failures appear only after an await still makes it reject", async () => {
  const c = counter();
  await assert.rejects(noNewFailures(c.count, async () => {
    await tick();
    await tick();
    c.bump(3);
  }), (e) => e instanceof Error && e.code !== "MODULE_NOT_FOUND" && e.message.includes("3"));
});
caseEnd();

caseBegin("thenable-increase-rejects", "tests/lib/case-verdict.js");
test("a thenable (not a native Promise) returned by fn is awaited before the second count", async () => {
  const c = counter();
  const thenable = { then(resolve) { setTimeout(() => { c.bump(4); resolve(); }, 5); } };
  await assert.rejects(noNewFailures(c.count, () => thenable), (e) => e instanceof Error && e.code !== "MODULE_NOT_FOUND" && e.message.includes("4"));
});
caseEnd();

caseBegin("async-no-increase-resolves", "tests/lib/case-verdict.js");
test("an async fn that adds no failures resolves", async () => {
  const c = counter();
  await assert.doesNotReject(noNewFailures(c.count, async () => {
    await tick();
  }));
});
caseEnd();

caseBegin("fn-throw-propagates", "tests/lib/case-verdict.js");
test("a synchronous throw of fn is passed through as the same error object", async () => {
  const boom = new Error("boom-sync");
  await assert.rejects(noNewFailures(counter().count, () => { throw boom; }), (e) => e === boom);
});
caseEnd();

caseBegin("fn-reject-propagates", "tests/lib/case-verdict.js");
test("a rejection of fn is passed through as the same error object", async () => {
  const boom = new Error("boom-async");
  await assert.rejects(noNewFailures(counter().count, async () => { await tick(); throw boom; }), (e) => e === boom);
});
caseEnd();

caseBegin("fn-throw-wins-over-increase", "tests/lib/case-verdict.js");
test("when fn tallies a failure and then throws, the thrown error is what comes out, not the increase", async () => {
  const c = counter();
  const boom = new Error("boom-after-tally");
  await assert.rejects(noNewFailures(c.count, () => { c.bump(); throw boom; }), (e) => e === boom);
});
caseEnd();

caseBegin("count-not-a-function-type-error", "tests/lib/case-verdict.js");
test("a count that is not a function is a TypeError (undefined, null, a number, a string, an object)",async () => {
  for (const bad of [undefined, null, 0, 3, "count", {}]) {
    let called = 0;
    await assert.rejects(async () => noNewFailures(bad, () => { called += 1; }), TypeError, `count=${JSON.stringify(bad)}`);
    assert.strictEqual(called, 0, `fn must not run when count=${JSON.stringify(bad)} is invalid`);
  }
});
caseEnd();
