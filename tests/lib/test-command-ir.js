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

const { parse, isOsTempPath, resolveEffectiveSegment } = ir;

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

// --- resolveEffectiveSegment: table-driven tests ---
const RESOLVE_CASES = [
  // Non-executable headers: return null
  { label: "for header → null",          input: "for",              argv: ["var", "in", "list"],          expected: null },
  { label: "select header → null",       input: "select",           argv: ["var", "in", "list"],          expected: null },
  { label: "case header → null",         input: "case",             argv: ["tests/foo.sh", "in", "*"],    expected: null },

  // Terminators: return null
  { label: "done → null",                input: "done",             argv: [],                              expected: null },
  { label: "fi → null",                  input: "fi",               argv: [],                              expected: null },
  { label: "esac → null",               input: "esac",             argv: [],                              expected: null },

  // Condition headers: strip keyword, argv is effective command
  { label: "if → argv[0] is cmd0",       input: "if",              argv: ["pytest", "tests/"],           expected: { cmd0: "pytest", argv: ["tests/"] } },
  { label: "elif → argv[0] is cmd0",     input: "elif",            argv: ["pytest", "tests/"],           expected: { cmd0: "pytest", argv: ["tests/"] } },
  { label: "while → argv[0] is cmd0",    input: "while",           argv: ["head", "tests/"],             expected: { cmd0: "head", argv: ["tests/"] } },
  { label: "until → argv[0] is cmd0",    input: "until",           argv: ["pytest", "tests/"],           expected: { cmd0: "pytest", argv: ["tests/"] } },

  // Body keywords: strip keyword, argv becomes effective command
  { label: "do → argv[0] is cmd0",       input: "do",              argv: ["head", "-n", "10"],           expected: { cmd0: "head", argv: ["-n", "10"] } },
  { label: "then → argv[0] is cmd0",     input: "then",            argv: ["pytest", "tests/"],           expected: { cmd0: "pytest", argv: ["tests/"] } },
  { label: "else → argv[0] is cmd0",     input: "else",            argv: ["cat", "tests/x.sh"],          expected: { cmd0: "cat", argv: ["tests/x.sh"] } },

  // Body/condition keyword with no argv: return null
  { label: "do alone → null",            input: "do",              argv: [],                              expected: null },
  { label: "then alone → null",          input: "then",            argv: [],                              expected: null },
  { label: "if alone → null",            input: "if",              argv: [],                              expected: null },

  // Normal commands: pass through unchanged
  { label: "echo → unchanged",           input: "echo",            argv: ["hello"],                       expected: { cmd0: "echo", argv: ["hello"] } },
  { label: "pytest → unchanged",         input: "pytest",          argv: ["tests/"],                      expected: { cmd0: "pytest", argv: ["tests/"] } },
  { label: "ls → unchanged",             input: "ls",              argv: ["-la"],                         expected: { cmd0: "ls", argv: ["-la"] } },

  // Keyword look-alikes (C2): control-structure stripping is EXACT Set membership
  // (.has(cmd0)), so capitalized / suffixed / hyphenated look-alikes must NOT be
  // stripped — they are ordinary commands and pass through unchanged.
  // Capitalized variants (Set is case-sensitive):
  { label: "For (capitalized) → unchanged",   input: "For",         argv: ["f", "in", "tests/*"],          expected: { cmd0: "For", argv: ["f", "in", "tests/*"] } },
  { label: "DO (uppercase) → unchanged",      input: "DO",          argv: ["head", "tests/x.sh"],          expected: { cmd0: "DO", argv: ["head", "tests/x.sh"] } },
  { label: "Then (capitalized) → unchanged",  input: "Then",        argv: ["pytest", "tests/"],            expected: { cmd0: "Then", argv: ["pytest", "tests/"] } },
  { label: "WHILE (uppercase) → unchanged",   input: "WHILE",       argv: ["head", "tests/"],              expected: { cmd0: "WHILE", argv: ["head", "tests/"] } },
  // Suffixed / hyphenated variants (not exact keyword tokens):
  { label: "thenx (suffixed) → unchanged",    input: "thenx",       argv: ["tests/foo.sh"],                expected: { cmd0: "thenx", argv: ["tests/foo.sh"] } },
  { label: "if-test (hyphenated) → unchanged", input: "if-test",    argv: ["tests/foo.sh"],                expected: { cmd0: "if-test", argv: ["tests/foo.sh"] } },
  { label: "done2 (suffixed) → unchanged",    input: "done2",       argv: ["tests/foo.sh"],                expected: { cmd0: "done2", argv: ["tests/foo.sh"] } },
  { label: "casex (suffixed) → unchanged",    input: "casex",       argv: ["tests/foo.sh"],                expected: { cmd0: "casex", argv: ["tests/foo.sh"] } },
  { label: "fi_ (suffixed) → unchanged",      input: "fi_",         argv: ["tests/foo.sh"],                expected: { cmd0: "fi_", argv: ["tests/foo.sh"] } },
  { label: "selectx (suffixed) → unchanged",  input: "selectx",     argv: ["tests/foo.sh"],                expected: { cmd0: "selectx", argv: ["tests/foo.sh"] } },

  // Env-prefix stripping: VAR=val prefix stripped
  { label: "env-prefix head → cmd0=head", input: "FOO=1",         argv: ["head", "tests/"],              expected: { cmd0: "head", argv: ["tests/"] } },
  { label: "env-prefix pytest → cmd0=pytest", input: "FOO=1",    argv: ["pytest", "tests/"],            expected: { cmd0: "pytest", argv: ["tests/"] } },

  // All-tokens-are-assignments: return null
  { label: "all-assignments → null",     input: "FOO=1",           argv: ["BAR=2"],                       expected: null },

  // Empty cmd0: return null
  { label: "empty cmd0 → null",          input: "",                argv: [],                              expected: null },
];

for (const { label, input, argv, expected } of RESOLVE_CASES) {
  const segmentIR = { cmd0: input, argv };
  const result = resolveEffectiveSegment(segmentIR);
  if (expected === null) {
    if (result === null) pass("resolveEffectiveSegment: " + label);
    else fail("resolveEffectiveSegment: " + label + " — expected null, got " + JSON.stringify(result), null, result);
  } else {
    if (result && result.cmd0 === expected.cmd0 && JSON.stringify(result.argv) === JSON.stringify(expected.argv))
      pass("resolveEffectiveSegment: " + label);
    else
      fail("resolveEffectiveSegment: " + label, JSON.stringify(expected), JSON.stringify(result));
  }
}

// --- resolveEffectiveSegment: case/esac edge cases ---
{
  // case header with argv (pattern matching): return null
  const seg1 = { cmd0: "case", argv: ["\"$f\"", "in", "tests/*"] };
  const r1 = resolveEffectiveSegment(seg1);
  if (r1 === null) pass("resolveEffectiveSegment: case header → null");
  else fail("resolveEffectiveSegment: case header", "null", r1);

  // esac terminator: return null
  const seg2 = { cmd0: "esac", argv: [] };
  const r2 = resolveEffectiveSegment(seg2);
  if (r2 === null) pass("resolveEffectiveSegment: esac terminator → null");
  else fail("resolveEffectiveSegment: esac terminator", "null", r2);
}

// --- resolveEffectiveSegment: parse-integrated tests ---
// Verify that parse() + resolveEffectiveSegment work together on real command strings.
const INTEGRATION_CASES = [
  { label: "for...do head (read-only)", cmd: "for f in tests/*.sh; do head -n 10 \"$f\"; done",
    expectedSegments: 3, effectiveCmd0s: [null, "head", null] },
  { label: "if pytest (condition)", cmd: "if pytest tests/; then : ; fi",
    expectedSegments: 3, effectiveCmd0s: ["pytest", ":", null] },
  { label: "FOO=1 head (env-prefix)", cmd: "FOO=1 head tests/foo.sh",
    expectedSegments: 1, effectiveCmd0s: ["head"] },
  { label: "do FOO=1 head (body+env)", cmd: "do FOO=1 head tests/foo.sh",
    expectedSegments: 1, effectiveCmd0s: ["head"] },
  { label: "while head (cond+read-only)", cmd: "while head tests/; do : ; done",
    expectedSegments: 3, effectiveCmd0s: ["head", ":", null] },
  { label: "until pytest (cond+runner)", cmd: "until pytest tests/; do : ; done",
    expectedSegments: 3, effectiveCmd0s: ["pytest", ":", null] },
  { label: "elif pytest (elif+runner)", cmd: "elif pytest tests/; then : ; fi",
    expectedSegments: 3, effectiveCmd0s: ["pytest", ":", null] },
  { label: "case head (case+read-only)", cmd: "case \"$f\" in tests/*) head -n 1 \"$f\" ;; esac",
    expectedSegments: 3, effectiveCmd0s: [null, "head", null] },
];
for (const { label, cmd, expectedSegments, effectiveCmd0s } of INTEGRATION_CASES) {
  const ir = parse(cmd);
  if (ir.segments.length === expectedSegments) pass("parse+resolve " + label + ": segment count");
  else fail("parse+resolve " + label + ": segment count", expectedSegments, ir.segments.length);
  for (let i = 0; i < effectiveCmd0s.length; i++) {
    const eff = resolveEffectiveSegment(ir.segments[i]);
    const expected = effectiveCmd0s[i];
    if (eff === null) {
      if (expected === "null" || expected === null) pass("parse+resolve " + label + ": seg " + i + " → null");
      else fail("parse+resolve " + label + ": seg " + i, "effective cmd0=" + expected, "null");
    } else if (eff.cmd0 === expected) {
      pass("parse+resolve " + label + ": seg " + i + " cmd0=" + expected);
    } else {
      fail("parse+resolve " + label + ": seg " + i, expected, eff.cmd0);
    }
  }
}

// --- resolveEffectiveSegment: edge cases ---
{
  // select header: return null
  const s1 = { cmd0: "select", argv: ["var", "in", "list"] };
  const r1 = resolveEffectiveSegment(s1);
  if (r1 === null) pass("resolveEffectiveSegment: select header → null");
  else fail("resolveEffectiveSegment: select header", "null", r1);
}

console.log("");
console.log("=== Summary ===");
console.log("Passed: " + passed);
console.log("Failed: " + failed);
if (failed > 0) process.exit(1);
