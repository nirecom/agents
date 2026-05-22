#!/usr/bin/env node
// Unit tests for hooks/lib/command-parser.js
// Pure Node.js — no external framework.

const parser = require("../../hooks/lib/command-parser");

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

function checkArrayIncludes(label, actual, needle) {
  if (Array.isArray(actual) && actual.includes(needle)) pass(label);
  else fail(label, "array including " + JSON.stringify(needle), actual);
}

function checkArrayNotIncludes(label, actual, needle) {
  if (Array.isArray(actual) && !actual.includes(needle)) pass(label);
  else fail(label, "array NOT including " + JSON.stringify(needle), actual);
}

function checkStringNotContains(label, actual, needle) {
  if (typeof actual === "string" && !actual.includes(needle)) pass(label);
  else fail(label, "string not containing " + JSON.stringify(needle), actual);
}

// --- tokenizeSegment ---
const { tokenizeSegment, splitSegments, stripSubstitutions, extractSubstitutionContents, checkBashCommand } = parser;

{
  const t = tokenizeSegment("cat TARGET");
  check("tokenize: cat TARGET length", t.length, 2);
  check("tokenize: cat TARGET[0]", t[0], "cat");
  check("tokenize: cat TARGET[1]", t[1], "TARGET");
}

{
  const t = tokenizeSegment('"double quoted"');
  check("tokenize: double-quoted length", t.length, 1);
  check("tokenize: double-quoted content", t[0], "double quoted");
}

{
  const t = tokenizeSegment("'single quoted'");
  check("tokenize: single-quoted length", t.length, 1);
  check("tokenize: single-quoted content", t[0], "single quoted");
}

{
  // Backslash-escapes are only processed inside double-quoted strings.
  // Input: "a\ b" (double-quoted, backslash before space) → single token "a b".
  const t = tokenizeSegment('"a\\ b"');
  check("tokenize: backslash-escape length", t.length, 1);
  check("tokenize: backslash-escape content", t[0], "a b");
}

{
  const t = tokenizeSegment("$'ansi\\tcr'");
  check("tokenize: ansi-c quote length", t.length, 1);
}

{
  // Should not throw
  let threw = false;
  let t;
  try { t = tokenizeSegment('unclosed "quote'); } catch (e) { threw = true; }
  if (threw) fail("tokenize: unclosed quote tolerance", "no throw", "threw");
  else if (Array.isArray(t)) pass("tokenize: unclosed quote tolerance");
  else fail("tokenize: unclosed quote tolerance", "array", t);
}

// --- splitSegments ---
check("split: a && b", splitSegments("a && b").length, 2);
check("split: a ; b ; c", splitSegments("a ; b ; c").length, 3);
check("split: a | b", splitSegments("a | b").length, 2);
check('split: "a | b" (quoted pipe)', splitSegments('"a | b"').length, 1);
check("split: a || b && c ; d", splitSegments("a || b && c ; d").length, 4);

// --- stripSubstitutions ---
check("strip: $() removed", stripSubstitutions("cat $(foo)"), "cat ");
check("strip: backtick removed", stripSubstitutions("cat `foo`"), "cat ");
checkStringNotContains("strip: heredoc body", stripSubstitutions("cat <<EOF\ncontent\nEOF"), "content");
checkStringNotContains("strip: single-quoted heredoc", stripSubstitutions("cat <<'EOF'\ncontent\nEOF"), "content");
checkStringNotContains("strip: double-quoted heredoc", stripSubstitutions('cat <<"EOF"\ncontent\nEOF'), "content");
checkStringNotContains("strip: indented heredoc <<-", stripSubstitutions("cat <<-EOF\n\tcontent\nEOF"), "content");

// --- extractSubstitutionContents ---
checkArrayIncludes("extract: $() body", extractSubstitutionContents('cmd "$(cat X)"'), "cat X");
checkArrayIncludes("extract: backtick body", extractSubstitutionContents("cmd `cat X`"), "cat X");
// The regex /\$\(([^()]*)\)/g finds all non-nested $() matches in the string,
// including inner $(cat X) embedded inside an outer $(echo ...). The innermost
// match IS captured — this is actually more protective than originally assumed.
checkArrayIncludes(
  "extract: inner sub captured (regex finds innermost match)",
  extractSubstitutionContents('cmd "$(echo $(cat X))"'),
  "cat X"
);

// --- checkBashCommand ---
const opts = {
  isTargetPath: (t) => t === "TARGET",
  textFlags: new Set(["--body"]),
  pathFlags: new Set(["-f"]),
  textCmds: new Set(["echo"]),
  shellBins: new Set(["bash"]),
};

check("check: positional cat TARGET", checkBashCommand("cat TARGET", opts), true);
check("check: positional cat SAFE", checkBashCommand("cat SAFE", opts), false);
check("check: redirect > TARGET", checkBashCommand("cmd > TARGET", opts), true);
check("check: echo TARGET (textCmd skipped)", checkBashCommand("echo TARGET", opts), false);
check("check: echo x > TARGET (redirect beats textCmd)", checkBashCommand("echo x > TARGET", opts), true);
check("check: --body TARGET (textFlag skipped)", checkBashCommand("cmd --body TARGET", opts), false);
check("check: -f TARGET (pathFlag checked)", checkBashCommand("cmd -f TARGET", opts), true);
check('check: bash -c "cat TARGET"', checkBashCommand('bash -c "cat TARGET"', opts), true);
check('check: bash -lc "cat TARGET"', checkBashCommand('bash -lc "cat TARGET"', opts), true);
check('check: substitution "$(cat TARGET)"', checkBashCommand('cmd "$(cat TARGET)"', opts), true);
// $(cat TARGET) is found inside $(echo ...) because the regex matches the innermost $().
check('check: nested sub innermost captured → true', checkBashCommand('cmd "$(echo $(cat TARGET))"', opts), true);
check("check: heredoc body stripped", checkBashCommand("cmd <<EOF\nTARGET\nEOF", opts), false);

// --- Attached-redirect bypass coverage ---
check("check: attached `>TARGET` (no space)", checkBashCommand("echo x >TARGET", opts), true);
check("check: attached `<TARGET` (no space)", checkBashCommand("cat <TARGET", opts), true);
check("check: attached `2>TARGET` (stderr)", checkBashCommand("cmd 2>TARGET", opts), true);
check("check: attached `>>TARGET` (append)", checkBashCommand("cmd >>TARGET", opts), true);
check("check: attached `&>TARGET` (combined)", checkBashCommand("cmd &>TARGET", opts), true);

// --- Attached `=` flag-value coverage ---
check("check: --body=TARGET (textFlag = form)", checkBashCommand("cmd --body=TARGET", opts), false);
check("check: -f=TARGET (pathFlag = form)", checkBashCommand("cmd -f=TARGET", opts), true);
check("check: --unknown=TARGET (defense-in-depth)", checkBashCommand("cmd --unknown=TARGET", opts), true);

console.log("");
console.log("=== Summary ===");
console.log("Passed: " + passed);
console.log("Failed: " + failed);
if (failed > 0) process.exit(1);
