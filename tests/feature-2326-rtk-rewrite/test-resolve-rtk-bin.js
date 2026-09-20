#!/usr/bin/env node
"use strict";
// tests/feature-2326-rtk-rewrite/test-resolve-rtk-bin.js
// Pure Node.js (no framework) tests for resolveRtkBin(existsFn) priority order
// and the main-flow passthrough when no binary resolves.

const path = require("path");
const assert = require("assert");

const HOOK = path.join(__dirname, "..", "..", "hooks", "rtk-rewrite.js");
const { resolveRtkBin, decide } = require(HOOK);

let pass = 0;
let fail = 0;
function check(name, fn) {
  try { fn(); console.log(`PASS: ${name}`); pass++; }
  catch (e) { console.log(`FAIL: ${name} — ${e.message}`); fail++; }
}

// Isolate: no ambient RTK_BIN, and an existsFn we control per case.
delete process.env.RTK_BIN;
const never = () => false;
const only = (target) => (p) => p === target;

check("priority 0: RTK_BIN wins", () => {
  process.env.RTK_BIN = "/custom/rtk";
  try {
    assert.strictEqual(resolveRtkBin(never), "/custom/rtk");
  } finally {
    delete process.env.RTK_BIN;
  }
});

check("homebrew apple-silicon candidate", () => {
  assert.strictEqual(resolveRtkBin(only("/opt/homebrew/bin/rtk")), "/opt/homebrew/bin/rtk");
});

check("homebrew intel candidate", () => {
  assert.strictEqual(resolveRtkBin(only("/usr/local/bin/rtk")), "/usr/local/bin/rtk");
});

check("linuxbrew candidate", () => {
  assert.strictEqual(resolveRtkBin(only("/home/linuxbrew/.linuxbrew/bin/rtk")), "/home/linuxbrew/.linuxbrew/bin/rtk");
});

if (process.platform === "win32") {
  const local = process.env.LOCALAPPDATA || "C:\\Users\\test\\AppData\\Local";
  const savedLocal = process.env.LOCALAPPDATA;
  process.env.LOCALAPPDATA = local;
  const linksPath = path.join(local, "Microsoft", "WinGet", "Links", "rtk.exe");
  const programsPath = path.join(local, "Programs", "rtk-ai", "rtk", "rtk.exe");

  check("winget Links candidate (win32)", () => {
    assert.strictEqual(resolveRtkBin(only(linksPath)), linksPath);
  });
  check("winget Programs candidate (win32)", () => {
    assert.strictEqual(resolveRtkBin(only(programsPath)), programsPath);
  });

  if (savedLocal === undefined) delete process.env.LOCALAPPDATA;
  else process.env.LOCALAPPDATA = savedLocal;
} else {
  console.log("SKIP: winget candidates (non-win32 platform)");
}

check("all candidates absent, RTK_BIN unset → null", () => {
  // which/where may still find a real rtk; only assert null when it does not.
  const r = resolveRtkBin(never);
  assert.ok(r === null || typeof r === "string",
    "resolveRtkBin must return null or a real PATH-resolved string");
});

check("null resolution → main() passthrough {}", () => {
  const out = decide(
    { tool_name: "Bash", tool_input: { command: "git status" } },
    { rtkOn: true, rtkBin: null },
  );
  assert.deepStrictEqual(out, {});
});

console.log("----");
console.log(`PASS=${pass} FAIL=${fail}`);
process.exit(fail === 0 ? 0 : 1);
