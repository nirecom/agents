"use strict";
// tests/hooks/feature-2019-finding-approval-prompt.js
// Tests: hooks/record-finding-approval-prompt.js
// Tags: TL2, hooks, user-prompt-submit, finding-approval, typed-command, slash-command, fail-open, table-driven, scope:issue-specific, pwsh-not-required
// #2019 S1-2: writer 1 rewrites `<sid>.finding-filing-approval` on every user prompt — one
// typed-command record when the prompt invokes /issue-create (wrapped or bare first line), else
// the file is removed. The prompt body is never recorded; every error path exits 0.
// TL3 gap: the real UserPromptSubmit payload of a live session (the wrapped form is the CC transcript shape).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2019p-"));
after(() => { restore(); fs.rmSync(SCRATCH, { recursive: true, force: true }); });

const HOOK = path.resolve(__dirname, "..", "..", "hooks", "record-finding-approval-prompt.js");
const WF = process.env.WORKFLOW_STATE_DIR;
const SID = "5e1d2c3b-2019-4b01-8a9b-0c1d2e3f4b01";
const FILE = path.join(WF, `${SID}.finding-filing-approval`);
const SECRET = "body-marker-7f3a-do-not-record";

// run(prompt, stateDir) -> { status, stdout }
function run(prompt, stateDir) {
  const env = Object.assign({}, process.env, { WORKFLOW_STATE_DIR: stateDir || WF });
  delete env.CLAUDE_CODE_SESSION_ID;
  const input = JSON.stringify({ hook_event_name: "UserPromptSubmit", session_id: SID, cwd: SCRATCH, prompt });
  const r = spawnSync(process.execPath, [HOOK], { input, env, cwd: SCRATCH, encoding: "utf8", timeout: 30000 });
  return { status: r.status, stdout: String(r.stdout || ""), stderr: String(r.stderr || "") };
}
const read = () => (fs.existsSync(FILE) ? fs.readFileSync(FILE, "utf8") : null);

const WRAPPED = `<command-message>issue-create is running…</command-message>\n<command-name>/issue-create</command-name>\n<command-args>${SECRET}</command-args>`;

caseBegin("typed-command-written-for-wrapped-and-bare", "hooks/record-finding-approval-prompt.js");
test("typed-command-written-for-wrapped-and-bare", () => {
  const ROWS = [
    ["wrapped /issue-create", WRAPPED],
    ["bare /issue-create on line 1", `/issue-create ${SECRET}\nmore text`],
  ];
  for (const [name, prompt] of ROWS) {
    fs.rmSync(FILE, { force: true });
    const r = run(prompt);
    assert.strictEqual(r.status, 0, `${name}: exit 0 (${r.stderr})`);
    const raw = read();
    assert.ok(raw, `${name}: the approval file is written`);
    const j = JSON.parse(raw);
    assert.strictEqual(j.version, 1, `${name}: version`);
    assert.strictEqual(j.session_id, SID, `${name}: session_id`);
    assert.strictEqual(j.records.length, 1, `${name}: exactly one record`);
    assert.strictEqual(j.records[0].type, "typed-command", `${name}: record type`);
    assert.ok(!Number.isNaN(Date.parse(j.records[0].at)) || typeof j.records[0].at === "number", `${name}: at is a time`);
    assert.ok(!raw.includes(SECRET), `${name}: the prompt body is not recorded`);
  }
});
caseEnd();

caseBegin("bare-on-line-2-not-detected", "hooks/record-finding-approval-prompt.js");
test("bare-on-line-2-not-detected", () => {
  fs.writeFileSync(FILE, JSON.stringify({ version: 1, session_id: SID, pending: [], records: [{ type: "typed-command", at: new Date().toISOString() }] }));
  const r = run(`please look at this\n/issue-create ${SECRET}`);
  assert.strictEqual(r.status, 0, "exit 0");
  assert.strictEqual(read(), null, "a /issue-create on line 2 is not an invocation; the stale file is removed");
});
caseEnd();

caseBegin("non-invoking-prompt-deletes-file", "hooks/record-finding-approval-prompt.js");
test("non-invoking-prompt-deletes-file", () => {
  const ROWS = [
    ["plain prose", "file the bug please"],
    ["another skill", "/issue-close-verified 12"],
    ["prefix collision", "/issue-create-batch x"],
  ];
  for (const [name, prompt] of ROWS) {
    fs.writeFileSync(FILE, JSON.stringify({ version: 1, session_id: SID, pending: [], records: [{ type: "askuser-answer", dialog_id: "notes-promotion.final-list", keys: ["aaaa1111"], at: new Date().toISOString() }] }));
    const r = run(prompt);
    assert.strictEqual(r.status, 0, `${name}: exit 0`);
    assert.strictEqual(read(), null, `${name}: the approval file is removed`);
  }
});
caseEnd();

caseBegin("write-failure-exits-0", "hooks/record-finding-approval-prompt.js");
test("write-failure-exits-0: an unwritable state dir is fail-open", () => {
  const blocker = path.join(SCRATCH, "not-a-dir");
  fs.writeFileSync(blocker, "x");
  const r = run(WRAPPED, path.join(blocker, "state"));
  assert.strictEqual(r.status, 0, `exit 0 on a write failure (${r.stderr})`);
});
caseEnd();
