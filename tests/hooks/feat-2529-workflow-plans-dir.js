#!/usr/bin/env node
"use strict";
// Tests: hooks/lib/workflow-plans-dir.js
// Tags: TL2, hooks, workflow-plans-dir, windows-path, absolute-path, default-path, scope:issue-specific
// #2529: getWorkflowPlansDir() trims WORKFLOW_PLANS_DIR, rejects a relative value, and turns a
// Git Bash `/c/...` value into `C:\...` on win32, so a containment check run against the plans
// dir accepts the `C:\` form of a file inside it. Every row runs the real module in a fresh
// node process (spawnSync + env), so the module-level .env load and the lazy branch-diff
// require are exercised exactly as a hook process meets them.

// TL3 gap: a real Git Bash session exporting WORKFLOW_PLANS_DIR into a live hook is not driven.

require("../lib/harness");
const { spawnSync } = require("child_process");
const os = require("os");
const path = require("path");

const ROOT = path.resolve(__dirname, "..", "..");
const PLANS_DIR_MOD = path.join(ROOT, "hooks", "lib", "workflow-plans-dir.js");
const PLAN_LANG_MOD = path.join(ROOT, "hooks", "lib", "plan-artifact-lang.js");
const WIN = process.platform === "win32";
const HOME_DEFAULT = path.join(os.homedir(), ".workflow-plans");
const SID = "4be7fc09-6096-4607-93d4-65f8f40334bc";

let pass = 0, fail = 0, skip = 0;
const ok = (name) => { pass++; console.log(`PASS: ${name}`); };
const bad = (name, detail) => { fail++; console.log(`FAIL: ${name} — ${detail}`); };
const skipped = (name, why) => { skip++; console.log(`SKIP: ${name} (${why})`); };

// The child: optionally fakes process.platform BEFORE any require, then either returns the
// plans dir or answers isPlanArtifactPath for each probe. Prints one JSON line.
const CHILD = `
const spec = JSON.parse(process.env.WPD_SPEC);
if (spec.platform) Object.defineProperty(process, "platform", { value: spec.platform });
const out = {};
try {
  out.dir = require(spec.mod).getWorkflowPlansDir();
  if (spec.probes) {
    const { isPlanArtifactPath } = require(spec.lang);
    out.contains = spec.probes.map((p) => isPlanArtifactPath(p));
  }
} catch (e) { out.error = String(e && e.message); }
process.stdout.write(JSON.stringify(out));
`;

function runChild(value, extra) {
  const spec = Object.assign({ mod: PLANS_DIR_MOD, lang: PLAN_LANG_MOD }, extra || {});
  const env = Object.assign({}, process.env, { WORKFLOW_PLANS_DIR: value, WPD_SPEC: JSON.stringify(spec) });
  delete env.CLAUDE_CODE_SESSION_ID;
  const r = spawnSync(process.execPath, ["-e", CHILD], { env, cwd: os.tmpdir(), encoding: "utf8", timeout: 20000 });
  try { return JSON.parse(r.stdout); } catch (_) { return { error: `child failed: status=${r.status} ${r.stderr}` }; }
}

function expectDir(name, value, want, extra) {
  const r = runChild(value, extra);
  if (r.error) return bad(name, `threw: ${r.error}`);
  if (r.dir === want) return ok(name);
  bad(name, `got ${JSON.stringify(r.dir)}, want ${JSON.stringify(want)}`);
}

// (a) win32: a Git Bash drive path becomes the native form.
if (WIN) expectDir("(a) win32: /c/x/plans -> C:\\x\\plans", "/c/x/plans", "C:\\x\\plans");
else skipped("(a) win32: /c/x/plans -> C:\\x\\plans", "not win32");

// (b) an absolute path that is not a drive path is returned unchanged.
expectDir("(b) /tmp/plans is returned unchanged", "/tmp/plans", "/tmp/plans");

// (c) off win32 the conversion is a no-op; on a win32 host the platform is faked in the child.
expectDir("(c) non-win32: /c/x is returned unchanged", "/c/x", "/c/x", WIN ? { platform: "linux" } : {});

// (d) every relative form throws, tilde included (it is never expanded).
for (const v of ["foo/bar", "./plans", "~/foo", "c/x"]) {
  const r = runChild(v);
  const name = `(d) relative ${JSON.stringify(v)} throws an 'absolute' error`;
  if (r.error && /absolute/.test(r.error)) ok(name);
  else bad(name, r.error ? `wrong error: ${r.error}` : `returned ${JSON.stringify(r.dir)}`);
}

// (e) surrounding whitespace is trimmed before the conversion; a whitespace-only value is
// truthy, so it wins over any .env default and falls back to <homedir>/.workflow-plans.
if (WIN) expectDir("(e) ' /c/x ' is trimmed, then converted", " /c/x ", "C:\\x");
else expectDir("(e) ' /c/x ' is trimmed", " /c/x ", "/c/x");
expectDir("(e) whitespace-only falls back to <homedir>/.workflow-plans", "   ", HOME_DEFAULT);

// (f) requiring workflow-plans-dir.js first (before branch-diff is loaded) must still reach
// toWindowsPath through the lazy require, not a half-initialised module export.
{
  const r = runChild("/c/x");
  const name = "(f) first-required module resolves toWindowsPath (no 'is not a function')";
  if (r.error && /toWindowsPath is not a function/.test(r.error)) bad(name, r.error);
  else if (r.error) bad(name, `threw: ${r.error}`);
  else if (r.dir === (WIN ? "C:\\x" : "/c/x")) ok(name);
  else bad(name, `got ${JSON.stringify(r.dir)}`);
}

// (g) containment via isPlanArtifactPath: with a `/c/` plans dir, a `C:\` file inside it is
// accepted and a sibling directory outside it is rejected.
if (WIN) {
  const inside = `C:\\x\\plans\\${SID}-detail.md`;
  const outside = [`C:\\x\\other\\${SID}-detail.md`, `C:\\x\\plans-evil\\${SID}-detail.md`];
  const r = runChild("/c/x/plans", { probes: [inside].concat(outside) });
  const name = "(g) win32: /c/ plans dir accepts a C:\\ file inside and rejects paths outside";
  if (r.error) bad(name, `threw: ${r.error}`);
  else if (JSON.stringify(r.contains) === JSON.stringify([true, false, false])) ok(name);
  else bad(name, `isPlanArtifactPath -> ${JSON.stringify(r.contains)} (want [true,false,false]); dir=${r.dir}`);
} else {
  skipped("(g) win32: /c/ plans dir containment", "not win32");
}

// (h1)/(h2)/(h4)/(h5)/(i) run against a fixture home and an explicit AGENTS_MAIN_ROOT (the sole .env
// source, never falling through), so neither the real home nor this checkout's .env is read.
const fs = require("fs");
const FIX = fs.mkdtempSync(path.join(os.tmpdir(), "wpd-2529-"));
const FIX_HOME = path.join(FIX, "home");
const NO_ENV_ROOT = path.join(FIX, "root-no-env");
const ENV_ROOT = path.join(FIX, "root-with-env");
const CWD = path.join(FIX, "cwd");
for (const d of [FIX_HOME, NO_ENV_ROOT, ENV_ROOT, CWD]) fs.mkdirSync(d, { recursive: true });
const ENV_DIR = WIN ? "C:\\wpd-2529\\from-env" : "/wpd-2529/from-env";
fs.writeFileSync(path.join(ENV_ROOT, ".env"), `WORKFLOW_PLANS_DIR=${ENV_DIR}\n`);
const FIX_DEFAULT = path.join(FIX_HOME, ".workflow-plans");

function runIsolated(value, root, extra) {
  const spec = Object.assign({ mod: PLANS_DIR_MOD, lang: PLAN_LANG_MOD }, extra || {});
  const env = {};
  for (const k of Object.keys(process.env)) if (k.toUpperCase() !== "WORKFLOW_PLANS_DIR") env[k] = process.env[k];
  delete env.CLAUDE_CODE_SESSION_ID;
  Object.assign(env, { HOME: FIX_HOME, USERPROFILE: FIX_HOME, AGENTS_MAIN_ROOT: root, WPD_SPEC: JSON.stringify(spec) });
  if (value !== undefined) env.WORKFLOW_PLANS_DIR = value;
  const r = spawnSync(process.execPath, ["-e", CHILD], { env, cwd: CWD, encoding: "utf8", timeout: 20000 });
  try { return JSON.parse(r.stdout); } catch (_) { return { error: `child failed: status=${r.status} ${r.stderr}` }; }
}

// The default must be <homedir>/.workflow-plans, absolute, and never in the MSYS `/c/` form.
function expectDefault(name, value, platform) {
  const r = runIsolated(value, NO_ENV_ROOT, { platform });
  if (r.error) return bad(name, `threw: ${r.error}`);
  if (r.dir !== FIX_DEFAULT) return bad(name, `got ${JSON.stringify(r.dir)}, want ${JSON.stringify(FIX_DEFAULT)}`);
  if (!path.isAbsolute(r.dir) || /^\/[A-Za-z]\//.test(r.dir)) return bad(name, `not a native absolute path: ${r.dir}`);
  ok(name);
}

for (const platform of ["win32", "linux"]) {
  // (h1) WORKFLOW_PLANS_DIR absent from the child env and from .env -> the home default.
  expectDefault(`(h1) ${platform}: unset falls back to <homedir>/.workflow-plans`, undefined, platform);
  // (h2) an empty string is "not set" -> the same home default.
  expectDefault(`(h2) ${platform}: "" falls back to <homedir>/.workflow-plans`, "", platform);
}

// (h4) unset or "" in the env -> a .env-supplied WORKFLOW_PLANS_DIR wins over the home default.
for (const value of [undefined, ""]) {
  const name = `(h4) ${value === undefined ? "unset" : '""'}: .env WORKFLOW_PLANS_DIR is used`;
  const r = runIsolated(value, ENV_ROOT);
  if (r.error) bad(name, `threw: ${r.error}`);
  else if (r.dir === ENV_DIR) ok(name);
  else bad(name, `got ${JSON.stringify(r.dir)}, want ${JSON.stringify(ENV_DIR)}`);
}

// (h5) a non-empty exported WORKFLOW_PLANS_DIR wins over a conflicting .env value.
{
  const exported = WIN ? "C:\\wpd-2529\\exported" : "/wpd-2529/exported";
  const name = "(h5) exported WORKFLOW_PLANS_DIR wins over a conflicting .env value";
  const r = runIsolated(exported, ENV_ROOT);
  if (r.error) bad(name, `threw: ${r.error}`);
  else if (r.dir === exported) ok(name);
  else bad(name, `got ${JSON.stringify(r.dir)}, want ${JSON.stringify(exported)} (.env has ${ENV_DIR})`);
}

// (i) win32: a Windows-native plans dir (a real temp dir, `C:\...` form) is returned unchanged,
// and isPlanArtifactPath accepts a file inside it and rejects a sibling directory outside it.
if (WIN) {
  const native = path.join(FIX, "native-plans");
  fs.mkdirSync(native, { recursive: true });
  const probes = [path.join(native, `${SID}-detail.md`), path.join(FIX, "native-plans-evil", `${SID}-detail.md`)];
  const r = runIsolated(native, NO_ENV_ROOT, { probes });
  const name = "(i) win32: a native C:\\ plans dir is unchanged and bounds isPlanArtifactPath";
  if (!/^[A-Za-z]:\\/.test(native)) bad(name, `temp dir is not in the native drive form: ${native}`);
  else if (r.error) bad(name, `threw: ${r.error}`);
  else if (r.dir !== native) bad(name, `got ${JSON.stringify(r.dir)}, want ${JSON.stringify(native)}`);
  else if (JSON.stringify(r.contains) === JSON.stringify([true, false])) ok(name);
  else bad(name, `isPlanArtifactPath -> ${JSON.stringify(r.contains)} (want [true,false])`);
} else {
  skipped("(i) win32: native C:\\ plans dir containment", "not win32");
}

fs.rmSync(FIX, { recursive: true, force: true });

console.log(`\nResults: ${pass} passed, ${fail} failed, ${skip} skipped`);
process.exitCode = fail > 0 ? 1 : 0;
