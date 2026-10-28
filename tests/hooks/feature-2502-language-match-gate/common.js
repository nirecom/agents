"use strict";
// Fixture helpers shared by the feature-2502-language-match-gate*.js entrypoints. Each entrypoint
// keeps its own isolation (harness isolate, temp root, env) and passes it in through make(ctx).

const assert = require("node:assert");
const fs = require("node:fs");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const CHECKOUT = path.resolve(__dirname, "..", "..", "..");
const HOOK = path.join(CHECKOUT, "hooks", "block-case-markers.js");
const PRECOMMIT_LIB = path.join(CHECKOUT, "hooks", "lib", "precommit-tests-frontmatter.sh");

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

// The marker words are split so the entrypoints' own case reader never takes fixture text for markers.
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

// make({ ROOT, NEUTRAL, gitInit }) — the helpers bound to one entrypoint's temp root.
function make(ctx) {
  const { ROOT, NEUTRAL, gitInit } = ctx;
  let repoSeq = 0;
  // mkRepo(head) — a fixture repo with helper library stubs, bash and JavaScript code, and the
  // files of head ({rel: body}) committed to HEAD. opts.noHelpers leaves the helper stubs out.
  function mkRepo(head = {}, opts = {}) {
    const dir = path.join(ROOT, `repo-${++repoSeq}`);
    fs.mkdirSync(dir);
    gitInit(dir);
    git(dir, "config", "user.email", "t@example.com");
    git(dir, "config", "user.name", "t");
    git(dir, "config", "core.autocrlf", "false");
    if (!opts.noHelpers) for (const ext of ["sh", "ps1", "py", "js"]) writeRel(dir, `tests/lib/harness.${ext}`, "\n");
    for (const f of ["bin/foo.js", "bin/foo.py", "bin/foo.sh", "bin/bar.sh"]) writeRel(dir, f, "\n");
    for (const [rel, body] of Object.entries(head)) writeRel(dir, rel, body);
    git(dir, "add", "-A");
    git(dir, "commit", "-q", "-m", "init");
    return dir;
  }

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
  // checkout as AGENTS_MAIN_ROOT; rc 127 when the function is not defined.
  function runPrecommit(repo) {
    const script = '_cfg_dir="$2"; . "$1" || exit 97; declare -F _precommit_check_test_language_match >/dev/null || exit 127; _precommit_check_test_language_match';
    const r = spawnSync("bash", ["-c", script, "_", posix(PRECOMMIT_LIB), posix(CHECKOUT)], {
      cwd: repo, encoding: "utf8", env: process.env, timeout: 180000,
    });
    return { rc: r.status, text: `${r.stdout || ""}\n${r.stderr || ""}` };
  }

  // runPrecommitCaseMarkers(repo) — _precommit_check_tests_case_markers the same way, with
  // stdout and stderr kept apart; rc 127 when the function is not defined.
  function runPrecommitCaseMarkers(repo) {
    const script = '_cfg_dir="$2"; . "$1" || exit 97; declare -F _precommit_check_tests_case_markers >/dev/null || exit 127; _precommit_check_tests_case_markers';
    const r = spawnSync("bash", ["-c", script, "_", posix(PRECOMMIT_LIB), posix(CHECKOUT)], {
      cwd: repo, encoding: "utf8", env: process.env, timeout: 180000,
    });
    return { rc: r.status, stdout: r.stdout || "", stderr: r.stderr || "" };
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

  return { mkRepo, runHook, runPrecommit, runPrecommitCaseMarkers, row };
}

module.exports = { CHECKOUT, HOOK, posix, git, writeRel, MB, ME, bashBody, HDR, BASE, BASE_JS, make };
