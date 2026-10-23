"use strict";
// Tests: hooks/block-case-markers.js, hooks/lib/precommit-tests-frontmatter.sh
// Tags: TL2, hooks, pre-commit, test-language-match, test-lang-exception:symmetry, edit-time, warn-context, scope:issue-specific, self-impl, fail-open
// #2502 S4-7: bin/check-test-language-match.sh is called from the edit-time hook and from the
// pre-commit gate _precommit_check_test_language_match; each row runs through both and must get
// the same verdict. New and existing files are both judged (existing ones with the HEAD copy).
// The judgment table: tests/bin/feature-2502-test-language-match.sh. S3-4 (self-impl) is below.
// TL3 gap: the hook as registered in a live session and the installed pre-commit hook
// (mitigation: tests/hooks/feature-1834-precommit-lib-split.sh part F pins the hook-line wiring).
// Host-level hook registration coverage is deferred: only a live session (claude -p, RUN_TL3)
// exercises it, and check-verification-gate.sh category hook-registration already pins the wiring.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { after, test } = require("node:test");

const CHECKOUT = path.resolve(__dirname, "..", "..");
const HOOK = path.join(CHECKOUT, "hooks", "block-case-markers.js");
const PRECOMMIT_LIB = path.join(CHECKOUT, "hooks", "lib", "precommit-tests-frontmatter.sh");
const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2502-lmg-"));
const NEUTRAL = path.join(ROOT, "cwd");
const DECOY = path.join(ROOT, "decoy");
fs.mkdirSync(NEUTRAL);
fs.mkdirSync(DECOY);
process.env.AGENTS_MAIN_ROOT = DECOY;
for (const k of ["CLAUDE_PROJECT_DIR", "CLAUDE_CODE_SESSION_ID", "GIT_DIR", "GIT_WORK_TREE"]) delete process.env[k];
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const posix = (p) => p.replace(/\\/g, "/");

function git(dir, ...args) {
  const r = spawnSync("git", ["-C", dir, ...args], { encoding: "utf8" });
  if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr || r.error}`);
  return r.stdout;
}

function writeRel(dir, rel, text) {
  const abs = path.join(dir, ...rel.split("/"));
  fs.mkdirSync(path.dirname(abs), { recursive: true });
  fs.writeFileSync(abs, text);
  return abs;
}

let repoSeq = 0;
// mkRepo(head) — a fixture repo with helper library stubs, bash and JavaScript code, and the
// files of head ({rel: body}) committed to HEAD.
function mkRepo(head = {}) {
  const dir = path.join(ROOT, `repo-${++repoSeq}`);
  fs.mkdirSync(dir);
  gitInit(dir);
  git(dir, "config", "user.email", "t@example.com");
  git(dir, "config", "user.name", "t");
  git(dir, "config", "core.autocrlf", "false");
  for (const ext of ["sh", "ps1", "py", "js"]) writeRel(dir, `tests/lib/harness.${ext}`, "\n");
  for (const f of ["bin/foo.js", "bin/foo.py", "bin/foo.sh", "bin/bar.sh"]) writeRel(dir, f, "\n");
  for (const [rel, body] of Object.entries(head)) writeRel(dir, rel, body);
  git(dir, "add", "-A");
  git(dir, "commit", "-q", "-m", "init");
  return dir;
}

// The marker words are split so this file's own case reader never takes fixture text for markers.
const MB = "case" + "_begin";
const ME = "case" + "_end";
// bashBody(tags, tests, cases) — a bash test body; cases is [[name, target, word?], ...].
function bashBody(tags, tests, cases = []) {
  const l = ["#!/usr/bin/env bash", `# Tests: ${tests}`, `# Tags: ${tags}`, 'source "$(dirname "$0")/../../tests/lib/harness.sh"'];
  for (const [n, t, w] of cases) l.push(`${MB} "${n}" "${t}"`, `echo ${w || n}`, ME);
  return l.join("\n") + "\n";
}

const HDR = "bin/foo.sh, bin/bar.sh";
const BASE = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["b", "bin/bar.sh"]]);
const BASE_JS = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["j", "bin/foo.js"]]);

function runHook(input) {
  const r = spawnSync(process.execPath, [HOOK], {
    cwd: NEUTRAL, input: JSON.stringify(input), encoding: "utf8", env: process.env, timeout: 180000,
  });
  let out = null;
  try { out = JSON.parse(String(r.stdout || "").trim().split(/\r?\n/).pop()); } catch (_e) { out = null; }
  const o = out || {};
  return {
    decision: o.decision || "none",
    reason: o.reason || "",
    context: (o.hookSpecificOutput && o.hookSpecificOutput.additionalContext) || o.additionalContext || "",
    raw: `stdout=[${r.stdout}] stderr=[${r.stderr}]`,
  };
}

// runPrecommit(repo) — _precommit_check_test_language_match with repo as cwd and the real
// checkout as the agents main root; rc 127 when the function is not defined.
function runPrecommit(repo) {
  const script = '_cfg_dir="$2"; . "$1" || exit 97; declare -F _precommit_check_test_language_match >/dev/null || exit 127; _precommit_check_test_language_match';
  const r = spawnSync("bash", ["-c", script, "_", posix(PRECOMMIT_LIB), posix(CHECKOUT)], {
    cwd: repo, encoding: "utf8", env: process.env, timeout: 180000,
  });
  return { rc: r.status, text: `${r.stdout || ""}\n${r.stderr || ""}` };
}

// row(spec) — runs one scenario through both callers. spec: {head, rel, work, edit, code, warn}.
// code: the HIGH code both must block with (null = both pass); warn: a WARN code the hook's
// notice and the pre-commit output must carry (only when code is null).
function row(spec) {
  const head = spec.head ? { [spec.rel]: spec.head } : {};
  const hookRepo = mkRepo(head);
  const abs = path.join(hookRepo, ...spec.rel.split("/"));
  const input = spec.edit
    ? { tool_name: "Edit", cwd: hookRepo, tool_input: { file_path: abs, ...spec.edit } }
    : { tool_name: "Write", cwd: hookRepo, tool_input: { file_path: abs, content: spec.work } };
  const h = runHook(input);
  const show = `hook decision=${h.decision} reason=[${h.reason}] context=[${h.context}] ${h.raw}`;
  if (spec.code) {
    assert.strictEqual(h.decision, "block", show);
    assert.ok(h.reason.includes(`code=${spec.code}`), show);
    assert.ok(h.reason.includes(spec.rel), show);
  } else {
    assert.strictEqual(h.decision, "approve", show);
    if (spec.warn) assert.ok(h.context.includes(`code=${spec.warn}`) && h.context.includes(spec.rel), show);
    else assert.strictEqual(h.context, "", show);
  }
  if (spec.edit) return;

  const pcRepo = mkRepo(head);
  writeRel(pcRepo, spec.rel, spec.work);
  git(pcRepo, "add", "--", spec.rel);
  const p = runPrecommit(pcRepo);
  const pshow = `precommit rc=${p.rc} output=[${p.text}]`;
  if (spec.code) {
    assert.strictEqual(p.rc, 1, pshow);
    assert.ok(p.text.includes(`code=${spec.code}`), pshow);
  } else {
    assert.strictEqual(p.rc, 0, pshow);
    assert.ok(!/code=(TEST_LANGUAGE_MISMATCH|INVALID_TEST_LANG_EXCEPTION)/.test(p.text), pshow);
    if (spec.warn) assert.ok(p.text.includes(`code=${spec.warn}`), pshow);
  }
}

caseBegin("new-file-header-mismatch-blocks", "hooks/block-case-markers.js");
test("a new bash test naming JavaScript code is blocked by both callers", () => {
  row({ rel: "tests/bin/m1.sh", work: bashBody("scope:common", "bin/foo.js"), code: "TEST_LANGUAGE_MISMATCH" });
});
caseEnd();

caseBegin("existing-file-added-js-case-blocks", "hooks/block-case-markers.js");
test("an existing bash test gaining a case on JavaScript code is blocked by both callers", () => {
  const work = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["b", "bin/bar.sh"], ["c", "bin/foo.js"]]);
  row({ rel: "tests/bin/m2.sh", head: BASE, work, code: "TEST_LANGUAGE_MISMATCH" });
});
caseEnd();

caseBegin("existing-file-edit-payload-blocks", "hooks/block-case-markers.js");
test("an Edit payload adding a case on JavaScript code to an existing file is blocked", () => {
  const tail = `echo b\n${ME}\n`;
  row({
    rel: "tests/bin/m3.sh", head: BASE, code: "TEST_LANGUAGE_MISMATCH",
    edit: { old_string: tail, new_string: `${tail}${MB} "c" "bin/foo.js"\necho c\n${ME}\n` },
  });
});
caseEnd();

// multiEdit(repo, rel, edits) — the hook on one MultiEdit call whose top-level file_path is rel;
// an element may carry its own file_path (absolute) to edit another file in the same call.
function multiEdit(repo, rel, edits) {
  const abs = path.join(repo, ...rel.split("/"));
  const r = runHook({ tool_name: "MultiEdit", cwd: repo, tool_input: { file_path: abs, edits } });
  return { ...r, show: `hook decision=${r.decision} reason=[${r.reason}] context=[${r.context}] ${r.raw}` };
}
const B_TAIL = `echo b\n${ME}\n`;
const ADD_JS_CASE = { old_string: B_TAIL, new_string: `${B_TAIL}${MB} "c" "bin/foo.js"\necho c\n${ME}\n` };

caseBegin("multiedit-added-js-case-blocks", "hooks/block-case-markers.js");
test("a MultiEdit whose second element adds a case on JavaScript code is blocked", () => {
  const rel = "tests/bin/me1.sh";
  const r = multiEdit(mkRepo({ [rel]: BASE }), rel, [{ old_string: "echo a\n", new_string: "echo a2\n" }, ADD_JS_CASE]);
  assert.strictEqual(r.decision, "block", r.show);
  assert.ok(r.reason.includes("code=TEST_LANGUAGE_MISMATCH") && r.reason.includes(rel), r.show);
});
caseEnd();

caseBegin("multiedit-two-files-blocks-the-mismatched-one", "hooks/block-case-markers.js");
test("a MultiEdit editing two files is blocked on the one gaining a JavaScript case only", () => {
  const ok = "tests/bin/me2.sh";
  const bad = "tests/bin/me3.sh";
  const repo = mkRepo({ [ok]: BASE, [bad]: BASE });
  const badAbs = path.join(repo, ...bad.split("/"));
  const r = multiEdit(repo, ok, [{ old_string: "echo a\n", new_string: "echo a2\n" }, { file_path: badAbs, ...ADD_JS_CASE }]);
  assert.strictEqual(r.decision, "block", r.show);
  assert.ok(r.reason.includes("code=TEST_LANGUAGE_MISMATCH") && r.reason.includes(bad), r.show);
  assert.ok(!r.reason.includes(ok), r.show);
});
caseEnd();

caseBegin("multiedit-body-changes-pass", "hooks/block-case-markers.js");
test("a MultiEdit changing case bodies only (HEAD's JavaScript case included) is approved silently", () => {
  const rel = "tests/bin/me4.sh";
  const r = multiEdit(mkRepo({ [rel]: BASE_JS }), rel, [
    { old_string: "echo a\n", new_string: "echo a2\n" },
    { old_string: "echo j\n", new_string: "echo changed\n" },
  ]);
  assert.strictEqual(r.decision, "approve", r.show);
  assert.strictEqual(r.context, "", r.show);
});
caseEnd();

caseBegin("new-file-invalid-exception-blocks", "hooks/lib/precommit-tests-frontmatter.sh");
test("a new file declaring test-lang-exception:other is blocked by both callers", () => {
  row({ rel: "tests/bin/m4.sh", work: bashBody("scope:common, test-lang-exception:other", "bin/foo.sh"), code: "INVALID_TEST_LANG_EXCEPTION" });
});
caseEnd();

caseBegin("existing-file-tags-changed-to-invalid-blocks", "hooks/lib/precommit-tests-frontmatter.sh");
test("an existing file whose Tags change to test-lang-exception:other is blocked by both callers", () => {
  const work = bashBody("scope:common, test-lang-exception:other", HDR, [["a", "bin/foo.sh"], ["b", "bin/bar.sh"]]);
  row({ rel: "tests/bin/m5.sh", head: BASE, work, code: "INVALID_TEST_LANG_EXCEPTION" });
});
caseEnd();

caseBegin("valid-exception-passes", "hooks/lib/precommit-tests-frontmatter.sh");
test("a new file with test-lang-exception:e2e on JavaScript code passes both callers", () => {
  row({ rel: "tests/bin/m6.sh", work: bashBody("scope:common, test-lang-exception:e2e", "bin/foo.js"), code: null });
});
caseEnd();

caseBegin("existing-mismatch-body-change-passes", "hooks/lib/precommit-tests-frontmatter.sh");
test("a body change to a case HEAD already had on JavaScript code passes both callers", () => {
  const work = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["j", "bin/foo.js", "changed"]]);
  row({ rel: "tests/bin/m7.sh", head: BASE_JS, work, code: null });
});
caseEnd();

caseBegin("existing-js-mismatch-retargeted-to-py-passes", "hooks/lib/precommit-tests-frontmatter.sh");
// Plan S4-4: a paired case whose HEAD target was already mismatched is an existing state, so
// moving it from JavaScript to Python code adds no mismatched case and both callers pass it.
test("a case HEAD already had on JavaScript code, moved to Python code, passes both callers", () => {
  const work = bashBody("scope:common", HDR, [["a", "bin/foo.sh"], ["j", "bin/foo.py"]]);
  row({ rel: "tests/bin/m9.sh", head: BASE_JS, work, code: null });
});
caseEnd();

caseBegin("unregistered-language-warn-notice", "hooks/block-case-markers.js");
test("(a) a tests/ file of no registered language passes with TEST_LANGUAGE_UNSUPPORTED in the notice", () => {
  row({ rel: "tests/bin/foo.rb", work: "# Tests: bin/foo.js\n# Tags: scope:common\nputs 1\n", code: null, warn: "TEST_LANGUAGE_UNSUPPORTED" });
});
caseEnd();

caseBegin("same-language-empty-notice", "hooks/block-case-markers.js");
test("(c) a new bash test on bash code passes and the notice stays empty", () => {
  row({ rel: "tests/bin/m8.sh", work: bashBody("scope:common", "bin/foo.sh"), code: null });
});
caseEnd();

// #2502 S3-4: the same hook runs bin/check-self-impl.sh on every NEW test file and blocks on a
// self-implemented harness. A WARN alone goes out as additionalContext, next to a HIGH it joins
// the block reason, and with none the notice stays empty. A missing CLI file skips that CLI only.
// CASE_MARKER_READER_UNSUPPORTED cannot reach the hook (a candidate needs a case reader); the CLI
// level pins it (tests/bin/feature-2411-gate-three-languages/gate-unsupported.sh).
const SI_CLI = path.join(CHECKOUT, "bin", "check-self-impl.sh");
const resolves = (cmd, env) => spawnSync("bash", ["-c", 'command -v "$1" >/dev/null 2>&1', "_", cmd], { env: env || process.env }).status === 0;

// mkSiRepo() — mkRepo plus one code file pair (bin/a.<ext>, bin/b.<ext>) per language.
const SI_HEAD = {};
for (const ext of ["sh", "ps1", "py", "js"]) for (const n of ["a", "b"]) SI_HEAD[`bin/${n}.${ext}`] = "\n";
const mkSiRepo = () => mkRepo(SI_HEAD);

// mkCheckout(name, change) — a copy of the hook's checkout (bin/ and hooks/) that change(dir)
// then alters; the copied hook resolves its CLIs and registry inside the copy.
function mkCheckout(name, change) {
  const dir = path.join(ROOT, name);
  for (const sub of ["bin", "hooks"]) fs.cpSync(path.join(CHECKOUT, sub), path.join(dir, sub), { recursive: true });
  change(dir);
  return dir;
}

const lines = (...l) => l.join("\n") + "\n";
const BODY = {
  // counter on line 5, redefinition of the helper's pass on line 6
  shBad: lines("#!/usr/bin/env bash", "# Tests: bin/a.sh", "# Tags: scope:common",
    'source "$(dirname "$0")/../../tests/lib/harness.sh"', "PASS=0", "pass() { echo ok; }", "echo done"),
  shClean: lines("#!/usr/bin/env bash", "# Tests: bin/a.sh", "# Tags: scope:common",
    'source "$(dirname "$0")/../../tests/lib/harness.sh"', "echo done"),
  shTwoPathsNoMarkers: lines("#!/usr/bin/env bash", "# Tests: bin/a.sh, bin/b.sh", "# Tags: scope:common",
    'source "$(dirname "$0")/../../tests/lib/harness.sh"', "echo no markers"),
  // counter on line 4, redefinition of the helper's gitInit on line 5
  jsBad: lines("// Tests: bin/a.js", "// Tags: scope:common", 'const harness = require("../lib/harness");',
    "let PASS = 0;", "function gitInit() {}", "console.log(typeof harness, PASS, gitInit);"),
  jsTwoPathsNoMarkers: lines("// Tests: bin/a.js, bin/b.js", "// Tags: scope:common",
    'const harness = require("../lib/harness");', "console.log(typeof harness);"),
  // counter on line 5
  pyBad: lines("# Tests: bin/a.py", "# Tags: scope:common", "import pytest", "", "passed = 0", "", "",
    "def isolate():", "    return None", "", "", "def test_a():", "    assert pytest is not None"),
  // counter on line 6
  pesterBad: lines("# Tests: bin/a.ps1", "# Tags: scope:common", "BeforeAll {",
    "    . (Join-Path $PSScriptRoot '..' 'lib' 'harness.ps1')", "}", "$script:Passed = 0",
    "function Enter-HarnessIsolation { }", "Describe 'a' {", "    It 'runs' { 1 | Should -Be 1 }", "}"),
};

const writeInput = (repo, rel, content) => ({
  tool_name: "Write", cwd: repo, tool_input: { file_path: path.join(repo, ...rel.split("/")), content },
});

// siHook(input, opts) — the hook from a neutral cwd; opts.hook replaces the hook file and
// opts.env the environment. Returns the parsed last stdout line as .out.
function siHook(input, opts = {}) {
  const r = spawnSync(process.execPath, [opts.hook || HOOK], {
    cwd: NEUTRAL, input: JSON.stringify(input), encoding: "utf8", env: opts.env || process.env, timeout: 180000,
  });
  let out = null;
  try { out = JSON.parse(String(r.stdout || "").trim().split(/\r?\n/).pop()); } catch (_e) { out = null; }
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, out };
}
const decision = (r) => (r.out && r.out.decision) || `none (stdout=${r.stdout} stderr=${r.stderr})`;
const reasonOf = (r) => (r.out && r.out.reason) || "";
const contextOf = (r) => {
  const o = r.out || {};
  return (o.hookSpecificOutput && o.hookSpecificOutput.additionalContext) || o.additionalContext || "";
};
const show = (r) => `decision=${decision(r)} reason=[${reasonOf(r)}] context=[${contextOf(r)}] stderr=[${r.stderr}]`;

function expectBlock(r, ...needles) {
  assert.strictEqual(decision(r), "block", show(r));
  for (const n of needles) assert.ok(reasonOf(r).includes(n), `reason lacks [${n}]: ${show(r)}`);
}
function expectApprove(r) {
  assert.strictEqual(decision(r), "approve", show(r));
}
function expectNoTempPath(r) {
  const text = reasonOf(r) + contextOf(r);
  for (const t of [os.tmpdir(), os.tmpdir().replace(/\\/g, "/")]) assert.ok(!text.includes(t), `temp path leaked: ${show(r)}`);
}

// envWithout(cmd) — process.env minus every PATH entry holding <cmd>, or null when it still resolves.
function envWithout(cmd) {
  const env = { ...process.env };
  const key = Object.keys(env).find((k) => k.toUpperCase() === "PATH") || "PATH";
  env[key] = String(env[key] || "").split(path.delimiter)
    .filter((d) => !["", ".exe", ".cmd"].some((x) => fs.existsSync(path.join(d, cmd + x))))
    .join(path.delimiter);
  return resolves(cmd, env) ? null : env;
}

caseBegin("self-impl-cli-present", "hooks/block-case-markers.js");
test("bin/check-self-impl.sh exists for the hook to call", () => {
  assert.ok(fs.existsSync(SI_CLI), `missing: ${SI_CLI}`);
});
caseEnd();

caseBegin("new-bash-self-impl-blocks", "hooks/block-case-markers.js");
test("a new bash test with a hand-made counter is blocked, reason names the rel path", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.sh", BODY.shBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/bin/x.sh line 5", "tests/bin/x.sh line 6");
  expectNoTempPath(r);
});
caseEnd();

caseBegin("new-js-self-impl-blocks", "hooks/block-case-markers.js");
test("a new js test with a counter and a helper redefinition is blocked", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/hooks/x.js", BODY.jsBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/hooks/x.js line 4", "tests/hooks/x.js line 5");
});
caseEnd();

caseBegin("new-pytest-self-impl-blocks", "hooks/block-case-markers.js");
test("a new pytest test with a counter is blocked", { skip: !resolves("uv") && "uv not installed" }, () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/test_x.py", BODY.pyBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/bin/test_x.py line 5");
});
caseEnd();

caseBegin("new-pester-self-impl-blocks", "hooks/block-case-markers.js");
test("a new Pester test with a counter is blocked", { skip: !resolves("pwsh") && "pwsh not installed" }, () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.Tests.ps1", BODY.pesterBad));
  expectBlock(r, "code=SELF_IMPLEMENTED_HARNESS", "tests/bin/x.Tests.ps1 line 6");
});
caseEnd();

caseBegin("clean-new-file-empty-notice", "hooks/block-case-markers.js");
test("(c) a clean new file is approved and the notice stays empty", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.sh", BODY.shClean));
  expectApprove(r);
  assert.strictEqual(contextOf(r), "", show(r));
});
caseEnd();

// #2502 S4-4b rule b: an existing marker-less file is judged for case addition unless the working
// Tests: lists exactly one path. The added lines are plain echo, never a self-implemented harness.
caseBegin("existing-file-one-path-case-added-approves", "hooks/lib/precommit-tests-frontmatter.sh");
test("an existing one-path bash test gaining a code line passes both callers", () => {
  row({ rel: "tests/bin/old.sh", head: BODY.shClean, work: BODY.shClean + "echo extra\n", code: null });
});
caseEnd();

caseBegin("existing-file-two-paths-case-added-blocks", "hooks/lib/precommit-tests-frontmatter.sh");
test("an existing two-path bash test without markers gaining a code line is blocked by both callers", () => {
  const work = BODY.shTwoPathsNoMarkers + "echo extra\n";
  row({ rel: "tests/bin/old.sh", head: BODY.shTwoPathsNoMarkers, work, code: "CASE_ADDED_WITHOUT_MARKERS" });
});
caseEnd();

caseBegin("existing-file-two-paths-value-rewrite-approves", "hooks/lib/precommit-tests-frontmatter.sh");
test("an existing two-path bash test without markers whose line is rewritten passes both callers", () => {
  const work = BODY.shTwoPathsNoMarkers.replace("echo no markers", "echo changed");
  assert.notStrictEqual(work, BODY.shTwoPathsNoMarkers);
  row({ rel: "tests/bin/old.sh", head: BODY.shTwoPathsNoMarkers, work, code: null });
});
caseEnd();

caseBegin("existing-file-one-path-not-self-impl-checked", "hooks/block-case-markers.js");
// The self-impl check skips a file HEAD already has; a one-path Tests: also exempts it from S4-4b.
test("an Edit adding a counter to an existing one-path file is approved and never self-impl checked", () => {
  const repo = mkRepo({ ...SI_HEAD, "tests/bin/old.sh": BODY.shClean });
  const abs = path.join(repo, "tests", "bin", "old.sh");
  const edit = (newString) => siHook({ tool_name: "Edit", cwd: repo,
    tool_input: { file_path: abs, old_string: "echo done\n", new_string: newString } });
  const same = edit("PASS=0; echo done\n");
  expectApprove(same);
  assert.ok(!(reasonOf(same) + contextOf(same)).includes("SELF_IMPL"), show(same));
  const added = edit("PASS=0\necho done\n");
  expectApprove(added);
  assert.ok(!(reasonOf(added) + contextOf(added)).includes("SELF_IMPL"), show(added));
});
caseEnd();

caseBegin("runtime-unavailable-warn-notice", "hooks/block-case-markers.js");
test("(a) a Pester self-impl without pwsh is approved with SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE in the notice", (t) => {
  const env = envWithout("pwsh");
  if (!env) { t.skip("pwsh still resolves after filtering PATH"); return; }
  const r = siHook(writeInput(mkSiRepo(), "tests/bin/x.Tests.ps1", BODY.pesterBad), { env });
  expectApprove(r);
  assert.ok(contextOf(r).includes("code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"), show(r));
  assert.ok(contextOf(r).includes("tests/bin/x.Tests.ps1"), show(r));
  expectNoTempPath(r);
});
caseEnd();

// A checkout whose registry gives js no caseEmbedRules: check-self-impl answers WARN for js.
const NO_EMBED = mkCheckout("checkout-no-js-embed", (dir) => {
  const file = path.join(dir, "hooks", "lib", "test-language-registry.json");
  const table = JSON.parse(fs.readFileSync(file, "utf8"));
  for (const e of table.entries) if (e.id === "js") e.caseEmbedRules = null;
  fs.writeFileSync(file, JSON.stringify(table, null, 2) + "\n");
});
const NO_EMBED_HOOK = path.join(NO_EMBED, "hooks", "block-case-markers.js");

caseBegin("unsupported-warn-notice", "hooks/block-case-markers.js");
test("(a) a js self-impl with no js caseEmbedRules is approved with SELF_IMPL_CHECK_UNSUPPORTED in the notice", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/hooks/x.js", BODY.jsBad), { hook: NO_EMBED_HOOK });
  expectApprove(r);
  assert.ok(contextOf(r).includes("code=SELF_IMPL_CHECK_UNSUPPORTED"), show(r));
  assert.ok(contextOf(r).includes("tests/hooks/x.js"), show(r));
});
caseEnd();

caseBegin("high-and-warn-both-in-reason", "hooks/block-case-markers.js");
test("(b) a case-marker HIGH next to a self-impl WARN blocks with both in the reason", () => {
  const r = siHook(writeInput(mkSiRepo(), "tests/hooks/two.js", BODY.jsTwoPathsNoMarkers), { hook: NO_EMBED_HOOK });
  expectBlock(r, "code=MISSING_CASE_MARKERS", "code=SELF_IMPL_CHECK_UNSUPPORTED", "tests/hooks/two.js");
});
caseEnd();

// A checkout without bin/check-self-impl.sh: only that CLI is skipped.
const NO_SI = mkCheckout("checkout-no-self-impl", (dir) => {
  fs.rmSync(path.join(dir, "bin", "check-self-impl.sh"), { force: true });
});
const NO_SI_HOOK = path.join(NO_SI, "hooks", "block-case-markers.js");

caseBegin("missing-self-impl-cli-skips-it-only", "hooks/block-case-markers.js");
test("without bin/check-self-impl.sh a self-impl body passes and the case-marker check still blocks", () => {
  const ok = siHook(writeInput(mkSiRepo(), "tests/bin/x.sh", BODY.shBad), { hook: NO_SI_HOOK });
  expectApprove(ok);
  const bad = siHook(writeInput(mkSiRepo(), "tests/bin/two.sh", BODY.shTwoPathsNoMarkers), { hook: NO_SI_HOOK });
  expectBlock(bad, "code=MISSING_CASE_MARKERS", "tests/bin/two.sh");
});
caseEnd();

// Block-reason headings (security review LOW): bodies in feature-2502-language-match-gate/.
const headings = require("./feature-2502-language-match-gate/reason-headings");
const H = { mkRepo, bashBody, runHook, MB, ME };

caseBegin("language-match-only-reason-heading", "hooks/block-case-markers.js");
headings.languageMatchOnlyHeading(H);
caseEnd();

caseBegin("both-gates-reason-headings", "hooks/block-case-markers.js");
headings.bothHeadings(H);
caseEnd();

caseBegin("case-marker-only-reason-unchanged", "hooks/block-case-markers.js");
headings.caseMarkerOnlyUnchanged(H);
caseEnd();
