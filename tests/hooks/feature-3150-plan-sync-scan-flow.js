"use strict";
// Tests: hooks/lib/plan-sync.js, hooks/lib/plan-sync/scan-gate.js
// Tags: TL2, hooks, plan-sync, scan-outbound, security, flow, ssh-stub, scope:issue-specific, subprocess, sandbox, fail-closed, carried
// #3150 T-B: createScanGate(plansDir, {rel, bytes, blob}, {deadline, deps}).check(carried) launches
// deps.scanEntry (a .sh) once for the target plus unpassed carried entries and maps its exit to ok /
// scan-blocked / scan-unavailable / scan-timeout. T-C: syncPlanFile runs that gate before the push and
// fails closed with the remote ref unmoved; a clean or warn-only plan is pushed; a content-bound skip
// approval lets an unavailable scan through once. Scanner copies sit outside git and read synthetic
// lists only; the other gate cases run a fake .sh that logs each launch (ssh stub remote, no network).
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const restore = isolate();
delete process.env.CLAUDE_CODE_SESSION_ID;
const F = require("../lib/plan-sync-turn-fixture");
const { createSandbox, setLists, removeSandbox } = require("../bin/feature-2507-scan-outbound-node/sandbox");
const path = require("node:path");

const REPO = path.join(__dirname, "..", "..");
const GATE = path.join(REPO, "hooks", "lib", "plan-sync", "scan-gate.js");
const G = require(path.join(REPO, "hooks", "lib", "plan-sync", "git.js"));
const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f3150-gate-")));
const TOKEN = "f3150-flow-blocked-token";
const WARN = "f3150-flow-warn-token";
const LEAK = "f3150-plan-leak-token";
const DECOY = "f3150-plansdir-only-token";
const SB = { clean: createSandbox(), block: createSandbox(), rc4: createSandbox(), gate: createSandbox() };
setLists(SB.clean, { blocklist: "f3150-fixture-never-present-token\n", allowlist: null });
setLists(SB.block, { blocklist: `${TOKEN}\nwarn:${WARN}\n`, allowlist: null });
setLists(SB.rc4, { blocklist: null, allowlist: null });
after(() => {
  for (const d of Object.values(SB)) removeSandbox(d);
  fs.rmSync(TMP, { recursive: true, force: true });
  F.finish();
  restore();
});

const T = { timeout: 120000 };

// gate() -> the module, or a failure that names the missing module.
function gate() {
  assert.ok(fs.existsSync(GATE), `scan-gate module missing: ${path.relative(REPO, GATE)}`);
  return require(GATE);
}

// The gate cases' plans repo: a git repository, cwd of the scanner. Its own decoy blocklist must never be read.
const PLANS = path.join(TMP, "plans");
fs.mkdirSync(PLANS);
gitInit(PLANS);
fs.writeFileSync(path.join(PLANS, ".private-info-blocklist"), `${DECOY}\n`);
const cfgGet = (key) => G.gitOut(PLANS, ["config", "--local", "--get", key]);
const cfgSet = (key, v) => G.runGit(PLANS, ["config", "--local", key, v]);
const cfgUnset = (key) => G.runGit(PLANS, ["config", "--local", "--unset-all", key]);
function clearSkip() { cfgUnset("plansync.scanSkipBlob"); cfgUnset("plansync.scanSkipReason"); }

let seq = 0;
// entry(text, rel) -> a target or a carried entry with its blob written to the plans repo.
function entry(text, rel) {
  const bytes = Buffer.from(text, "utf8");
  const blob = G.hashBytes(PLANS, bytes);
  assert.ok(blob, "blob written");
  return { rel: rel || `s${++seq}-detail.md`, bytes, blob };
}

// The fake scanner: logs each launch, keeps its stdin and cwd, then acts on ./mode.
const FAKE_DIR = path.join(TMP, "fake");
fs.mkdirSync(FAKE_DIR);
const FAKE = path.join(FAKE_DIR, "fake-scan.sh");
fs.writeFileSync(FAKE, [
  "#!/bin/bash",
  'd="$(dirname "$0")"',
  'echo call >> "$d/calls.log"',
  'cat > "$d/last-input"',
  'pwd > "$d/last-cwd"',
  'mode="$(cat "$d/mode")"',
  'case "$mode" in',
  "  busy) while :; do :; done ;;",
  "  signal) kill -KILL $$ ;;",
  '  *) if [ -f "$d/out" ]; then cat "$d/out"; fi; exit "$mode" ;;',
  "esac",
  "",
].join("\n"));
function fake(mode, out) {
  fs.writeFileSync(path.join(FAKE_DIR, "mode"), String(mode));
  fs.rmSync(path.join(FAKE_DIR, "calls.log"), { force: true });
  fs.rmSync(path.join(FAKE_DIR, "out"), { force: true });
  if (out) fs.writeFileSync(path.join(FAKE_DIR, "out"), out);
}
const calls = () => {
  const p = path.join(FAKE_DIR, "calls.log");
  return fs.existsSync(p) ? fs.readFileSync(p, "utf8").split("\n").filter(Boolean).length : 0;
};
const REAL = path.join(SB.gate, "bin", "scan-outbound.sh");
const opts = (scanEntry, ms) => ({ deadline: Date.now() + (ms || 30000), deps: { scanEntry } });
const check = (target, carried, scanEntry, ms) => gate().createScanGate(PLANS, target, opts(scanEntry, ms)).check(carried);

caseBegin("exit-code-mapping", "hooks/lib/plan-sync/scan-gate.js");
for (const [mode, want] of [["0", true], ["2", true], ["1", "scan-blocked"], ["3", "scan-unavailable"], ["4", "scan-unavailable"], ["7", "scan-unavailable"], ["signal", "scan-unavailable"]]) {
  test(`fake exit ${mode} -> ${want === true ? "ok" : want}`, T, () => {
    clearSkip();
    fake(mode);
    const r = check(entry(`plan ${mode}\n`), [], FAKE);
    if (want === true) assert.strictEqual(r.ok, true, JSON.stringify(r));
    else assert.deepStrictEqual([r.ok, r.reason], [false, want], JSON.stringify(r));
    assert.strictEqual(calls(), 1, "one launch");
  });
}
test("an entry that does not exist -> scan-unavailable", T, () => {
  clearSkip();
  const r = check(entry("plan\n"), [], path.join(TMP, "no-such-scan.sh"));
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-unavailable"], JSON.stringify(r));
});
test("bash not on PATH -> scan-unavailable (fail-closed)", T, () => {
  const empty = path.join(TMP, "empty-path");
  fs.mkdirSync(empty, { recursive: true });
  const t = entry("plan no bash\n");
  const src = `const g=require(${JSON.stringify(GATE)});const r=g.createScanGate(${JSON.stringify(PLANS)},{rel:"nb-detail.md",bytes:Buffer.from("plan no bash\\n"),blob:${JSON.stringify(t.blob)}},{deadline:Date.now()+20000,deps:{scanEntry:${JSON.stringify(FAKE)}}}).check([]);process.stdout.write(JSON.stringify(r));`;
  fake("0");
  const env = { ...process.env, PATH: empty, Path: empty };
  const c = spawnSync(process.execPath, ["-e", src], { cwd: TMP, env, encoding: "utf8", timeout: 30000 });
  assert.strictEqual(c.status, 0, `child ran (stderr=${c.stderr})`);
  const r = JSON.parse(c.stdout);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-unavailable"], c.stdout);
  assert.strictEqual(calls(), 0, "the fake never ran");
});
caseEnd();

caseBegin("real-scanner-copy", "hooks/lib/plan-sync/scan-gate.js");
test("no blocklist in the scanner copy (rc 4) -> scan-unavailable", T, () => {
  clearSkip();
  setLists(SB.gate, { blocklist: null, allowlist: null });
  const r = check(entry("clean plan\n"), [], REAL);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-unavailable"], JSON.stringify(r));
});
test("a clean target passes; cwd = plansDir does not pull in the plans repo's decoy list", T, () => {
  setLists(SB.gate, { blocklist: `${LEAK}\n`, allowlist: null });
  const r = check(entry(`clean\nmentions ${DECOY}\n`), [], REAL);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
});
test("a blocklist word of the scanner copy -> scan-blocked with rel:line kind, no matched text", T, () => {
  setLists(SB.gate, { blocklist: `${LEAK}\n`, allowlist: null });
  const t = entry(`line one\nline two ${LEAK}\n`, "tgt-detail.md");
  const r = check(t, [], REAL);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-blocked"], JSON.stringify(r));
  assert.ok(Array.isArray(r.findings) && r.findings.length >= 1, JSON.stringify(r));
  assert.deepStrictEqual(Object.keys(r.findings[0]).sort(), ["kind", "line", "rel"], JSON.stringify(r.findings));
  assert.strictEqual(r.findings[0].rel, "tgt-detail.md");
  assert.strictEqual(Number(r.findings[0].line), 2);
  assert.ok(typeof r.findings[0].kind === "string" && r.findings[0].kind !== "", "kind named");
  assert.ok(!JSON.stringify(r).includes(LEAK), "the matched text is not repeated in the result");
});
test("a violation inside a carried entry is attributed to the carried rel", T, () => {
  setLists(SB.gate, { blocklist: `${LEAK}\n`, allowlist: null });
  const carried = [entry("clean carried\n", "c1-intent.md"), entry(`a\nb\nc ${LEAK}\n`, "c2-outline.md")];
  const r = check(entry("clean target\n", "t2-detail.md"), carried.map(({ rel, blob }) => ({ rel, blob })), REAL);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-blocked"], JSON.stringify(r));
  assert.deepStrictEqual(r.findings.map((f) => [f.rel, Number(f.line)]), [["c2-outline.md", 3]], JSON.stringify(r.findings));
});
test("a warn-only word (rc 2) passes and lists no warn finding", T, () => {
  setLists(SB.gate, { blocklist: `${LEAK}\nwarn:f3150-soft-word\n`, allowlist: null });
  const r = check(entry("has f3150-soft-word\n"), [], REAL);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
});
caseEnd();

caseBegin("one-launch-per-push", "hooks/lib/plan-sync/scan-gate.js");
test("target + two carried entries -> one launch, all three framed in its stdin; cwd is plansDir", T, () => {
  clearSkip();
  fake("0");
  const carried = [entry("c-a\n", "ca-intent.md"), entry("c-b\n", "cb-outline.md")];
  const r = check(entry("tgt\n", "tc-detail.md"), carried.map(({ rel, blob }) => ({ rel, blob })), FAKE);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  assert.strictEqual(calls(), 1, "one launch");
  const input = fs.readFileSync(path.join(FAKE_DIR, "last-input"), "utf8");
  for (const rel of ["tc-detail.md", "ca-intent.md", "cb-outline.md"]) assert.ok(input.includes(`\x1e${rel}\x1e`), `${rel} framed`);
  const cwd = fs.readFileSync(path.join(FAKE_DIR, "last-cwd"), "utf8").trim();
  assert.ok(path.basename(cwd) === path.basename(PLANS), `cwd is the plans dir (${cwd})`);
});
test("a retry re-entry with the same blobs does not launch again; a new carried blob launches once more", T, () => {
  fake("0");
  const carried = [entry("r-a\n", "ra-intent.md")].map(({ rel, blob }) => ({ rel, blob }));
  const g = gate().createScanGate(PLANS, entry("retry tgt\n", "rt-detail.md"), opts(FAKE));
  assert.strictEqual(g.check(carried).ok, true);
  assert.strictEqual(g.check(carried).ok, true);
  assert.strictEqual(calls(), 1, "re-entry with passed blobs: no launch");
  const more = carried.concat([entry("r-b\n", "rb-outline.md")].map(({ rel, blob }) => ({ rel, blob })));
  assert.strictEqual(g.check(more).ok, true);
  assert.strictEqual(calls(), 2, "only the new blob launches");
  const input = fs.readFileSync(path.join(FAKE_DIR, "last-input"), "utf8");
  assert.ok(input.includes("\x1erb-outline.md\x1e") && !input.includes("\x1ert-detail.md\x1e"), "only the unpassed entry is framed");
});
test("a carried entry with the target's rel but an old blob is dropped: not scanned, not blocked by the old content", T, () => {
  setLists(SB.gate, { blocklist: `${LEAK}\n`, allowlist: null });
  const old = entry(`old version ${LEAK}\n`, "same-rel-detail.md");
  const r = check(entry("new clean version\n", "same-rel-detail.md"), [{ rel: old.rel, blob: old.blob }], REAL);
  assert.strictEqual(r.ok, true, JSON.stringify(r));
  fake("0");
  const r2 = check(entry("new clean version 2\n", "same-rel-detail.md"), [{ rel: old.rel, blob: old.blob }], FAKE);
  assert.strictEqual(r2.ok, true, JSON.stringify(r2));
  const input = fs.readFileSync(path.join(FAKE_DIR, "last-input"), "utf8");
  assert.ok(!input.includes(old.blob) && !input.includes("old version"), "the old content is not framed in the manifest");
  assert.strictEqual(input.split("\x1esame-rel-detail.md\x1e").length - 1, 1, "the rel is framed once (the target only)");
});
test("an unreadable carried blob -> scan-unavailable", T, () => {
  fake("0");
  const r = check(entry("tgt ok\n"), [{ rel: "gone-detail.md", blob: "0123456789abcdef0123456789abcdef01234567" }], FAKE);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-unavailable"], JSON.stringify(r));
});
caseEnd();

caseBegin("deadline", "hooks/lib/plan-sync/scan-gate.js");
test("a scanner that outlives the deadline -> scan-timeout", T, () => {
  clearSkip();
  fake("busy");
  const t0 = Date.now();
  const r = check(entry("slow\n"), [], FAKE, 1500);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-timeout"], JSON.stringify(r));
  assert.ok(Date.now() - t0 < 20000, "returned near the deadline");
});
test("remaining <= 0 -> scan-timeout with no launch", T, () => {
  fake("0");
  const r = gate().createScanGate(PLANS, entry("late\n"), { deadline: Date.now() - 1, deps: { scanEntry: FAKE } }).check([]);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-timeout"], JSON.stringify(r));
  assert.strictEqual(calls(), 0, "no launch");
});
caseEnd();

caseBegin("one-shot-content-bound-skip", "hooks/lib/plan-sync/scan-gate.js");
test("unavailable + an approval for this blob -> ok with scanSkipped, consumed once", T, () => {
  clearSkip();
  fake("4");
  const t = entry("approved plan\n", "ap-detail.md");
  cfgSet("plansync.scanSkipBlob", t.blob);
  cfgSet("plansync.scanSkipReason", "scanner broken on host");
  const r1 = check(t, [], FAKE);
  assert.deepStrictEqual([r1.ok, r1.scanSkipped], [true, true], JSON.stringify(r1));
  assert.strictEqual(cfgGet("plansync.scanSkipBlob"), null, "approval consumed");
  const r2 = check(t, [], FAKE);
  assert.deepStrictEqual([r2.ok, r2.reason], [false, "scan-unavailable"], JSON.stringify(r2));
});
test("timeout + an approval for this blob -> ok with scanSkipped", T, () => {
  clearSkip();
  fake("0");
  const t = entry("approved late plan\n");
  cfgSet("plansync.scanSkipBlob", t.blob);
  const r = gate().createScanGate(PLANS, t, { deadline: Date.now() - 1, deps: { scanEntry: FAKE } }).check([]);
  assert.deepStrictEqual([r.ok, r.scanSkipped], [true, true], JSON.stringify(r));
});
test("an approval for an earlier version of the plan does not apply after an edit", T, () => {
  clearSkip();
  fake("4");
  const before = entry("plan v1\n", "ed-detail.md");
  cfgSet("plansync.scanSkipBlob", before.blob);
  const r = check(entry("plan v2\n", "ed-detail.md"), [], FAKE);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-unavailable"], JSON.stringify(r));
});
test("an approval matching only a carried blob (not the target) stays scan-unavailable", T, () => {
  clearSkip();
  fake("4");
  const carried = entry("carried version\n", "cb-approval-intent.md");
  cfgSet("plansync.scanSkipBlob", carried.blob);
  const r = check(entry("target version\n", "tg-approval-detail.md"), [{ rel: carried.rel, blob: carried.blob }], FAKE);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-unavailable"], JSON.stringify(r));
  assert.strictEqual(cfgGet("plansync.scanSkipBlob"), carried.blob, "approval not consumed");
  clearSkip();
});
test("scan-blocked stays blocked under an approval, which is not consumed", T, () => {
  clearSkip();
  fake("1", "bl-detail.md:1: [blocklist] x\n\nFound 1 hard violation(s), 0 warning(s)\n");
  const t = entry("blocked plan\n", "bl-detail.md");
  cfgSet("plansync.scanSkipBlob", t.blob);
  const r = check(t, [], FAKE);
  assert.deepStrictEqual([r.ok, r.reason], [false, "scan-blocked"], JSON.stringify(r));
  assert.strictEqual(cfgGet("plansync.scanSkipBlob"), t.blob, "approval kept");
  clearSkip();
});
caseEnd();

const entryOf = (sb) => path.join(sb, "bin", "scan-outbound.sh");
const depsFor = (sb) => ({ deps: Object.assign({}, F.allowLocal, { scanEntry: entryOf(sb) }) });
async function sync(repo, rel, body, sb) {
  F.writePlan(repo, rel, body);
  return Promise.resolve(F.sync(repo, rel, depsFor(sb)));
}
const blobOf = (repo, text) => spawnSync("git", ["-C", repo.dir, "hash-object", "--no-filters", "--stdin"],
  { input: text, encoding: "utf8" }).stdout.trim();
const label = (r) => JSON.stringify(r);
const localMain = (repo) => F.git(repo.dir, ["rev-parse", "refs/heads/main"]);

caseBegin("pre-push-scan-fails-closed", "hooks/lib/plan-sync.js");
test("SC1 a hard blocklist hit: failed/scan-blocked, remote unmoved, findings without matched text", T, async () => {
  const repo = F.makeRepo("sc1");
  const tip = F.bareTip(repo);
  const local = localMain(repo);
  const r = await sync(repo, "sc1-intent.md", `intent body\nsee ${TOKEN} here\n`, SB.block);
  assert.strictEqual(r.status, "failed", label(r));
  assert.strictEqual(r.reason, "scan-blocked", label(r));
  assert.strictEqual(F.bareTip(repo), tip, "bare main unmoved");
  assert.strictEqual(localMain(repo), local, "the plans repo's local main is unchanged (no commit made)");
  assert.strictEqual(F.showAt(repo, "refs/heads/main", "sc1-intent.md"), null, "the plan never reached the remote");
  assert.ok(Array.isArray(r.findings) && r.findings.some((f) => f.rel === "sc1-intent.md" && f.line === 2 && f.kind === "blocklist"),
    `finding sc1-intent.md:2 [blocklist]: ${label(r)}`);
  assert.ok(!label(r).includes(TOKEN), `no matched text in the result: ${label(r)}`);
});
test("SC2 a scanner that cannot scan (rc 4, no blocklist): failed/scan-unavailable, remote unmoved", T, async () => {
  const repo = F.makeRepo("sc2");
  const tip = F.bareTip(repo);
  const local = localMain(repo);
  const r = await sync(repo, "sc2-intent.md", "intent body 2\n", SB.rc4);
  assert.strictEqual(r.status, "failed", label(r));
  assert.strictEqual(r.reason, "scan-unavailable", label(r));
  assert.strictEqual(F.bareTip(repo), tip, "bare main unmoved");
  assert.strictEqual(localMain(repo), local, "the plans repo's local main is unchanged (no commit made)");
});
test("SC8 a hit in a carried plan (local commit not on the remote) blocks a clean target's push", T, async () => {
  const repo = F.makeRepo("sc8");
  const carriedRel = "sc8a-intent.md";
  F.writePlan(repo, carriedRel, `carried\nleak ${TOKEN}\n`);
  F.record(repo, carriedRel);
  F.git(repo.dir, ["add", "--", carriedRel]);
  F.git(repo.dir, ["commit", "-q", "-m", "local only"]);
  const tip = F.bareTip(repo);
  const local = localMain(repo);
  const r = await sync(repo, "sc8b-intent.md", "clean target\n", SB.block);
  assert.strictEqual(r.status, "failed", label(r));
  assert.strictEqual(r.reason, "scan-blocked", label(r));
  assert.ok(Array.isArray(r.findings) && r.findings.some((f) => f.rel === carriedRel && f.line === 2),
    `finding names the carried plan ${carriedRel}:2: ${label(r)}`);
  assert.strictEqual(F.bareTip(repo), tip, "bare main unmoved");
  assert.strictEqual(localMain(repo), local, "the plans repo's local main is unchanged (no new commit for the target)");
  assert.strictEqual(F.showAt(repo, "refs/heads/main", carriedRel), null, "the carried plan never reached the remote");
});
caseEnd();

caseBegin("pre-push-scan-lets-clean-through", "hooks/lib/plan-sync.js");
test("SC3 a clean plan is scanned and pushed", T, async () => {
  const repo = F.makeRepo("sc3");
  const r = await sync(repo, "sc3-intent.md", "intent body 3\n", SB.clean);
  assert.deepStrictEqual([r.status, Object.hasOwn(r, "scanSkipped")], ["pushed", false], label(r));
  assert.strictEqual(F.showAt(repo, "refs/heads/main", "sc3-intent.md"), "intent body 3");
});
test("SC4 a warn-only hit does not block the push", T, async () => {
  const repo = F.makeRepo("sc4");
  const r = await sync(repo, "sc4-intent.md", `intent\nnote ${WARN}\n`, SB.block);
  assert.strictEqual(r.status, "pushed", label(r));
});
test("SC5 the blocked plan, once cleaned, goes through; the token never reaches the remote history", T, async () => {
  const repo = F.makeRepo("sc5");
  const first = await sync(repo, "sc5-intent.md", `intent\n${TOKEN}\n`, SB.block);
  assert.strictEqual(first.reason, "scan-blocked", label(first));
  const r = await sync(repo, "sc5-intent.md", "intent\nclean now\n", SB.block);
  assert.strictEqual(r.status, "pushed", label(r));
  const log = F.git(repo.bare, ["log", "-p", "--all"]);
  assert.ok(!log.includes(TOKEN), "token absent from the remote history");
});
test("SC9 the shared fixture's default deps scan with a synthetic-list copy outside the repo and push a clean plan", T, async () => {
  const entry0 = F.allowLocal.scanEntry;
  assert.ok(typeof entry0 === "string" && fs.existsSync(entry0), `fixture scanEntry exists: ${entry0}`);
  assert.ok(path.relative(REPO, entry0).startsWith(".."), `fixture scanEntry is outside the repository: ${entry0}`);
  const repo = F.makeRepo("sc9");
  const r = await Promise.resolve(F.writeSync(repo, "sc9-intent.md", "intent body 9\n"));
  assert.strictEqual(r.status, "pushed", label(r));
});
caseEnd();

caseBegin("pre-push-scan-skip-approval", "hooks/lib/plan-sync.js");
test("SC10 unknown forge + an approval + an unavailable scan: pushed / unknown-forge, scanSkipped", T, async () => {
  const repo = F.makeRepo("sc10", { url: F.ORIGIN_PLAIN });
  const body = "intent body 10\n";
  F.git(repo.dir, ["config", "--local", "plansync.scanSkipBlob", blobOf(repo, body)]);
  const r = await sync(repo, "sc10-intent.md", body, SB.rc4);
  assert.deepStrictEqual([r.status, r.reason, r.scanSkipped], ["pushed", "unknown-forge", true], label(r));
});
test("SC6 an approval bound to the plan's blob lets an unavailable scan through once, then is gone", T, async () => {
  const repo = F.makeRepo("sc6");
  const body = "intent body 6\n";
  F.git(repo.dir, ["config", "--local", "plansync.scanSkipBlob", blobOf(repo, body)]);
  F.git(repo.dir, ["config", "--local", "plansync.scanSkipReason", "scanner broken here"]);
  const r = await sync(repo, "sc6-intent.md", body, SB.rc4);
  assert.deepStrictEqual([r.status, r.scanSkipped], ["pushed", true], label(r));
  assert.strictEqual(F.config(repo.dir, "plansync.scanSkipBlob"), null, "the approval is consumed");
  const again = await sync(repo, "sc6-intent.md", "intent body 6 edited\n", SB.rc4);
  assert.strictEqual(again.reason, "scan-unavailable", label(again));
});
test("SC7 an approval for another blob does not apply", T, async () => {
  const repo = F.makeRepo("sc7");
  F.git(repo.dir, ["config", "--local", "plansync.scanSkipBlob", blobOf(repo, "some other content\n")]);
  const tip = F.bareTip(repo);
  const r = await sync(repo, "sc7-intent.md", "intent body 7\n", SB.rc4);
  assert.strictEqual(r.reason, "scan-unavailable", label(r));
  assert.strictEqual(F.bareTip(repo), tip, "bare main unmoved");
});
caseEnd();
