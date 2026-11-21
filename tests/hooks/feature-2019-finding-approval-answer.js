"use strict";
// tests/hooks/feature-2019-finding-approval-answer.js
// Tests: hooks/pre-tool-use-askuser-jev.js, hooks/record-finding-approval-answer.js
// Tags: TL2, hooks, askuserquestion, pretooluse, posttooluse, finding-approval, approval-key, pending, fail-closed, table-driven, scope:issue-specific, pwsh-not-required
// #2019 S1-3/4: the PreToolUse hook leaves a pending entry only for the approval dialog IDs; the
// PostToolUse hook turns a human answer into one askuser-answer record of the `[k:<8hex>]` keys of the
// chosen labels (one key per label; a label with 2+ keys records nothing). A Jev-answered route, an
// input that already had answers, no pending entry, or a non-target dialog writes nothing.
// TL3 gap: the real PostToolUse(AskUserQuestion) payload — tests/hooks/TL3-hook-finding-approval-answer.sh.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2019a-"));
fs.mkdirSync(path.join(SCRATCH, "transcripts"));
after(() => { restore(); fs.rmSync(SCRATCH, { recursive: true, force: true }); });

const ROOT = path.resolve(__dirname, "..", "..");
const PRE = path.join(ROOT, "hooks", "pre-tool-use-askuser-jev.js");
const POST = path.join(ROOT, "hooks", "record-finding-approval-answer.js");
const WF = process.env.WORKFLOW_STATE_DIR;
const SID = "5e1d2c3b-2019-4c01-8a9b-0c1d2e3f4c01";
const FILE = path.join(WF, `${SID}.finding-filing-approval`);
const Q = "Which findings should be filed?";

function hook(file, payload) {
  const env = Object.assign({}, process.env, { JEV: "off", CLAUDE_TRANSCRIPT_BASE_DIR: path.join(SCRATCH, "transcripts") });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [file], { input: JSON.stringify(payload), env, cwd: SCRATCH, encoding: "utf8", timeout: 30000 });
  return { status: r.status, stderr: String(r.stderr || "") };
}
const toolInput = (dialogId, extra) => Object.assign({
  questions: [{ question: Q, header: "Findings", multiSelect: true, options: [{ label: "A [k:11112222]", description: "a" }, { label: "B [k:33334444]", description: "b" }] }],
  metadata: { source: dialogId },
}, extra || {});
const pre = (id, dialogId, extra) => hook(PRE, { hook_event_name: "PreToolUse", tool_name: "AskUserQuestion", session_id: SID, tool_use_id: id, cwd: SCRATCH, tool_input: toolInput(dialogId, extra) });
const post = (id, dialogId, answers) => hook(POST, { hook_event_name: "PostToolUse", tool_name: "AskUserQuestion", session_id: SID, tool_use_id: id, cwd: SCRATCH, tool_input: toolInput(dialogId), tool_response: { questions: toolInput(dialogId).questions, answers } });
const read = () => (fs.existsSync(FILE) ? JSON.parse(fs.readFileSync(FILE, "utf8")) : null);
const pendingIds = () => ((read() || {}).pending || []).map((p) => p.tool_use_id);
const recordedKeys = () => ((read() || {}).records || []).filter((r) => r.type === "askuser-answer").flatMap((r) => r.keys || []).sort();
// seed(pending[]) — a fixed approval file holding only pending entries.
function seed(pending) {
  const at = new Date().toISOString();
  fs.writeFileSync(FILE, JSON.stringify({ version: 1, session_id: SID, pending: pending.map((p) => Object.assign({ at }, p)), records: [] }));
}

caseBegin("pending-only-for-approval-dialogs", "hooks/pre-tool-use-askuser-jev.js");
test("pending-only-for-approval-dialogs", () => {
  const ROWS = [
    ["issue-create.confirm-gate", true],
    ["notes-promotion.final-list", true],
    ["mid-workflow-findings.blocking-file", true],
    ["write-code.edit-plan-approve", false],
    ["no-such.dialog", false],
  ];
  for (const [dialogId, want] of ROWS) {
    fs.rmSync(FILE, { force: true });
    const id = `toolu_pre_${dialogId.replace(/\W/g, "_")}`;
    const r = pre(id, dialogId);
    assert.strictEqual(r.status, 0, `${dialogId}: exit 0`);
    assert.strictEqual(pendingIds().includes(id), want, `${dialogId}: pending written=${want}`);
    if (want) {
      const p = read().pending.find((x) => x.tool_use_id === id);
      assert.strictEqual(p.dialog_id, dialogId, `${dialogId}: dialog_id`);
      assert.strictEqual(typeof p.route, "string", `${dialogId}: route recorded`);
      assert.strictEqual(p.input_had_answers, false, `${dialogId}: input_had_answers false`);
    }
  }
  fs.rmSync(FILE, { force: true });
  pre("toolu_pre_had", "issue-create.confirm-gate", { answers: { [Q]: "A [k:11112222]" } });
  const p = ((read() || {}).pending || []).find((x) => x.tool_use_id === "toolu_pre_had");
  assert.ok(p && p.input_had_answers === true, "an input that carries answers is recorded as input_had_answers");
});
caseEnd();

caseBegin("human-answer-yields-keys", "hooks/record-finding-approval-answer.js");
test("human-answer-yields-keys: string, multiSelect array, comma-joined", () => {
  const ROWS = [
    ["single label", "A [k:11112222]", ["11112222"]],
    ["multiSelect array", ["A [k:11112222]", "B [k:33334444]"], ["11112222", "33334444"]],
    // Two picks delivered as one comma-joined string: still one key per label, no label lost or merged.
    ["comma-joined, 2 picked", "A [k:11112222], B [k:33334444]", ["11112222", "33334444"]],
  ];
  for (const [name, value, want] of ROWS) {
    seed([{ tool_use_id: "toolu_h", dialog_id: "notes-promotion.final-list", route: "high", input_had_answers: false }]);
    const r = post("toolu_h", "notes-promotion.final-list", { [Q]: value });
    assert.strictEqual(r.status, 0, `${name}: exit 0`);
    assert.deepStrictEqual(recordedKeys(), want, `${name}: keys`);
    const rec = read().records.find((x) => x.type === "askuser-answer");
    assert.strictEqual(rec.dialog_id, "notes-promotion.final-list", `${name}: dialog_id`);
    assert.ok(!pendingIds().includes("toolu_h"), `${name}: the pending entry is taken out`);
  }
});
caseEnd();

caseBegin("label-with-two-keys-or-free-text-records-nothing", "hooks/record-finding-approval-answer.js");
test("label-with-two-keys-or-free-text-records-nothing", () => {
  const ROWS = [
    ["two keys on one label", "A [k:11112222] [k:55556666]", []],
    ["Other free text", "please file the first one", []],
    ["mixed: one valid, one double", ["B [k:33334444]", "A [k:11112222] [k:55556666]"], ["33334444"]],
  ];
  for (const [name, value, want] of ROWS) {
    seed([{ tool_use_id: "toolu_x", dialog_id: "issue-create.confirm-gate", route: "high", input_had_answers: false }]);
    post("toolu_x", "issue-create.confirm-gate", { [Q]: value });
    assert.deepStrictEqual(recordedKeys(), want, name);
  }
});
caseEnd();

caseBegin("non-human-or-unmatched-writes-nothing", "hooks/record-finding-approval-answer.js");
test("non-human-or-unmatched-writes-nothing", () => {
  const ROWS = [
    ["route answered (Jev)", [{ tool_use_id: "toolu_n", dialog_id: "mid-workflow-findings.blocking-file", route: "answered", input_had_answers: false }], "mid-workflow-findings.blocking-file"],
    ["input_had_answers", [{ tool_use_id: "toolu_n", dialog_id: "issue-create.confirm-gate", route: "high", input_had_answers: true }], "issue-create.confirm-gate"],
    ["no pending entry", [{ tool_use_id: "toolu_other", dialog_id: "issue-create.confirm-gate", route: "high", input_had_answers: false }], "issue-create.confirm-gate"],
    ["non-target dialog", [{ tool_use_id: "toolu_n", dialog_id: "write-code.edit-plan-approve", route: "high", input_had_answers: false }], "write-code.edit-plan-approve"],
  ];
  for (const [name, pending, dialogId] of ROWS) {
    seed(pending);
    const r = post("toolu_n", dialogId, { [Q]: "A [k:11112222]" });
    assert.strictEqual(r.status, 0, `${name}: exit 0`);
    assert.deepStrictEqual(recordedKeys(), [], `${name}: no key recorded`);
  }
  fs.rmSync(FILE, { force: true });
  post("toolu_n", "issue-create.confirm-gate", { [Q]: "A [k:11112222]" });
  assert.deepStrictEqual(recordedKeys(), [], "no approval file at all: nothing recorded");
});
caseEnd();

caseBegin("pre-then-post-end-to-end", "hooks/record-finding-approval-answer.js");
test("pre-then-post-end-to-end: a high approval dialog answered by the human", () => {
  fs.rmSync(FILE, { force: true });
  pre("toolu_e2e", "issue-create.confirm-gate");
  post("toolu_e2e", "issue-create.confirm-gate", { [Q]: "B [k:33334444]" });
  assert.deepStrictEqual(recordedKeys(), ["33334444"], "the chosen label's key is recorded");
});
caseEnd();
