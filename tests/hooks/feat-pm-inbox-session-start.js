"use strict";
// Tests: hooks/session-start/pm-inbox.js
// Tags: TL1, scope:issue-specific, pm-session, session-start, issue-2942
// #2942: at SessionStart only a PM session runs its inbox (bin/lib/pm-notify/inbox.js runInbox) within the
// hook's budget; no budget left or any inbox error gives one fail-open line instead. runInbox is stubbed.
// TL3 gap (what this test does NOT catch):
// - a real SessionStart in Claude Code showing these lines as additionalContext inside the hook's timeout.
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const restore = isolate();
const P = require("../lib/pm-state-fixture");
after(() => { restore(); });

const SRC = path.join(P.ROOT, "hooks", "session-start", "pm-inbox.js");
const INBOX = path.join(P.ROOT, "bin", "lib", "pm-notify", "inbox.js");
const LATER = "[pm-inbox] skipped at session start; it runs at the next PM command";
let n = 0;
const sid = () => P.uuid(0x29420900 + (++n));

// withInbox(runInbox, fn) -> fn(pmInboxLines) with inbox.js replaced by {runInbox}; calls lists its arguments.
function withInbox(runInbox, fn) {
  const calls = [];
  const saved = require.cache[INBOX];
  require.cache[INBOX] = { id: INBOX, filename: INBOX, loaded: true, exports: { runInbox: (...a) => { calls.push(a); return runInbox(...a); } } };
  delete require.cache[SRC];
  try { return fn(require(SRC).pmInboxLines, calls); } finally {
    if (saved) require.cache[INBOX] = saved; else delete require.cache[INBOX];
    delete require.cache[SRC];
  }
}
const pmSid = () => { const s = sid(); P.seedPm(s, P.pm({ tag: `PM-ib${n}`, issues: [] })); return s; };

caseBegin("pm-inbox-only-a-pm-session", "hooks/session-start/pm-inbox.js");
test("IB1 a session without the pm mark, a missing or corrupt state, or a bad sid runs nothing", () => {
  const plain = sid();
  P.seedState(plain);
  const corrupt = sid();
  fs.writeFileSync(P.load("hooks/workflow-state/state-io").getStatePath(corrupt), "{broken");
  withInbox(() => "never", (lines, calls) => {
    for (const s of [plain, sid(), corrupt, "../evil", ""]) assert.deepStrictEqual(lines(s, 2000), [], String(s));
    assert.strictEqual(calls.length, 0);
  });
});
caseEnd();

caseBegin("pm-inbox-budget-and-fail-open", "hooks/session-start/pm-inbox.js");
test("IB2 a PM session runs its inbox with the budget and drift on; the text follows a blank line", () => {
  const s = pmSid();
  withInbox(() => "[pm-inbox] 2 notifications\n- one\n- two", (lines, calls) => {
    assert.deepStrictEqual(lines(s, 1500), ["", "[pm-inbox] 2 notifications", "- one", "- two"]);
    assert.deepStrictEqual(calls, [[s, { budgetMs: 1500, drift: true }]]);
  });
});
test("IB2 an empty inbox adds nothing", () => {
  const s = pmSid();
  withInbox(() => "", (lines) => assert.deepStrictEqual(lines(s, 1500), []));
});
test("IB3 no budget left gives the fail-open line without running the inbox", () => {
  const s = pmSid();
  withInbox(() => "never", (lines, calls) => {
    for (const b of [0, -5, undefined, NaN]) assert.deepStrictEqual(lines(s, b), ["", LATER], String(b));
    assert.strictEqual(calls.length, 0);
  });
});
test("IB3 an inbox that throws gives the fail-open line", () => {
  const s = pmSid();
  withInbox(() => { throw new Error("lock busy"); }, (lines) => assert.deepStrictEqual(lines(s, 1500), ["", LATER]));
});
caseEnd();
