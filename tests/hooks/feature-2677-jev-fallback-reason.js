"use strict";
// Tests: hooks/lib/jev/two-stage/merge.js, hooks/lib/jev/two-stage/merge-skip.js, hooks/lib/jev/two-stage/replay.js, hooks/lib/jev/two-stage/finalize.js
// Tags: TL2, hooks, jev, two-stage, fallback-reason, answer-file, finalize, superseded, idempotent, placement-guard, mock-server, source-changed, settle-priority, sweep-replay, scope:issue-specific
// #2677: when finalize demotes its output because the backup subagent's answer was absent,
// empty / NO_ANSWER or unparseable, it prints FALLBACK=<reason> (and records the same
// fallback_reason) for complexity and skip alike; a received, parsed answer prints no line.
// #2701: a settle-time demotion because the stage sources changed after the query prints one
// FALLBACK=source-changed line, unless the merge already named a reason (that one wins).
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

// #2701 source-changed. The subagent answers S2 validly, so the merge names no reason and any
// FALLBACK line comes from the settle stage alone.
const settles = (fx, ticket) => J.records(fx, ticket).filter((x) => x.record_type === "settle")
  .map((x) => `${x.settle}|${x.detail}`);
const P = (fx, n) => path.join(fx.plans, `${J.SID}-${n}`);
const editIntent = (fx) => fs.writeFileSync(P(fx, "intent.md"), "# Intent\n\nRewrite the report pipeline and its storage format.\n");
// cxAnswered(name, files): complexity query with S2 delegated and the valid answer written.
function cxAnswered(name, files = {}) {
  const fx = J.newFx(ROOT, name, files);
  mock.probs(0.01, { "S2-architecture": 0.5 });
  const q = J.cxQuery(fx, mock, "complexity");
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `${name}: premise, the query delegates (stdout: ${q.stdout})`);
  writeAnswer(q.kv("ANSWER_FILE"), "SIGNALS: S2-architecture\n");
  return { fx, ticket: q.kv("TICKET") };
}
const modFinalize = (r, crashAt) => J.probe(r.fx, mock, ["finalize", JSON.stringify({ sid: J.SID, ticket: r.ticket, crashAt })]);

caseBegin("complexity-source-changed-fallback-line", "hooks/lib/jev/two-stage/replay.js");
const CX_CHANGES = [
  ["edit", {}, (fx) => editIntent(fx)],
  ["create", {}, (fx) => fs.writeFileSync(P(fx, "outline.md"), "# Outline\n\nWritten while the judge was out.\n")],
  ["delete", {}, (fx) => fs.rmSync(P(fx, "context.md"))],
];
for (const [name, files, change] of CX_CHANGES) {
  test(`complexity, source ${name} after the query: S0, exactly one FALLBACK=source-changed`, () => {
    const r = cxAnswered(`cx-sc-${name}`, files);
    change(r.fx);
    const f = J.finalize(r.fx, mock, r.ticket);
    assert.strictEqual(f.status, 0, `finalize exit 0 (stderr: ${f.stderr})`);
    assert.strictEqual(f.kv("SIGNALS_CSV"), "S0-undecidable", `stdout: ${f.stdout}`);
    assert.strictEqual(f.kv("SETTLE"), "ok");
    assert.deepStrictEqual(fallbacks(f), ["source-changed"], `stdout: ${f.stdout}`);
    assert.deepStrictEqual(settles(r.fx, r.ticket), ["ok|source-changed"]);
    assert.strictEqual(reasonOf(r), null, "the merge itself named no reason");
  });
}
test("complexity, source edited: the done-marker re-run prints byte-identical stdout", () => {
  const r = cxAnswered("cx-sc-rerun");
  editIntent(r.fx);
  const f = J.finalize(r.fx, mock, r.ticket);
  assert.deepStrictEqual(fallbacks(f), ["source-changed"], `stdout: ${f.stdout}`);
  const again = J.finalize(r.fx, mock, r.ticket);
  assert.strictEqual(again.status, 0);
  assert.strictEqual(again.stdout, f.stdout);
  assert.deepStrictEqual(settles(r.fx, r.ticket), ["ok|source-changed"], "the settle record is not duplicated");
});
test("complexity, source edited, stopped after the append, sweep replay: the done stdout keeps the line", () => {
  const r = cxAnswered("cx-sc-sweep");
  editIntent(r.fx);
  const c = modFinalize(r, "after-append");
  assert.strictEqual(c.status, 99, `premise: stopped after the decision append (stderr: ${c.stderr})`);
  J.sleepMs(1100);
  const s = J.probe(r.fx, mock, ["sweep", J.SID, "1"]);
  assert.strictEqual(s.status, 0, `sweep exit 0 (stderr: ${s.stderr})`);
  const f = J.finalize(r.fx, mock, r.ticket);
  assert.strictEqual(f.status, 0, `finalize after the sweep exit 0 (stdout: ${f.stdout})`);
  assert.strictEqual(f.kv("SIGNALS_CSV"), "S0-undecidable");
  assert.deepStrictEqual(fallbacks(f), ["source-changed"], `stdout: ${f.stdout}`);
});
test("contrast, source rewritten with the same bytes: S2 settles, no FALLBACK line", () => {
  const r = cxAnswered("cx-sc-same");
  const keep = fs.readFileSync(P(r.fx, "intent.md"));
  J.sleepMs(1100);
  fs.writeFileSync(P(r.fx, "intent.md"), keep);
  const f = J.finalize(r.fx, mock, r.ticket);
  assert.strictEqual(f.kv("SIGNALS_CSV"), "S2-architecture", `stdout: ${f.stdout}`);
  assert.deepStrictEqual(fallbacks(f), []);
  assert.deepStrictEqual(settles(r.fx, r.ticket), []);
});
test("contrast, source edited after the value was decided: S2 settles, no FALLBACK line", () => {
  const r = cxAnswered("cx-sc-late");
  const c = modFinalize(r, "after-owner-writing");
  assert.strictEqual(c.status, 99, `premise: stopped inside the settle (stderr: ${c.stderr})`);
  editIntent(r.fx);
  const f = J.finalize(r.fx, mock, r.ticket);
  assert.strictEqual(f.status, 0, `stderr: ${f.stderr}`);
  assert.strictEqual(f.kv("SIGNALS_CSV"), "S2-architecture", `stdout: ${f.stdout}`);
  assert.deepStrictEqual(fallbacks(f), []);
});
test("complexity, source edited and a newer query took the owner: SETTLE=superseded, no FALLBACK line", () => {
  const r = cxAnswered("cx-sc-newer");
  editIntent(r.fx);
  J.sleepMs(60);
  mock.probs(0.01, { "S2-architecture": 0.5 });
  const b = J.cxQuery(r.fx, mock, "complexity");
  assert.strictEqual(b.status, 0, `query B exit 0 (stderr: ${b.stderr})`);
  assert.notStrictEqual(b.kv("TICKET"), r.ticket, "premise: query B issued its own ticket");
  const f = J.finalize(r.fx, mock, r.ticket);
  assert.strictEqual(f.status, 0, `stderr: ${f.stderr}`);
  assert.strictEqual(f.kv("SETTLE"), "superseded", `stdout: ${f.stdout}`);
  assert.deepStrictEqual(fallbacks(f), [], `stdout: ${f.stdout}`);
});
caseEnd();

caseBegin("complexity-settle-source-changed-defers-to-merge-reason", "hooks/lib/jev/two-stage/replay.js");
const CX_MERGE_FIRST = [
  ["absent", undefined, "answer-file-absent"],
  ["empty", "", "answer-empty"],
];
for (const [name, answer, reason] of CX_MERGE_FIRST) {
  test(`complexity, answer ${name} (merge reason) and intent edited (settle reason): only FALLBACK=${reason}`, () => {
    const fx = J.newFx(ROOT, `cx-sc-merge-${name}`);
    mock.probs(0.01, { "S2-architecture": 0.5 });
    const q = J.cxQuery(fx, mock, "complexity");
    assert.strictEqual(q.kv("RESULT"), "need-subagent", `premise, the query delegates (stdout: ${q.stdout})`);
    if (answer !== undefined) writeAnswer(q.kv("ANSWER_FILE"), answer);
    const r = { fx, ticket: q.kv("TICKET") };
    editIntent(fx);
    const f = J.finalize(fx, mock, r.ticket);
    assert.strictEqual(f.status, 0, `stderr: ${f.stderr}`);
    assert.strictEqual(f.kv("SIGNALS_CSV"), "S0-undecidable", `stdout: ${f.stdout}`);
    assert.deepStrictEqual(fallbacks(f), [reason], `stdout: ${f.stdout}`);
    // The merge already demoted to S0, so the edit changes nothing: no settle-stage demotion to record.
    assert.deepStrictEqual(settles(fx, r.ticket), []);
    assert.strictEqual(reasonOf(r), reason);
  });
}
caseEnd();

caseBegin("skip-settle-source-changed-defers-to-merge-reason", "hooks/lib/jev/two-stage/replay.js");
test("skip: partial answer (merge reason) and outline edited (settle reason): only FALLBACK=answer-unparseable", () => {
  const fx = J.newFx(ROOT, "sk-sc-merge", { outline: true, stateJson: J.STATE_AT_DETAIL });
  // K2 adopted true from Jev; K1 delegated and answered true, the answer missing K2 is partial.
  mock.probs(0.5, { [K2]: 0.95 });
  const q = J.skipQuery(fx, mock, "detail");
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `premise (stdout: ${q.stdout})`);
  writeAnswer(q.kv("ANSWER_FILE"), `SKIP_CONDITIONS: ${K1}=true\n`);
  fs.writeFileSync(P(fx, "outline.md"), "# Outline\n\nTwo approaches are open now.\n");
  const f = J.finalize(fx, mock, q.kv("TICKET"));
  assert.strictEqual(f.status, 0, `stderr: ${f.stderr}`);
  assert.strictEqual(f.kv("SETTLE"), "superseded", `premise: the source change demotes the skip (stdout: ${f.stdout})`);
  assert.strictEqual(f.kv("SKIP"), "false");
  assert.deepStrictEqual(settles(fx, q.kv("TICKET")), ["superseded|source-changed"]);
  assert.deepStrictEqual(fallbacks(f), ["answer-unparseable"], `stdout: ${f.stdout}`);
});
test("skip: valid answer and outline edited: exactly one FALLBACK=source-changed", () => {
  const fx = J.newFx(ROOT, "sk-sc-only", { outline: true, stateJson: J.STATE_AT_DETAIL });
  mock.probs(0.5, { [K2]: 0.95 });
  const q = J.skipQuery(fx, mock, "detail");
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `premise (stdout: ${q.stdout})`);
  writeAnswer(q.kv("ANSWER_FILE"), `SKIP_CONDITIONS: ${K1}=true, ${K2}=true\n`);
  fs.writeFileSync(P(fx, "outline.md"), "# Outline\n\nTwo approaches are open now.\n");
  const f = J.finalize(fx, mock, q.kv("TICKET"));
  assert.strictEqual(f.kv("SETTLE"), "superseded", `stdout: ${f.stdout}`);
  assert.deepStrictEqual(fallbacks(f), ["source-changed"], `stdout: ${f.stdout}`);
});
test("skip, outline edited, stopped after the settle, outline restored, sweep replay: the recorded settle keeps the line", () => {
  const fx = J.newFx(ROOT, "sk-sc-sweep", { outline: true, stateJson: J.STATE_AT_DETAIL });
  mock.probs(0.5, { [K2]: 0.95 });
  const q = J.skipQuery(fx, mock, "detail");
  assert.strictEqual(q.kv("RESULT"), "need-subagent", `premise (stdout: ${q.stdout})`);
  writeAnswer(q.kv("ANSWER_FILE"), `SKIP_CONDITIONS: ${K1}=true, ${K2}=true\n`);
  const r = { fx, ticket: q.kv("TICKET") };
  const original = fs.readFileSync(P(fx, "outline.md"));
  fs.writeFileSync(P(fx, "outline.md"), "# Outline\n\nTwo approaches are open now.\n");
  const c = modFinalize(r, "after-settle");
  assert.strictEqual(c.status, 99, `premise: stopped after the settle (stderr: ${c.stderr})`);
  // The settle outcome was already decided; restoring the bytes must not undo it.
  fs.writeFileSync(P(fx, "outline.md"), original);
  J.sleepMs(1100);
  const s = J.probe(fx, mock, ["sweep", J.SID, "1"]);
  assert.strictEqual(s.status, 0, `sweep exit 0 (stderr: ${s.stderr})`);
  const f = J.finalize(fx, mock, r.ticket);
  assert.strictEqual(f.status, 0, `finalize after the sweep exit 0 (stdout: ${f.stdout})`);
  assert.strictEqual(f.kv("SETTLE"), "superseded", `stdout: ${f.stdout}`);
  assert.deepStrictEqual(fallbacks(f), ["source-changed"], `stdout: ${f.stdout}`);
  assert.deepStrictEqual(settles(fx, r.ticket), ["superseded|source-changed"], "exactly one settle record");
});
caseEnd();

caseBegin("fallback-lines-priority", "hooks/lib/jev/two-stage/replay.js");
test("fallbackLines(r, settled): the merge reason wins, else source-changed, else nothing", () => {
  const { fallbackLines } = require(path.join(J.REPO, "hooks", "lib", "jev", "two-stage", "replay.js"));
  assert.strictEqual(typeof fallbackLines, "function", "replay.js exports fallbackLines");
  assert.deepStrictEqual(fallbackLines({ fallback: "answer-empty" }, { settle: "ok", detail: "source-changed" }),
    ["FALLBACK=answer-empty"]);
  assert.deepStrictEqual(fallbackLines({ fallback: null }, { detail: "source-changed" }), ["FALLBACK=source-changed"]);
  assert.deepStrictEqual(fallbackLines({ fallback: null }, { settle: "ok", detail: null }), []);
  assert.deepStrictEqual(fallbackLines({}, { settle: "superseded", detail: "newer-owner" }), []);
  // A finalize that never reached the settle stage passes no settle record.
  assert.deepStrictEqual(fallbackLines({ fallback: "answer-empty" }, undefined), ["FALLBACK=answer-empty"]);
  assert.deepStrictEqual(fallbackLines({ fallback: "answer-empty" }, null), ["FALLBACK=answer-empty"]);
  assert.deepStrictEqual(fallbackLines({ fallback: null }, undefined), []);
  assert.deepStrictEqual(fallbackLines({ fallback: null }, null), []);
});
caseEnd();
