"use strict";
// Tests: hooks/lib/limited-child-process.js, hooks/lib/limited-child-process/file-stdio.js, hooks/lib/spawn-shimmed-cli.js
// Tags: TL1, scope:issue-specific, hooks, windows, spawn, subprocess
// #3127 the three child_process wrappers hand windowsHide: true to every call, fixed over the caller's value,
// and keep the caller's timeout / env / cwd. child_process is stubbed on its module object before a fresh load,
// so spawn-shimmed-cli's destructured spawnSync binds to the stub; process.platform is pinned per case.
// TL3 gap (what this test does NOT catch):
// - a real child started through these wrappers on Windows from a detached, console-less hook shows no console window.
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: pwsh-required.
const { caseBegin, caseEnd, isolate } = require("../lib/harness");

const assert = require("node:assert");
const childProcess = require("node:child_process");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { after, test } = require("node:test");

const restore = isolate();
const tmpRoot = fs.mkdtempSync(path.join(os.tmpdir(), "wrapper-windowshide-"));
// An armed case registers the decision timing log's exit listener: keep it off ~/.agents, and
// remove the temp root in an exit listener added after it.
process.env.AGENTS_STATE_DIR = tmpRoot;
const fakes = require("./feature-2676-hook-timeout-relation/fake-process");
after(() => { restore(); process.on("exit", () => fs.rmSync(tmpRoot, { recursive: true, force: true })); });

const LIB = path.resolve(__dirname, "..", "..", "hooks", "lib");
const FILES = ["decision-time-limit.js", "limited-child-process.js", path.join("limited-child-process", "file-stdio.js"), "spawn-shimmed-cli.js"];
const FNS = ["spawnSync", "execSync", "execFileSync"];
const okResult = () => ({ status: 0, signal: null, output: [null, "", ""], pid: 1, stdout: "", stderr: "", error: undefined });
const CALLER = { timeout: 1234, env: { WRAPPER_HIDE_PROBE: "1" }, cwd: tmpRoot };

// withStub(fn): fn({ calls, lcp, stdio, shim }) with child_process stubbed and the wrappers loaded fresh.
function withStub(fn) {
  const calls = [];
  const saved = Object.fromEntries(FNS.map((name) => [name, childProcess[name]]));
  for (const name of FNS) {
    childProcess[name] = (...args) => {
      const options = args.slice(1).find((a) => a && typeof a === "object" && !Array.isArray(a)) || {};
      calls.push({ name, args, options });
      return name === "spawnSync" ? okResult() : "";
    };
  }
  try {
    for (const rel of FILES) delete require.cache[path.join(LIB, rel)];
    const load = (rel) => require(path.join(LIB, rel));
    return fn({ calls, lcp: load("limited-child-process.js"), stdio: load(FILES[2]), shim: load("spawn-shimmed-cli.js") });
  } finally { Object.assign(childProcess, saved); }
}

function withPlatform(value, fn) {
  const desc = Object.getOwnPropertyDescriptor(process, "platform");
  Object.defineProperty(process, "platform", { value, configurable: true, enumerable: true, writable: true });
  try { return fn(); } finally { Object.defineProperty(process, "platform", desc); }
}

function withEnv(vars, fn) {
  const saved = Object.fromEntries(Object.keys(vars).map((k) => [k, process.env[k]]));
  Object.assign(process.env, vars);
  try { return fn(); } finally {
    for (const [k, v] of Object.entries(saved)) { if (v === undefined) delete process.env[k]; else process.env[k] = v; }
  }
}

// Each call form: [label, invoke(wrapper)]; the caller's options are `opts` (may be undefined).
const forms = (opts) => [
  ["spawnSync with args", (w) => w.spawnSync("git", ["status"], opts)],
  ["spawnSync without args", (w) => w.spawnSync("git", opts)],
  ["execFileSync with args", (w) => w.execFileSync("git", ["status"], opts)],
  ["execSync", (w) => w.execSync("git status", opts)],
];
const OPTION_SETS = [
  ["caller options", () => ({ ...CALLER })],
  ["caller windowsHide: false", () => ({ ...CALLER, windowsHide: false })],
  ["no options", () => undefined],
];

function assertHidden(calls, label, given) {
  assert.strictEqual(calls.length, 1, `${label}: one child_process call`);
  const got = calls[0].options;
  assert.strictEqual(got.windowsHide, true, `${label}: windowsHide reaches child_process as true`);
  if (given && given.timeout !== undefined) {
    assert.deepStrictEqual([got.timeout, got.env, got.cwd], [given.timeout, given.env, given.cwd], `${label}: timeout / env / cwd kept`);
  }
}

caseBegin("lcp-unarmed-windowshide", "hooks/lib/limited-child-process.js");
test("limited-child-process unarmed: spawnSync / execFileSync / execSync get windowsHide: true, fixed", () => {
  for (const [setLabel, make] of OPTION_SETS) {
    for (const [label] of forms(undefined)) {
      withStub(({ calls, lcp }) => {
        const given = make();
        const call = forms(given).find(([l]) => l === label)[1];
        assert.doesNotThrow(() => call(lcp), `${setLabel} / ${label}`);
        assertHidden(calls, `${setLabel} / ${label}`, given);
      });
    }
  }
});
caseEnd();

caseBegin("lcp-unarmed-omitted-options", "hooks/lib/limited-child-process.js");
test("limited-child-process unarmed: a call with the options argument left out still gets windowsHide: true", () => {
  const omitted = [
    ['spawnSync("git", ["status"])', (w) => w.spawnSync("git", ["status"])],
    ['execFileSync("git", ["status"])', (w) => w.execFileSync("git", ["status"])],
    ['spawnSync("git")', (w) => w.spawnSync("git")],
  ];
  for (const [label, call] of omitted) {
    withStub(({ calls, lcp }) => {
      assert.doesNotThrow(() => call(lcp), label);
      assertHidden(calls, label, undefined);
    });
  }
});
caseEnd();

caseBegin("lcp-armed-windowshide", "hooks/lib/limited-child-process.js");
test("limited-child-process armed: a caller's windowsHide: false still reaches child_process as true", () => {
  for (const [label] of forms(undefined)) {
    withStub(({ calls }) => {
      const fake = fakes.fakeProcess();
      const { modules, error } = fakes.freshRequire(fake, ["decision-time-limit.js", "limited-child-process.js"]);
      assert.ifError(error);
      const limit = modules["decision-time-limit.js"];
      fakes.withFake(fake, () => limit.armDecisionTimeLimit(fakes.armOptions(fake, "example-hook")));
      const given = { cwd: tmpRoot, env: CALLER.env, windowsHide: false };
      const call = forms(given).find(([l]) => l === label)[1];
      const done = fakes.runCaught(fake, () => call(modules["limited-child-process.js"]));
      assert.deepStrictEqual([done.thrown, done.exited], [null, false], `armed / ${label}: ran without asking`);
      assertHidden(calls, `armed / ${label}`, undefined);
    });
  }
});
caseEnd();

caseBegin("file-stdio-windowshide", "hooks/lib/limited-child-process/file-stdio.js");
test("file-stdio: spawnSync / execFileSync / execSync hand windowsHide: true to child_process.spawnSync, fixed", () => {
  const stdioForms = (opts) => [
    ["spawnSync with args", (s) => s.spawnSync("git", ["status"], opts)],
    ["spawnSync without args", (s) => s.spawnSync("git", undefined, opts)],
    ["execFileSync with args", (s) => s.execFileSync("git", ["status"], opts)],
    ["execSync", (s) => s.execSync("git status", undefined, opts)],
  ];
  for (const [setLabel, make] of OPTION_SETS) {
    for (const [label] of stdioForms(undefined)) {
      withStub(({ calls, stdio }) => {
        const given = make();
        const call = stdioForms(given).find(([l]) => l === label)[1];
        assert.doesNotThrow(() => call(stdio), `${setLabel} / ${label}`);
        assert.ok(calls.every((c) => c.name === "spawnSync"), `${label}: every form goes through child_process.spawnSync`);
        assertHidden(calls, `${setLabel} / ${label}`, given);
      });
    }
  }
});
caseEnd();

caseBegin("shimmed-cli-posix-windowshide", "hooks/lib/spawn-shimmed-cli.js");
test("spawn-shimmed-cli off win32: the pass-through spawnSync gets windowsHide: true, fixed", () => {
  for (const [setLabel, make] of OPTION_SETS) {
    withStub(({ calls, shim }) => withPlatform("linux", () => {
      const given = make();
      assert.doesNotThrow(() => shim.spawnShimmedCli("codegraph", ["status"], given), setLabel);
      assert.deepStrictEqual(calls[0] && calls[0].args.slice(0, 2), ["codegraph", ["status"]], `${setLabel}: command and args untouched`);
      assertHidden(calls, setLabel, given);
    }));
  }
});
caseEnd();

caseBegin("shimmed-cli-win32-windowshide", "hooks/lib/spawn-shimmed-cli.js");
test("spawn-shimmed-cli on win32: the .exe and the .cmd-shim launches get windowsHide: true, fixed", () => {
  const dir = path.join(tmpRoot, "shim-bin");
  fs.mkdirSync(path.join(dir, "node_modules", "tool"), { recursive: true });
  fs.writeFileSync(path.join(dir, "direct.exe"), "");
  fs.writeFileSync(path.join(dir, "shimmed.cmd"), '@"%dp0%\\node_modules\\tool\\cli.js" %*\r\n');
  fs.writeFileSync(path.join(dir, "shimmed"), 'exec node "$basedir/node_modules/tool/cli.js" "$@"\n');
  fs.writeFileSync(path.join(dir, "node_modules", "tool", "cli.js"), "");
  const targets = [["direct", path.join(dir, "direct.exe")], ["shimmed", process.execPath]];
  for (const [command, launched] of targets) {
    for (const [setLabel, make] of OPTION_SETS) {
      withStub(({ calls, shim }) => withPlatform("win32", () => withEnv({ PATH: dir, PATHEXT: ".EXE;.CMD" }, () => {
        const given = make();
        const label = `${command} / ${setLabel}`;
        const result = shim.spawnShimmedCli(command, ["status"], given);
        assert.strictEqual(result.error, undefined, `${label}: resolved, not ENOENT`);
        assert.strictEqual(calls[0].args[0], launched, `${label}: launched image`);
        assertHidden(calls, label, given);
      })));
    }
  }
});
caseEnd();
