#!/usr/bin/env node
// Tests: hooks/lib/command-ir.js
// Tags: scope:common, canary-3, ir
//
// Unit tests for hooks/lib/command-ir.js parse() and isOsTempPath().
// Pure Node.js — no external framework. Style mirrors tests/lib/test-command-parser.js.

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

// --- parse: gh pr merge — segments[0].cmd0 and argv (#1294) ---
// These cases verify that the IR properties new consumers rely on for
// isGhWriteIR dispatch are correctly populated.
{
  const p = parse("gh pr merge origin/main");
  check("parse gh pr merge: segments[0].cmd0", p.segments[0].cmd0, "gh");
  checkTruthy("parse gh pr merge: argv includes 'pr'", p.segments[0].argv.includes("pr"));
  checkTruthy("parse gh pr merge: argv includes 'merge'", p.segments[0].argv.includes("merge"));
}

// --- parse: tee — cmd0 (#1294) ---
{
  const p = parse("tee out.txt");
  check("parse tee: segments[0].cmd0", p.segments[0].cmd0, "tee");
}

// --- parse: cp — cmd0 (#1294) ---
{
  const p = parse("cp src dst");
  check("parse cp: segments[0].cmd0", p.segments[0].cmd0, "cp");
}

// --- parse: rm -rf — cmd0 (#1294) ---
{
  const p = parse("rm -rf /tmp/x");
  check("parse rm: segments[0].cmd0", p.segments[0].cmd0, "rm");
}

// --- parse: pwsh aliases — cmd0 (#1294) ---
// Verify that each pwsh alias command word is correctly extracted as cmd0.
// These feed collectBashWriteTargets in bash-write-scope.js.
{
  const aliases = [
    ["ni newfile.txt", "ni"],
    ["ri oldfile.txt", "ri"],
    ["sc out.txt 'x'", "sc"],
    ["ac append.txt 'x'", "ac"],
    ["mi src.txt dst.txt", "mi"],
    ["ci src.txt dst.txt", "ci"],
  ];
  for (const [cmd, expected] of aliases) {
    const p = parse(cmd);
    check("parse pwsh alias " + expected + ": segments[0].cmd0", p.segments[0].cmd0, expected);
  }
}

// --- parse: redirect present in segment (#1294) ---
// Verifies that redirect targets from first segment are accessible as p.redirects.
{
  const p = parse("echo x > out.txt");
  checkTruthy(
    "parse redirect: out.txt redirect present in segment",
    Array.isArray(p.redirects) &&
      p.redirects.some((r) => r.target === "out.txt")
  );
}

// --- parse: parseFailure rawText preservation — single-quote variant (#1294) ---
// Confirms rawText is preserved across multiple parseFailure triggers, not only
// the double-quote case tested in the earlier parseFailure block above.
{
  const raw = "echo 'also unterminated";
  const p = parse(raw);
  check("parse parseFailure (single-quote variant): parseFailure===true", p.parseFailure, true);
  check("parse parseFailure (single-quote variant): rawText preserved", p.rawText, raw);
}

// --- parse: null / undefined / non-string inputs — no-throw, fail-closed ---
// After IR threading, callers may pass unvalidated inputs. parse() must never throw.
{
  for (const [label, input] of [["null", null], ["undefined", undefined], ["number", 42], ["object", {}]]) {
    let threw = false;
    let result;
    try { result = parse(input); } catch (e) { threw = true; }
    if (threw) {
      fail("parse(" + label + "): must not throw", "no throw", "threw");
    } else {
      // fail-closed: non-string inputs should set parseFailure=true or return empty segments
      const safe = result && (result.parseFailure === true || (Array.isArray(result.segments) && result.segments.length === 0));
      if (safe) pass("parse(" + label + "): fail-closed (parseFailure or empty segments)");
      else fail("parse(" + label + "): fail-closed (parseFailure or empty segments)", "fail-closed", JSON.stringify(result));
    }
  }
}

// --- parse: redirect edge cases (table-driven) ---
// Verify that various redirect operators are captured in ir.redirects.
for (const { label, cmd, predicate } of [
  { label: "stderr redirect 2>err.log",   cmd: "cmd 2>err.log",     predicate: (r) => r.target === "err.log" },
  { label: "append redirect >>out.log",   cmd: "echo x >>out.log",  predicate: (r) => r.op === ">>" && r.target === "out.log" },
  { label: "input redirect <in.txt op='<'", cmd: "cat <in.txt",     predicate: (r) => r.op === "<" && r.target === "in.txt" },
]) {
  const p = parse(cmd);
  checkTruthy(
    "parse " + label,
    Array.isArray(p.redirects) && p.redirects.some(predicate)
  );
}

// --- isOsTempPath: path-traversal adversarial cases (table-driven) ---
// Paths that escape temp directory via ".." must NOT be classified as temp.
for (const { label, input, want } of [
  { label: "/tmp/../repo/file (traversal)",           input: "/tmp/../repo/file",              want: false },
  { label: "C:\\\\tmp\\\\..\\\\repo\\\\x (traversal)", input: "C:\\tmp\\..\\repo\\x",            want: false },
  { label: "AppData\\\\Local\\\\Temp\\\\..\\\\x",     input: "AppData\\Local\\Temp\\..\\x",      want: false },
  { label: "/tmp/valid (real temp)",                  input: "/tmp/valid",                     want: true  },
  { label: "C:\\\\tmp\\\\valid (real temp)",          input: "C:\\tmp\\valid",                  want: true  },
]) {
  check("isOsTempPath: " + label, isOsTempPath(input), want);
}

console.log("");
console.log("=== Summary ===");
console.log("Passed: " + passed);
console.log("Failed: " + failed);
if (failed > 0) process.exit(1);
