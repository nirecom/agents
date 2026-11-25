"use strict";
// Tests: hooks/pre-commit.d/checks/outbound-scan/staged.js
// Tags: TL1, hooks, pre-commit, scan-outbound, outbound-scan, security, table-driven, scope:issue-specific
// #3150 T-A2 (pre-commit call site): the staged-blob scan shares the path check with the hook.
// Old path forms block with the same matched text as before; new forms (lower-case users,
// JSON \\, U+00A5, any-case home) block too; the exception-definition file stays skipped; run()
// reads its lists from a cfgDir outside any git repository (synthetic lists only).
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const STAGED = path.join(__dirname, "..", "..", "hooks", "pre-commit.d", "checks", "outbound-scan", "staged.js");
const TMP = fs.realpathSync(fs.mkdtempSync(path.join(os.tmpdir(), "f3150-precommit-")));
after(() => { fs.rmSync(TMP, { recursive: true, force: true }); restore(); });

const BS = "\\";
const SL = "/";
const YEN = "¥";
const NAME = "someone";
const LISTS = { allow: [], blockHard: [], blockWarn: [] };
const blob = (p, text) => ({ path: p, mode: "100644", content: Buffer.from(`${text}\n`, "utf8") });
const pathFindings = (r) => ((r.details && r.details.findings) || []).filter((f) => f.kind === "path");

// want: the exact matched text when it is fixed (old forms); null = any path finding (new forms).
const FORMS = [
  { name: "old-mac-users", text: `see ${SL}Users${SL}${NAME}${SL}x`, want: `${SL}Users${SL}${NAME}` },
  { name: "old-drive-backslash", text: `see C:${BS}Users${BS}${NAME}${BS}x`, want: `C:${BS}Users${BS}${NAME}` },
  { name: "old-drive-slash", text: `see C:${SL}Users${SL}${NAME}${SL}x`, want: `${SL}Users${SL}${NAME}` },
  { name: "old-home", text: `see ${SL}home${SL}${NAME}`, want: `${SL}home${SL}${NAME}` },
  { name: "new-lower-users", text: `see ${SL}users${SL}${NAME}${SL}x`, want: null },
  { name: "new-lower-drive-backslash", text: `see c:${BS}users${BS}${NAME}${BS}x`, want: null },
  { name: "new-json-backslash", text: `"cwd": "C:${BS}${BS}Users${BS}${BS}${NAME}"`, want: null },
  { name: "new-yen", text: `see C:${YEN}Users${YEN}${NAME}`, want: null },
  { name: "new-upper-home", text: `see ${SL}HOME${SL}${NAME}`, want: null },
];

caseBegin("scan-staged-path-forms-block", "hooks/pre-commit.d/checks/outbound-scan/staged.js");
for (const { name, text, want } of FORMS) {
  test(`${name}: scanStaged blocks the staged blob with one path finding`, () => {
    const { scanStaged } = require(STAGED);
    const r = scanStaged({ files: [blob("docs/note.md", text)], lists: LISTS });
    assert.strictEqual(r.verdict, "block", `${name}: verdict for ${JSON.stringify(text)}`);
    const got = pathFindings(r);
    assert.strictEqual(got.length, 1, `${name}: one path finding (${JSON.stringify(got)})`);
    assert.strictEqual(got[0].file, "docs/note.md", `${name}: file attribution`);
    if (want !== null) assert.strictEqual(got[0].matched, want, `${name}: matched unchanged`);
    assert.ok(r.messages.some((m) => /Commit blocked/.test(m.text)), `${name}: commit-blocked wording`);
  });
}
caseEnd();

caseBegin("scan-staged-skip-and-clean-unchanged", "hooks/pre-commit.d/checks/outbound-scan/staged.js");
test("the allowlist file itself stays skipped even with a new-form path inside", () => {
  const { scanStaged } = require(STAGED);
  const r = scanStaged({ files: [blob(".private-info-allowlist", `c:${BS}users${BS}${NAME}`)], lists: LISTS });
  assert.strictEqual(r.verdict, "pass");
});
test("a clean blob and URL / non-path look-alikes pass", () => {
  const { scanStaged } = require(STAGED);
  const text = [`GET https:${SL}${SL}api.github.com${SL}users${SL}${NAME}`, `Manage Users${SL}Groups`, `see ${SL}Users${SL}<name>`].join("\n");
  const r = scanStaged({ files: [blob("docs/clean.md", text)], lists: LISTS });
  assert.strictEqual(r.verdict, "pass", JSON.stringify(r.details));
});
test("an allowlist row naming the user clears old and new forms alike", () => {
  const { scanStaged } = require(STAGED);
  const files = FORMS.map((f, i) => blob(`docs/n${i}.md`, f.text));
  const r = scanStaged({ files, lists: { ...LISTS, allow: [NAME] } });
  assert.strictEqual(r.verdict, "pass", JSON.stringify(pathFindings(r)));
});
caseEnd();

// run() with a fake snapshot; cfgDir sits outside any git repository, so its own lists are read.
const CFG = path.join(TMP, "cfg");
fs.mkdirSync(path.join(CFG, "bin"), { recursive: true });
fs.writeFileSync(path.join(CFG, ".private-info-blocklist"), "fixture-never-present-token\n");
function runStaged(texts) {
  const { run } = require(STAGED);
  const content = new Map(texts.map((t, i) => [`docs/s${i}.md`, Buffer.from(`${t}\n`, "utf8")]));
  const snapshot = { hasHead: () => true, status: () => "A", mode: () => "100644", content: (p) => content.get(p) };
  return run({ context: { cfgDir: CFG, env: process.env }, snapshot, files: [...content.keys()] });
}

caseBegin("run-reads-cfgdir-lists", "hooks/pre-commit.d/checks/outbound-scan/staged.js");
for (const { name, text } of FORMS) {
  test(`${name}: run() blocks with the cfgDir lists`, async () => {
    fs.rmSync(path.join(CFG, ".private-info-allowlist"), { force: true });
    const r = await runStaged([text]);
    assert.strictEqual(r.verdict, "block", `${name}: verdict (${JSON.stringify(r.messages)})`);
    assert.strictEqual(pathFindings(r).length, 1, `${name}: one path finding`);
  });
}
test("run(): the cfgDir allowlist row clears every form", async () => {
  fs.writeFileSync(path.join(CFG, ".private-info-allowlist"), `${NAME}\n`);
  try {
    const r = await runStaged(FORMS.map((f) => f.text));
    assert.strictEqual(r.verdict, "pass", JSON.stringify(r.messages));
  } finally {
    fs.rmSync(path.join(CFG, ".private-info-allowlist"), { force: true });
  }
});
test("run(): no blocklist in cfgDir still blocks as rc 4", async () => {
  const bl = path.join(CFG, ".private-info-blocklist");
  fs.renameSync(bl, `${bl}.off`);
  try {
    const r = await runStaged([FORMS[4].text]);
    assert.strictEqual(r.verdict, "block");
    assert.ok(r.messages.some((m) => /rc=4/.test(m.text)), JSON.stringify(r.messages));
  } finally {
    fs.renameSync(`${bl}.off`, bl);
  }
});
caseEnd();
