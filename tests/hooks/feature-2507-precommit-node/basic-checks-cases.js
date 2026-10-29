"use strict";
// settings-effort-unstage, code-lang, sh-exec-bit and env-file-block part of
// tests/hooks/feature-2507-precommit-node.js (#2507). Expected text is the current hooks/pre-commit
// wording; code-lang's lint-commit-lang module is stubbed in a temp cfgDir. No case markers.
const assert = require("node:assert");
const { test } = require("node:test");

const linesOf = (F, r) => F.texts(r).split("\n");
function streamOf(F, r, needle) {
  const m = F.messageOf(r, needle);
  assert.ok(m, `missing: ${needle}\n${F.texts(r)}`);
  return m.stream;
}

function settingsEffortUnstage(F) {
  const run = (dir) => F.runCheck("settings-effort-unstage", { repoTop: dir, cfgDir: dir, env: F.cleanEnv() });
  const seeded = () => {
    const dir = F.repo("effort");
    F.write(dir, "settings.json", JSON.stringify({ a: 1, effortLevel: "low" }));
    F.stage(dir, "settings.json");
    F.git(dir, ["commit", "-q", "-m", "settings"]);
    return dir;
  };
  test("an effortLevel-only change is unstaged with the bash notice on stdout and indexChanged", async () => {
    const dir = seeded();
    F.write(dir, "settings.json", JSON.stringify({ a: 1, effortLevel: "high" }));
    F.stage(dir, "settings.json");
    const r = await run(dir);
    assert.strictEqual(r.verdict, "pass");
    assert.strictEqual(r.indexChanged, true);
    assert.strictEqual(streamOf(F, r, "pre-commit: auto-unstaged settings.json (effortLevel-only change)"), "stdout");
    assert.strictEqual(F.git(dir, ["diff", "--cached", "--name-only"]), "");
  });
  test("a second run over the same index is idempotent: no notice, no index change, no error", async () => {
    const dir = seeded();
    F.write(dir, "settings.json", JSON.stringify({ a: 1, effortLevel: "high" }));
    F.write(dir, "other.txt", "o\n");
    F.stage(dir, "settings.json", "other.txt");
    const first = await run(dir);
    assert.strictEqual(first.verdict, "pass");
    assert.strictEqual(first.indexChanged, true);
    const after1 = F.git(dir, ["ls-files", "--stage"]);
    assert.strictEqual(F.git(dir, ["diff", "--cached", "--name-only"]), "other.txt");
    const second = await run(dir);
    assert.strictEqual(second.verdict, "pass");
    assert.ok(!second.indexChanged, "the second run has nothing to unstage");
    assert.strictEqual(F.messageOf(second, "auto-unstaged"), undefined, F.texts(second));
    assert.strictEqual(F.git(dir, ["ls-files", "--stage"]), after1);
    assert.strictEqual(F.git(dir, ["diff", "--cached", "--name-only"]), "other.txt");
    assert.match(F.git(dir, ["diff", "--name-only"]), /^settings\.json$/m, "the working-tree edit survives both runs");
  });
  test("any other change, a new settings.json, or a nested settings.json stays staged", async () => {
    const dir = seeded();
    F.write(dir, "settings.json", JSON.stringify({ a: 2, effortLevel: "high" }));
    F.write(dir, "sub/settings.json", "{}");
    F.stage(dir, "settings.json", "sub/settings.json");
    const r = await run(dir);
    assert.strictEqual(r.verdict, "pass");
    assert.ok(!r.indexChanged);
    assert.match(F.git(dir, ["diff", "--cached", "--name-only"]), /^settings\.json$/m);
    const fresh = F.repo("effort-new");
    F.write(fresh, "settings.json", JSON.stringify({ effortLevel: "x" }));
    F.stage(fresh, "settings.json");
    assert.ok(!(await run(fresh)).indexChanged, "no HEAD side: kept");
  });
}

function codeLang(F) {
  const cfg = (body) => {
    const dir = F.tmp("lang-cfg");
    F.write(dir, "hooks/lib/lint-commit-lang.js", `"use strict";\nmodule.exports = { check: () => (${body}) };\n`);
    return dir;
  };
  const staged = () => {
    const dir = F.repo("lang");
    F.write(dir, "a.js", "x\n");
    F.stage(dir, "a.js");
    return dir;
  };
  // `...lang`, not a default: an explicit `undefined` (CODE_LANG unset) must not become "en".
  const run = (dir, cfgDir, ...lang) => F.runCheck("code-lang", { repoTop: dir, cfgDir, env: F.envWith({ CODE_LANG: lang.length ? lang[0] : "en", CODE_LANG_EXCLUDE: undefined }) });
  const viol = (n) => `[${Array.from({ length: n }, (_, i) => `{ file: "a.js", lineNumber: ${i + 1}, line: "${"v".repeat(100)}" }`).join(",")}]`;
  test("CODE_LANG unset or empty: pass with no output and no module load", async () => {
    const dir = staged();
    for (const lang of [undefined, ""]) {
      const r = await run(dir, cfg("(() => { throw new Error('must not load'); })()"), lang);
      assert.strictEqual(r.verdict, "pass");
      assert.strictEqual(F.texts(r), "");
    }
  });
  test("violations: at most 10 lines cut to 80 chars, then the bash block lines, all on stdout", async () => {
    const r = await run(staged(), cfg(`{ violations: ${viol(12)}, hints: [] }`));
    assert.strictEqual(r.verdict, "block");
    const lines = linesOf(F, r);
    const v = lines.filter((l) => l.startsWith("  a.js:"));
    assert.strictEqual(v.length, 10);
    assert.strictEqual(v[0], `  a.js:1: ${"v".repeat(80)}`);
    assert.strictEqual(streamOf(F, r, "Commit blocked: CODE_LANG policy violation in staged files."), "stdout");
    assert.ok(F.messageOf(r, "Fix the issues above, or add 'lang-check: ignore' anywhere in the file to bypass."));
  });
  test("hints only: at most 5 '  hint:' lines and pass; excluded prints the skip trace", async () => {
    const hints = `[${Array.from({ length: 7 }, (_, i) => `{ file: "h.js", lineNumber: ${i}, line: "h" }`).join(",")}]`;
    const r = await run(staged(), cfg(`{ violations: [], hints: ${hints} }`));
    assert.strictEqual(r.verdict, "pass");
    assert.strictEqual(linesOf(F, r).filter((l) => l.startsWith("  hint: h.js:")).length, 5);
    const ex = await run(staged(), cfg("{ excluded: true, violations: [], hints: [] }"));
    assert.strictEqual(ex.verdict, "pass");
    assert.ok(F.messageOf(ex, "lint-commit-lang: skipped (CODE_LANG_EXCLUDE match)"));
  });
  test("a throwing or missing module fails open with 'pre-commit: lint-commit-lang skipped (<msg>)'", async () => {
    const r = await run(staged(), cfg("(() => { throw new Error('fixture-lang-err'); })()"));
    assert.strictEqual(r.verdict, "pass");
    assert.ok(F.messageOf(r, "pre-commit: lint-commit-lang skipped (fixture-lang-err)"));
    const gone = await run(staged(), F.tmp("lang-empty"));
    assert.strictEqual(gone.verdict, "pass");
    assert.ok(F.messageOf(gone, "pre-commit: lint-commit-lang skipped ("));
  });
}

function shExecBit(F) {
  test("a staged 100644 .sh blocks with the bash text on stdout; 100755 passes", async () => {
    const dir = F.repo("shbit");
    F.write(dir, "ok.sh", "#!/bin/sh\n");
    F.write(dir, "sub/bad.sh", "#!/bin/sh\n");
    F.stage(dir, "ok.sh", "sub/bad.sh");
    F.git(dir, ["update-index", "--chmod=+x", "ok.sh"]);
    F.git(dir, ["update-index", "--chmod=-x", "sub/bad.sh"]);
    const r = await F.runCheck("sh-exec-bit", { repoTop: dir, cfgDir: dir, env: F.cleanEnv() });
    assert.strictEqual(r.verdict, "block");
    // bash echo leaves "\n" literal: the list is "...permission:\n  sub/bad.sh" on one line.
    assert.strictEqual(streamOf(F, r, "pre-commit: .sh files lacking execute permission:\\n  sub/bad.sh"), "stdout");
    assert.ok(!F.texts(r).includes("ok.sh"));
    assert.ok(F.messageOf(r, "Run: git update-index --chmod=+x <file>"));
    F.git(dir, ["update-index", "--chmod=+x", "sub/bad.sh"]);
    assert.strictEqual((await F.runCheck("sh-exec-bit", { repoTop: dir, cfgDir: dir, env: F.cleanEnv() })).verdict, "pass");
  });
}

function envFileBlock(F) {
  test("an added or modified .env at any depth blocks; .env.example and foo.env pass", async () => {
    const dir = F.repo("envblk");
    F.write(dir, ".env.example", "A=1\n");
    F.write(dir, "foo.env", "A=1\n");
    F.stage(dir, ".env.example", "foo.env");
    const run = () => F.runCheck("env-file-block", { repoTop: dir, cfgDir: dir, env: F.cleanEnv() });
    assert.strictEqual((await run()).verdict, "pass");
    F.write(dir, "sub/.env", "A=1\n");
    F.git(dir, ["add", "-f", "sub/.env"]);
    const r = await run();
    assert.strictEqual(r.verdict, "block");
    assert.strictEqual(streamOf(F, r, "pre-commit: .env file(s) staged for commit:"), "stdout");
    assert.ok(linesOf(F, r).includes("  sub/.env"), F.texts(r));
    assert.ok(F.messageOf(r, "Use .env.example / .env.sample / .env.template instead."));
  });
  test("a deleted .env does not block (diff-filter=AM)", async () => {
    const dir = F.repo("envdel");
    F.write(dir, ".env", "A=1\n");
    F.git(dir, ["add", "-f", ".env"]);
    F.git(dir, ["commit", "-q", "-m", "env"]);
    F.git(dir, ["rm", "-q", "--cached", ".env"]);
    const r = await F.runCheck("env-file-block", { repoTop: dir, cfgDir: dir, env: F.cleanEnv() });
    assert.strictEqual(r.verdict, "pass");
  });
}

module.exports = { settingsEffortUnstage, codeLang, shExecBit, envFileBlock };
