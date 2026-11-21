"use strict";
// tests/bin/feature-2903-notes-append-user-ack.js
// Tests: bin/worktree-notes-append.js, bin/worktree-notes-append/args.js
// Tags: worktree-notes, append-cli, user-acknowledged, severity, pr-scope, mode-b, table-driven, scope:issue-specific, TL2
// #2903 introduced `--user-acknowledged`; #2019 retired it for `--severity high|medium|low|not-defect`
// + `--pr-scope this-pr|other` (required for BugsFound / RelatedTasks / NextTasks). What carries over
// from #2903: ManualReminders and Mode A take no triage flags, and Mode B stays body-keyed idempotent.
// The new marker format itself: tests/bin/feature-2019-notes-entry-format.js.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const APPEND = path.join(ROOT, "bin", "worktree-notes-append.js");
const restore = isolate();
delete process.env.CLAUDE_CODE_SESSION_ID;
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2903-append-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

let seq = 0;
const freshNotes = () => {
  const dir = path.join(TMP, `c${seq += 1}`);
  fs.mkdirSync(dir);
  return path.join(dir, "WORKTREE_NOTES.md");
};
const append = (notes, args) => spawnSync(process.execPath, [APPEND, "--notes-path", notes, ...args], { cwd: TMP, encoding: "utf8", timeout: 30000 });
const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, "utf8") : null);
const HEAD = "# Worktree Notes\n\n";
const TRIAGE = ["--severity", "medium", "--pr-scope", "other"];

caseBegin("args: triage flags required, ack flag retired", "bin/worktree-notes-append/args.js");
test("args: triage flags required, ack flag retired", () => {
  const cases = [
    { name: "BugsFound without triage flags", args: ["--section", "BugsFound", "--title", "X"], rc: 2 },
    { name: "RelatedTasks without --pr-scope", args: ["--section", "RelatedTasks", "--severity", "low", "--title", "X"], rc: 2 },
    { name: "NextTasks without --severity", args: ["--section", "NextTasks", "--pr-scope", "this-pr", "--title", "X"], rc: 2 },
    { name: "retired --user-acknowledged true", args: ["--section", "NextTasks", ...TRIAGE, "--title", "X", "--user-acknowledged", "true"], rc: 2 },
    { name: "retired --user-acknowledged false", args: ["--section", "NextTasks", ...TRIAGE, "--title", "X", "--user-acknowledged", "false"], rc: 2 },
    { name: "ManualReminders with triage flags", args: ["--section", "ManualReminders", ...TRIAGE, "--title", "X"], rc: 2 },
    { name: "Mode A with triage flags", args: ["--issue-number", "60", "--title", "X", "--label", "type:task", ...TRIAGE], rc: 2 },
    { name: "ManualReminders bare", args: ["--section", "ManualReminders", "--title", "X"], rc: 0 },
    { name: "NextTasks with triage flags", args: ["--section", "NextTasks", ...TRIAGE, "--title", "X"], rc: 0 },
  ];
  for (const { name, args, rc } of cases) {
    const notes = freshNotes();
    const r = append(notes, args);
    assert.strictEqual(r.status, rc, `${name}: exit code (stderr=${(r.stderr || "").trim().slice(0, 200)})`);
    if (rc === 2) assert.strictEqual(fs.existsSync(notes), false, `${name}: no write on rejection`);
  }
});
caseEnd();

caseBegin("append: untagged sections keep their #2903 shape", "bin/worktree-notes-append.js");
test("append: untagged sections keep their #2903 shape", () => {
  const cases = [
    { name: "manual reminders untagged", args: ["--section", "ManualReminders"], want: "## ManualReminders\n- X\n" },
    { name: "mode A unchanged", args: ["--issue-number", "60", "--label", "type:task"], want: "## RelatedTasks\n- X (#60) <!-- promoted: #60 -->\n" },
  ];
  for (const { name, args, want } of cases) {
    const notes = freshNotes();
    const r = append(notes, [...args, "--title", "X"]);
    assert.strictEqual(r.status, 0, `${name}: exit 0 (stderr=${(r.stderr || "").trim().slice(0, 200)})`);
    assert.strictEqual(read(notes), HEAD + want, `${name}: file content`);
  }
});
caseEnd();

caseBegin("append: idempotency is body-keyed across marker values", "bin/worktree-notes-append.js");
test("append: idempotency is body-keyed across marker values", () => {
  const cases = [
    { name: "medium/other then high/this-pr", first: ["--severity", "medium", "--pr-scope", "other"], second: ["--severity", "high", "--pr-scope", "this-pr"] },
    { name: "low/this-pr then not-defect/other", first: ["--severity", "low", "--pr-scope", "this-pr"], second: ["--severity", "not-defect", "--pr-scope", "other"] },
  ];
  for (const { name, first, second } of cases) {
    const notes = freshNotes();
    const base = ["--section", "NextTasks", "--title", "Dup me"];
    assert.strictEqual(append(notes, [...base, ...first]).status, 0, `${name}: first append`);
    const before = read(notes);
    assert.strictEqual(append(notes, [...base, ...second]).status, 0, `${name}: second append is a no-op success`);
    assert.strictEqual(read(notes), before, `${name}: file unchanged (no duplicate, no marker update)`);
  }
});
caseEnd();
