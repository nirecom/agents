"use strict";
// Tests: bin/workflow/lib/workflow-init/spawn-env.js
// Tags: TL1, scope:issue-specific, windows, spawn
// #3127 the spawn-env builders must return opts.windowsHide === true. Only spawn-env.js needs the fix; NA members:
// session-sync/proc.js run() (sets it), state-io/core/context.js :22,:50 (parent has a console), detect-issues.js:24 (node).
// Path literals avoid the single-letter-directory form that the outbound scan reads as an MSYS path.
// TL3 gap (what this test does NOT catch):
// - a real bash spawned on Windows from a detached, console-less node parent shows no console window.
// Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
// via bin/check-verification-gate.sh category: pwsh-required.

const { caseBegin, caseEnd } = require("../lib/harness");
const assert = require("node:assert");
const { test } = require("node:test");
const fs = require("node:fs");
const path = require("node:path");

const ROOT = path.resolve(__dirname, "..", "..");
const SE = require(path.join(ROOT, "bin/workflow/lib/workflow-init/spawn-env.js"));
const CALLERS = [
  "bin/lib/forge-issue-links.js",
  "bin/workflow/lib/workflow-init/phases/fetch-issues.js",
  "bin/workflow/lib/workflow-init/phases/meta-classify.js",
  "bin/workflow/lib/workflow-init/phases/wip-check.js",
];

// Blank out comments and string/template contents (same length, newlines kept) so brackets inside them are inert.
function mask(src) {
  let out = "";
  for (let i = 0; i < src.length; i++) {
    const c = src[i], d = src[i + 1];
    if (c === "/" && d === "/") {
      while (i < src.length && src[i] !== "\n") { out += " "; i++; }
      i--; continue;
    }
    if (c === "/" && d === "*") {
      while (i < src.length && !(src[i] === "*" && src[i + 1] === "/")) { out += src[i] === "\n" ? "\n" : " "; i++; }
      out += "  "; i++; continue;
    }
    if (c === '"' || c === "'" || c === "`") {
      out += c; i++;
      while (i < src.length && src[i] !== c) {
        if (src[i] === "\\") { out += " "; i++; }
        out += src[i] === "\n" ? "\n" : " "; i++;
      }
      out += c; continue;
    }
    out += c;
  }
  return out;
}

// Split text at top-level commas (depth over () [] {}), using the masked text for structure.
function splitTop(orig, masked) {
  const parts = []; let depth = 0, start = 0;
  for (let i = 0; i < masked.length; i++) {
    const c = masked[i];
    if ("([{".includes(c)) depth++;
    else if (")]}".includes(c)) depth--;
    else if (c === "," && depth === 0) { parts.push(orig.slice(start, i).trim()); start = i + 1; }
  }
  const last = orig.slice(start).trim();
  if (last) parts.push(last);
  return parts;
}

// Every call of the given names in src as its top-level argument strings, found by bracket matching.
function spawnCalls(src, names = "spawnSync") {
  const m = mask(src), calls = [];
  const re = new RegExp("\\b(?:" + names + ")\\s*\\(", "g"); let hit;
  while ((hit = re.exec(m))) {
    let depth = 1, i = re.lastIndex;
    for (; i < m.length && depth > 0; i++) {
      if ("([{".includes(m[i])) depth++;
      else if (")]}".includes(m[i])) depth--;
    }
    calls.push(splitTop(src.slice(re.lastIndex, i - 1), m.slice(re.lastIndex, i - 1)));
  }
  return calls;
}

// Raw spawn-family calls of bash/gh/git (literal 1st arg, any line layout) whose argument text lacks windowsHide.
function rawWithoutHide(src) {
  return spawnCalls(src, "spawn|spawnSync|execFile|execFileSync")
    .filter((a) => /^["'](?:bash|gh|git)["']$/.test(a[0]) && !/windowsHide/.test(a.join(",")))
    .map((a) => a.join(" , "));
}

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
