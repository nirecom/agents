"use strict";
// Tests: hooks/lib/test-gates/test-runner.js, hooks/lib/test-language-registry/validate.js
// Tags: TL1, hooks, test-runner, registry, scope:issue-specific
// #2863 unit layer: the required-runner verdict (judge / runnerHint) over in-memory and on-disk
// files, its WARN and infra paths through a patched P.embed, and the registry validation of the
// newEntrypointRunner field.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2863-judge-"));
process.env.AGENTS_MAIN_ROOT = path.join(ROOT, "decoy");
for (const k of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE"]) delete process.env[k];
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort */ }
});

const F = require("./feature-2863-test-runner/fixtures");
const REPO = path.resolve(__dirname, "..", "..");
const lib = (...p) => path.join(REPO, "hooks", "lib", ...p);
const S = require(lib("test-gates", "source.js"));
const P = require(lib("test-gates", "parts", "index.js"));
const R = require(lib("test-gates", "registry.js"));
const { validate } = require(lib("test-language-registry", "validate.js"));
const TR = () => require(lib("test-gates", "test-runner.js"));
const REL = "tests/bin/x.js";
const show = (res) => JSON.stringify(res);

// withEmbed(fake, fn) — runs fn with P.embed replaced by fake (the real one is put back after).
function withEmbed(fake, fn) {
  const real = P.embed;
  P.embed = (...a) => fake(real, ...a);
  try { return fn(); } finally { P.embed = real; }
}
// withJsEntry(change, fn) — runs fn with the cached js registry entry altered by change(entry).
function withJsEntry(change, fn) {
  const entry = R.match(REL).entry;
  const saved = JSON.parse(JSON.stringify(entry));
  change(entry);
  try { return fn(); } finally {
    for (const k of Object.keys(entry)) delete entry[k];
    Object.assign(entry, saved);
  }
}

caseBegin("u3-plain-mem-high", "hooks/lib/test-gates/test-runner.js");
test("U3: judge(S.mem) on a plain script gives exactly the MISSING_TEST_RUNNER HIGH line", () => {
  const res = TR().judge(S.mem("x.js", F.BODY.plain), REL);
  assert.deepStrictEqual(res, { lines: [{ err: false, text: F.highLine(REL) }], high: true, infra: false });
});
caseEnd();

caseBegin("u3-runner-present-no-lines", "hooks/lib/test-gates/test-runner.js");
test("U3: judge gives no line for node:test by require, static import or dynamic import", () => {
  for (const key of ["nodeTest", "importTest", "dynamicImport"]) {
    const res = TR().judge(S.mem("x.js", F.BODY[key]), REL);
    assert.deepStrictEqual(res, { lines: [], high: false, infra: false }, `${key}: ${show(res)}`);
  }
});
caseEnd();

caseBegin("u3-blanked-regions-high", "hooks/lib/test-gates/test-runner.js");
test("U3: node:test only in a comment or a string literal is still a plain script", () => {
  for (const key of ["lineComment", "blockComment", "string", "template"]) {
    const res = TR().judge(S.mem("x.js", F.BODY[key]), REL);
    assert.strictEqual(res.high, true, `${key}: ${show(res)}`);
  }
});
caseEnd();

caseBegin("u3-path-file", "hooks/lib/test-gates/test-runner.js");
test("U3: judge accepts a path too, and the entry is chosen by name, not by the file's own basename", () => {
  const file = path.join(ROOT, "snippet.txt");
  fs.writeFileSync(file, F.BODY.plain);
  assert.strictEqual(TR().judge(file, REL).lines[0].text, F.highLine(REL));
  assert.deepStrictEqual(TR().judge(file, "tests/bin/snippet.txt").lines, []);
});
caseEnd();

caseBegin("u3-out-of-scope-names", "hooks/lib/test-gates/test-runner.js");
test("U3: no line for an unmatched name or an entry without newEntrypointRunner (bash)", () => {
  for (const name of ["tests/bin/x.txt", "tests/bin/x.sh", "README"]) {
    const res = TR().judge(S.mem("x", F.BODY.plain), name);
    assert.deepStrictEqual(res, { lines: [], high: false, infra: false }, `${name}: ${show(res)}`);
  }
});
caseEnd();

caseBegin("u3-op-is-skip-reason", "hooks/lib/test-gates/test-runner.js");
test("U3: judge asks the entry's caseEmbedRules for the skip-reason op and adds no regex of its own", () => {
  const calls = [];
  const res = withEmbed((real, entry, op, file, opts) => {
    calls.push([entry.id, op]);
    return { rc: 0, stdout: "", stderr: "" };
  }, () => TR().judge(S.mem("x.js", F.BODY.plain), REL));
  assert.deepStrictEqual(calls, [["js", "skip-reason"]]);
  assert.deepStrictEqual(res.lines, [], "an empty skip-reason is no violation even for a plain script");
});
caseEnd();

caseBegin("u3-other-word-not-rejected", "hooks/lib/test-gates/test-runner.js");
test("U3: only the declared rejectSkipReason word blocks; another word passes", () => {
  const res = withEmbed(() => ({ rc: 0, stdout: "narrow-harness\n", stderr: "" }),
    () => TR().judge(S.mem("x.js", F.BODY.plain), REL));
  assert.deepStrictEqual(res, { lines: [], high: false, infra: false });
});
caseEnd();

caseBegin("u3-field-removed", "hooks/lib/test-gates/test-runner.js");
test("U3: with newEntrypointRunner removed from the cached js entry, nothing is checked", () => {
  const res = withJsEntry((e) => { delete e.newEntrypointRunner; },
    () => TR().judge(S.mem("x.js", F.BODY.plain), REL));
  assert.deepStrictEqual(res, { lines: [], high: false, infra: false });
});
caseEnd();

caseBegin("u4-runtime-unavailable-warn", "hooks/lib/test-gates/test-runner.js");
test("U4: rc 69 from the op is a WARN naming launch.requires, never HIGH", () => {
  const res = withEmbed(() => ({ rc: 69, stdout: "", stderr: "" }), () => TR().judge(S.mem("x.js", F.BODY.plain), REL));
  assert.deepStrictEqual(res, {
    lines: [{ err: false, text: `WARN: ${REL}: required runner not checked (node is not installed) code=${F.WARN_CODE}` }],
    high: false, infra: false,
  });
});
caseEnd();

caseBegin("u4-op-failure-infra", "hooks/lib/test-gates/test-runner.js");
test("U4: any other rc is an infra err line (fail-open), never HIGH", () => {
  for (const rc of [1, 70]) {
    const res = withEmbed(() => ({ rc, stdout: "custom-runner\n", stderr: "boom" }), () => TR().judge(S.mem("x.js", F.BODY.plain), REL));
    assert.deepStrictEqual(res, {
      lines: [{ err: true, text: `check-test-runner.sh: skip-reason op failed (rc=${rc}): ${REL}` }],
      high: false, infra: true,
    }, `rc=${rc}`);
  }
});
caseEnd();

caseBegin("runner-hint", "hooks/lib/test-gates/test-runner.js");
test("runnerHint: hint plus the notationDoc, markerDoc preferred, null without the field", () => {
  const T = TR();
  assert.strictEqual(T.runnerHint(R.match(REL).entry), F.HINT);
  const fake = { notationDoc: "a.md", diagnostics: { markerDoc: "b.md" }, newEntrypointRunner: { rejectSkipReason: "w", hint: "Do it" } };
  assert.strictEqual(T.runnerHint(fake), "Do it — see b.md.");
  assert.strictEqual(T.runnerHint({ ...fake, diagnostics: {} }), "Do it — see a.md.");
  assert.strictEqual(T.runnerHint({ notationDoc: "a.md" }), null);
  assert.strictEqual(T.runnerHint(R.match("tests/bin/x.sh").entry), null);
});
caseEnd();

// U5 — validate over a clone of the shipped table.
const TABLE = lib("test-language-registry.json");
const clone = () => JSON.parse(fs.readFileSync(TABLE, "utf8"));
const byId = (t, id) => t.entries.find((e) => e.id === id);
const FIELD_ERR = { message: /^test-language-registry: entries\[\d+\]\.newEntrypointRunner/ };
const OPTS = { repoFiles: false, complete: false };

caseBegin("u5-real-table", "hooks/lib/test-language-registry/validate.js");
test("U5: the shipped table declares the field on js only and passes validation (load opts and full)", () => {
  const t = clone();
  assert.deepStrictEqual(byId(t, "js").newEntrypointRunner, { rejectSkipReason: "custom-runner", hint: F.HINT_TEXT });
  for (const e of t.entries) if (e.id !== "js") assert.ok(e.newEntrypointRunner == null, `${e.id} declares it`);
  validate(t, REPO, OPTS);
  validate(clone(), REPO);
});
caseEnd();

caseBegin("u5-bad-values-rejected", "hooks/lib/test-language-registry/validate.js");
test("U5: validate rejects a non-word rejectSkipReason, an empty or multi-line hint, and a non-object", () => {
  const bad = [
    { rejectSkipReason: "Custom Runner", hint: "h" },
    { rejectSkipReason: "custom-runner,x", hint: "h" },
    { rejectSkipReason: "", hint: "h" },
    { hint: "h" },
    { rejectSkipReason: "custom-runner", hint: "" },
    { rejectSkipReason: "custom-runner", hint: "a\nb" },
    { rejectSkipReason: "custom-runner" },
    "custom-runner",
    ["custom-runner"],
  ];
  for (const v of bad) {
    const t = clone();
    byId(t, "js").newEntrypointRunner = v;
    assert.throws(() => validate(t, REPO, OPTS), FIELD_ERR, JSON.stringify(v));
  }
});
caseEnd();

caseBegin("u5-null-and-absent-accepted", "hooks/lib/test-language-registry/validate.js");
test("U5: null and an absent field are accepted (the field is optional)", () => {
  const t = clone();
  byId(t, "js").newEntrypointRunner = null;
  validate(t, REPO, OPTS);
  delete byId(t, "js").newEntrypointRunner;
  validate(t, REPO, OPTS);
});
caseEnd();

caseBegin("u5-needs-case-embed-rules", "hooks/lib/test-language-registry/validate.js");
test("U5: the field on an entry without caseEmbedRules is rejected at load", () => {
  const t = clone();
  const target = t.entries.find((e) => e.caseEmbedRules == null);
  assert.ok(target, "the shipped table has an entry without caseEmbedRules");
  target.newEntrypointRunner = { rejectSkipReason: "custom-runner", hint: "h" };
  assert.throws(() => validate(t, REPO, OPTS), FIELD_ERR);
});
caseEnd();
