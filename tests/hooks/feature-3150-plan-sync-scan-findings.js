"use strict";
// Tests: hooks/lib/plan-sync/scan-gate.js, hooks/lib/plan-sync/commit-push.js
// Tags: TL2, hooks, plan-sync, scan-outbound, security, findings, retry, ssh-stub, scope:issue-specific, subprocess, fail-closed, carried
// #3150 (review gaps C1/C2): an rc 1 scan keeps only the hard findings of the pending entries,
// each attributed to its own rel (warn lines, summary lines, other names and malformed rows are
// dropped); a skip approval taken on the first attempt keeps scanSkipped on a re-entry without a
// second scanner launch, both at the gate and through syncPlanFile's push-race retry. The scanner is
// a fake .sh that logs each launch; the remote is the ssh stub's local bare repo (no network).
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
delete process.env.CLAUDE_CODE_SESSION_ID;
const F = require("../lib/plan-sync-turn-fixture");

const REPO = path.join(__dirname, "..", "..");
const { createScanGate } = require(path.join(REPO, "hooks", "lib", "plan-sync", "scan-gate.js"));
const G = require(path.join(REPO, "hooks", "lib", "plan-sync", "git.js"));
const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f3150-find-")));
after(() => {
  try { fs.rmSync(process.env.PS2768_INJECT, { force: true }); } catch (_) { /* never left armed */ }
  fs.rmSync(TMP, { recursive: true, force: true });
  F.finish();
  restore();
});

const T = { timeout: 120000 };
const PLANS = path.join(TMP, "plans");
fs.mkdirSync(PLANS);
gitInit(PLANS);
const cfgGet = (dir, key) => G.gitOut(dir, ["config", "--local", "--get", key]);
const cfgSet = (dir, key, v) => G.runGit(dir, ["config", "--local", key, v]);
function clearSkip() {
  G.runGit(PLANS, ["config", "--local", "--unset-all", "plansync.scanSkipBlob"]);
  G.runGit(PLANS, ["config", "--local", "--unset-all", "plansync.scanSkipReason"]);
}

// entry(text, rel) -> {rel, bytes, blob} with the blob written to the gate's plans repo.
function entry(text, rel) {
  const bytes = Buffer.from(text, "utf8");
  const blob = G.hashBytes(PLANS, bytes);
  assert.ok(blob, "blob written");
  return { rel, bytes, blob };
}
const carriedOf = (list) => list.map(({ rel, blob }) => ({ rel, blob }));

// The fake scanner: logs each launch, drains stdin, prints ./out when present, exits with ./mode.
const FAKE_DIR = path.join(TMP, "fake");
fs.mkdirSync(FAKE_DIR);
const FAKE = path.join(FAKE_DIR, "fake-scan.sh");
fs.writeFileSync(FAKE, [
  "#!/bin/bash",
  'd="$(dirname "$0")"',
  'echo call >> "$d/calls.log"',
  "cat > /dev/null",
  'if [ -f "$d/out" ]; then cat "$d/out"; fi',
  'exit "$(cat "$d/mode")"',
  "",
].join("\n"));
function fake(mode, out) {
  fs.writeFileSync(path.join(FAKE_DIR, "mode"), String(mode));
  fs.rmSync(path.join(FAKE_DIR, "calls.log"), { force: true });
  fs.rmSync(path.join(FAKE_DIR, "out"), { force: true });
  if (out !== undefined) fs.writeFileSync(path.join(FAKE_DIR, "out"), out);
}
const calls = () => {
  const p = path.join(FAKE_DIR, "calls.log");
  return fs.existsSync(p) ? fs.readFileSync(p, "utf8").split("\n").filter(Boolean).length : 0;
};
const gateOf = (target) => createScanGate(PLANS, target, { deadline: Date.now() + 30000, deps: { scanEntry: FAKE } });

caseBegin("rc1-keeps-hard-findings-only", "hooks/lib/plan-sync/scan-gate.js");
// [label, target rel, carried rels, scanner stdout lines, wanted [rel, line, kind] rows]
const FINDINGS = [
  ["hard + warn + summary on the target", "fa-detail.md", [],
    ["fa-detail.md:1: [blocklist] x", "fa-detail.md:2: [blocklist-warn] y", "", "Found 1 hard violation(s), 1 warning(s)"],
    [["fa-detail.md", 1, "blocklist"]]],
  ["rows routed to each pending rel; other names, hints and malformed rows dropped", "ft-detail.md", ["fc1-intent.md", "fc2-outline.md"],
    ["fc2-outline.md:3: [blocklist] x", "ft-detail.md:5: [pattern] y", "fc1-intent.md:4: [blocklist-warn] z",
      "other-detail.md:1: [blocklist] q", "  hint: see the allowlist", "ft-detail.md:x: [blocklist] bad",
      "ft-detail.md 6: [blocklist] nocolon", "fc1-intent.md:7: [blocklist] w"],
    [["fc2-outline.md", 3, "blocklist"], ["ft-detail.md", 5, "pattern"], ["fc1-intent.md", 7, "blocklist"]]],
  ["warn rows only on rc 1 -> blocked with no finding", "fw-detail.md", [],
    ["fw-detail.md:1: [blocklist-warn] y", "Found 0 hard violation(s), 1 warning(s)"], []],
  ["CRLF line ends", "fr-detail.md", ["fr2-intent.md"],
    ["fr2-intent.md:2: [blocklist] x", "fr-detail.md:9: [blocklist] y"],
    [["fr2-intent.md", 2, "blocklist"], ["fr-detail.md", 9, "blocklist"]]],
];
for (const [label, rel, carriedRels, lines, want] of FINDINGS) {
  test(`rc 1: ${label}`, T, () => {
    clearSkip();
    const eol = label.startsWith("CRLF") ? "\r\n" : "\n";
    fake("1", lines.join(eol) + eol);
    const carried = carriedRels.map((c) => entry(`carried ${c}\n`, c));
    const r = gateOf(entry(`target ${rel}\n`, rel)).check(carriedOf(carried));
    assert.deepStrictEqual([r.ok, r.reason], [false, "scan-blocked"], JSON.stringify(r));
    assert.deepStrictEqual(r.findings, want.map(([fr, line, kind]) => ({ rel: fr, line, kind })), JSON.stringify(r.findings));
    assert.strictEqual(calls(), 1, "one launch");
  });
}
caseEnd();

caseBegin("skip-survives-re-entry", "hooks/lib/plan-sync/scan-gate.js");
test("a clean pass carries no scanSkipped key", T, () => {
  clearSkip();
  fake("0");
  assert.deepStrictEqual(gateOf(entry("clean pass\n", "cp-detail.md")).check([]), { ok: true });
});
test("an approved skip: the re-entry with the same blobs keeps scanSkipped and launches nothing", T, () => {
  clearSkip();
  fake("4");
  const t = entry("approved re-entry\n", "re-detail.md");
  cfgSet(PLANS, "plansync.scanSkipBlob", t.blob);
  const g = gateOf(t);
  assert.deepStrictEqual(g.check([]), { ok: true, scanSkipped: true });
  assert.strictEqual(cfgGet(PLANS, "plansync.scanSkipBlob"), null, "approval consumed");
  assert.deepStrictEqual(g.check([]), { ok: true, scanSkipped: true }, "second attempt");
  assert.strictEqual(calls(), 1, "the scanner ran once");
});
caseEnd();

// race(repo, X): armed so the next receive-pack moves bare main X -> a foreign commit (non-fast-forward).
const FOREIGN_REF = "refs/heads/f3150-foreign";
function race(repo, X) {
  const Y = F.humanPush(repo, F.planName("f3150-foreign-session", "intent"), "foreign\n", "foreign commit", FOREIGN_REF);
  const g = `git --git-dir="${repo.bare}"`;
  fs.writeFileSync(process.env.PS2768_INJECT, `${g} update-ref refs/heads/main ${Y} ${X}\n${g} update-ref -d ${FOREIGN_REF}\n`);
  return Y;
}

caseBegin("sync-retry-keeps-scan-skipped", "hooks/lib/plan-sync/commit-push.js");
test("a push race after an approved skip: the retry pushes with scanSkipped, the scanner ran once", T, async () => {
  const repo = F.makeRepo("f3150-retry");
  const rel = F.planName(F.newSid("f3150-retry"), "intent");
  const first = await Promise.resolve(F.writeSync(repo, rel, "retry body v1\n"));
  assert.strictEqual(first.status, "pushed", JSON.stringify(first));
  assert.ok(!Object.hasOwn(first, "scanSkipped"), `a scanned push has no scanSkipped: ${JSON.stringify(first)}`);
  const Y = race(repo, F.bareTip(repo));
  const body = "retry body v2\n";
  cfgSet(repo.dir, "plansync.scanSkipBlob", G.hashBytes(repo.dir, Buffer.from(body, "utf8")));
  fake("4");
  F.writePlan(repo, rel, body);
  const r = await Promise.resolve(F.sync(repo, rel, { deps: Object.assign({}, F.allowLocal, { scanEntry: FAKE }) }));
  assert.ok(!fs.existsSync(process.env.PS2768_INJECT), "the race fired during the write");
  assert.deepStrictEqual([r.status, r.scanSkipped], ["pushed", true], JSON.stringify(r));
  assert.strictEqual(calls(), 1, "the retry did not launch the scanner again");
  assert.strictEqual(F.config(repo.dir, "plansync.scanSkipBlob"), null, "the approval is consumed");
  assert.strictEqual(F.showAt(repo, "refs/heads/main", rel), "retry body v2");
  assert.ok(F.isAncestor(repo, Y, F.bareTip(repo)), "the foreign commit is kept");
});
caseEnd();
