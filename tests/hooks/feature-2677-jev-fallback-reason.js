"use strict";
// Tests: hooks/lib/jev/two-stage/merge.js, hooks/lib/jev/two-stage/merge-skip.js, hooks/lib/jev/two-stage/replay.js, hooks/lib/jev/two-stage/finalize.js
// Tags: TL2, hooks, jev, two-stage, fallback-reason, answer-file, finalize, superseded, idempotent, placement-guard, mock-server, scope:issue-specific
// #2677: when finalize demotes its output because the backup subagent's answer was absent,
// empty / NO_ANSWER or unparseable, it prints FALLBACK=<reason> (and records the same
// fallback_reason) for complexity and skip alike; a received, parsed answer prints no line.
// TL3 gap (what this test does NOT catch):
// - the caller skill reading FALLBACK= and showing it to the user on a live session
// Closest-to-action mitigation: the real jev-judge CLI and the module-API query run here.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");
const J = require("./feature-2677-jev/jj-fixture");

const MERGE_JS = path.join(J.REPO, "hooks", "lib", "jev", "two-stage", "merge.js");
const GUARD_JS = path.join(J.REPO, "hooks", "block-clearance-token-write", "placement-guard.js");
const K1 = "sd_single_approach";
const K2 = "sd_no_open_decision";

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2677-fb-"));
const mock = J.startMock(path.join(ROOT, "mock"));
after(() => {
  mock.stop();
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

// The FALLBACK lines of one finalize stdout (every one, so a duplicate is visible).
const fallbacks = (o) => o.all("FALLBACK");
const writeAnswer = (file, text) => {
  assert.ok(file && file !== "-" && file !== "<none>", `query handed back an ANSWER_FILE (got ${file})`);
  fs.writeFileSync(file, text);
};

// cx(name, answer): complexity query (S2 held at p=0.5, the rest confidently false), the answer
// written as given (undefined = no file), then finalize. -> {fx, q, f, ticket}.
function cx(name, answer, stage = "complexity", files = {}) {
  const fx = J.newFx(ROOT, name, files);
  mock.probs(0.01, { "S2-architecture": 0.5 });
  const q = J.cxQuery(fx, mock, stage);
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `${name}: premise, the query delegates (stdout: ${q.stdout})`);
  if (answer !== undefined) writeAnswer(q.kv("ANSWER_FILE"), answer);
  const ticket = q.kv("TICKET");
  const f = J.finalize(fx, mock, ticket);
  assert.strictEqual(f.status, 0, `${name}: finalize exit 0 (stderr: ${f.stderr})`);
  return { fx, q, f, ticket };
}

// sk(name, answer, files): detail-skip query with both keys held (p=0.5), the answer, finalize.
function sk(name, answer, files = { outline: true, stateJson: J.STATE_AT_DETAIL }, probs = 0.5) {
  const fx = J.newFx(ROOT, name, files);
  mock.probs(probs);
  const q = J.skipQuery(fx, mock, "detail");
  assert.strictEqual(q.status, 0, `${name}: skip query exit 0 (stderr: ${q.stderr})`);
  if (answer !== undefined) writeAnswer(q.kv("ANSWER_FILE"), answer);
  const ticket = q.kv("TICKET");
  const f = J.finalize(fx, mock, ticket);
  assert.strictEqual(f.status, 0, `${name}: finalize exit 0 (stderr: ${f.stderr})`);
  return { fx, q, f, ticket };
}

const reasonOf = (r) => J.decision(r.fx, r.ticket) && J.decision(r.fx, r.ticket).fallback_reason;

caseBegin("complexity-fallback-line-per-answer-state", "hooks/lib/jev/two-stage/merge.js");
const CX_DEMOTED = [
  ["absent", undefined, "answer-file-absent"],
  ["empty", "", "answer-empty"],
  ["no-answer", "NO_ANSWER\n", "answer-empty"],
  ["prose", "I looked at the change and it seems architectural to me.\n", "answer-unparseable"],
  ["over-cap", `SIGNALS: S2-architecture,${"A".repeat(2 * 1048576)}\n`, "answer-unparseable"],
];
for (const [name, answer, reason] of CX_DEMOTED) {
  test(`complexity, answer ${name}: FALLBACK=${reason}, record fallback_reason ${reason}, S0`, () => {
    const r = cx(`cx-${name}`, answer);
    assert.strictEqual(r.f.kv("SIGNALS_CSV"), "S0-undecidable", "the output is demoted to S0");
    assert.deepStrictEqual(fallbacks(r.f), [reason], `stdout: ${r.f.stdout}`);
    assert.strictEqual(reasonOf(r), reason);
  });
}
test("complexity, valid answer: no FALLBACK line, fallback_reason null", () => {
  const r = cx("cx-valid", "SIGNALS: S2-architecture\n");
  assert.strictEqual(r.f.kv("SIGNALS_CSV"), "S2-architecture");
  assert.deepStrictEqual(fallbacks(r.f), []);
  assert.strictEqual(reasonOf(r), null);
});
test("complexity, the subagent's own SIGNALS: S0-undecidable: no FALLBACK line (not a demotion)", () => {
  const r = cx("cx-own-s0", "SIGNALS: S0-undecidable\n");
  assert.strictEqual(r.f.kv("SIGNALS_CSV"), "S0-undecidable");
  assert.deepStrictEqual(fallbacks(r.f), []);
  assert.strictEqual(reasonOf(r), null);
});
caseEnd();

caseBegin("skip-fallback-line-per-answer-state", "hooks/lib/jev/two-stage/merge-skip.js");
const SK_DEMOTED = [
  ["absent", undefined, "answer-file-absent"],
  ["empty", "", "answer-empty"],
  ["no-answer", "NO_ANSWER\n", "answer-empty"],
  ["unknown-key", `SKIP_CONDITIONS: ${K1}=true, ${K2}=true, sd_c1=true\n`, "answer-unparseable"],
];
for (const [name, answer, reason] of SK_DEMOTED) {
  test(`skip, answer ${name}: FALLBACK=${reason}, record fallback_reason ${reason}, SKIP=false`, () => {
    const r = sk(`sk-${name}`, answer);
    assert.strictEqual(r.f.kv("SKIP"), "false");
    assert.deepStrictEqual(fallbacks(r.f), [reason], `stdout: ${r.f.stdout}`);
    assert.strictEqual(reasonOf(r), reason);
  });
}
test("skip, partial answer (one key): FALLBACK=answer-unparseable, the unanswered key false", () => {
  const r = sk("sk-partial", `SKIP_CONDITIONS: ${K1}=true\n`);
  assert.strictEqual(r.f.kv("SKIP"), "false");
  assert.deepStrictEqual(fallbacks(r.f), ["answer-unparseable"], `stdout: ${r.f.stdout}`);
  const rec = J.decision(r.fx, r.ticket);
  assert.strictEqual(rec && rec.fallback_reason, "answer-unparseable");
  assert.deepStrictEqual(rec && rec.final && rec.final.conditions, { [K1]: true, [K2]: false });
});
test("skip, valid answer: SKIP=true, no FALLBACK line, fallback_reason null", () => {
  const r = sk("sk-valid", `SKIP_CONDITIONS: ${K1}=true, ${K2}=true\n`);
  assert.strictEqual(r.f.kv("SKIP"), "true");
  assert.deepStrictEqual(fallbacks(r.f), []);
  assert.strictEqual(reasonOf(r), null);
});
caseEnd();

caseBegin("fallback-priority", "hooks/lib/jev/two-stage/merge-skip.js");
test("skip, no outline.md and no answer: FALLBACK=input-insufficient (the root cause wins)", () => {
  const r = sk("sk-noout", undefined, { stateJson: J.STATE_AT_DETAIL }, 0.99);
  assert.strictEqual(r.q.kv("RESULT"), "need-subagent", "premise: an input-insufficient query delegates");
  assert.deepStrictEqual(fallbacks(r.f), ["input-insufficient"], `stdout: ${r.f.stdout}`);
  assert.strictEqual(reasonOf(r), "input-insufficient");
});
test("complexity at write-code, no write-code-files.txt, valid answer: FALLBACK=write-code-list-missing", () => {
  const fx = J.newFx(ROOT, "cx-wc-missing", { outline: true, detail: true });
  mock.probs(0.01, { "S2-architecture": 0.5 });
  const q = J.cxQuery(fx, mock, "write-code");
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `premise: S2 held, the query delegates (stdout: ${q.stdout})`);
  writeAnswer(q.kv("ANSWER_FILE"), "SIGNALS: S2-architecture\n");
  const f = J.finalize(fx, mock, q.kv("TICKET"));
  assert.strictEqual(f.kv("SIGNALS_CSV"), "S0-undecidable", "the deterministic failure demotes the output");
  assert.deepStrictEqual(fallbacks(f), ["write-code-list-missing"], `stdout: ${f.stdout}`);
  const rec = J.decision(fx, q.kv("TICKET"));
  assert.strictEqual(rec && rec.fallback_reason, "write-code-list-missing");
});
caseEnd();

caseBegin("fallback-line-replayed", "hooks/lib/jev/two-stage/replay.js");
test("complexity: re-finalizing the same ticket re-emits the same FALLBACK line (done marker)", () => {
  const r = cx("cx-replay", undefined);
  assert.deepStrictEqual(fallbacks(r.f), ["answer-file-absent"], `first finalize stdout: ${r.f.stdout}`);
  const again = J.finalize(r.fx, mock, r.ticket);
  assert.strictEqual(again.status, 0);
  assert.deepStrictEqual(again.lines, r.f.lines, "the re-run prints the recorded lines");
  assert.deepStrictEqual(fallbacks(again), ["answer-file-absent"]);
});
caseEnd();

caseBegin("skip-superseded-keeps-fallback", "hooks/lib/jev/two-stage/finalize.js");
test("skip: A finalized without an answer, newer query B, A re-finalized -> superseded, FALLBACK kept", () => {
  const a = sk("sk-sup", undefined);
  assert.strictEqual(a.f.kv("SETTLE"), "ok", `premise: A settled (stdout: ${a.f.stdout})`);
  assert.deepStrictEqual(fallbacks(a.f), ["answer-file-absent"], `A stdout: ${a.f.stdout}`);
  J.sleepMs(60);
  mock.probs(0.5);
  const b = J.skipQuery(a.fx, mock, "detail");
  assert.strictEqual(b.status, 0, `query B exit 0 (stderr: ${b.stderr})`);
  assert.notStrictEqual(b.kv("TICKET"), a.ticket);
  const again = J.finalize(a.fx, mock, a.ticket);
  assert.strictEqual(again.kv("SETTLE"), "superseded", `premise: the re-run is superseded (stdout: ${again.stdout})`);
  assert.strictEqual(again.kv("SKIP"), "false");
  assert.deepStrictEqual(fallbacks(again), ["answer-file-absent"]);
});
caseEnd();

caseBegin("answer-through-placement-guard", "hooks/lib/jev/two-stage/merge.js");
// The guard reads both workflow dirs from process.env when it classifies, so each check runs
// with the env pointed at that fixture.
const { classifyPlacement } = require(GUARD_JS);
const guardVerdict = (fx, file) => J.withPins(fx, () => classifyPlacement(file, { sid: J.SID, wsid: J.SID }));
test("complexity: ANSWER_FILE passes the placement guard, the answer is adopted, no FALLBACK", () => {
  const fx = J.newFx(ROOT, "cx-through");
  // S3 p=0.95 is adopted from Jev (true side) without deciding the point; the absent side is
  // never adopted (false: null), so S2 and S5 go to the subagent and ADOPTED is mixed.
  mock.probs(0.5, { "S3-security": 0.95 });
  const q = J.cxQuery(fx, mock, "complexity");
  assert.strictEqual(q.kv("RESULT"), "need-subagent");
  assert.strictEqual(guardVerdict(fx, q.kv("ANSWER_FILE")), null, `guard verdict for ${q.kv("ANSWER_FILE")}`);
  writeAnswer(q.kv("ANSWER_FILE"), "SIGNALS: S2-architecture\n");
  const f = J.finalize(fx, mock, q.kv("TICKET"));
  assert.strictEqual(f.kv("ADOPTED"), "mixed");
  assert.strictEqual(f.kv("SIGNALS_CSV"), "S2-architecture,S3-security");
  assert.deepStrictEqual(fallbacks(f), []);
});
test("skip: ANSWER_FILE passes the placement guard, the answer is adopted, no FALLBACK", () => {
  const fx = J.newFx(ROOT, "sk-through", { outline: true, stateJson: J.STATE_AT_DETAIL });
  mock.probs(0.5, { [K2]: 0.95 });
  const q = J.skipQuery(fx, mock, "detail");
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `premise (stdout: ${q.stdout})`);
  assert.strictEqual(guardVerdict(fx, q.kv("ANSWER_FILE")), null, `guard verdict for ${q.kv("ANSWER_FILE")}`);
  writeAnswer(q.kv("ANSWER_FILE"), `SKIP_CONDITIONS: ${K1}=true, ${K2}=true\n`);
  const f = J.finalize(fx, mock, q.kv("TICKET"));
  assert.strictEqual(f.kv("ADOPTED"), "mixed");
  assert.strictEqual(f.kv("SKIP"), "true");
  assert.deepStrictEqual(fallbacks(f), []);
});
caseEnd();

caseBegin("answer-fallback-of-table", "hooks/lib/jev/two-stage/merge.js");
test("answerFallbackOf(needed, received, parsedStatus) maps the answer state to one reason", () => {
  const { answerFallbackOf } = require(MERGE_JS);
  assert.strictEqual(typeof answerFallbackOf, "function", "merge.js exports answerFallbackOf");
  const rows = [
    [false, false, "missing", null],
    [false, true, "parse-fallback", null],
    [true, true, "ok", null],
    [true, false, "missing", "answer-file-absent"],
    [true, true, "missing", "answer-empty"],
    [true, true, "parse-fallback", "answer-unparseable"],
  ];
  for (const [needed, received, status, want] of rows) {
    assert.strictEqual(answerFallbackOf(needed, received, status), want, `(${needed}, ${received}, ${status})`);
  }
});
caseEnd();
