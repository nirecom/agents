"use strict";
// tests/hooks/feature-2019-finding-approval-guard.js
// Tests: hooks/lib/protected-basenames.js, hooks/block-clearance-token-write/dispatch.js
// Tags: TL2, hooks, protected-marker, forgery, block-clearance-token-write, finding-approval, security, negative-assertion, table-driven, scope:issue-specific, pwsh-not-required
// #2019 S1/S7 guard: `<sid>.finding-filing-approval` joins the protected session markers. The model's
// Write, Edit and Bash redirect to it (and to its `.tmp`) are blocked and the file stays unchanged;
// the writer hook itself writes it through fs. An unrelated path keeps the allow verdict.
// TL3 gap: the live PreToolUse dispatch order in settings.json (block-clearance-token-write before the tool).

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const restore = isolate();
const SCRATCH = fs.mkdtempSync(path.join(os.tmpdir(), "f2019g-"));
after(() => { restore(); fs.rmSync(SCRATCH, { recursive: true, force: true }); });

const ROOT = path.resolve(__dirname, "..", "..");
const BLOCK_HOOK = path.join(ROOT, "hooks", "block-clearance-token-write.js");
const WRITER = path.join(ROOT, "hooks", "record-finding-approval-prompt.js");
const PB = require(path.join(ROOT, "hooks", "lib", "protected-basenames.js"));
const DISPATCH = require(path.join(ROOT, "hooks", "block-clearance-token-write", "dispatch.js"));
const WF = process.env.WORKFLOW_STATE_DIR.replace(/\\/g, "/");
const SID = "5e1d2c3b-2019-4d01-8a9b-0c1d2e3f4d01";
const KIND = "finding-filing-approval";
const TARGET = `${WF}/${SID}.${KIND}`;
const ORIGINAL = JSON.stringify({ version: 1, session_id: SID, pending: [], records: [] });

function child(file, payload) {
  const env = Object.assign({}, process.env);
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, [file], { input: JSON.stringify(payload), env, cwd: SCRATCH, encoding: "utf8", timeout: 30000 });
  return { status: r.status, out: String(r.stdout || "") };
}
const verdict = (toolName, toolInput) => child(BLOCK_HOOK, { tool_name: toolName, session_id: SID, cwd: SCRATCH, tool_input: toolInput }).out;
const blocked = (out) => /"decision"\s*:\s*"block"/.test(out) || /"permissionDecision"\s*:\s*"deny"/.test(out);

caseBegin("kind-registered-as-session-marker", "hooks/lib/protected-basenames.js");
test("kind-registered-as-session-marker", () => {
  assert.ok(PB.SESSION_MARKER_KINDS.includes(KIND), "SESSION_MARKER_KINDS carries the new kind");
  assert.strictEqual(PB.classifyProtectedPath(TARGET), "marker", "the approval file is a protected marker");
  assert.strictEqual(PB.classifyProtectedPath(`${TARGET}.tmp`), "marker", "its .tmp is covered too");
  assert.strictEqual(PB.classifyProtectedPath(`${WF}/${SID}.finding-notes.md`), null, "a look-alike name is not protected");
});
caseEnd();

caseBegin("model-writes-blocked-file-unchanged", "hooks/block-clearance-token-write/dispatch.js");
test("model-writes-blocked-file-unchanged", () => {
  fs.writeFileSync(TARGET, ORIGINAL);
  const ROWS = [
    ["Write", "Write", { file_path: TARGET, content: "{}" }],
    ["Write .tmp", "Write", { file_path: `${TARGET}.tmp`, content: "{}" }],
    ["Edit", "Edit", { file_path: TARGET, old_string: "[]", new_string: "[{}]" }],
    ["Bash redirect", "Bash", { command: `printf x > ${TARGET}` }],
    ["Bash redirect .tmp", "Bash", { command: `printf x > ${TARGET}.tmp` }],
  ];
  for (const [name, tool, input] of ROWS) {
    const out = verdict(tool, input);
    assert.ok(blocked(out), `${name}: blocked (got ${out.slice(0, 200)})`);
  }
  assert.strictEqual(fs.readFileSync(TARGET, "utf8"), ORIGINAL, "the protected file is unchanged");
  assert.ok(!fs.existsSync(`${TARGET}.tmp`), "no .tmp was created");
});
caseEnd();

caseBegin("block-message-names-the-kind", "hooks/block-clearance-token-write/dispatch.js");
test("block-message-names-the-kind", () => {
  assert.ok(DISPATCH.MARKER_BLOCK_MSG.includes(`.${KIND}`), "MARKER_BLOCK_MSG lists the new kind");
});
caseEnd();

caseBegin("unrelated-path-allowed", "hooks/block-clearance-token-write/dispatch.js");
test("unrelated-path-allowed", () => {
  const ROWS = [
    ["Write elsewhere", "Write", { file_path: path.join(SCRATCH, "notes.md").replace(/\\/g, "/"), content: "x" }],
    ["Bash elsewhere", "Bash", { command: `printf x > ${SCRATCH.replace(/\\/g, "/")}/out.txt` }],
  ];
  for (const [name, tool, input] of ROWS) assert.ok(!blocked(verdict(tool, input)), `${name}: allowed`);
});
caseEnd();

caseBegin("writer-hook-may-write", "hooks/lib/protected-basenames.js");
test("writer-hook-may-write: the UserPromptSubmit writer creates the protected file", () => {
  fs.rmSync(TARGET, { force: true });
  const r = child(WRITER, { hook_event_name: "UserPromptSubmit", session_id: SID, cwd: SCRATCH, prompt: "/issue-create x" });
  assert.strictEqual(r.status, 0, "writer exit 0");
  assert.ok(fs.existsSync(TARGET), "the hook wrote the protected marker file");
});
caseEnd();
