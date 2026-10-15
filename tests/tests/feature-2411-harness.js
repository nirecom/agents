"use strict";
// Tests: tests/lib/harness.js
// Tags: test-infra, node-test, harness, TL2, scope:issue-specific
// harness.js contract (#2411): isolate, gitInit, xfail, tl3Enabled, caseBegin / caseEnd pairing,
// and loading through the real node wrapper from a copied tree.
// TL3 gap (what this test does NOT catch):
// - a tests/run-all.sh run, where the command guard git and the run-root pin are active
// - a node older than the registry minVersion
// Closest-to-action mitigation: the full tests/run-all.sh run of the release gate;
// no bin/check-verification-gate.sh category covers a test helper library.
const { caseBegin, caseEnd, isolate, gitInit, xfail, tl3Enabled } = require("../lib/harness");

const assert = require("node:assert");
const { spawnSync } = require("node:child_process");
const crypto = require("node:crypto");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, before, describe, test } = require("node:test");

const SCRIPT_CHECKOUT_ROOT = path.resolve(__dirname, "..", "..");
const HELPER = path.join(SCRIPT_CHECKOUT_ROOT, "tests", "lib", "harness.js");
const WRAPPER_REL = "bin/lib/test-wrappers/node.js";
const REGISTRY_FILE = path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "test-language-registry.json");
const PIN_NAMES = ["WORKFLOW_STATE_DIR", "WORKFLOW_PLANS_DIR"];
const REMOVED_NAMES = ["CLAUDE_CODE_SESSION_ID"];
const ISO_NAMES = PIN_NAMES.concat(REMOVED_NAMES);
const SENTINEL = Object.fromEntries(ISO_NAMES.map((n) => [n, `h2411-secret-${crypto.randomUUID()}`]));
const PRESETS = {
  "all set": Object.fromEntries(ISO_NAMES.map((n) => [n, `h2411-${n.toLowerCase()}`])),
  "all unset": {},
  mixed: { WORKFLOW_PLANS_DIR: "h2411-plans", CLAUDE_CODE_SESSION_ID: "h2411-ccsid" },
};
const LOAD_LINE = 'const { caseBegin, caseEnd, isolate, xfail, tl3Enabled } = require("../lib/harness");';
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "h2411-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const freshDir = (prefix) => fs.mkdtempSync(path.join(TMP, `${prefix}-`));
const snapshot = (names) => Object.fromEntries(names.map((n) => [n, process.env[n]]));
const comparable = (p) => (process.platform === "win32" ? fs.realpathSync(p).toLowerCase() : fs.realpathSync(p));
const isInside = (child, parent) => comparable(child).startsWith(comparable(parent) + path.sep);

// Runs fn with the named variables set to preset (absent key = unset); the caller's values come back.
function withEnv(names, preset, fn) {
  const saved = snapshot(names);
  const apply = (values) => {
    for (const n of names) {
      if (values[n] === undefined) delete process.env[n];
      else process.env[n] = values[n];
    }
  };
  apply(preset);
  try {
    return fn();
  } finally {
    apply(saved);
  }
}

// A temp tree shaped like the repo's tests/: tests/<category>/ and tests/lib/ with the real helper.
function makeTree(category) {
  const root = freshDir("tree");
  fs.mkdirSync(path.join(root, "tests", category), { recursive: true });
  fs.mkdirSync(path.join(root, "tests", "lib"));
  fs.copyFileSync(HELPER, path.join(root, "tests", "lib", "harness.js"));
  return root;
}

// One file through the real wrapper, with the registry entry's launch.command.
function runWrapper(testFile, cwd, envExtra = {}) {
  const entries = JSON.parse(fs.readFileSync(REGISTRY_FILE, "utf8")).entries;
  const launch = entries.map((e) => e.launch).find((l) => l && l.wrapper === WRAPPER_REL);
  const values = { "{wrapper}": path.join(SCRIPT_CHECKOUT_ROOT, WRAPPER_REL), "{nativePath}": testFile, "{minVersion}": launch.minVersion.version };
  const resultDir = freshDir("result");
  const env = Object.assign({}, process.env, envExtra, { RUN_ALL_RESULT_DIR: resultDir });
  delete env.NODE_TEST_CONTEXT;
  const argv = launch.command.slice(1).map((a) => (a in values ? values[a] : a));
  const r = spawnSync(process.execPath, argv, { cwd, env, encoding: "utf8", timeout: 100000 });
  const casesFile = path.join(resultDir, "cases.tsv");
  return { status: r.status, output: `${r.stdout}${r.stderr}`, cases: fs.existsSync(casesFile) ? fs.readFileSync(casesFile, "utf8") : null };
}

function writeChild(category, name, lines) {
  const root = makeTree(category);
  const file = path.join(root, "tests", category, name);
  fs.writeFileSync(file, ['"use strict";', LOAD_LINE].concat(lines).join("\n") + "\n");
  return { root, file };
}

describe("isolation", () => {
  for (const [label, preset] of Object.entries(PRESETS)) {
    test(`ISO-enter-restore (${label}): pins both dirs into temp, removes the session variables, restores exactly`, () => {
      withEnv(ISO_NAMES, preset, () => {
        const beforeEnv = snapshot(ISO_NAMES);
        const restore = isolate();
        try {
          for (const n of PIN_NAMES) {
            assert.ok(process.env[n] && process.env[n] !== preset[n], `${n} is re-pointed`);
            assert.ok(fs.statSync(process.env[n]).isDirectory(), `${n} is a directory`);
            assert.ok(isInside(process.env[n], os.tmpdir()), `${n} sits under the temp area`);
          }
          for (const n of REMOVED_NAMES) assert.strictEqual(process.env[n], undefined, `${n} is removed`);
        } finally {
          restore();
        }
        assert.deepStrictEqual(snapshot(ISO_NAMES), beforeEnv);
      });
    });
  }

  test("ISO-fresh: every isolate gets a directory of its own", () => {
    withEnv(ISO_NAMES, {}, () => {
      const first = isolate();
      const firstDir = process.env.WORKFLOW_STATE_DIR;
      first();
      const second = isolate();
      try {
        assert.notStrictEqual(process.env.WORKFLOW_STATE_DIR, firstDir);
      } finally {
        second();
      }
    });
  });

  test("ISO-exception: a restore in finally restores after the body threw", () => {
    withEnv(ISO_NAMES, PRESETS.mixed, () => {
      const beforeEnv = snapshot(ISO_NAMES);
      assert.throws(() => {
        const restore = isolate();
        try {
          throw new Error("body failed");
        } finally {
          restore();
        }
      }, /body failed/);
      assert.deepStrictEqual(snapshot(ISO_NAMES), beforeEnv);
    });
  });

  test("ISO-restore-twice: a second restore neither throws nor disturbs the restored values", () => {
    withEnv(ISO_NAMES, PRESETS.mixed, () => {
      const beforeEnv = snapshot(ISO_NAMES);
      const restore = isolate();
      restore();
      assert.doesNotThrow(() => restore());
      assert.deepStrictEqual(snapshot(ISO_NAMES), beforeEnv);
    });
  });
});

describe("fixture git repo", () => {
  const GIT_NAMES = ["GIT_CONFIG_GLOBAL", "GIT_CONFIG_NOSYSTEM"];
  const saved = snapshot(GIT_NAMES);
  const git = (repo, ...args) => spawnSync("git", ["-C", repo, ...args], { encoding: "utf8", timeout: 60000 });
  const commit = (repo, message) => git(repo, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "-m", message);

  // Plants a failing pre-commit hook, then commits one file. Reports what the repo did.
  function fixtureCommit(repo) {
    const hook = path.join(repo, ".git", "hooks", "pre-commit");
    fs.mkdirSync(path.dirname(hook), { recursive: true });
    fs.writeFileSync(hook, "#!/bin/sh\necho ran > hook-ran.marker\nexit 1\n", { mode: 0o755 });
    fs.writeFileSync(path.join(repo, "tracked.txt"), "x\n");
    fs.writeFileSync(path.join(repo, "ignored.txt"), "x\n");
    const status = git(repo, "status", "--porcelain", "--untracked-files=all").stdout;
    git(repo, "add", "tracked.txt");
    return { commitStatus: commit(repo, "init").status, hookRan: fs.existsSync(path.join(repo, "hook-ran.marker")), status };
  }

  before(() => {
    // A global config whose excludes file would hide ignored.txt, and no system config.
    const gitHome = freshDir("githome");
    const ignoreFile = path.join(gitHome, "global-ignore");
    fs.writeFileSync(ignoreFile, "ignored.txt\n");
    fs.writeFileSync(path.join(gitHome, "gitconfig"), `[core]\n\texcludesFile = ${ignoreFile.replace(/\\/g, "/")}\n`);
    process.env.GIT_CONFIG_GLOBAL = path.join(gitHome, "gitconfig");
    process.env.GIT_CONFIG_NOSYSTEM = "1";
  });
  after(() => {
    for (const n of GIT_NAMES) {
      if (saved[n] === undefined) delete process.env[n];
      else process.env[n] = saved[n];
    }
  });

  test("GIT-control: in a plain git init repo the planted hook fires and the global excludes file applies", () => {
    const repo = path.join(freshDir("control"), "repo");
    assert.strictEqual(spawnSync("git", ["init", "-q", repo], { timeout: 60000 }).status, 0);
    const r = fixtureCommit(repo);
    assert.ok(r.hookRan && r.commitStatus !== 0);
    assert.ok(!r.status.includes("ignored.txt"));
  });

  for (const dirName of ["plain", "with space dir"]) {
    test(`GIT-fixture (${dirName}): no hook runs, the global excludes file does not apply, re-init is harmless`, () => {
      const repo = path.join(freshDir("fixture"), dirName);
      fs.mkdirSync(repo);
      gitInit(repo);
      assert.ok(fs.existsSync(path.join(repo, ".git")));
      const r = fixtureCommit(repo);
      assert.strictEqual(r.commitStatus, 0);
      assert.strictEqual(r.hookRan, false);
      assert.ok(r.status.includes("?? ignored.txt"), r.status);
      const excludes = git(repo, "config", "--local", "--get", "core.excludesFile").stdout.trim();
      assert.ok(excludes, "core.excludesFile is set in the repo config");
      assert.ok(path.resolve(repo, excludes).toLowerCase().startsWith(path.resolve(repo).toLowerCase() + path.sep), "and points inside the repo");

      assert.doesNotThrow(() => gitInit(repo));
      assert.strictEqual(git(repo, "rev-list", "--count", "HEAD").stdout.trim(), "1");
      fs.writeFileSync(path.join(repo, "second.txt"), "y\n");
      git(repo, "add", "second.txt");
      assert.strictEqual(commit(repo, "second").status, 0);
    });
  }
});

describe("known failure, RUN_TL3 gate, case pairing (child runs through the real wrapper)", () => {
  const throwing = 'xfail("still-throws", () => { throw new Error("boom"); });';
  const rejecting = 'xfail("still-rejects", async () => { throw new Error("boom"); });';
  for (const [label, lines, want] of [
    ["block still throws and rejects", [throwing, rejecting], 0],
    ["block stopped throwing", [throwing, 'xfail("stopped-throwing", () => {});'], 1],
    ["block stopped rejecting", [rejecting, 'xfail("stopped-rejecting", async () => {});'], 1],
  ]) {
    test(`XFAIL-child (${label}): wrapper exit ${want}`, () => {
      const { root, file } = writeChild("tests", "known-failure.js", lines);
      const r = runWrapper(file, root);
      assert.strictEqual(r.status, want, r.output);
    });
  }

  test("TL3-in-process: tl3Enabled is false for off and true for on", () => {
    withEnv(["RUN_TL3"], { RUN_TL3: "off" }, () => assert.strictEqual(tl3Enabled(), false));
    withEnv(["RUN_TL3"], { RUN_TL3: "on" }, () => assert.strictEqual(tl3Enabled(), true));
  });

  const begin = (name) => `caseBegin("${name}", "tests/lib/harness.js");`;
  for (const [label, lines, want] of [
    ["paired", [begin("a"), "caseEnd();", begin("b"), "caseEnd();"], 0],
    ["second caseBegin before caseEnd", [begin("a"), begin("b"), "caseEnd();"], 1],
    ["caseEnd without caseBegin", ["caseEnd();"], 1],
    ["unclosed case at process exit", [begin("a"), "caseEnd();", begin("b")], 1],
  ]) {
    test(`PAIR-child (${label}): wrapper exit ${want}`, () => {
      const { root, file } = writeChild("tests", "pairing.js", lines);
      const r = runWrapper(file, root);
      assert.strictEqual(r.status, want, r.output);
    });
  }

  test("EXPORTS: the six parts are functions", () => {
    for (const part of [caseBegin, caseEnd, isolate, gitInit, xfail, tl3Enabled]) assert.strictEqual(typeof part, "function");
  });
});

// caseBegin argument checks, in this process; mirrors A6-A11 of tests/tests/feature-2080-shared-harness.sh.
// The calls are indented and take variables, so the static reader never mistakes them for markers.
describe("caseBegin argument checks", () => {
  // The whole message must match, not a fragment of it.
  const exact = (message) => ({ name: "Error", message });
  // Every rejection leaves no case open: caseEnd() right after must still have nothing to close.
  const nothingOpen = () => assert.throws(() => caseEnd(), exact("caseEnd() without caseBegin()"));

  for (const [label, target, fault] of [
    ["empty target", "", "is empty"],
    ["missing target", undefined, "is empty"],
    ["absolute path", "/etc/passwd", "is absolute"],
    ["UNC path", "//server/share", "is absolute"],
    ["drive letter with backslash", "C:\\foo", "has a drive letter or backslash"],
    ["drive letter with slash", "C:/foo", "has a drive letter or backslash"],
    ["backslash separator", "hooks\\x.js", "has a drive letter or backslash"],
    ["bare ..", "..", "escapes the tree"],
    ["leading ../", "../secret", "escapes the tree"],
    ["inner ../", "a/../../b", "escapes the tree"],
    ["semicolon", "foo;rm -rf /", "has shell metacharacters"],
    ["dollar", "a$b", "has shell metacharacters"],
    ["backtick", "a`b", "has shell metacharacters"],
    ["pipe", "a|b", "has shell metacharacters"],
    ["ampersand", "a&b", "has shell metacharacters"],
    ["redirect >", "a>b", "has shell metacharacters"],
    ["redirect <", "a<b", "has shell metacharacters"],
    ["parentheses", "a(b)", "has shell metacharacters"],
    ["trailing ..", "a/..", "escapes the tree"],
    ["middle ..", "a/../b", "escapes the tree"],
    ["leading ./", "./x", "starts with ./"],
    ["bare .", ".", "starts with ./"],
    ["space", "a b", "has whitespace"],
    ["tab", "a\tb", "has whitespace"],
    ["plus", "a+b", "has a character outside A-Z a-z 0-9 . _ / -"],
    ["asterisk", "a*b", "has a character outside A-Z a-z 0-9 . _ / -"],
    ["non-ASCII letter", "tests/é.js", "has a character outside A-Z a-z 0-9 . _ / -"],
  ]) {
    test(`BEGIN-reject (${label}): target-path ${fault}`, () => {
      assert.throws(() => caseBegin("c", target), exact(`caseBegin("c"): target-path ${fault}`));
      nothingOpen();
    });
  }

  for (const [label, name] of [["empty string", ""], ["missing", undefined]]) {
    test(`BEGIN-reject-name (${label}): name is empty, checked before the target`, () => {
      assert.throws(() => caseBegin(name, "hooks/x.js"), exact("caseBegin: name is empty"));
      assert.throws(() => caseBegin(name, ""), exact("caseBegin: name is empty"));
      nothingOpen();
    });
  }

  test("BEGIN-accept-reset: a valid target opens the case and caseEnd() closes it, so a second caseBegin succeeds", () => {
    const first = "hooks/enforce-worktree.js";
    const second = "tests/lib/harness.js";
    assert.doesNotThrow(() => caseBegin("first", first));
    assert.throws(() => caseBegin("early", second), exact('caseBegin("early") while "first" is still open'));
    assert.doesNotThrow(() => caseEnd());
    assert.doesNotThrow(() => caseBegin("second", second));
    assert.doesNotThrow(() => caseEnd());
    nothingOpen();
  });

  // The reader does not export its target rule, so it reads one generated file per target; a
  // target it calls `malformed ... target` must be one caseBegin rejects, and the reverse.
  test("BEGIN-parity: caseBegin accepts a target exactly when the static case reader does", () => {
    const reader = path.join(SCRIPT_CHECKOUT_ROOT, "bin", "lib", "test-language-parts", "js-case-reader.js");
    const dir = freshDir("parity");
    const targets = [
      "hooks/x.js", "tests/lib/harness.js", "x", "a-b_c.d", ".hidden/x", "a/./b", "a//b", "...", "..foo/bar", "a../b", "a/b/",
      "", "/etc/passwd", "//server/share", "C:\\foo", "C:/foo", "hooks\\x.js", "..", "../secret", "a/../../b", "a/..", "a/../b",
      ".", "./x", "foo;rm -rf /", "a$b", "a`b", "a|b", "a&b", "a>b", "a<b", "a(b)", "a b", "a\tb", "a+b", "a*b", "tests/é.js",
      "a~b", "a@b", "a,b", "a'b",
    ];
    const mismatches = [];
    for (const [i, target] of targets.entries()) {
      const file = path.join(dir, `t${i}.js`);
      const literal = `"${target.replace(/\\/g, "\\\\")}"`;
      fs.writeFileSync(file, `caseBegin("p", ${literal});\ncaseEnd();\n`);
      const r = spawnSync(process.execPath, [reader, file], { encoding: "utf8", timeout: 60000 });
      const verdict = String(r.stdout).split("\n")[0].split("\t");
      assert.ok(verdict[1] === "conforming" || (verdict[1] === "malformed" && verdict[3] === "target"), `reader on ${JSON.stringify(target)}: ${r.stdout}${r.stderr}`);
      // A line that starts with the call would be read as a nested marker, so it never does.
      const begin = () => caseBegin("p", target);
      let accepted = true;
      try {
        begin();
      } catch {
        accepted = false;
      }
      if (accepted) caseEnd();
      if (accepted !== (verdict[1] === "conforming")) mismatches.push(`${JSON.stringify(target)} runtime=${accepted} reader=${verdict[1]}`);
    }
    assert.deepStrictEqual(mismatches, []);
    nothingOpen();
  });
});

// Known failure, in this process: a block that still throws leaves the file green.
xfail("XFAIL-in-process: a throwing block passes", () => {
  throw new Error("known gap");
});

describe("loading through the real wrapper", () => {
  const LOAD_BODY = [
    'const assert = require("node:assert");',
    'const fs = require("node:fs");',
    'const path = require("node:path");',
    'const { test } = require("node:test");',
    'test("calls-helper", () => {',
    "  const restore = isolate();",
    "  try {",
    "    assert.ok(process.env.WORKFLOW_STATE_DIR);",
    "    assert.strictEqual(process.env.CLAUDE_CODE_SESSION_ID, undefined);",
    "  } finally {",
    "    restore();",
    "  }",
    '  fs.writeFileSync(path.join(__dirname, "helper.marker"), "ok");',
    "});",
    'test("tl3-gated", { skip: !tl3Enabled() }, () => {',
    '  fs.writeFileSync(path.join(__dirname, "tl3.marker"), "ok");',
    "});",
  ];
  for (const [category, cwdKind, tl3, gated] of [
    ["bin", "inside", "off", "SKIP"],
    ["tests", "inside", "on", "PASS"],
    ["bin", "outside", "on", "PASS"],
    ["tests", "outside", "off", "SKIP"],
  ]) {
    test(`LOAD (${category}, cwd ${cwdKind}, RUN_TL3 ${tl3}): recorded as a node:test run; the gated case is ${gated}`, () => {
      const { root, file } = writeChild(category, "load.js", LOAD_BODY);
      const r = runWrapper(file, cwdKind === "inside" ? root : freshDir("outside"), Object.assign({ RUN_TL3: tl3 }, SENTINEL));
      assert.strictEqual(r.status, 0, r.output);
      // cases.tsv exists only for a run the wrapper settled as node:test.
      assert.notStrictEqual(r.cases, null, "the wrapper wrote node:test case records");
      assert.match(r.cases, /\tPASS\tcalls-helper\t/);
      assert.match(r.cases, new RegExp(`\\t${gated}\\ttl3-gated\\t`));
      assert.ok(fs.existsSync(path.join(path.dirname(file), "helper.marker")));
      assert.strictEqual(fs.existsSync(path.join(path.dirname(file), "tl3.marker")), tl3 === "on");
      // Security: the removed and restored values never reach the output.
      assert.deepStrictEqual(ISO_NAMES.filter((n) => r.output.includes(SENTINEL[n])), []);
    });
  }

  // <root>/bin/get-config-var: answers value with exitCode, and only to `RUN_TL3 off`.
  function writeTl3Reader(root, value, exitCode) {
    fs.mkdirSync(path.join(root, "bin"));
    const lines = ["#!/usr/bin/env bash", '[ "$1" = RUN_TL3 ] && [ "$2" = off ] || exit 9', `printf '%s\\n' '${value}'`, `exit ${exitCode}`];
    fs.writeFileSync(path.join(root, "bin", "get-config-var"), lines.join("\n") + "\n");
  }
  const TL3_BODY = [
    'const fs = require("node:fs");',
    'const path = require("node:path");',
    'const { test } = require("node:test");',
    'test("tl3-gated", { skip: !tl3Enabled() }, () => {',
    '  fs.writeFileSync(path.join(__dirname, "tl3.marker"), "ok");',
    "});",
  ];
  for (const [label, reader, processValue, gated] of [
    ["reader answers on", ["on", 0], null, "PASS"],
    ["reader answers off", ["off", 0], null, "SKIP"],
    ["no reader", null, null, "SKIP"],
    ["reader fails after answering on", ["on", 3], null, "SKIP"],
    ["reader answers padded mixed case", [" On ", 0], null, "PASS"],
    ["process off over reader on", ["on", 0], "off", "SKIP"],
    ["process on over reader off", ["off", 0], "on", "PASS"],
  ]) {
    // The reader is found from the helper file, not the working directory, and the
    // developer's own RUN_TL3 never reaches the child.
    test(`TL3-resolve (${label}): the gated case is ${gated}`, () => {
      const { root, file } = writeChild("tests", "tl3.js", TL3_BODY);
      if (reader) writeTl3Reader(root, reader[0], reader[1]);
      const extra = processValue === null ? {} : { RUN_TL3: processValue };
      const r = withEnv(["RUN_TL3"], {}, () => runWrapper(file, freshDir("outside"), extra));
      // The gated case is the child's only case, so a skip makes the wrapper answer 77.
      assert.strictEqual(r.status, gated === "PASS" ? 0 : 77, r.output);
      assert.notStrictEqual(r.cases, null, "the wrapper wrote node:test case records");
      assert.match(r.cases, new RegExp(`\\t${gated}\\ttl3-gated\\t`));
      assert.strictEqual(fs.existsSync(path.join(path.dirname(file), "tl3.marker")), gated === "PASS");
    });
  }

  test("NOT-A-TEST: tests/lib/harness.js exists and sits outside every test location", () => {
    assert.ok(fs.statSync(HELPER).isFile());
    const registry = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "lib", "test-language-registry.js"));
    const { isCaseMarkerTarget } = require(path.join(SCRIPT_CHECKOUT_ROOT, "hooks", "block-case-markers.js"));
    const reg = registry.loadRegistry();
    // *.js is not self-identifying, so only the location makes a .js file a test.
    assert.strictEqual(registry.matchesSelfIdentifying("harness.js", reg), false);
    assert.strictEqual(isCaseMarkerTarget("tests/tests/h2411-control.sh", reg), true);
    assert.strictEqual(isCaseMarkerTarget("tests/lib/h2411-control.sh", reg), false);
    assert.strictEqual(isCaseMarkerTarget("tests/lib/harness.js", reg), false);
  });
});
