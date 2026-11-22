"use strict";
// tests/hooks/feature-2019-finding-approval.js
// Tests: hooks/lib/finding-approval.js
// Tags: TL2, hooks, finding-approval, approval-record, consume, fail-closed, marker, table-driven, scope:issue-specific, pwsh-not-required
// #2019 S1-1/5/6: the approval record `<sid>.finding-filing-approval` is consumed once per matching key;
// a record outside its age window, a record of another session, a broken file or a lost claim gives no
// approval; a file the hook recreated before the write-back is never overwritten.
// Records are fixed by fs here (ISO `at`); the two writers are exercised in feature-2019-finding-approval-*.js.
// TL3 gap: concurrent hook writes in a live session (the recreated-file race is staged by patching the claim step).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");

const restore = isolate();
after(restore);

const ROOT = path.resolve(__dirname, "..", "..");
const LIB = path.join(ROOT, "hooks", "lib", "finding-approval.js");
const CEF = path.join(ROOT, "hooks", "lib", "consume-exact-file.js");
const WF = process.env.WORKFLOW_STATE_DIR;
const SID = "5e1d2c3b-2019-4a01-8a9b-0c1d2e3f4a01";
const OTHER = "5e1d2c3b-2019-4a01-8a9b-0c1d2e3f4a02";
const NOW = Date.parse("2026-11-20T12:00:00.000Z");
const H2 = 2 * 60 * 60 * 1000;
const KIND = "finding-filing-approval";

const iso = (ms) => new Date(ms).toISOString();
const fileOf = (sid) => path.join(WF, `${sid}.${KIND}`);
const answer = (keys, atMs, dialogId) => ({ type: "askuser-answer", dialog_id: dialogId || "notes-promotion.final-list", keys, at: iso(atMs) });
const typed = (atMs) => ({ type: "typed-command", at: iso(atMs) });
function put(sid, records, sessionId) {
  const body = { version: 1, session_id: sessionId === undefined ? sid : sessionId, pending: [], records };
  fs.writeFileSync(fileOf(sid), JSON.stringify(body));
}
const readBack = (sid) => (fs.existsSync(fileOf(sid)) ? JSON.parse(fs.readFileSync(fileOf(sid), "utf8")) : null);
// The contract may return a boolean or an object carrying `approved`; both read as one verdict.
const approved = (r) => r === true || Boolean(r && typeof r === "object" && r.approved === true);

// fresh(patch) — the library loaded anew; `patch` replaces consumeExactFile before the load so a
// destructured import sees it too.
function fresh(patch) {
  delete require.cache[require.resolve(LIB)];
  const cef = require(CEF);
  const original = cef.consumeExactFile;
  if (patch) cef.consumeExactFile = (p, raw) => patch(original, p, raw);
  try { return require(LIB); } finally { if (patch) setImmediate(() => { cef.consumeExactFile = original; }); }
}

caseBegin("contract-constants", "hooks/lib/finding-approval.js");
test("contract-constants: kind name and the three approval dialog IDs", () => {
  const M = fresh();
  assert.strictEqual(M.FINDING_APPROVAL_MARKER_KIND, KIND, "kind name");
  const ids = Array.from(M.APPROVAL_DIALOG_IDS).sort();
  assert.deepStrictEqual(ids, ["issue-create.confirm-gate", "mid-workflow-findings.blocking-file", "notes-promotion.final-list"], "dialog IDs");
  assert.strictEqual(typeof M.consumeApproval, "function", "consumeApproval exported");
});
caseEnd();

caseBegin("consume-once-and-boundaries", "hooks/lib/finding-approval.js");
test("consume-once-and-boundaries: age window table", () => {
  const M = fresh();
  // [name, record at (ms), want approved]
  const ROWS = [
    ["fresh record", NOW - 1000, true],
    ["exactly 2h old is accepted", NOW - H2, true],
    ["2h + 1ms old is rejected", NOW - H2 - 1, false],
    ["60s in the future is accepted", NOW + 60000, true],
    ["60s + 1ms in the future is rejected", NOW + 60001, false],
  ];
  for (const [name, at, want] of ROWS) {
    put(SID, [answer(["aaaa1111"], at)]);
    assert.strictEqual(approved(M.consumeApproval(SID, "aaaa1111", NOW)), want, name);
  }
});
caseEnd();

caseBegin("second-consume-rejected", "hooks/lib/finding-approval.js");
test("second-consume-rejected: a matching key is consumed exactly once", () => {
  const M = fresh();
  put(SID, [answer(["bbbb2222"], NOW - 1000)]);
  assert.strictEqual(approved(M.consumeApproval(SID, "bbbb2222", NOW)), true, "first consume approves");
  assert.strictEqual(approved(M.consumeApproval(SID, "bbbb2222", NOW)), false, "second consume is rejected");
  put(SID, [answer(["bbbb2222"], NOW - 1000)]);
  assert.strictEqual(approved(M.consumeApproval(SID, "cccc3333", NOW)), false, "a non-matching key is not approved");
  const left = readBack(SID);
  assert.ok(left && left.records.some((r) => (r.keys || []).includes("bbbb2222")), "the unmatched record is kept");
});
caseEnd();

caseBegin("multi-key-record-consumes-one-key", "hooks/lib/finding-approval.js");
test("multi-key-record-consumes-one-key: only the matched key leaves the record", () => {
  const M = fresh();
  put(SID, [answer(["dddd0001", "dddd0002", "dddd0003"], NOW - 1000)]);
  assert.strictEqual(approved(M.consumeApproval(SID, "dddd0002", NOW)), true, "the middle key is approved");
  const keys = (readBack(SID) || { records: [] }).records.flatMap((r) => r.keys || []).sort();
  assert.deepStrictEqual(keys, ["dddd0001", "dddd0003"], "the other two keys remain");
  assert.strictEqual(approved(M.consumeApproval(SID, "dddd0002", NOW)), false, "the consumed key does not approve again");
  assert.strictEqual(approved(M.consumeApproval(SID, "dddd0003", NOW)), true, "a remaining key still approves");
});
caseEnd();

caseBegin("typed-command-matches-any-key-once", "hooks/lib/finding-approval.js");
test("typed-command-matches-any-key-once", () => {
  const M = fresh();
  put(SID, [typed(NOW - 1000)]);
  assert.strictEqual(approved(M.consumeApproval(SID, "eeee5555", NOW)), true, "typed-command approves the first filing");
  assert.strictEqual(approved(M.consumeApproval(SID, "ffff6666", NOW)), false, "the second filing is not approved");
});
caseEnd();

caseBegin("no-approval-fail-closed", "hooks/lib/finding-approval.js");
test("no-approval-fail-closed: other session, wsid file, broken JSON, missing file", () => {
  const M = fresh();
  put(SID, [answer(["abab1212"], NOW - 1000)], OTHER);
  assert.strictEqual(approved(M.consumeApproval(SID, "abab1212", NOW)), false, "session_id differs from the stem");
  fs.rmSync(fileOf(SID), { force: true });
  put(OTHER, [answer(["abab1212"], NOW - 1000)]);
  assert.strictEqual(approved(M.consumeApproval(SID, "abab1212", NOW)), false, "the root/wsid file is never read");
  assert.ok(readBack(OTHER), "the other session's file is left alone");
  fs.writeFileSync(fileOf(SID), "{ not json");
  assert.strictEqual(approved(M.consumeApproval(SID, "abab1212", NOW)), false, "broken JSON");
  fs.rmSync(fileOf(SID), { force: true });
  assert.strictEqual(approved(M.consumeApproval(SID, "abab1212", NOW)), false, "no file");
});
caseEnd();

caseBegin("lost-claim-is-no-approval", "hooks/lib/finding-approval.js");
test("lost-claim-is-no-approval: consumeExactFile lost/failed", () => {
  for (const verdict of ["lost", "failed"]) {
    const M = fresh(() => verdict);
    put(SID, [answer(["acac3434"], NOW - 1000)]);
    assert.strictEqual(approved(M.consumeApproval(SID, "acac3434", NOW)), false, `consumeExactFile ${verdict}`);
  }
});
caseEnd();

caseBegin("recreated-file-not-overwritten", "hooks/lib/finding-approval.js");
test("recreated-file-not-overwritten: wx EEXIST drops the remainder and keeps the hook's file", () => {
  const hookBody = JSON.stringify({ version: 1, session_id: SID, pending: [], records: [typed(NOW)] });
  const M = fresh((original, p, raw) => {
    const r = original(p, raw);
    fs.writeFileSync(p, hookBody);
    return r;
  });
  put(SID, [answer(["adad5656", "adad7878"], NOW - 1000)]);
  const r = M.consumeApproval(SID, "adad5656", NOW);
  assert.strictEqual(fs.readFileSync(fileOf(SID), "utf8"), hookBody, "the hook's new file is kept byte for byte");
  assert.ok(typeof r === "boolean" || (r && typeof r === "object"), "a verdict is returned (no throw)");
});
caseEnd();
