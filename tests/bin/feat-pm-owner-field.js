"use strict";
// Tests: bin/lib/pm-state/owner.js, hooks/pm-session/scan.js, bin/lib/pm-field/forge-kind.js
// Tags: TL2, scope:common, pm-session, pm-field, owner, issue-2942
// #2942 S8: `bin/pm-state owner` answers from the PM field (the issue, then its nearest ancestor), maps the tag to
// its generation (generationOfTag), keeps the 3-value contract, and takes --timeout-ms; GitLab makes no forge call.
// TL3 gap (what this test does NOT catch):
// - a real Projects v2 board whose `pm` field values were written by hand in the GitHub UI;
// - resolveForgeTarget against a real self-hosted GitLab origin.
const { test, after } = require("node:test");
const assert = require("node:assert");
const cp = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const restore = isolate();
const X = require("../lib/pm-s3-fixture");
const { P, G } = X;
after(() => { restore(); });

let n = 0;
const sid = () => P.uuid(0x29420300 + (++n));
const seed = (o) => { const s = sid(); P.seedPm(s, P.pm(o)); return s; };
const R = (num) => ({ number: num, repo: "o/r" });
const owner = (args) => X.cli(["owner"].concat(args), undefined);

caseBegin("owner-reads-the-pm-field", "bin/lib/pm-state/owner.js");
test("O1 the issue's own field names an active local PM -> {tag, session_id}", () => {
  const s = seed({ tag: "PM-own1", issues: [] });
  G.setMap({ "o/r#10001": { pm: "PM-own1" } });
  const r = owner(["--issue", "#10001"]);
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.deepStrictEqual(r.json, { tag: "PM-own1", session_id: s });
});
test("O2 no field on the issue -> the nearest ancestor's field wins over a farther one", () => {
  const near = seed({ tag: "PM-near", issues: [] });
  seed({ tag: "PM-far", issues: [] });
  G.setMap({ "o/r#10011": { parent: R(10012) }, "o/r#10012": { parent: R(10013), pm: "PM-near" }, "o/r#10013": { pm: "PM-far" } });
  const r = owner(["--issue", "#10011"]);
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.deepStrictEqual(r.json, { tag: "PM-near", session_id: near });
});
test("O3 the issue's own field beats an ancestor's", () => {
  const own = seed({ tag: "PM-self", issues: [] });
  seed({ tag: "PM-anc", issues: [] });
  G.setMap({ "o/r#10021": { parent: R(10022), pm: "PM-self" }, "o/r#10022": { pm: "PM-anc" } });
  assert.deepStrictEqual(owner(["--issue", "#10021"]).json, { tag: "PM-self", session_id: own });
});
test("O4 the field names an ended PM -> {pm:null}, exit 0", () => {
  seed({ tag: "PM-ended", issues: [], archived_at: "2026-11-10T00:00:00.000Z" });
  G.setMap({ "o/r#10031": { pm: "PM-ended" } });
  const r = owner(["--issue", "#10031"]);
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.deepStrictEqual(r.json, { pm: null });
});
test("O5 the field names a tag no state on this PC holds -> undecidable (non-zero, tag-not-local)", () => {
  G.setMap({ "o/r#10041": { pm: "PM-elsewhere" } });
  const r = owner(["--issue", "#10041"]);
  assert.notStrictEqual(r.code, 0, JSON.stringify(r));
  assert.match(r.err, /tag-not-local/);
  assert.strictEqual(r.json, undefined);
});
test("O6 a PM state listing the issue no longer decides: no field anywhere -> {pm:null}", () => {
  seed({ tag: "PM-listonly", issues: [10051] });
  G.setMap({ "o/r#10051": {} });
  const r = owner(["--issue", "#10051"]);
  assert.strictEqual(r.code, 0, JSON.stringify(r));
  assert.deepStrictEqual(r.json, { pm: null });
});
test("O7 the field maps to the current generation of the tag, not an older one", () => {
  seed({ tag: "PM-gens", issues: [], current_since: "2026-11-01T00:00:00.000Z" });
  const cur = seed({ tag: "PM-gens", issues: [], current_since: "2026-11-06T00:00:00.000Z" });
  G.setMap({ "o/r#10061": { pm: "PM-gens" } });
  assert.deepStrictEqual(owner(["--issue", "#10061"]).json, { tag: "PM-gens", session_id: cur });
});
test("O8 mid-rename: a field still holding the old tag and one holding the new tag reach the same session", () => {
  const s = seed({ tag: "PM-mid-old", issues: [] });
  const st = P.raw(s);
  st.pm.rename_pending = { from: "PM-mid-old", to: "PM-mid-new" };
  P.writeRaw(s, st);
  G.setMap({ "o/r#10071": { pm: "PM-mid-old" }, "o/r#10072": { pm: "PM-mid-new" } });
  const a = owner(["--issue", "#10071"]);
  const b = owner(["--issue", "#10072"]);
  assert.strictEqual(a.code, 0, JSON.stringify(a));
  assert.strictEqual(b.code, 0, JSON.stringify(b));
  assert.strictEqual(a.json.session_id, s);
  assert.strictEqual(b.json.session_id, s);
  assert.ok(["PM-mid-old", "PM-mid-new"].includes(a.json.tag) && a.json.tag === b.json.tag, JSON.stringify([a.json, b.json]));
});
test("O9 --timeout-ms bounds the forge read: a slow gh gives non-zero within the bound, never {pm:null}", () => {
  G.setMap({ "o/r#10081": { pm: "PM-x" } });
  G.sleep(4000);
  let r;
  try { r = owner(["--issue", "#10081", "--timeout-ms", "500"]); } finally { G.sleep(null); }
  assert.strictEqual(r.code, 1, `undecidable is exit 1 (2 would be a usage error): ${JSON.stringify(r)}`);
  assert.ok(r.ms < 3000, `owner waited ${r.ms} ms`);
  assert.strictEqual(r.json, undefined);
});
test("O9 a malformed --timeout-ms is a usage error (exit 2)", () => {
  assert.strictEqual(owner(["--issue", "#10082", "--timeout-ms", "soon"]).code, 2);
});
caseEnd();

caseBegin("generation-of-tag", "hooks/pm-session/scan.js");
test("T1 generationOfTag maps a tag to its current generation; an unknown tag maps to null", () => {
  const scan = P.load("hooks/pm-session/scan.js");
  seed({ tag: "PM-gt", issues: [], current_since: "2026-11-01T00:00:00.000Z" });
  const cur = seed({ tag: "PM-gt", issues: [], current_since: "2026-11-03T00:00:00.000Z" });
  assert.strictEqual(typeof scan.generationOfTag, "function", "generationOfTag is not exported");
  assert.strictEqual(scan.generationOfTag("pm-gt").session_id, cur);
  assert.strictEqual(scan.generationOfTag("PM-nowhere"), null);
});
test("T2 generationOfTag: a retired tag and a rename_pending target both map to the renamed PM", () => {
  const scan = P.load("hooks/pm-session/scan.js");
  const s = seed({ tag: "PM-gt-new", issues: [] });
  const st = P.raw(s);
  st.pm.retired_tags = ["PM-gt-old"];
  P.writeRaw(s, st);
  const m = seed({ tag: "PM-gt-from", issues: [] });
  const mt = P.raw(m);
  mt.pm.rename_pending = { from: "PM-gt-from", to: "PM-gt-to" };
  P.writeRaw(m, mt);
  assert.strictEqual((scan.generationOfTag("PM-gt-old") || {}).session_id, s);
  assert.strictEqual((scan.generationOfTag("PM-gt-to") || {}).session_id, m);
});
test("T3 tagInUse counts retired tags and a rename_pending target as used", () => {
  const scan = P.load("hooks/pm-session/scan.js");
  const s = seed({ tag: "PM-tu-new", issues: [] });
  const st = P.raw(s);
  st.pm.retired_tags = ["PM-tu-old"];
  st.pm.rename_pending = { from: "PM-tu-new", to: "PM-tu-next" };
  P.writeRaw(s, st);
  assert.strictEqual(scan.tagInUse("PM-tu-old"), true);
  assert.strictEqual(scan.tagInUse("PM-tu-next"), true);
  assert.strictEqual(scan.tagInUse("PM-tu-free"), false);
});
caseEnd();

caseBegin("gitlab-makes-no-forge-call", "bin/lib/pm-field/forge-kind.js");
test("K1 owner from a GitLab checkout answers {pm:null} without calling gh", () => {
  const repo = fs.mkdtempSync(path.join(os.tmpdir(), "pm-owner-gitlab-"));
  try {
    gitInit(repo);
    cp.spawnSync("git", ["-C", repo, "remote", "add", "origin", "https://gitlab.com/o/r.git"], { encoding: "utf8", timeout: 20000 });
    G.setMap({ "o/r#10091": { pm: "PM-x" } });
    const before = G.calls();
    const env = Object.assign({}, process.env);
    delete env.CLAUDE_CODE_SESSION_ID;
    const r = cp.spawnSync("bash", ["-c", '"$0" "$@"', P.fwd(path.join(P.ROOT, "bin", "pm-state")), "owner", "--issue", "#10091"], { cwd: repo, env, encoding: "utf8", timeout: 60000 });
    assert.strictEqual(r.status, 0, `${r.stdout}${r.stderr}`);
    assert.deepStrictEqual(JSON.parse(String(r.stdout).trim()), { pm: null });
    assert.strictEqual(G.calls() - before, 0, G.queries().slice(before).join("\n"));
  } finally { fs.rmSync(repo, { recursive: true, force: true }); }
});
test("K2 forge-kind classifies the origin: github -> github, gitlab -> gitlab", () => {
  const K = P.load("bin/lib/pm-field/forge-kind.js");
  assert.strictEqual(typeof K.forgeKindOf, "function", "forgeKindOf is not exported");
  assert.strictEqual(K.forgeKindOf({ origin: "https://github.com/o/r.git" }), "github");
  assert.strictEqual(K.forgeKindOf({ origin: "git@gitlab.com:o/r.git" }), "gitlab");
});
caseEnd();
