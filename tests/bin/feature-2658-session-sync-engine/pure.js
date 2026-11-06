"use strict";
// Pure-rule parts of tests/bin/feature-2658-session-sync-engine.js (#2658): jsonl union, history
// merge, conflict decision and sibling name, exclude managed block, mtime decision. Holds no case
// markers; each export registers the tests of one module and loads it inside each test.
const assert = require("node:assert");
const { test } = require("node:test");
const { jline } = require("./fixtures");

const lines = (...ls) => ls.join("\n") + "\n";

function jsonl(F) {
  test("jsonl.union keeps local order and appends remote-only lines in remote order", () => {
    const r = F.lib("jsonl").union(lines(jline("a"), jline("b")), lines(jline("a"), jline("c"), jline("d")));
    assert.strictEqual(r.deferred, false);
    assert.strictEqual(r.text, lines(jline("a"), jline("b"), jline("c"), jline("d")));
    assert.strictEqual(r.remoteSuperset, false);
  });
  test("jsonl.union returns the remote blob as is when local keys are a subset", () => {
    const remote = lines(jline("a"), '{"type":"summary","summary":"s"}', jline("b"));
    const r = F.lib("jsonl").union(lines(jline("a")), remote);
    assert.strictEqual(r.remoteSuperset, true);
    assert.strictEqual(r.text, remote);
  });
  test("jsonl.union keeps the local file order in the working tree when the shared lines are ordered differently", () => {
    const local = lines(jline("b"), jline("a"));
    const remote = lines(jline("a"), jline("b"), jline("c"));
    const r = F.lib("jsonl").union(local, remote);
    assert.strictEqual(r.remoteSuperset, true);
    assert.strictEqual(r.text, remote);
    assert.strictEqual(r.appendText, lines(jline("c")));
    assert.strictEqual(local + r.appendText, lines(jline("b"), jline("a"), jline("c")));
  });
  test("jsonl.union keys lines without a uuid by the whole line", () => {
    const s1 = '{"type":"summary","summary":"one"}';
    const s2 = '{"type":"summary","summary":"two"}';
    const r = F.lib("jsonl").union(lines(s1, jline("a")), lines(s1, s2));
    assert.strictEqual(r.text, lines(s1, jline("a"), s2));
  });
  test("jsonl.union keeps the local line on a uuid content mismatch and counts it", () => {
    const local = jline("a", { message: "local" });
    const r = F.lib("jsonl").union(lines(local), lines(jline("a", { message: "remote" }), jline("b")));
    assert.strictEqual(r.text, lines(local, jline("b")));
    assert.strictEqual(r.uuidMismatch, 1);
  });
  test("jsonl.union drops rebase conflict-marker lines and counts them", () => {
    const local = lines("<<<<<<< HEAD", jline("a"), "=======", jline("b"), ">>>>>>> 1234abc (sync)");
    const r = F.lib("jsonl").union(local, lines(jline("a")));
    assert.strictEqual(r.droppedMarkerLines, 3);
    assert.strictEqual(r.text, lines(jline("a"), jline("b")));
    assert.ok(!/^(<{7}|={7}|>{7})/m.test(r.text), r.text);
  });
  test("jsonl.union drops conflict-marker lines from the remote side without touching local lines", () => {
    const local = lines(jline("a"), jline("b"));
    const remote = lines("<<<<<<< HEAD", jline("a"), "=======", jline("c"), ">>>>>>> 1234abc (sync)");
    const r = F.lib("jsonl").union(local, remote);
    assert.strictEqual(r.droppedMarkerLines, 3);
    assert.strictEqual(r.text, lines(jline("a"), jline("b"), jline("c")));
    assert.strictEqual(r.appendText, lines(jline("c")));
    assert.ok(!/^(<{7}|={7}|>{7})/m.test(r.text), r.text);
  });
  test("jsonl.union defers a local file without a trailing newline", () => {
    const r = F.lib("jsonl").union(jline("a") + "\n" + jline("b"), lines(jline("a"), jline("c")));
    assert.strictEqual(r.deferred, true);
  });
  test("jsonl.union is stable on a second round (union of union and remote is unchanged)", () => {
    const U = F.lib("jsonl").union;
    const first = U(lines(jline("a"), jline("b")), lines(jline("a"), jline("c"))).text;
    const second = U(first, lines(jline("a"), jline("c")));
    assert.strictEqual(second.text, first);
  });
}

function history(F) {
  const h = (ts, d) => JSON.stringify({ display: d, timestamp: ts, project: "p" });
  test("history.mergeHistory unions whole lines and stable-sorts by numeric timestamp", () => {
    const r = F.lib("history").mergeHistory(lines(h(10, "a"), h(30, "c")), lines(h(20, "b"), h(10, "a"), h(20, "b2")));
    assert.strictEqual(r.text, lines(h(10, "a"), h(20, "b"), h(20, "b2"), h(30, "c")));
    assert.strictEqual(r.changed, true);
  });
  test("history.mergeHistory reports no change when remote adds nothing", () => {
    const local = lines(h(10, "a"), h(20, "b"));
    const r = F.lib("history").mergeHistory(local, lines(h(10, "a")));
    assert.strictEqual(r.changed, false);
    assert.strictEqual(r.text, local);
  });
}

function conflict(F) {
  const R = Date.UTC(2026, 0, 2, 3, 4, 5);
  test("conflict.decide applies the 120 s skew window on both sides", () => {
    const { decide, SKEW_MS } = F.lib("conflict");
    assert.strictEqual(SKEW_MS, 120000);
    assert.strictEqual(decide({ localMtimeMs: R + 120001, remoteTimeMs: R }), "local");
    assert.strictEqual(decide({ localMtimeMs: R + 120000, remoteTimeMs: R }), "both");
    assert.strictEqual(decide({ localMtimeMs: R, remoteTimeMs: R }), "both");
    assert.strictEqual(decide({ localMtimeMs: R - 120000, remoteTimeMs: R }), "both");
    assert.strictEqual(decide({ localMtimeMs: R - 120001, remoteTimeMs: R }), "remote");
  });
  test("conflict.siblingName builds the sync-conflict name and numbers collisions", () => {
    const { siblingName } = F.lib("conflict");
    const date = new Date(R);
    assert.strictEqual(siblingName("p/note.md", "hostA", date, () => false), "p/note.sync-conflict-hostA-20260102T030405Z.md");
    assert.strictEqual(siblingName("README", "hostA", date, () => false), "README.sync-conflict-hostA-20260102T030405Z");
    const taken = new Set(["p/note.sync-conflict-hostA-20260102T030405Z.md", "p/note.sync-conflict-hostA-20260102T030405Z-2.md"]);
    assert.strictEqual(siblingName("p/note.md", "hostA", date, (n) => taken.has(n)), "p/note.sync-conflict-hostA-20260102T030405Z-3.md");
  });
}

function exclude(F) {
  const expected = ["/workflow/", "/codex-review/", "/plans/*", "!/plans/*.md", "*.bak.*", "*.tmp",
    "/*-AppData-Local-Temp-*/", "/-tmp-*/", "/-var-folders-*/", "/-private-var-folders-*/"];
  test("exclude.PATTERNS holds every default pattern", () => {
    const { PATTERNS } = F.lib("exclude");
    for (const p of expected) assert.ok(PATTERNS.includes(p), `missing ${p}`);
  });
  test("exclude.applyManagedBlock is idempotent and keeps lines outside the block", () => {
    const { applyManagedBlock, BEGIN, END } = F.lib("exclude");
    assert.strictEqual(BEGIN, "# BEGIN agents session-sync (managed)");
    assert.ok(END.startsWith("# END"), END);
    const once = applyManagedBlock("/workflow/*.tmp\nmy-custom/\n");
    assert.strictEqual(applyManagedBlock(once), once);
    assert.ok(once.includes("my-custom/\n") && once.includes("/workflow/*.tmp\n"), once);
    for (const p of expected) assert.ok(once.split(/\r?\n/).includes(p), `block lacks ${p}`);
  });
  test("exclude.applyManagedBlock replaces an outdated block instead of adding a second one", () => {
    const { applyManagedBlock, BEGIN, END } = F.lib("exclude");
    const out = applyManagedBlock(`keep-before\n${BEGIN}\nold-pattern\n${END}\nkeep-after\n`);
    assert.strictEqual(out.split(BEGIN).length - 1, 1, out);
    assert.ok(!out.includes("old-pattern"), out);
    assert.ok(out.includes("keep-before\n") && out.includes("keep-after\n"), out);
  });
  const excludedTable = [
    ["workflow dir file", "workflow/state.json"],
    ["workflow dir nested file", "workflow/sub/x.json"],
    ["codex-review dir file", "codex-review/r.md"],
    ["plans non-md file", "plans/x.json"],
    ["plans md in a subdir", "plans/sub/a.md"],
    ["tmp file in a project", "p1/a.tmp"],
    ["tmp file at the root", "a.tmp"],
    ["bak file with a suffix", "p1/a.jsonl.bak.20260101"],
    ["file under a bak dir", "p1/old.bak.1/x.jsonl"],
    ["Windows Temp scratch project", "C--Users-u-AppData-Local-Temp-claude-scratchpad/s.jsonl"],
    ["POSIX /tmp project", "-tmp-scratch/s.jsonl"],
    ["macOS /var/folders project", "-var-folders-ab-T-x/s.jsonl"],
    ["macOS /private/var/folders project", "-private-var-folders-ab-T-x/s.jsonl"],
  ];
  const allowedTable = [
    ["transcript in a project", "C--src-agents/0f1e2d3c.jsonl"],
    ["subagent transcript", "C--src-agents/0f1e2d3c/subagents/agent-1.jsonl"],
    ["plans md file", "plans/keep.md"],
    ["plans dir itself", "plans"],
    ["workflow file name at the root", "workflow"],
    ["ordinary non-jsonl file", "p1/note.md"],
    ["bak without a suffix", "p1/a.bak"],
    ["Temp-like name used as a file, not a dir", "-tmp-x"],
    ["project whose name contains tmp", "C--src-tmpl/a.jsonl"],
    ["history file", ".history.jsonl"],
    [".gitignore", ".gitignore"],
  ];
  for (const [name, rel] of excludedTable) {
    test(`exclude.isExcluded excludes ${name} (${rel})`, () => {
      assert.strictEqual(F.lib("exclude").isExcluded(rel), true, `${name}: ${rel}`);
    });
  }
  for (const [name, rel] of allowedTable) {
    test(`exclude.isExcluded allows ${name} (${rel})`, () => {
      assert.strictEqual(F.lib("exclude").isExcluded(rel), false, `${name}: ${rel}`);
    });
  }
}

function mtime(F) {
  const withTs = (ts) => lines(jline("a", { timestamp: "2020-01-01T00:00:00Z" }), JSON.stringify({ uuid: "b", timestamp: ts }));
  for (const bad of ["--reference=/etc/passwd", "-r/etc/passwd", "-t202001010000", "--date=@0", "-", "--"]) {
    test(`mtime.decideMtime rejects the option-like value ${bad}`, () => {
      assert.deepStrictEqual(F.lib("mtime").decideMtime(withTs(bad)), { ok: false, reason: "option-like" });
    });
  }
  test("mtime.decideMtime rejects an unparseable value", () => {
    assert.deepStrictEqual(F.lib("mtime").decideMtime(withTs("not-a-date")), { ok: false, reason: "unparseable" });
  });
  test("mtime.decideMtime rejects a file without a timestamp", () => {
    assert.deepStrictEqual(F.lib("mtime").decideMtime(lines('{"uuid":"a"}')), { ok: false, reason: "no-timestamp" });
  });
  test("mtime.decideMtime takes the last timestamp of the file", () => {
    const r = F.lib("mtime").decideMtime(withTs("2026-03-04T05:06:07.000Z"));
    assert.strictEqual(r.ok, true);
    assert.strictEqual(r.date.getTime(), Date.parse("2026-03-04T05:06:07.000Z"));
  });
}

module.exports = { jsonl, history, conflict, exclude, mtime };
