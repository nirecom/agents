"use strict";
// Self-impl (#2502 S3-4) fixtures shared by the feature-2502-language-match-gate*.js entrypoints:
// test bodies, the hook runner with a replaceable hook file and env, and checkout copies.

const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const { CHECKOUT, HOOK } = require("./common");

const SI_CLI = path.join(CHECKOUT, "bin", "check-self-impl.sh");
const resolves = (cmd, env) => spawnSync("bash", ["-c", 'command -v "$1" >/dev/null 2>&1', "_", cmd], { env: env || process.env }).status === 0;

// One code file pair (bin/a.<ext>, bin/b.<ext>) per language.
const SI_HEAD = {};
for (const ext of ["sh", "ps1", "py", "js"]) for (const n of ["a", "b"]) SI_HEAD[`bin/${n}.${ext}`] = "\n";

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

// make({ ROOT, NEUTRAL, mkRepo }) — the helpers bound to one entrypoint's temp root.
function make(ctx) {
  const { ROOT, NEUTRAL, mkRepo } = ctx;
  const mkSiRepo = () => mkRepo(SI_HEAD);

  // mkCheckout(name, change) — a copy of the hook's checkout (bin/ and hooks/) that change(dir)
  // then alters; the copied hook resolves its CLIs and registry inside the copy.
  function mkCheckout(name, change) {
    const dir = path.join(ROOT, name);
    for (const sub of ["bin", "hooks"]) fs.cpSync(path.join(CHECKOUT, sub), path.join(dir, sub), { recursive: true });
    change(dir);
    return dir;
  }

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

  return { mkSiRepo, mkCheckout, siHook };
}

module.exports = {
  SI_CLI, resolves, SI_HEAD, BODY, writeInput, decision, reasonOf, contextOf, show,
  expectBlock, expectApprove, expectNoTempPath, envWithout, make,
};
