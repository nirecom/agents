"use strict";
// tests/bin/feature-2903-notes-append-user-ack.js
// Tests: bin/worktree-notes-append.js, bin/worktree-notes-append/args.js, bin/worktree-notes-triage.js
// Tags: worktree-notes, append-cli, triage, user-acknowledged, mode-b, table-driven, scope:issue-specific, TL2
// #2903: Mode B takes `--user-acknowledged true|false` (required for BugsFound / RelatedTasks / NextTasks,
// rejected for ManualReminders and Mode A), writes the marker in canonical order, stays body-keyed
// idempotent, and `worktree-notes-triage.js list` reports userAcknowledged per entry.

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const APPEND = path.join(ROOT, "bin", "worktree-notes-append.js");
const TRIAGE = path.join(ROOT, "bin", "worktree-notes-triage.js");
const restore = isolate();
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2903-append-"));
after(() => { restore(); fs.rmSync(TMP, { recursive: true, force: true }); });

let seq = 0;
const freshNotes = (seed) => {
  const dir = path.join(TMP, `c${seq += 1}`);
  fs.mkdirSync(dir);
  const p = path.join(dir, "WORKTREE_NOTES.md");
  if (seed !== undefined) fs.writeFileSync(p, seed);
  return p;
};
const run = (script, args) => spawnSync(process.execPath, [script, ...args], { cwd: TMP, encoding: "utf8", timeout: 30000 });
const append = (notes, args) => run(APPEND, ["--notes-path", notes, ...args]);
const read = (p) => (fs.existsSync(p) ? fs.readFileSync(p, "utf8") : null);
const HEAD = "# Worktree Notes\n\n";

caseBegin("args: --user-acknowledged requirement and allowlist", "bin/worktree-notes-append/args.js");
test("args: --user-acknowledged requirement and allowlist", () => {
  const cases = [
    { name: "BugsFound without ack", args: ["--section", "BugsFound", "--severity", "high", "--title", "X"], rc: 2 },
    { name: "RelatedTasks without ack", args: ["--section", "RelatedTasks", "--title", "X"], rc: 2 },
    { name: "NextTasks without ack", args: ["--section", "NextTasks", "--title", "X"], rc: 2 },
    { name: "ManualReminders with ack", args: ["--section", "ManualReminders", "--title", "X", "--user-acknowledged", "true"], rc: 2 },
    { name: "Mode A with ack", args: ["--issue-number", "60", "--title", "X", "--label", "type:task", "--user-acknowledged", "true"], rc: 2 },
    { name: "value maybe", args: ["--section", "NextTasks", "--title", "X", "--user-acknowledged", "maybe"], rc: 2 },
    { name: "value TRUE", args: ["--section", "NextTasks", "--title", "X", "--user-acknowledged", "TRUE"], rc: 2 },
    { name: "value empty", args: ["--section", "NextTasks", "--title", "X", "--user-acknowledged", ""], rc: 2 },
    { name: "ManualReminders without ack", args: ["--section", "ManualReminders", "--title", "X"], rc: 0 },
    { name: "NextTasks ack false", args: ["--section", "NextTasks", "--title", "X", "--user-acknowledged", "false"], rc: 0 },
  ];
  for (const { name, args, rc } of cases) {
    const notes = freshNotes();
    const r = append(notes, args);
    assert.strictEqual(r.status, rc, `${name}: exit code (stderr=${(r.stderr || "").trim().slice(0, 200)})`);
    if (rc === 2) assert.strictEqual(fs.existsSync(notes), false, `${name}: no write on rejection`);
  }
});
caseEnd();

caseBegin("append: marker line per section / severity / ack", "bin/worktree-notes-append.js");
test("append: marker line per section / severity / ack", () => {
  const cases = [
    { name: "high+true", args: ["--section", "BugsFound", "--severity", "high", "--user-acknowledged", "true"], want: "## BugsFound\n- X <!-- severity: high --> <!-- user-acknowledged: true -->\n" },
    { name: "high+false", args: ["--section", "BugsFound", "--severity", "high", "--user-acknowledged", "false"], want: "## BugsFound\n- X <!-- severity: high --> <!-- user-acknowledged: false -->\n" },
    { name: "low+true", args: ["--section", "BugsFound", "--severity", "low", "--user-acknowledged", "true"], want: "## BugsFound\n- X <!-- user-acknowledged: true -->\n" },
    { name: "related false", args: ["--section", "RelatedTasks", "--user-acknowledged", "false"], want: "## RelatedTasks\n- X <!-- user-acknowledged: false -->\n" },
    { name: "next true", args: ["--section", "NextTasks", "--user-acknowledged", "true"], want: "## NextTasks\n- X <!-- user-acknowledged: true -->\n" },
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

caseBegin("append: idempotency is body-keyed across ack values", "bin/worktree-notes-append.js");
test("append: idempotency is body-keyed across ack values", () => {
  const cases = [
    { name: "true then false", first: "true", second: "false" },
    { name: "false then true", first: "false", second: "true" },
  ];
  for (const { name, first, second } of cases) {
    const notes = freshNotes();
    const base = ["--section", "NextTasks", "--title", "Dup me", "--user-acknowledged"];
    assert.strictEqual(append(notes, [...base, first]).status, 0, `${name}: first append`);
    const before = read(notes);
    assert.strictEqual(append(notes, [...base, second]).status, 0, `${name}: second append is a no-op success`);
    assert.strictEqual(read(notes), before, `${name}: file unchanged (no duplicate, no ack update)`);
  }
});
caseEnd();

caseBegin("triage list: JSON entries carry userAcknowledged", "bin/worktree-notes-triage.js");
test("triage list: JSON entries carry userAcknowledged", () => {
  const notes = freshNotes([
    "# Worktree Notes", "", "## BugsFound",
    "- B1 <!-- severity: high --> <!-- user-acknowledged: true -->",
    "- B2 <!-- user-acknowledged: false -->",
    "- B3",
    "- B4 <!-- user-acknowledged: maybe -->",
    "", "## NextTasks", "- N1 <!-- user-acknowledged: true -->", "",
  ].join("\n"));
  const r = run(TRIAGE, ["list", notes]);
  assert.strictEqual(r.status, 0, `triage list exit 0 (stderr=${(r.stderr || "").trim().slice(0, 200)})`);
  const items = JSON.parse(r.stdout);
  const byBody = Object.fromEntries(items.map((e) => [String(e.raw).replace(/^- (\S+).*$/, "$1"), e]));
  const cases = [
    { name: "B1", want: true }, { name: "B2", want: false }, { name: "B3", want: false },
    { name: "B4", want: false }, { name: "N1", want: true },
  ];
  for (const { name, want } of cases) {
    assert.ok(byBody[name], `${name}: listed`);
    assert.strictEqual(byBody[name].userAcknowledged, want, `${name}: userAcknowledged`);
  }
});
caseEnd();
