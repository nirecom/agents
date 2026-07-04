#!/usr/bin/env node
// Unit tests for hooks/lib/command-ir.js
// Pure Node.js — no external framework. Style mirrors tests/lib/test-command-parser.js.
//
// NOTE (write-tests stage): hooks/lib/command-ir.js does NOT exist yet — it is
// created in the write-code step. Running this file now is EXPECTED to fail with
// MODULE_NOT_FOUND on the require() below. That failure confirms the require path
// is correct; the assertions below define the target contract for write-code.

const ir = require("../../hooks/lib/command-ir");

let passed = 0;
let failed = 0;

function pass(label) {
  passed++;
  console.log("PASS: " + label);
}

function fail(label, expected, actual) {
  failed++;
  console.log("FAIL: " + label + " — expected " + JSON.stringify(expected) + ", got " + JSON.stringify(actual));
}

function check(label, actual, expected) {
  if (actual === expected) pass(label);
  else fail(label, expected, actual);
}

function checkArrayLen(label, actual, expectedLen) {
  if (Array.isArray(actual) && actual.length === expectedLen) pass(label);
  else fail(label, "array length " + expectedLen, actual);
}

function checkArrayLenAtLeast(label, actual, minLen) {
  if (Array.isArray(actual) && actual.length >= minLen) pass(label);
  else fail(label, "array length >= " + minLen, actual);
}

function checkTruthy(label, actual) {
  if (actual) pass(label);
  else fail(label, "truthy", actual);
}

const { parse, isOsTempPath } = ir;

// --- parse: simple command ---
{
  const p = parse("ls -la");
  check("parse simple: cmd0", p.cmd0, "ls");
  checkArrayLen("parse simple: argv", p.argv, 1);
  check("parse simple: argv[0]", p.argv[0], "-la");
  checkArrayLenAtLeast("parse simple: segments", p.segments, 1);
  checkArrayLen("parse simple: redirects", p.redirects, 0);
  check("parse simple: parseFailure", p.parseFailure, false);
  check("parse simple: rawText", p.rawText, "ls -la");
}

// --- parse: redirect ---
{
  const p = parse("echo x > /tmp/foo");
  checkTruthy(
    "parse redirect: contains {op:'>', fd:'1', target:'/tmp/foo'}",
    Array.isArray(p.redirects) &&
      p.redirects.some((r) => r.op === ">" && r.fd === "1" && r.target === "/tmp/foo")
  );
}

// --- parse: pipeline ---
{
  const p = parse("cmd1 | cmd2");
  checkArrayLen("parse pipeline: 2 segments", p.segments, 2);
}

// --- parse: subshell ---
{
  const p = parse("(echo x)");
  checkArrayLenAtLeast("parse subshell: at least 1 segment", p.segments, 1);
  checkTruthy(
    "parse subshell: a segment carries a sub field",
    Array.isArray(p.segments) && p.segments.some((s) => s && s.sub != null)
  );
}

// --- parse: parseFailure on malformed input ---
{
  // A pathological input that the parser cannot tokenize should set parseFailure
  // (fail-closed) while preserving rawText. Unclosed quote is a common trigger.
  const raw = 'echo "unterminated';
  const p = parse(raw);
  // parseFailure must be true for malformed input — fail-closed design (reviewer C3).
  check("parse parseFailure: type is boolean", typeof p.parseFailure, "boolean");
  check("parse parseFailure: must be true for unclosed quote", p.parseFailure, true);
  // rawText must always be preserved regardless of parse outcome.
  check("parse parseFailure: rawText preserved", p.rawText, raw);
}

// --- parse: empty string ---
{
  const p = parse("");
  checkArrayLen("parse empty: segments", p.segments, 0);
}

// --- isOsTempPath ---
check("isOsTempPath: /tmp/x", isOsTempPath("/tmp/x"), true);
check("isOsTempPath: /var/tmp/x", isOsTempPath("/var/tmp/x"), true);
check("isOsTempPath: AppData/Local/Temp/x (fwd slash)", isOsTempPath("AppData/Local/Temp/x"), true);
check("isOsTempPath: AppData\\Local\\Temp\\x (backslash)", isOsTempPath("AppData\\Local\\Temp\\x"), true);
check("isOsTempPath: C:\\tmp\\x", isOsTempPath("C:\\tmp\\x"), true);
check("isOsTempPath: C:/tmp/x", isOsTempPath("C:/tmp/x"), true);
check(
  "isOsTempPath: AppData/Local/Temp/claude/session/scratchpad",
  isOsTempPath("AppData/Local/Temp/claude/session/scratchpad"),
  true
);
check("isOsTempPath: /home/user/project/file.txt (non-temp)", isOsTempPath("/home/user/project/file.txt"), false);
check("isOsTempPath: empty string", isOsTempPath(""), false);

// null must not throw
{
  let threw = false;
  let res;
  try { res = isOsTempPath(null); } catch (e) { threw = true; }
  if (threw) fail("isOsTempPath: null (no throw)", "no throw + false", "threw");
  else check("isOsTempPath: null", res, false);
}

console.log("");
console.log("=== Summary ===");
console.log("Passed: " + passed);
console.log("Failed: " + failed);
if (failed > 0) process.exit(1);
