"use strict";
// tests/install/feature-2303-deployed-sources.js
// Tests: install/deployed-sources.txt, install/lib/settings-assembly.js
// Tags: scope:issue-specific, TL2, install, settings, deployed-sources, ssot, fail-closed, pwsh-not-required
// #2303: install/deployed-sources.txt declares every install/-external source the installers copy or
// assemble; settings-assembly.js derives BASE_REL / EXT_REL from it and fails closed without it.
// Module cases copy settings-assembly.js into a temp tree (module-relative read), never the real installer.
// TL3 gap: the real install.sh / install.ps1 run through dotfileslink is not exercised; checked at
// WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: installer.

const { caseBegin, caseEnd } = require("../lib/harness");
const { test, after } = require("node:test");
const assert = require("node:assert");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const { spawnSync } = require("node:child_process");

const ROOT = path.resolve(__dirname, "..", "..");
const DECL = path.join(ROOT, "install", "deployed-sources.txt");
const ASSEMBLY = path.join(ROOT, "install", "lib", "settings-assembly.js");
const TMP = fs.mkdtempSync(path.join(os.tmpdir(), "f2303-"));
after(() => fs.rmSync(TMP, { recursive: true, force: true }));

const EXPORTS = ["BASE_REL", "DEFAULT_ROOT", "EXT_REL", "GenError", "buildAssembledSettings", "deployedSettingsPath", "mergeSettings"];
const SYMLINK_DEPLOYED = (p) => p === "CLAUDE.md" || /^(rules|skills|agents)\//.test(p);

// parseDecl(text) -> [{role, rel, kind}] for every non-blank, non-# line.
function parseDecl(text) {
  return text.split(/\r?\n/).map((l) => l.trim()).filter((l) => l && !l.startsWith("#"))
    .map((l) => { const [role, rel, kind, ...rest] = l.split(/\s+/); return { role, rel, kind, rest }; });
}
const readDecl = () => { try { return fs.readFileSync(DECL, "utf8"); } catch { return null; } };

// fixtureTree(name, decl) — a temp checkout holding a copy of install/lib/*.js; decl === null
// writes no declaration file. Returns the tree root.
function fixtureTree(name, decl) {
  const dir = path.join(TMP, name);
  fs.mkdirSync(path.join(dir, "install", "lib"), { recursive: true });
  for (const f of fs.readdirSync(path.dirname(ASSEMBLY)).filter((n) => n.endsWith(".js"))) {
    fs.copyFileSync(path.join(path.dirname(ASSEMBLY), f), path.join(dir, "install", "lib", f));
  }
  if (decl !== null) fs.writeFileSync(path.join(dir, "install", "deployed-sources.txt"), decl);
  return dir;
}

// probe(dir, files) — writes files into dir, then in a child node: require the copied module and
// build from dir. Prints JSON {ok, base, ext, allow} or {threw, name, message}.
function probe(dir, files) {
  for (const [rel, body] of Object.entries(files || {})) fs.writeFileSync(path.join(dir, rel), body);
  const script = [
    "const path = require('path');",
    "const dir = process.argv[1];",
    "try {",
    "  const a = require(path.join(dir, 'install', 'lib', 'settings-assembly.js'));",
    "  const s = a.buildAssembledSettings({ agentsRoot: dir }).settings;",
    "  console.log(JSON.stringify({ ok: true, base: a.BASE_REL, ext: a.EXT_REL, allow: s.permissions.allow }));",
    "} catch (e) { console.log(JSON.stringify({ threw: true, name: e && e.name, message: String(e && e.message) })); }",
  ].join("\n");
  const done = spawnSync(process.execPath, ["-e", script, dir], { encoding: "utf8", timeout: 30000, cwd: dir });
  try { return JSON.parse(String(done.stdout).trim()); } catch { return { unparsable: String(done.stdout) + String(done.stderr) }; }
}

const BASE_DOC = JSON.stringify({ permissions: { allow: ["Bash(fx-base *)"], deny: [] } });
const EXT_DOC = JSON.stringify({ permissions: { allow: ["Bash(fx-ext *)"] } });

caseBegin("declaration-format", "install/deployed-sources.txt");
test("declaration-format: every entry is <role> <path> <required|optional> with unique roles", () => {
  const text = readDecl();
  assert.notStrictEqual(text, null, `missing: ${DECL}`);
  const entries = parseDecl(text);
  assert.ok(entries.length > 0, "no entries");
  for (const e of entries) {
    assert.ok(e.role && e.rel && e.kind && e.rest.length === 0, `malformed entry: ${JSON.stringify(e)}`);
    assert.ok(e.kind === "required" || e.kind === "optional", `bad kind: ${e.kind}`);
    assert.ok(!path.isAbsolute(e.rel) && !e.rel.split("/").includes(".."), `path escapes the repo: ${e.rel}`);
  }
  const roles = entries.map((e) => e.role);
  assert.strictEqual(new Set(roles).size, roles.length, `duplicate role: ${roles.join(",")}`);
});
caseEnd();

caseBegin("declaration-settings-roles", "install/deployed-sources.txt");
test("declaration-settings-roles: settings-base -> settings.json required, settings-extension -> settings-extension.json optional", () => {
  const entries = parseDecl(readDecl() || "");
  const byRole = Object.fromEntries(entries.map((e) => [e.role, e]));
  assert.deepStrictEqual(byRole["settings-base"] && [byRole["settings-base"].rel, byRole["settings-base"].kind], ["settings.json", "required"]);
  assert.deepStrictEqual(byRole["settings-extension"] && [byRole["settings-extension"].rel, byRole["settings-extension"].kind], ["settings-extension.json", "optional"]);
});
caseEnd();

caseBegin("declaration-required-paths-exist", "install/deployed-sources.txt");
test("declaration-required-paths-exist: every required path exists; optional paths are not required to", () => {
  const entries = parseDecl(readDecl() || "");
  assert.ok(entries.some((e) => e.kind === "required"), "no required entry");
  for (const e of entries.filter((x) => x.kind === "required")) {
    assert.ok(fs.existsSync(path.join(ROOT, e.rel)), `required path missing in the checkout: ${e.rel}`);
  }
});
caseEnd();

caseBegin("declaration-scope", "install/deployed-sources.txt");
test("declaration-scope: no symlink-deployed target and no install/ path", () => {
  const entries = parseDecl(readDecl() || "");
  assert.ok(entries.length > 0, "no entries");
  for (const e of entries) {
    assert.ok(!SYMLINK_DEPLOYED(e.rel), `symlink-deployed target listed: ${e.rel}`);
    assert.ok(!e.rel.startsWith("install/"), `install/ path listed (Stage C already covers install/): ${e.rel}`);
  }
});
caseEnd();

caseBegin("assembly-real-declaration", "install/lib/settings-assembly.js");
test("assembly-real-declaration: the checkout's module resolves settings.json / settings-extension.json", () => {
  const a = require(ASSEMBLY);
  assert.strictEqual(a.BASE_REL, "settings.json");
  assert.strictEqual(a.EXT_REL, "settings-extension.json");
});
caseEnd();

caseBegin("assembly-derives-from-declaration", "install/lib/settings-assembly.js");
test("assembly-derives-from-declaration: BASE_REL / EXT_REL and the merge follow the declared paths", () => {
  const decl = ["# fixture declaration", "", "settings-base alt-base.json required", "settings-extension alt-ext.json optional", ""].join("\n");
  const dir = fixtureTree("derive", decl);
  const got = probe(dir, { "alt-base.json": BASE_DOC, "alt-ext.json": EXT_DOC });
  assert.deepStrictEqual(got, { ok: true, base: "alt-base.json", ext: "alt-ext.json", allow: ["Bash(fx-base *)", "Bash(fx-ext *)"] });
});
caseEnd();

caseBegin("assembly-ignores-comment-lines", "install/lib/settings-assembly.js");
test("assembly-ignores-comment-lines: a # line naming a role is not an entry", () => {
  const decl = ["#settings-base commented.json required", "# settings-extension commented-ext.json optional",
    "settings-base real-base.json required", "settings-extension real-ext.json optional"].join("\n");
  const dir = fixtureTree("comments", decl);
  const got = probe(dir, { "real-base.json": BASE_DOC });
  assert.deepStrictEqual(got, { ok: true, base: "real-base.json", ext: "real-ext.json", allow: ["Bash(fx-base *)"] });
});
caseEnd();

caseBegin("assembly-optional-extension-absent", "install/lib/settings-assembly.js");
test("assembly-optional-extension-absent: a declared optional extension that does not exist merges as {}", () => {
  const decl = ["settings-base settings.json required", "settings-extension settings-extension.json optional"].join("\n");
  const dir = fixtureTree("ext-absent", decl);
  const got = probe(dir, { "settings.json": BASE_DOC });
  assert.deepStrictEqual(got, { ok: true, base: "settings.json", ext: "settings-extension.json", allow: ["Bash(fx-base *)"] });
});
caseEnd();

caseBegin("assembly-crlf-declaration", "install/lib/settings-assembly.js");
test("assembly-crlf-declaration: a CRLF declaration resolves both roles without a GenError", () => {
  const decl = ["# fixture declaration", "settings-base crlf-base.json required", "settings-extension crlf-ext.json optional", ""].join("\r\n");
  const dir = fixtureTree("crlf", decl);
  const got = probe(dir, { "crlf-base.json": BASE_DOC, "crlf-ext.json": EXT_DOC });
  assert.deepStrictEqual(got, { ok: true, base: "crlf-base.json", ext: "crlf-ext.json", allow: ["Bash(fx-base *)", "Bash(fx-ext *)"] });
});
caseEnd();

caseBegin("assembly-fail-closed", "install/lib/settings-assembly.js");
const failClosed = [
  { name: "declaration-missing", decl: null },
  { name: "settings-base-role-missing", decl: "settings-extension settings-extension.json optional\n" },
  { name: "settings-extension-role-missing", decl: "settings-base settings.json required\n" },
  { name: "only-comments", decl: "# settings-base settings.json required\n# settings-extension settings-extension.json optional\n" },
];
for (const { name, decl } of failClosed) {
  test(`assembly-fail-closed: ${name} throws instead of falling back`, () => {
    const dir = fixtureTree(`fc-${name}`, decl);
    const got = probe(dir, { "settings.json": BASE_DOC, "settings-extension.json": EXT_DOC });
    assert.strictEqual(got.threw, true, `${name}: expected a throw, got ${JSON.stringify(got)}`);
    assert.strictEqual(got.name, "GenError", `${name}: expected GenError, got ${got.name}: ${got.message}`);
  });
}
caseEnd();

caseBegin("assembly-malformed-line-fails-closed", "install/lib/settings-assembly.js");
const ROLE_EXT = "settings-extension settings-extension.json optional\n";
const malformed = [
  { name: "parent-segment", line: "settings-base ../settings.json required" },
  { name: "posix-absolute", line: "settings-base /etc/settings.json required" },
  { name: "drive-absolute", line: "settings-base C:/xy/settings.json required" },
  { name: "embedded-parent-segment", line: "settings-base sub/../../x.json required" },
  { name: "bad-kind", line: "settings-base settings.json maybe" },
  { name: "path-missing", line: "settings-base" },
];
for (const { name, line } of malformed) {
  test(`assembly-malformed-line-fails-closed: ${name} throws GenError`, () => {
    const dir = fixtureTree(`mal-${name}`, `${line}\n${ROLE_EXT}`);
    const got = probe(dir, { "settings.json": BASE_DOC, "settings-extension.json": EXT_DOC });
    assert.strictEqual(got.threw, true, `${name}: expected a throw, got ${JSON.stringify(got)}`);
    assert.strictEqual(got.name, "GenError", `${name}: expected GenError, got ${got.name}: ${got.message}`);
  });
}
test("assembly-malformed-line-fails-closed: positive control loads", () => {
  const dir = fixtureTree("mal-control", `settings-base settings.json required\n${ROLE_EXT}`);
  const got = probe(dir, { "settings.json": BASE_DOC, "settings-extension.json": EXT_DOC });
  assert.strictEqual(got.ok, true, JSON.stringify(got));
  assert.strictEqual(got.base, "settings.json");
});
caseEnd();

caseBegin("assembly-exports-unchanged","install/lib/settings-assembly.js");
test("assembly-exports-unchanged: export names stay, and settings-deploy / settings-drift still load against them", () => {
  const a = require(ASSEMBLY);
  assert.deepStrictEqual(Object.keys(a).sort(), EXPORTS);
  const d = require(path.join(ROOT, "install", "lib", "settings-deploy.js"));
  assert.strictEqual(d.GenError, a.GenError);
  assert.strictEqual(typeof d.deployAssembledSettings, "function");
  const drift = require(path.join(ROOT, "hooks", "lib", "settings-drift.js"));
  assert.strictEqual(typeof drift.detectDrift, "function");
});
caseEnd();
