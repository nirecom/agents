"use strict";
// Tests: bin/workflow/lib/workflow-init/spawn-env.js
// Tags: TL1, scope:issue-specific, windows, spawn, hooks
// #3127 spawn-env builders return windowsHide: true, and every child_process call under hooks/** and bin/**
// (scan: tests/lib/windows-hide-scan.js) guarantees it or is counted in ALLOWLIST. detect-issues.js:24 (node) is
// fixed, no longer NA: node.exe is a console app too. state-io/core/context.js is covered by limited-child-process's
// fixed windowsHide; session-sync/proc.js run() sets it. Path literals avoid the form the outbound scan reads as MSYS.
// TL3 gap (what this test does NOT catch):
// - a real bash/node/git spawned on Windows from a detached, console-less node parent shows no console window.
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: pwsh-required.

const { caseBegin, caseEnd } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const scan = require("../lib/windows-hide-scan");
const { mask, splitTop, spawnCalls, rawWithoutHide } = scan;

const ROOT = path.resolve(__dirname, "..", "..");
const SE = require(path.join(ROOT, "bin/workflow/lib/workflow-init/spawn-env.js"));
const CALLERS = [
  "bin/lib/forge-issue-links.js",
  "bin/workflow/lib/workflow-init/phases/fetch-issues.js",
  "bin/workflow/lib/workflow-init/phases/meta-classify.js",
  "bin/workflow/lib/workflow-init/phases/wip-check.js",
];
// Reviewed exits: file-level counts, no line numbers (they move on every edit).
const ALLOWLIST = [
  { file: "bin/codegraph-lifecycle/process-identity.js", count: 1, reason: "cmd is a variable; the symptom belongs to #2456" },
  { file: "bin/lib/test-wrappers/node.js", count: 1, reason: "foreground CLI with stdio: inherit" },
  { file: "bin/vscode-cc-repair/patch/apply.js", count: 2, reason: "repair CLI run by hand" },
  { file: "bin/run-eslint.d/provision.js", count: 2, reason: "CLI run by hand" },
];
const FIX = "Fix: add windowsHide: true as the last entry of the call's options, or add { file, count, reason } to ALLOWLIST in tests/bin/feature-3127-spawn-env-windowshide.js";

// null when the call forwards the builder's opts untouched; otherwise a reason string.
function checkCall(args, triples) {
  if (args.length !== 3) return "expected 3 args, got " + args.length;
  const t = triples.find(([c, a]) => c === args[0] && a === args[1]);
  if (!t) return "cmd/args not from a builder";
  const opts = t[2], third = args[2];
  if (third === opts) return null;
  const am = /^Object\.assign\s*\(([\s\S]*)\)$/.exec(third);
  if (!am) return "3rd arg is not the builder opts";
  const rest = splitTop(am[1], mask(am[1]));
  if (rest[0] !== "{}" && !/^\{\s*\}$/.test(rest[0])) return "Object.assign target is not {}";
  if (rest[1] !== opts) return "Object.assign does not start from the builder opts";
  if (rest.slice(2).some((r) => !/^\{[\s\S]*\}$/.test(r))) return "extra argument is not an object literal";
  if (rest.slice(2).some((r) => /windowsHide/.test(r))) return "extra argument can override windowsHide";
  return null;
}

caseBegin("gh-windowshide", "bin/workflow/lib/workflow-init/spawn-env.js");
test("buildGhSpawn sets windowsHide true", () => {
  assert.strictEqual(SE.buildGhSpawn(["issue", "view", "1"])[2].windowsHide, true);
});
caseEnd();

caseBegin("git-windowshide", "bin/workflow/lib/workflow-init/spawn-env.js");
test("buildGitSpawn sets windowsHide true", () => {
  assert.strictEqual(SE.buildGitSpawn(["status"])[2].windowsHide, true);
});
caseEnd();

caseBegin("script-windowshide", "bin/workflow/lib/workflow-init/spawn-env.js");
test("buildBashScriptSpawn sets windowsHide true for drive-letter and POSIX paths", () => {
  assert.strictEqual(SE.buildBashScriptSpawn("C:/work/y.sh", ["a"])[2].windowsHide, true);
  assert.strictEqual(SE.buildBashScriptSpawn("/opt/y.sh", ["a"])[2].windowsHide, true);
});
caseEnd();

caseBegin("existing-fields-kept", "bin/workflow/lib/workflow-init/spawn-env.js");
test("existing cmd / args / encoding / env stay unchanged", () => {
  for (const [fn, tool] of [[SE.buildGhSpawn, "gh"], [SE.buildGitSpawn, "git"]]) {
    const [cmd, args, opts] = fn(["x", "y"]);
    assert.strictEqual(cmd, "bash");
    assert.deepStrictEqual(args, ["-c", 'exec "$0" "$@"', tool, "x", "y"]);
    assert.strictEqual(opts.encoding, "utf8");
    assert.strictEqual(opts.env, process.env);
  }
  const [cmd, args, opts] = SE.buildBashScriptSpawn("C:/work/y.sh", ["a"]);
  assert.strictEqual(cmd, "bash");
  assert.deepStrictEqual(args, [["/c", "/work/y.sh"].join(""), "a"]);
  assert.strictEqual(opts.encoding, "utf8");
  assert.strictEqual(opts.env, process.env);
});
caseEnd();

caseBegin("empty-args-windowshide", "bin/workflow/lib/workflow-init/spawn-env.js");
test("empty args arrays still yield windowsHide true", () => {
  assert.strictEqual(SE.buildGhSpawn([])[2].windowsHide, true);
  assert.strictEqual(SE.buildGitSpawn([])[2].windowsHide, true);
  assert.strictEqual(SE.buildBashScriptSpawn("/opt/y.sh", [])[2].windowsHide, true);
});
caseEnd();

caseBegin("callers-pass-builder-opts", "bin/workflow/lib/workflow-init/spawn-env.js");
test("every caller spawnSync passes the builder's opts as 3rd arg (directly or via Object.assign)", () => {
  const destr = /const\s*\[\s*(\w+)\s*,\s*(\w+)\s*,\s*(\w+)\s*\]\s*=\s*build(?:Gh|Git|BashScript)Spawn\(/g;
  for (const rel of CALLERS) {
    const src = fs.readFileSync(path.join(ROOT, rel), "utf8");
    const triples = [...mask(src).matchAll(destr)].map((m) => [m[1], m[2], m[3]]);
    assert.ok(triples.length > 0, rel + ": no builder destructuring found");
    const calls = spawnCalls(src);
    assert.ok(calls.length > 0, rel + ": no spawnSync call found");
    for (const args of calls) assert.strictEqual(checkCall(args, triples), null, rel + ": " + args.join(" , "));
  }
});
caseEnd();

caseBegin("opts-check-negatives", "bin/workflow/lib/workflow-init/spawn-env.js");
test("the opts check rejects multi-line drops and windowsHide overrides, accepts valid forms", () => {
  const T = [["c", "a", "o"]];
  const verdict = (code) => spawnCalls(code).map((x) => checkCall(x, T));
  assert.deepStrictEqual(verdict("spawnSync(c, a, o);"), [null]);
  assert.deepStrictEqual(verdict("spawnSync(\n  c,\n  a,\n  Object.assign({}, o, { input: 'x, ) y', timeout: 1 }),\n);"), [null]);
  assert.notStrictEqual(verdict("spawnSync(\n  c,\n  a,\n  {},\n);")[0], null);
  assert.notStrictEqual(verdict("spawnSync(c, a);")[0], null);
  assert.notStrictEqual(verdict("spawnSync(c, a, Object.assign({}, o, { windowsHide: false }));")[0], null);
  assert.notStrictEqual(verdict("spawnSync(c, a, Object.assign({}, o, { input: 1 }, { windowsHide: false }));")[0], null);
  assert.notStrictEqual(verdict("spawnSync(c, a, Object.assign({}, { timeout: 1 }));")[0], null);
  assert.notStrictEqual(verdict("spawnSync(c, a, Object.assign({}, o, extra));")[0], null);
  assert.deepStrictEqual(verdict("// spawnSync(c, a, {})\nconst s = 'spawnSync(c)';"), []);
  assert.strictEqual(rawWithoutHide("execFileSync(\n  'git',\n  ['status'],\n  { encoding: 'utf8' },\n);").length, 1);
  assert.strictEqual(rawWithoutHide("spawn('bash', ['x'], { windowsHide: true });").length, 0);
  assert.strictEqual(rawWithoutHide("spawnSync(cmd, args, opts);").length, 0);
});
caseEnd();

caseBegin("callers-use-builders","bin/workflow/lib/workflow-init/spawn-env.js");
test("callers take spawn opts from spawn-env builders, no raw bash/gh/git spawn literal", () => {
  for (const rel of CALLERS) {
    const src = fs.readFileSync(path.join(ROOT, rel), "utf8");
    assert.match(src, /require\([^)]*spawn-env"\)/, rel + " must require spawn-env");
    assert.match(src, /\bbuild(?:Gh|Git|BashScript)Spawn\(/, rel + " must call a builder");
    assert.deepStrictEqual(rawWithoutHide(src), [], rel + ": raw spawn without windowsHide");
  }
});
caseEnd();

caseBegin("full-scan-no-violation", "bin/workflow/lib/workflow-init/spawn-env.js");
test("every child_process call under hooks/** and bin/** guarantees windowsHide: true (or is allowlisted)", () => {
  const { violations, stale } = scan.applyAllowlist(scan.scanTree(ROOT), ALLOWLIST);
  const lines = [...violations.map(scan.formatViolation), ...stale];
  assert.strictEqual(lines.length, 0, `${lines.length} windowsHide violation(s):\n${lines.join("\n")}\n${FIX}`);
});
caseEnd();

const C = 'const cp = require("child_process");\n';
const D = 'const { spawnSync, execSync } = require("child_process");\n';
const E = 'const { spawn, execFile, exec, fork } = require("child_process");\n';
// want: violation count; reason: pattern each violation's reason must match; line: first violation's line.
const SCAN_CASES = [
  { name: "builder-direct", code: D + 'const [cmd, args, opts] = buildGhSpawn(["x"]);\nspawnSync(cmd, args, opts);', want: 0 },
  { name: "builder-object-assign", code: D + 'const [cmd, args, opts] = buildGitSpawn(["x"]);\nspawnSync(cmd, args, Object.assign({}, opts, { input: "x" }));', want: 0 },
  { name: "opts-variable", code: D + 'const o = Object.assign({}, { encoding: "utf8" }, { windowsHide: true });\nspawnSync("git", ["x"], o);', want: 0 },
  { name: "forwarding-function-ok", code: D + 'function run(c, a, o) { return spawnSync(c, a, o); }\nconst r = (x && x.run) || run;\nr("git", ["x"], { windowsHide: true });', want: 0 },
  { name: "same-name-local-function", code: C + 'function spawnSync(c, a, o) { return cp.spawnSync(c, a, { ...o, windowsHide: true }); }\nspawnSync("git", ["x"]);', want: 0 },
  { name: "wrapper-spread-then-hide", code: D + "function w(command, args, options) {\n  const spawnOptions = { ...options, windowsHide: true };\n  return spawnSync(command, args, spawnOptions);\n}\nmodule.exports = { w };", want: 0 },
  { name: "wrapper-computed-member", code: C.replace("cp", "childProcess") + "function run(fnName, command, rest) {\n  const options = { ...(rest.options || {}), windowsHide: true };\n  return rest.args === undefined ? childProcess[fnName](command, options) : childProcess[fnName](command, rest.args, options);\n}\nmodule.exports = { run };", want: 0 },
  { name: "exec-second-arg", code: D + 'execSync("git x", { windowsHide: true });', want: 0 },
  { name: "literal-lacks-hide", code: D + 'spawnSync("git", ["x"], { encoding: "utf8" });', want: 1, reason: /^options literal lacks windowsHide: true$/ },
  { name: "no-options-argument", code: D + 'spawnSync("git", ["status"]);', want: 1, reason: /^no options argument$/ },
  { name: "two-args-identifier", code: D + 'spawnSync("git", args);', want: 1, reason: /options identifier args/ },
  { name: "hide-false", code: D + 'spawnSync("git", ["x"], { windowsHide: false });', want: 1, reason: /^windowsHide: false$/ },
  { name: "hide-false-wrapper-caller", code: 'const lcp = require("./limited-child-process");\nlcp.spawnSync("git", ["x"], { windowsHide: false });', want: 1, reason: /^windowsHide: false$/ },
  { name: "opts-variable-lacks-hide", code: D + 'const opts = { encoding: "utf8" };\nspawnSync("git", ["x"], opts);', want: 1, reason: /options identifier opts has no in-file declaration/ },
  { name: "forward-exported", code: D + "function run(c, a, o) { return spawnSync(c, a, o); }\nmodule.exports = { run };", want: 1, reason: /forwarded parameter o of run: exported/ },
  { name: "forward-caller-lacks", code: D + 'function run(c, a, o) { return spawnSync(c, a, o); }\nrun("git", ["x"], { windowsHide: true });\nrun("git", ["y"], { encoding: "utf8" });', want: 1, reason: /forwarded parameter o of run: caller at 4 lacks/ },
  { name: "forward-non-call-reference", code: D + "function run(c, a, o) { return spawnSync(c, a, o); }\nlater(run);", want: 1, reason: /non-call reference/ },
  { name: "computed-member-spread", code: C + "cp[fn](c, ...v);", want: 1, reason: /not analyzable: \.\.\.v/ },
  { name: "inline-require", code: 'require("child_process").execSync("git x");', want: 1, reason: /^no options argument$/ },
  { name: "member-call-lacks-hide", code: C + 'cp.execFileSync("git", ["x"], { cwd: d });', want: 1, reason: /lacks windowsHide/ },
  { name: "order-hide-then-param-spread", code: D + "function go(options) { return spawnSync(c, a, { windowsHide: true, ...options }); }\nmodule.exports = { go };", want: 1, reason: /overridden by later spread \.\.\.options/ },
  { name: "order-param-spread-then-hide", code: D + "function go(options) { return spawnSync(c, a, { ...options, windowsHide: true }); }\nmodule.exports = { go };", want: 0 },
  { name: "order-hide-then-safe-spread", code: D + "const base = { windowsHide: true };\nspawnSync(c, a, { windowsHide: true, ...base });", want: 0 },
  { name: "order-assign-param-last", code: D + "function go(options) { return spawnSync(c, a, Object.assign({}, { windowsHide: true }, options)); }\nmodule.exports = { go };", want: 1, reason: /forwarded parameter options of go: exported/ },
  { name: "order-assign-param-last-callers-hide", code: D + 'function go(options) { return spawnSync(c, a, Object.assign({}, options)); }\ngo({ windowsHide: true });', want: 0 },
  { name: "quoted-key", code: D + 'spawnSync("git", ["x"], { "windowsHide": true });\nspawnSync("git", ["y"], { \'windowsHide\': true });', want: 0 },
  { name: "shorthand-key", code: D + 'const windowsHide = true;\nspawnSync("git", ["x"], { windowsHide });', want: 1, reason: /lacks windowsHide/ },
  { name: "double-declaration-one-lacks", code: D + 'let o = { windowsHide: true };\nif (x) { let o = { encoding: "utf8" }; }\nspawnSync("git", ["x"], o);', want: 1, reason: /options identifier o has no in-file declaration/ },
  { name: "esm-default-import", code: 'import cp from "child_process";\ncp.spawnSync("git", ["x"], {});\ncp.spawnSync("git", ["y"], { windowsHide: true });', want: 1, reason: /lacks windowsHide/, line: 2 },
  { name: "esm-namespace-import", code: 'import * as cp from "node:child_process";\ncp.execFileSync("git", ["x"], {});\ncp.execFileSync("git", ["y"], { windowsHide: true });', want: 1, reason: /lacks windowsHide/, line: 2 },
  { name: "unterminated-block-comment", code: C + '/* open\ncp.spawnSync("git", ["x"], { windowsHide: true });', want: 1, reason: /^scanner cannot parse file/ },
  { name: "division-then-call", code: C + 'const r = a / b / c;\ncp.spawnSync("git", ["x"], {});', want: 1, reason: /lacks windowsHide/, line: 3 },
  { name: "return-regex-then-call", code: C + 'function f() { return /["/]/.test(x); }\ncp.spawnSync("git", ["x"], {});', want: 1, reason: /lacks windowsHide/, line: 3 },
  { name: "order-computed-key", code: D + "spawnSync(c, a, { windowsHide: true, [k]: v });", want: 1, reason: /computed key/ },
  { name: "comment-and-string-ignored", code: C + '// cp.spawnSync("git", ["x"], {});\nconst s = \'cp.spawnSync("git")\';\n/* require("child_process").execSync("x") */', want: 0 },
  { name: "binding-in-comment-ignored", code: '// const { spawnSync } = require("child_process");\nspawnSync("git", ["x"]);', want: 0 },
  { name: "regex-literal-then-call", code: C + "const q = /[`'\"]/;\ncp.spawnSync(\"git\", [\"x\"], {});", want: 1, reason: /lacks windowsHide/, line: 3 },
  { name: "unterminated-template", code: C + "const t = `abc;\ncp.spawnSync('git', ['x'], { windowsHide: true });", want: 1, reason: /^scanner cannot parse file/ },
  { name: "destructured-alias", code: 'const { spawnSync: run } = require("child_process");\nrun("git", ["x"], { cwd: d });', want: 1, reason: /lacks windowsHide/ },
  { name: "esm-import-alias", code: 'import { execFileSync as ef } from "node:child_process";\nef("git", ["x"], {});', want: 1, reason: /lacks windowsHide/ },
  { name: "multi-line-call", code: D + 'spawnSync(\n  "git",\n  ["x"],\n  {\n    encoding: "utf8",\n  },\n);', want: 1, reason: /lacks windowsHide/, line: 2 },
  ...[
    ["spawn", 'spawn("git", ["x"], OPTS);'],
    ["execFile", 'execFile("git", ["x"], OPTS, cb);'],
    ["exec", 'exec("git x", OPTS, cb);'],
    ["fork", 'fork("m.js", ["x"], OPTS);'],
  ].flatMap(([fn, call]) => [
    { name: `${fn}-with-hide`, code: E + call.replace("OPTS", "{ windowsHide: true }"), want: 0 },
    { name: `${fn}-lacks-hide`, code: E + call.replace("OPTS", '{ encoding: "utf8" }'), want: 1, reason: /^options literal lacks windowsHide: true$/, line: 2 },
  ]),
];

caseBegin("false-positive-classes", "bin/workflow/lib/workflow-init/spawn-env.js");
test("builder / opts variable / forwarding function / same-name function: no violation in the real files", () => {
  const clean = [...CALLERS, "bin/workflow/workflow-init-driver", "bin/worker-dispatch/spawn.js", "hooks/protect-user-block/call-guard.js",
    "bin/lib/review-scope-header-targets.js", "hooks/lib/test-gates/parts/external-runtime.js"];
  for (const rel of clean) {
    const got = scan.scanSource(rel, fs.readFileSync(path.join(ROOT, rel), "utf8"));
    assert.deepStrictEqual(got.map(scan.formatViolation), [], rel);
  }
  const stdio = "hooks/lib/limited-child-process/file-stdio.js";
  for (const v of scan.scanSource(stdio, fs.readFileSync(path.join(ROOT, stdio), "utf8"))) {
    assert.match(v.call, /^childProcess\./, `${stdio}: its own spawnSync / execSync / execFileSync are not child_process calls`);
  }
});
caseEnd();

caseBegin("scan-source-table", "bin/workflow/lib/workflow-init/spawn-env.js");
test("scanSource verdicts on inline sources (normal, abnormal, edge)", () => {
  for (const { name, code, want, reason, line } of SCAN_CASES) {
    const got = scan.scanSource("x.js", code);
    assert.strictEqual(got.length, want, `${name}: ${JSON.stringify(got)}`);
    if (reason) for (const v of got) assert.match(v.reason, reason, name);
    if (line) assert.strictEqual(got[0].line, line, `${name}: line`);
  }
});
caseEnd();

caseBegin("allowlist-stale-and-excess", "bin/workflow/lib/workflow-init/spawn-env.js");
test("applyAllowlist: exact count clears, excess stays a violation, shortfall is stale", () => {
  const v = (rel, line) => ({ rel, line, call: "spawnSync(x)", reason: "r" });
  const cases = [
    { name: "exact", vs: [v("a.js", 1), v("a.js", 2)], allow: [{ file: "a.js", count: 2 }], want: [0, 0] },
    { name: "excess", vs: [v("a.js", 1), v("a.js", 2), v("a.js", 3)], allow: [{ file: "a.js", count: 2 }], want: [1, 0] },
    { name: "stale", vs: [v("a.js", 1)], allow: [{ file: "a.js", count: 2 }], want: [0, 1] },
    { name: "missing-file-stale", vs: [v("b.js", 1)], allow: [{ file: "a.js", count: 1 }], want: [1, 1] },
  ];
  for (const { name, vs, allow, want } of cases) {
    const got = scan.applyAllowlist(vs, allow);
    assert.deepStrictEqual([got.violations.length, got.stale.length], want, name);
  }
  assert.deepStrictEqual(scan.applyAllowlist([v("a.js", 1)], [{ file: "a.js", count: 2 }]).stale, ["stale allowlist entry: a.js expects 2, found 1"]);
  assert.strictEqual(scan.formatViolation(v("a.js", 7)), "a.js:7 spawnSync(x) — r");
});
caseEnd();

caseBegin("list-target-files", "bin/workflow/lib/workflow-init/spawn-env.js");
test("listTargetFiles: js/cjs/mjs and node-shebang files under hooks/ and bin/, not bash scripts or node_modules", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "windows-hide-scan-"));
  try {
    const put = (rel, text) => { fs.mkdirSync(path.dirname(path.join(dir, rel)), { recursive: true }); fs.writeFileSync(path.join(dir, rel), text); };
    put("hooks/a.js", ""); put("hooks/b.cjs", ""); put("hooks/c.mjs", ""); put("hooks/readme.md", ""); put("hooks/lib/deep/x.js", "");
    put("hooks/node_modules/x.js", ""); put("bin/.git/y.js", ""); put("other/z.js", "");
    put("bin/tool", "#!/usr/bin/env node\n"); put("bin/tool-sh", "#!/usr/bin/env bash\n"); put("bin/plain", "node\n");
    assert.deepStrictEqual(scan.listTargetFiles(dir), ["bin/tool", "hooks/a.js", "hooks/b.cjs", "hooks/c.mjs", "hooks/lib/deep/x.js"]);
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
caseEnd();

caseBegin("list-target-files-fail-closed", "bin/workflow/lib/workflow-init/spawn-env.js");
test("listTargetFiles / scanTree fail closed: a missing root, a missing top dir, or a file where a dir belongs throws", () => {
  const dir = fs.mkdtempSync(path.join(os.tmpdir(), "windows-hide-scan-"));
  try {
    const cases = [
      ["missing root", path.join(dir, "absent"), path.join(dir, "absent", "hooks")],
      ["missing bin/", path.join(dir, "only-hooks"), path.join(dir, "only-hooks", "bin")],
      ["hooks is a file", path.join(dir, "file-hooks"), path.join(dir, "file-hooks", "hooks")],
    ];
    fs.mkdirSync(path.join(dir, "only-hooks", "hooks"), { recursive: true });
    fs.mkdirSync(path.join(dir, "file-hooks", "bin"), { recursive: true });
    fs.writeFileSync(path.join(dir, "file-hooks", "hooks"), "");
    for (const [name, root, culprit] of cases) {
      for (const fn of [scan.listTargetFiles, scan.scanTree]) {
        assert.throws(() => fn(root), (e) => e.code === "SCAN_UNREADABLE" && e.path === culprit && e.message.includes(culprit), `${name}: ${fn.name}`);
      }
    }
  } finally { fs.rmSync(dir, { recursive: true, force: true }); }
});
caseEnd();
