"use strict";
// Tests: hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js, hooks/lib/test-gates/placement.js, hooks/lib/test-gates/registry.js
// Tags: test-gates, repo-settings, placement, migrate, node-precommit, scope:issue-specific, windows, app-execution-alias
// #2473 — the frontmatter and case marker gates place tests by the repo settings file (.agents.json)
// of the repo being committed, not by the agents repo's fixed category list: flat, by-type and
// by-target fixtures, the support dirs, the covers mismatch WARN and the uninitialized WARN.
// TL3 gap (what this test does NOT catch):
// - #3149: fs.readlinkSync on a real Store pwsh App Execution Alias, and the resolved exe showing no window.
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: pwsh-required.
const { caseBegin, caseEnd, isolate, gitInit } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert/strict");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");
const C = require("./feature-2502-language-match-gate/common");

const restore = isolate();
after(() => restore());

const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "pg2473-"));
after(() => fs.rmSync(ROOT, { recursive: true, force: true }));
const NEUTRAL = path.join(ROOT, "neutral");
fs.mkdirSync(NEUTRAL);
const RUNNER = path.join(C.CHECKOUT, "tests", "lib", "precommit-check-runner.js");
const H = C.make({ ROOT, NEUTRAL, gitInit });

const SW = { testHarness: "on", caseMarker: "on" };
const FLAT = { tests: { categorization: "flat", ...SW } };
const BY_TYPE = {
  tests: { categorization: "by-type", categories: [{ dir: "unit" }, { dir: "e2e" }], supportDirs: ["helpers"], ...SW },
};
const BY_TARGET = {
  tests: {
    categorization: "by-target",
    categories: [{ dir: "hooks", covers: ["hooks"] }, { dir: "bin", covers: ["bin"] }],
    supportDirs: ["lib"],
    ...SW,
  },
};

// repo(settings) — a fixture repo with .agents.json committed at HEAD (none when settings is null).
function repo(settings) {
  return H.mkRepo(settings ? { ".agents.json": JSON.stringify(settings, null, 2) + "\n" } : {});
}

// stage(dir, files) — writes and stages {rel: body}.
function stage(dir, files) {
  for (const [rel, body] of Object.entries(files)) {
    C.writeRel(dir, rel, body);
    C.git(dir, "add", "--", rel);
  }
}

function gate(dir, name) {
  const r = spawnSync(process.execPath, [RUNNER, "--cfg", C.CHECKOUT, "tests-frontmatter", name], {
    cwd: dir, encoding: "utf8", env: process.env, timeout: 180000,
  });
  return { rc: r.status, text: `${r.stdout || ""}\n${r.stderr || ""}` };
}

const ONE = C.bashBody("scope:common", "bin/foo.sh");
const TWO_NO_MARKERS = C.bashBody("scope:common", "bin/foo.sh, bin/bar.sh");
const NO_HARNESS = "#!/usr/bin/env bash\n# Tests: bin/foo.sh\n# Tags: scope:common\necho hi\n";

caseBegin("PG-flat-top-level", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-flat-top-level: a flat repo accepts a new tests/<file> entrypoint", () => {
  const dir = repo(FLAT);
  stage(dir, { "tests/foo.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.ok(!/FLAT_TEST_/.test(r.text), r.text);
});
caseEnd();

caseBegin("PG-by-type-flat-rejected", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-by-type-flat-rejected: a by-type repo rejects tests/<file> and names its own categories", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/foo.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 1, r.text);
  assert.match(r.text, /FLAT_TEST_[A-Z_]*REJECTED/);
  assert.match(r.text, /categories: unit e2e/);
  assert.ok(!/categories: [^\n]*\bskills\b/.test(r.text), `agents categories leaked: ${r.text}`);
});
caseEnd();

caseBegin("PG-by-type-entrypoint", "hooks/lib/test-gates/registry.js");
test("PG-by-type-entrypoint: tests/unit/<file> is an entrypoint, so the harness source is required", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/unit/foo.sh": NO_HARNESS });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 1, r.text);
  assert.match(r.text, /MISSING_HARNESS_SOURCE: tests\/unit\/foo\.sh/);
});
caseEnd();

caseBegin("PG-support-dir", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-support-dir: a file under a configured support dir is not checked as a test", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/helpers/common.sh": "#!/usr/bin/env bash\necho helper\n" });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.ok(!/MISSING_TESTS_HEADER/.test(r.text), r.text);
});
caseEnd();

caseBegin("PG-by-type-case-markers", "hooks/lib/test-gates/placement.js");
test("PG-by-type-case-markers: tests/unit/<file> is a case-marker placement; a support file is not", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/unit/two.sh": TWO_NO_MARKERS });
  const r = H.runPrecommitCaseMarkers(dir);
  const text = `${r.stdout}\n${r.stderr}`;
  assert.equal(r.rc, 1, text);
  assert.match(text, /MISSING_CASE_MARKERS/);
  const dir2 = repo(BY_TYPE);
  stage(dir2, { "tests/helpers/two.sh": TWO_NO_MARKERS });
  const r2 = H.runPrecommitCaseMarkers(dir2);
  assert.equal(r2.rc, 0, `${r2.stdout}\n${r2.stderr}`);
});
caseEnd();

caseBegin("PG-covers-mismatch-warn", "hooks/lib/test-gates/registry.js");
test("PG-covers-mismatch-warn: by-target warns (never blocks) when Tests: is outside the category's covers", () => {
  const dir = repo(BY_TARGET);
  stage(dir, { "tests/hooks/feature-1-x.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  assert.match(r.text, /code=TEST_CATEGORY_MISMATCH/);
  assert.match(r.text, /tests\/hooks\/feature-1-x\.sh/);
  const dir2 = repo(BY_TARGET);
  stage(dir2, { "tests/bin/feature-1-x.sh": ONE });
  const r2 = gate(dir2, "frontmatter");
  assert.equal(r2.rc, 0, r2.text);
  assert.ok(!/TEST_CATEGORY_MISMATCH/.test(r2.text), r2.text);
});
caseEnd();

caseBegin("PG-uninitialized-warn-once", "hooks/lib/test-gates/registry.js");
test("PG-uninitialized-warn-once: no .agents.json → not blocked, one REPO_SETTINGS_UNINITIALIZED WARN", () => {
  const dir = repo(null);
  stage(dir, { "tests/unit/a.sh": ONE, "tests/unit/b.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 0, r.text);
  const n = (r.text.match(/REPO_SETTINGS_UNINITIALIZED/g) || []).length;
  assert.equal(n, 1, r.text);
});
caseEnd();

// cfgWith(name, edit) — a copy of the checkout's hooks/ whose registry table `edit(table)` has altered.
function cfgWith(name, edit) {
  const cfg = path.join(ROOT, name);
  for (const sub of ["bin", "hooks", "skills", "docs"]) fs.cpSync(path.join(C.CHECKOUT, sub), path.join(cfg, sub), { recursive: true });
  const file = path.join(cfg, "hooks", "lib", "test-language-registry.json");
  const table = JSON.parse(fs.readFileSync(file, "utf8"));
  edit(table);
  fs.writeFileSync(file, `${JSON.stringify(table, null, 2)}\n`);
  return cfg;
}

// gateWith(cfg, dir) — the frontmatter gate of the cfg copy over dir's index.
function gateWith(cfg, dir) {
  const r = spawnSync(process.execPath, [RUNNER, "--cfg", cfg, "tests-frontmatter", "frontmatter"], {
    cwd: dir, encoding: "utf8", env: process.env, timeout: 180000,
  });
  return { rc: r.status, text: `${r.stdout || ""}\n${r.stderr || ""}` };
}

const firstSupported = (table) => table.entries.find((e) => e.status === "supported");

caseBegin("PG-flat-example-default-shape", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-flat-example-default-shape: the real registry (bash first) keeps the example tests/unit/<name>.sh", () => {
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/foo.sh": ONE });
  const r = gate(dir, "frontmatter");
  assert.equal(r.rc, 1, r.text);
  assert.ok(r.text.includes("e.g. tests/unit/<name>.sh."), r.text);
});
caseEnd();

caseBegin("PG-flat-example-follows-registry-shape", "hooks/pre-commit.d/checks/tests-frontmatter/frontmatter-gate.js");
test("PG-flat-example-follows-registry-shape: the example is built from the first supported entry's newFileNameShape", () => {
  const cfg = cfgWith("cfg-shape", (t) => { firstSupported(t).newFileNameShape = "<name>.alt.sh"; });
  const dir = repo(BY_TYPE);
  stage(dir, { "tests/foo.sh": ONE });
  const r = gateWith(cfg, dir);
  assert.equal(r.rc, 1, r.text);
  assert.ok(r.text.includes("e.g. tests/unit/<name>.alt.sh."), r.text);
  assert.ok(!r.text.includes("<name>.sh."), `old fixed example leaked: ${r.text}`);
});
caseEnd();

// #3149 — which(tool, env, deps) resolves a Windows App Execution Alias to its versioned exe. A fixture
// cannot make a real alias, so deps fake lstat / readlink (and stat for non-local Windows paths).
const REGISTRY = require(path.resolve(__dirname, "..", "..", "hooks", "lib", "test-gates", "registry.js"));
const AX = path.join(ROOT, "alias");
const norm = (p) => (p === null ? null : String(p).replace(/\\/g, "/").toLowerCase());
const put = (dir, name) => { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, name), ""); return path.join(dir, name); };
const PKG = (v) => path.join(AX, "Program Files", "WindowsApps", `Microsoft.PowerShell_${v}_x64__8wekyb3d8bbwe`);
const ALIAS_DIR = path.join(AX, "Local", "Microsoft", "WindowsApps");
const ALIAS = put(ALIAS_DIR, "pwsh");
const REAL = put(PKG("7.5.4.0"), "pwsh");
const REAL_OLD = put(PKG("7.5.3.0"), "pwsh");
const SHIM_DIR = path.join(AX, "shims");
const SHIM = put(SHIM_DIR, "node");
const FNM_NODE = put(path.join(AX, "fnm", "v20"), "node");
const LOOKALIKE = put(path.join(AX, "MyWindowsAppsX", "pkg"), "pwsh");
const PLAIN_DIR = path.join(AX, "plain");
const PLAIN = put(PLAIN_DIR, "pwsh");
const WIN_TARGET = "C:\\Program Files\\WindowsApps\\Microsoft.PowerShell_7.5.4.0_x64__8wekyb3d8bbwe\\pwsh.exe";

// fake(links, opts) — deps: lstat calls each links key a symlink (or not, with symlink: false), readlink
// returns its value (a function is called per read, an Error is thrown), stat is real except fakeFiles.
function fake(links, { platform = "win32", fakeFiles = [], symlink = true } = {}) {
  const keyed = new Map(Object.entries(links).map(([k, v]) => [norm(k), v]));
  const files = new Set(fakeFiles.map(norm));
  return {
    platform,
    lstat: (p) => (keyed.has(norm(p)) ? { isSymbolicLink: () => symlink } : fs.lstatSync(p)),
    readlink: (p) => {
      const v = keyed.get(norm(p));
      if (v === undefined) return fs.readlinkSync(p);
      if (v instanceof Error) throw v;
      return typeof v === "function" ? v() : v;
    },
    stat: (p) => (files.has(norm(p)) ? { isFile: () => true } : fs.statSync(p)),
  };
}

// look(tool, dirs, deps) — which() over an explicit PATH (never the ambient one); asserts path-or-null.
function look(tool, dirs, deps) {
  const got = REGISTRY.which(tool, { PATH: dirs.join(path.delimiter) }, deps);
  assert.ok(got === null || typeof got === "string", `which returned ${typeof got}`);
  return norm(got);
}

caseBegin("ALIAS-resolves-to-package-exe", "hooks/lib/test-gates/registry.js");
test("ALIAS-resolves-to-package-exe: an alias first on PATH resolves to the WindowsApps exe, also when that exe is second", () => {
  const deps = fake({ [ALIAS]: REAL });
  assert.equal(look("pwsh", [ALIAS_DIR], deps), norm(REAL));
  assert.equal(look("pwsh", [ALIAS_DIR, PKG("7.5.4.0")], deps), norm(REAL));
  assert.equal(look("pwsh", [PKG("7.5.4.0"), ALIAS_DIR], deps), norm(REAL));
});
caseEnd();

caseBegin("ALIAS-resolved-per-call", "hooks/lib/test-gates/registry.js");
test("ALIAS-resolved-per-call: a Store update between two calls changes the resolved version", () => {
  let target = REAL_OLD;
  const deps = fake({ [ALIAS]: () => target });
  assert.equal(look("pwsh", [ALIAS_DIR], deps), norm(REAL_OLD));
  target = REAL;
  assert.equal(look("pwsh", [ALIAS_DIR], deps), norm(REAL));
});
caseEnd();

caseBegin("ALIAS-readlink-fails-keeps-alias", "hooks/lib/test-gates/registry.js");
test("ALIAS-readlink-fails-keeps-alias: a readlink that throws returns the alias itself, never null or a throw", () => {
  const err = Object.assign(new Error("EINVAL: invalid argument, readlink"), { code: "EINVAL" });
  assert.equal(look("pwsh", [ALIAS_DIR], fake({ [ALIAS]: err })), norm(ALIAS));
});
caseEnd();

caseBegin("ALIAS-target-rejected", "hooks/lib/test-gates/registry.js");
test("ALIAS-target-rejected: a missing, non-file, relative, non-WindowsApps or look-alike target keeps the alias", () => {
  const rel = "WindowsApps/Microsoft.PowerShell_7.5.4.0_x64__8wekyb3d8bbwe/pwsh.exe";
  const cases = [
    ["missing", path.join(PKG("7.5.4.0"), "missing.exe"), []],
    ["directory", PKG("7.5.4.0"), []],
    ["relative", rel, [rel]],
    ["no-WindowsApps", FNM_NODE, []],
    ["look-alike MyWindowsAppsX", LOOKALIKE, []],
  ];
  for (const [name, target, fakeFiles] of cases) {
    assert.equal(look("pwsh", [ALIAS_DIR], fake({ [ALIAS]: target }, { fakeFiles })), norm(ALIAS), name);
  }
});
caseEnd();

caseBegin("ALIAS-classifier-non-alias-kept", "hooks/lib/test-gates/registry.js");
test("ALIAS-classifier-non-alias-kept: a shim symlink, a plain file and a non-win32 platform return the candidate", () => {
  assert.equal(look("node", [SHIM_DIR], fake({ [SHIM]: FNM_NODE })), norm(SHIM));
  assert.equal(look("pwsh", [PLAIN_DIR], fake({ [PLAIN]: REAL }, { symlink: false })), norm(PLAIN));
  for (const platform of ["linux", "darwin"]) {
    assert.equal(look("pwsh", [ALIAS_DIR], fake({ [ALIAS]: REAL }, { platform })), norm(ALIAS), platform);
  }
});
caseEnd();

caseBegin("ALIAS-windows-separators", "hooks/lib/test-gates/registry.js");
test("ALIAS-windows-separators: a WindowsApps element is found in \\ and / targets, case-insensitively", () => {
  for (const target of [WIN_TARGET, WIN_TARGET.replace(/\\/g, "/"), WIN_TARGET.toLowerCase()]) {
    assert.equal(look("pwsh", [ALIAS_DIR], fake({ [ALIAS]: target }, { fakeFiles: [target] })), norm(target), target);
  }
});
caseEnd();

caseBegin("ALIAS-edge-null-and-order", "hooks/lib/test-gates/registry.js");
test("ALIAS-edge-null-and-order: no tool or an empty PATH is null; .exe / .cmd / bare order is unchanged", () => {
  for (const deps of [undefined, fake({}, { platform: process.platform })]) {
    assert.equal(look("no-such-tool-3149", [ALIAS_DIR, PLAIN_DIR], deps), null);
    assert.equal(look("pwsh", [], deps), null);
    assert.equal(REGISTRY.which("pwsh", {}, deps), null);
    const dir = path.join(AX, `ext-${deps ? "fake" : "default"}`);
    const [exe, cmd, bare] = ["pwsh.exe", "pwsh.cmd", "pwsh"].map((n) => put(dir, n));
    if (process.platform === "win32") {
      assert.equal(look("pwsh", [dir], deps), norm(exe));
      fs.rmSync(exe);
      assert.equal(look("pwsh", [dir], deps), norm(cmd));
      fs.rmSync(cmd);
    }
    assert.equal(look("pwsh", [dir], deps), norm(bare));
  }
});
caseEnd();

caseBegin("ALIAS-path-order-unchanged", "hooks/lib/test-gates/registry.js");
test("ALIAS-path-order-unchanged: the first PATH hit wins — a leading alias resolves, a leading plain exe beats a later alias", () => {
  const deps = fake({ [ALIAS]: REAL });
  assert.notEqual(norm(PLAIN), norm(REAL));
  assert.equal(look("pwsh", [PLAIN_DIR, ALIAS_DIR], deps), norm(PLAIN));
  assert.equal(look("pwsh", [ALIAS_DIR, PLAIN_DIR], deps), norm(REAL));
});
caseEnd();

caseBegin("ALIAS-default-deps-real-fs", "hooks/lib/test-gates/registry.js");
test("ALIAS-default-deps-real-fs: which(tool, env) with no deps resolves a real WindowsApps symlink on win32 only", (t) => {
  const base = fs.mkdtempSync(path.join(os.tmpdir(), "alias3149-"));
  t.after(() => fs.rmSync(base, { recursive: true, force: true }));
  const real = put(path.join(base, "Program Files", "WindowsApps", "Microsoft.PowerShell_7.5.4.0_x64__8wekyb3d8bbwe"), "pwsh.exe");
  const linkDir = path.join(base, "Local", "Microsoft", "WindowsApps");
  fs.mkdirSync(linkDir, { recursive: true });
  const link = path.join(linkDir, process.platform === "win32" ? "pwsh.exe" : "pwsh");
  try {
    fs.symlinkSync(real, link, "file");
  } catch (err) {
    if (err.code !== "EPERM" && err.code !== "EACCES") throw err;
    // SKIPPED: default-deps wiring over a real symlink
    // Because: this host denies symlink creation (no Developer Mode / privilege)
    t.skip(`symlink not permitted (${err.code})`);
    return;
  }
  const got = REGISTRY.which("pwsh", { PATH: linkDir });
  assert.equal(norm(got), norm(process.platform === "win32" ? real : link));
});
caseEnd();
