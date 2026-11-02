#!/usr/bin/env node
// tests/hooks/feature-2461-next-step-spawn-sites.js
// Tests: hooks/lib/next-step-spawn.js, hooks/stop-premature-stop-guard.js, hooks/stop-final-report-guard.js, hooks/session-start.js
// Tags: TL2, hooks, bin, jev, next-step, spawn-sites, static-scan, spawn-spy, scope:issue-specific, pwsh-not-required
// #2461 Step 3-7: a hook that runs next-step must never start a Jev query of its own, so every
// next-step spawn under hooks/ and bin/ goes through hooks/lib/next-step-spawn.js, which always
// adds --jev-cache-only. The static scan lists the spawn sites; the spy runs prove each of the 3
// hooks really starts next-step with the flag.
// TL3 gap: Claude Code's own hook timeouts around these spawns. Mitigation: the real hook entrypoints
// run here; only the outer harness timeout differs.
"use strict";

const { caseBegin, caseEnd, isolate } = require("../lib/harness");
const assert = require("node:assert");
const { after, test } = require("node:test");
const fs = require("node:fs");
const os = require("node:os");
const path = require("node:path");
const F = require("./feature-2461-jev/fixture");

const restore = isolate();
const ROOT = fs.mkdtempSync(path.join(os.tmpdir(), "f2461ss-"));
after(() => {
  restore();
  try { fs.rmSync(ROOT, { recursive: true, force: true }); } catch (_e) { /* best effort on Windows */ }
});

const HELPER = "hooks/lib/next-step-spawn.js";
const FLAG = "--jev-cache-only";
// next-step itself (its entrypoint and private modules) is the callee, not a spawn site.
const SELF = [/^bin\/workflow\/next-step$/, /^bin\/workflow\/lib\/next-step\//];
const JS_PATH = /["']workflow["']\s*,\s*["']next-step["']|workflow\/next-step["'`]|\bENTRYPOINT_PATH\b/;
const JS_SPAWN = /\b(spawnSync|spawn|execFileSync|execFile|execSync|exec|fork)\s*\(/;
const SH_CALL = /\bnode\s+\S*workflow\/next-step\b/;

// walk(dir) -> every regular file under it, as repo-relative forward-slash paths.
function walk(rel) {
  const out = [];
  for (const e of fs.readdirSync(path.join(F.REPO, rel), { withFileTypes: true })) {
    const r = `${rel}/${e.name}`;
    if (e.isDirectory()) { if (e.name !== "node_modules") out.push(...walk(r)); } else if (e.isFile()) out.push(r);
  }
  return out;
}
// codeLines(rel, text) -> the non-comment lines (JS: // and block-comment lines; sh: #).
function codeLines(rel, text) {
  const sh = rel.endsWith(".sh") || /^#!.*\b(ba)?sh\b/.test(text);
  return text.split(/\r?\n/).filter((l) => {
    const t = l.trim();
    return t !== "" && !(sh ? t.startsWith("#") : (t.startsWith("//") || t.startsWith("*") || t.startsWith("/*")));
  });
}
// spawnSites() -> the files under hooks/ and bin/ that spawn next-step.
function spawnSites() {
  const sites = [];
  for (const rel of [...walk("hooks"), ...walk("bin")]) {
    if (SELF.some((re) => re.test(rel))) continue;
    if (!/\.(js|sh)$/.test(rel) && path.extname(rel) !== "") continue;
    const text = fs.readFileSync(path.join(F.REPO, rel), "utf8");
    if (text.includes("\0")) continue;
    const code = codeLines(rel, text);
    const shell = rel.endsWith(".sh") || /^#!.*\b(ba)?sh\b/.test(text);
    if (shell ? code.some((l) => SH_CALL.test(l)) : (code.some((l) => JS_PATH.test(l)) && code.some((l) => JS_SPAWN.test(l)))) sites.push(rel);
  }
  return sites.sort();
}

caseBegin("static-spawn-sites", "hooks/lib/next-step-spawn.js");
test("the only next-step spawn site under hooks/ and bin/ is the helper", () => {
  assert.deepStrictEqual(spawnSites(), [HELPER]);
});
test("the helper always adds --jev-cache-only and the 3 hooks use it", () => {
  const helper = path.join(F.REPO, HELPER);
  assert.ok(fs.existsSync(helper), `${HELPER} exists`);
  assert.ok(fs.readFileSync(helper, "utf8").includes(FLAG), `${HELPER} names ${FLAG}`);
  for (const h of ["hooks/stop-premature-stop-guard.js", "hooks/stop-final-report-guard.js", "hooks/session-start.js"]) {
    assert.ok(/require\(["']\.\/lib\/next-step-spawn(\.js)?["']\)/.test(fs.readFileSync(path.join(F.REPO, h), "utf8")), `${h} requires the helper`);
  }
});
caseEnd();

// nextStepCalls(sc) -> the spied calls whose first argument is the next-step entrypoint.
const nextStepCalls = (sc) => F.spyCalls(sc).filter((c) => c.args.length && F.fwd(c.args[0]).endsWith("bin/workflow/next-step"));
// hookRun(name, rel, input) -> the next-step calls the real hook made for a started session.
function hookRun(name, rel, mkInput) {
  const sc = F.scene(ROOT, name);
  const sid = F.newSid();
  F.seedStarted(sc, sid);
  const o = F.runHook(sc, null, rel, mkInput(sid, sc), Object.assign(F.spyEnv(sc), { JEV: "off" }));
  return { o, calls: nextStepCalls(sc), sid };
}

caseBegin("hooks-spawn-with-flag", "hooks/lib/next-step-spawn.js");
const STOP = (sid, sc) => ({ session_id: sid, hook_event_name: "Stop", stop_hook_active: false, cwd: F.fwd(sc.cwd) });
const RUNS = [
  ["stop-premature-stop-guard", "hooks/stop-premature-stop-guard.js", STOP],
  ["stop-final-report-guard", "hooks/stop-final-report-guard.js", STOP],
  ["session-start", "hooks/session-start.js", (sid, sc) => ({ session_id: sid, hook_event_name: "SessionStart", source: "startup", cwd: F.fwd(sc.proj) })],
];
for (const [name, rel, mkInput] of RUNS) {
  test(`${name}: next-step is started with --session <sid> ${FLAG}`, () => {
    const { o, calls, sid } = hookRun(name, rel, mkInput);
    assert.ok(calls.length >= 1, `${name} started next-step (status ${o.status}, stderr ${o.stderr.slice(0, 300)})`);
    for (const c of calls) {
      assert.ok(c.args.includes(FLAG), `every next-step call carries ${FLAG} (got ${JSON.stringify(c.args.slice(1))})`);
      assert.strictEqual(c.args[c.args.indexOf("--session") + 1], sid);
    }
  });
}
test("spawnNextStep(args, {timeout}) appends the flag and returns next-step's output", () => {
  const sc = F.scene(ROOT, "unit");
  const sid = F.newSid();
  F.seedStarted(sc, sid);
  const code = `const r = require(${JSON.stringify(F.lib(HELPER))}).spawnNextStep(["--session", process.argv[2]], { timeout: 20000 });
console.log(JSON.stringify({ status: r.status, action: String(r.stdout || "").split(/\\r?\\n/).find((l) => l.startsWith("ACTION=")) || null }));`;
  const o = F.nodeEval(sc, null, code, [sid], Object.assign(F.spyEnv(sc), { JEV: "off" }));
  assert.strictEqual(o.status, 0, o.stderr.slice(0, 400));
  assert.deepStrictEqual(o.json, { status: 0, action: "ACTION=invoke" });
  const calls = nextStepCalls(sc);
  assert.strictEqual(calls.length, 1);
  assert.deepStrictEqual(calls[0].args.slice(1), ["--session", sid, FLAG]);
});
caseEnd();
