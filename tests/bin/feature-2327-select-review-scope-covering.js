"use strict";
// Tests: bin/select-review-scope.js, bin/lib/review-scope-header-targets.js
// Tags: TL2, review-tests, scope-delta, covering-test, large-change, cli, real-git, scope:issue-specific
// #2327: the select-review-scope CLI end to end on real fixture repos — an impl change reviews only
// the staged tests whose Tests header names it, an uncovered or broad change stays full, and an
// unavailable header map degrades to a full review (exit 0, one stderr line) instead of failing.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const REPO_ROOT = path.join(__dirname, "..", "..");
const CLI = path.join(REPO_ROOT, "bin", "select-review-scope.js");
const ENV_KEY = "REVIEW_SCOPE_HEADER_TARGETS_BASH";
const fwd = (p) => p.replace(/\\/g, "/");

delete process.env[ENV_KEY];
const restore = isolate();
const stateIo = require(path.join(REPO_ROOT, "hooks", "workflow-state", "state-io.js"));
const { computeReviewScopeManifest } = require(path.join(REPO_ROOT, "hooks", "workflow-gate", "review-tests-evidence.js"));
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2327-select-covering-"));
after(() => {
  restore();
  fs.rmSync(TMP, { recursive: true, force: true, maxRetries: 5, retryDelay: 200 });
});

const SH_COVER = "#!/usr/bin/env bash\n# Tests: hooks/impl.js\n# Tags: t\n";
const shFor = (target) => `#!/usr/bin/env bash\n# Tests: ${target}\n# Tags: t\n`;

let seq = 0;
// A fixture repo with `files` staged, `sid` recording that staged manifest as the review baseline.
function fixture(files, { record = true } = {}) {
  seq += 1;
  const repo = path.join(TMP, `repo-${seq}`);
  const sid = `f2327-covering-${seq}`;
  gitInit(repo);
  const git = (...args) => {
    const r = spawnSync("git", ["-C", repo, ...args], { encoding: "utf8", timeout: 30000 });
    if (r.status !== 0) throw new Error(`git ${args.join(" ")}: ${r.stderr || r.error}`);
  };
  git("config", "user.email", "test@example.com");
  git("config", "user.name", "Test");
  git("config", "core.autocrlf", "false");
  const write = (rel, body) => {
    fs.mkdirSync(path.dirname(path.join(repo, rel)), { recursive: true });
    fs.writeFileSync(path.join(repo, rel), body);
  };
  const stage = (rels) => git("add", "--", ...rels);
  for (const [rel, body] of Object.entries(files)) write(rel, body);
  stage(Object.keys(files));
  stateIo.writeState(sid, stateIo.createInitialState(sid, { cwd: "." }));
  if (record) {
    const m = computeReviewScopeManifest(repo);
    assert.strictEqual(m.ok, true, JSON.stringify(m));
    stateIo.appendEvents(sid, [{
      kind: "step_annotation", step: "review_tests", key: "review_scope_manifest",
      value: { v: 1, files: m.files }, provenance: "observed", origin: "review-tests-complete",
    }]);
  }
  // Edit then stage, so the next run sees a new staged OID.
  const change = (rel, body) => { write(rel, body); stage([rel]); };
  return { repo, sid, write, change, root: fwd(repo).replace(/\/+$/, "") };
}

function runCli(fx, extraEnv) {
  const env = { ...process.env, ...(extraEnv || {}) };
  const res = spawnSync(process.execPath, [CLI, "--session", fx.sid, "--worktree", fx.root], { env, encoding: "utf8", timeout: 60000 });
  const lines = String(res.stdout || "").split(/\r?\n/).filter((l) => l !== "").sort();
  const errLines = String(res.stderr || "").split(/\r?\n/).filter((l) => l !== "");
  return { res, lines, errLines };
}
const expectLines = (fx, { scope, reason, review = [], inventory = [], deleted = [], source = [] }) => [
  `SCOPE=${scope}`, `REASON=${reason}`,
  ...review.map((r) => `REVIEW\t${fx.root}/${r}`),
  ...deleted.map((r) => `DELETED\t${r}`),
  ...inventory.map((r) => `INVENTORY\t${r}`),
  ...source.map((r) => `SOURCE\t${fx.root}/${r}`),
].sort();
function assertRun(out, want) {
  assert.strictEqual(out.res.status, 0, `exit ${out.res.status}; stderr=${out.res.stderr}`);
  assert.deepStrictEqual(out.lines, want, `stdout=${out.res.stdout}\nstderr=${out.res.stderr}`);
}

caseBegin("C1-C12-covering-test-selection", "bin/select-review-scope.js");
test("C1: an impl change reviews only the staged test that names it", () => {
  const fx = fixture({ "tests/cover.sh": SH_COVER, "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n" });
  fx.change("hooks/impl.js", "2;\n");
  assertRun(runCli(fx), expectLines(fx, {
    scope: "delta", reason: "impl-changed", review: ["tests/cover.sh"], inventory: ["tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
});
test("C2: an impl change no staged test names stays a full review", () => {
  const fx = fixture({ "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n" });
  fx.change("hooks/impl.js", "2;\n");
  assertRun(runCli(fx), expectLines(fx, {
    scope: "full", reason: "impl-uncovered", review: ["tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
});
test("C3: a tests-only change over half the tests is a full large-change review", () => {
  const fx = fixture({ "tests/a.sh": shFor("bin/a.sh"), "tests/b.sh": shFor("bin/b.sh"), "tests/c.sh": shFor("bin/c.sh"), "tests/d.sh": shFor("bin/d.sh") });
  for (const r of ["tests/a.sh", "tests/b.sh", "tests/c.sh"]) fx.change(r, `${shFor("bin/x.sh")}echo changed\n`);
  assertRun(runCli(fx), expectLines(fx, {
    scope: "full", reason: "large-change", review: ["tests/a.sh", "tests/b.sh", "tests/c.sh", "tests/d.sh"],
  }));
});
test("C4: the staged header decides coverage, not the unstaged worktree copy", () => {
  const fx = fixture({ "tests/cover.sh": SH_COVER, "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n" });
  fx.change("hooks/impl.js", "2;\n");
  fx.write("tests/cover.sh", "#!/usr/bin/env bash\n# header removed only in the worktree\n");
  assertRun(runCli(fx), expectLines(fx, {
    scope: "delta", reason: "impl-changed", review: ["tests/cover.sh"], inventory: ["tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
});
test("C16: an unstaged worktree header naming the impl does not make it covered", () => {
  const fx = fixture({ "tests/cover.sh": shFor("bin/other.sh"), "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n" });
  fx.change("hooks/impl.js", "2;\n");
  fx.write("tests/cover.sh", SH_COVER);
  assertRun(runCli(fx), expectLines(fx, {
    scope: "full", reason: "impl-uncovered", review: ["tests/cover.sh", "tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
});
test("C5:a .js covering test is read through its // header", () => {
  const fx = fixture({
    "tests/cover.test.js": "\"use strict\";\n// Tests: hooks/impl.js\n// Tags: t\n",
    "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n",
  });
  fx.change("hooks/impl.js", "2;\n");
  assertRun(runCli(fx), expectLines(fx, {
    scope: "delta", reason: "impl-changed", review: ["tests/cover.test.js"], inventory: ["tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
});
test("C11: impl path — covering plus changed tests over half the staged tests is full large-change", () => {
  const fx = fixture({
    "tests/cover.sh": SH_COVER, "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"),
    "tests/u3.sh": shFor("bin/u3.sh"), "tests/u4.sh": shFor("bin/u4.sh"), "hooks/impl.js": "1;\n",
  });
  fx.change("hooks/impl.js", "2;\n");
  for (const r of ["tests/u1.sh", "tests/u2.sh"]) fx.change(r, `${shFor(`bin/${path.basename(r)}`)}echo changed\n`);
  assertRun(runCli(fx), expectLines(fx, {
    scope: "full", reason: "large-change",
    review: ["tests/cover.sh", "tests/u1.sh", "tests/u2.sh", "tests/u3.sh", "tests/u4.sh"], source: ["hooks/impl.js"],
  }));
});
test("C12: a covering test with Japanese (UTF-8) text around its header resolves through cat-file", () => {
  const cover = [
    "#!/usr/bin/env bash",
    "# \u65E5\u672C\u8A9E\u306E\u30B3\u30E1\u30F3\u30C8: covering test \u306E\u691C\u8A3C\uFF08\u30DE\u30EB\u30C1\u30D0\u30A4\u30C8\uFF09",
    "# Tests: hooks/impl.js",
    "# Tags: t",
    "# \u30D8\u30C3\u30C0\u30FC\u76F4\u5F8C\u306E\u30B3\u30E1\u30F3\u30C8 \u2015 \u5168\u89D2\u8A18\u53F7\u30FB\u7D75\u6587\u5B57\u306A\u3057",
    "echo '\u3053\u3093\u306B\u3061\u306F\u3001\u4E16\u754C'",
    "",
  ].join("\n");
  const fx = fixture({ "tests/cover.sh": cover, "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n" });
  fx.change("hooks/impl.js", "2;\n");
  assertRun(runCli(fx), expectLines(fx, {
    scope: "delta", reason: "impl-changed", review: ["tests/cover.sh"], inventory: ["tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
});
caseEnd();

caseBegin("C6-C13-record-and-map-fallback", "bin/select-review-scope.js");
test("C6: a state without a recorded manifest stays full/no-record", () => {
  const fx = fixture({ "tests/cover.sh": SH_COVER, "hooks/impl.js": "1;\n" }, { record: false });
  assertRun(runCli(fx), expectLines(fx, { scope: "full", reason: "no-record", review: ["tests/cover.sh"], source: ["hooks/impl.js"] }));
});
const C7_FILES = { "tests/cover.sh": SH_COVER, "tests/u1.sh": shFor("bin/u1.sh"), "tests/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n" };
test("C7: an unavailable header map degrades to full, exit 0, one stderr line", () => {
  const fx = fixture(C7_FILES);
  fx.change("hooks/impl.js", "2;\n");
  const out = runCli(fx, { [ENV_KEY]: fwd(path.join(TMP, "no-such-dir", "bash")) });
  assertRun(out, expectLines(fx, {
    scope: "full", reason: "header-map-unavailable", review: ["tests/cover.sh", "tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
  assert.strictEqual(out.errLines.length, 1, `stderr=${out.res.stderr}`);
  assert.ok(out.errLines[0].startsWith("select-review-scope: header map unavailable: "), out.errLines[0]);
});
test("C9: a header hook that exits 0 with a malformed NUL record degrades to full, one stderr line", () => {
  // The override names node itself; NODE_OPTIONS --require preloads a stub that, only when node is
  // launched on the header-targets script, drains stdin, prints a record with a non-digit count
  // and exits 0 before the .sh is ever loaded. Both env values are set on this one invocation only.
  const stub = path.join(TMP, `c9-malformed-hook-${seq + 1}.js`);
  fs.writeFileSync(stub, [
    "if (process.argv.slice(1).some((a) => /review-scope-header-targets\\.sh$/.test(String(a).replace(/\\\\/g, '/')))) {",
    "  try { require('fs').readFileSync(0); } catch (_) {}",
    "  process.stdout.write('tests/cover.sh\\0x\\0');",
    "  process.exit(0);",
    "}",
  ].join("\n"));
  const fx = fixture(C7_FILES);
  fx.change("hooks/impl.js", "2;\n");
  const out = runCli(fx, { [ENV_KEY]: process.execPath, NODE_OPTIONS: `--require "${fwd(stub)}"` });
  assertRun(out, expectLines(fx, {
    scope: "full", reason: "header-map-unavailable", review: ["tests/cover.sh", "tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
  assert.strictEqual(out.errLines.length, 1, `stderr=${out.res.stderr}`);
  assert.ok(out.errLines[0].startsWith("select-review-scope: header map unavailable: "), out.errLines[0]);
});
test("C10: a staged blob git cat-file reports missing degrades to full, one stderr line", () => {
  // GIT_OBJECT_DIRECTORY → an empty dir: the manifest (diff --cached, ls-files -s) reads only the
  // index and still works, while `git cat-file --batch` answers `<oid> missing` for every staged
  // blob. Set on this one invocation only; the commit-less fixture never needs a tree object.
  const fx = fixture(C7_FILES);
  fx.change("hooks/impl.js", "2;\n");
  const emptyObjects = path.join(TMP, `c10-empty-objects-${seq}`);
  fs.mkdirSync(emptyObjects, { recursive: true });
  const out = runCli(fx, { GIT_OBJECT_DIRECTORY: fwd(emptyObjects) });
  assertRun(out, expectLines(fx, {
    scope: "full", reason: "header-map-unavailable", review: ["tests/cover.sh", "tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
  assert.strictEqual(out.errLines.length, 1, `stderr=${out.res.stderr}`);
  assert.ok(out.errLines[0].startsWith("select-review-scope: header map unavailable: "), out.errLines[0]);
});
test("C13: a tests-only change stays delta/tests-only even when the header map cannot be built", () => {
  // Detail plan step 3: the CLI builds the map whenever a state exists and a test is staged (not
  // lazily), so the one diagnostic line still appears; decideReviewScope's tests-only path never
  // consults the map, so the scope is unaffected.
  const fx = fixture({ "tests/a.sh": shFor("bin/a.sh"), "tests/b.sh": shFor("bin/b.sh"), "tests/c.sh": shFor("bin/c.sh"), "hooks/impl.js": "1;\n" });
  fx.change("tests/a.sh", `${shFor("bin/a.sh")}echo changed\n`);
  const out = runCli(fx, { [ENV_KEY]: fwd(path.join(TMP, "no-such-dir", "bash")) });
  assertRun(out, expectLines(fx, {
    scope: "delta", reason: "tests-only", review: ["tests/a.sh"], inventory: ["tests/b.sh", "tests/c.sh"], source: ["hooks/impl.js"],
  }));
  assert.ok(!out.lines.some((l) => l.includes("header-map-unavailable")), out.res.stdout);
  assert.strictEqual(out.errLines.length, 1, `stderr=${out.res.stderr}`);
  assert.ok(out.errLines[0].startsWith("select-review-scope: header map unavailable: "), out.errLines[0]);
});
test("C8: the same fixture without the override is a delta, and the override never leaked", () => {
  assert.strictEqual(process.env[ENV_KEY], undefined, "C7/C9 set the override on their own invocation only");
  assert.ok(!String(process.env.NODE_OPTIONS || "").includes("c9-malformed-hook"), "C9's NODE_OPTIONS never leaked");
  assert.strictEqual(process.env.GIT_OBJECT_DIRECTORY, undefined, "C10's GIT_OBJECT_DIRECTORY never leaked");
  const fx = fixture(C7_FILES);
  fx.change("hooks/impl.js", "2;\n");
  assertRun(runCli(fx), expectLines(fx, {
    scope: "delta", reason: "impl-changed", review: ["tests/cover.sh"], inventory: ["tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
});
test("C17: two runs on the same fixture print identical output and leave state, index and dirs unchanged", () => {
  const fx = fixture(C7_FILES);
  fx.change("hooks/impl.js", "2;\n");
  const statePath = stateIo.getStatePath(fx.sid);
  const stateDir = path.dirname(statePath);
  const lsFiles = () => {
    const r = spawnSync("git", ["-C", fx.repo, "ls-files", "-s"], { encoding: "utf8", timeout: 30000 });
    assert.strictEqual(r.status, 0, `git ls-files -s: ${r.stderr || r.error}`);
    return r.stdout;
  };
  const listDir = (dir, skip) => fs.readdirSync(dir, { recursive: true }).map(String)
    .filter((p) => !skip || !p.split(/[\\/]/).includes(skip)).sort();
  const before = {
    state: fs.readFileSync(statePath, "utf8"), index: lsFiles(),
    stateDir: listDir(stateDir), repo: listDir(fx.repo, ".git"), tmp: fs.readdirSync(TMP).sort(),
  };
  const want = expectLines(fx, {
    scope: "delta", reason: "impl-changed", review: ["tests/cover.sh"], inventory: ["tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  });
  const first = runCli(fx);
  const second = runCli(fx);
  assertRun(first, want);
  assertRun(second, want);
  assert.strictEqual(second.res.status, first.res.status, "exit status differs between runs");
  assert.strictEqual(second.res.stdout, first.res.stdout, "stdout is not byte-identical between runs");
  assert.strictEqual(fs.readFileSync(statePath, "utf8"), before.state, "the CLI changed the state file");
  assert.strictEqual(lsFiles(), before.index, "the CLI changed the staged index");
  assert.deepStrictEqual(listDir(stateDir), before.stateDir, "the CLI left entries in the session state dir");
  assert.deepStrictEqual(listDir(fx.repo, ".git"), before.repo, "the CLI left entries in the fixture worktree");
  assert.deepStrictEqual(fs.readdirSync(TMP).sort(), before.tmp, "the CLI left entries in the test temp root");
});
caseEnd();

caseBegin("C14-C15-test-dir-and-hook-exit", "bin/select-review-scope.js");
test("C14: a covering test under test/ (not tests/) is selected on the impl path", () => {
  const fx = fixture({ "test/cover.sh": SH_COVER, "tests/u1.sh": shFor("bin/u1.sh"), "test/u2.sh": shFor("bin/u2.sh"), "hooks/impl.js": "1;\n" });
  fx.change("hooks/impl.js", "2;\n");
  assertRun(runCli(fx), expectLines(fx, {
    scope: "delta", reason: "impl-changed", review: ["test/cover.sh"], inventory: ["test/u2.sh", "tests/u1.sh"], source: ["hooks/impl.js"],
  }));
});
test("C15: a header hook that exits 3 degrades to full, exit 0, one stderr line naming the exit", () => {
  // Same seam as C9: the stub fires only on the header-targets script and exits 3 with a stderr note.
  const stub = path.join(TMP, `c15-exit3-hook-${seq + 1}.js`);
  fs.writeFileSync(stub, [
    "if (process.argv.slice(1).some((a) => /review-scope-header-targets\\.sh$/.test(String(a).replace(/\\\\/g, '/')))) {",
    "  try { require('fs').readFileSync(0); } catch (_) {}",
    "  process.stderr.write('stub failure\\n');",
    "  process.exit(3);",
    "}",
  ].join("\n"));
  const fx = fixture(C7_FILES);
  fx.change("hooks/impl.js", "2;\n");
  const out = runCli(fx, { [ENV_KEY]: process.execPath, NODE_OPTIONS: `--require "${fwd(stub)}"` });
  assertRun(out, expectLines(fx, {
    scope: "full", reason: "header-map-unavailable", review: ["tests/cover.sh", "tests/u1.sh", "tests/u2.sh"], source: ["hooks/impl.js"],
  }));
  assert.strictEqual(out.errLines.length, 1, `stderr=${out.res.stderr}`);
  assert.ok(out.errLines[0].startsWith("select-review-scope: header map unavailable: bash exited 3"), out.errLines[0]);
});
caseEnd();
