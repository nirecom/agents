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

// `kind` is for the reader only — the runner below ignores it.
const tokenizeCases = [
  { name: "cat TARGET", input: "cat TARGET", want: ["cat", "TARGET"], kind: "n/a" },
  { name: "double-quoted", input: '"double quoted"', want: ["double quoted"], kind: "n/a" },
  { name: "single-quoted", input: "'single quoted'", want: ["single quoted"], kind: "n/a" },
  {
    // Inside "..." a backslash is special only before $ ` " \ or newline;
    // before anything else (here, a space) it stays literal (#2210).
    name: "backslash before space (POSIX #2210)",
    input: '"a\\ b"',
    want: ["a\\ b"],
    kind: "preserved backslash",
  },
  {
    // Backslash-newline vanishes entirely, joining the halves into one token —
    // so a delete verb can be smuggled across a line break (#2210).
    name: "backslash-newline line continuation (POSIX #2210 C1)",
    input: '"r\\' + "\n" + 'm" -r target',
    want: ["rm", "-r", "target"],
    kind: "consumed backslash",
  },
  {
    // $'...': the backslash is stripped, but no ANSI-C escape translation runs.
    name: "ansi-c quote",
    input: "$'ansi\\tcr'",
    wantLen: 1,
    kind: "consumed backslash",
  },
];

for (const c of tokenizeCases) {
  const t = tokenizeSegment(c.input);
  if (c.want) {
    check("tokenize: " + c.name + " length", t.length, c.want.length);
    c.want.forEach((w, idx) => check("tokenize: " + c.name + "[" + idx + "]", t[idx], w));
  } else if (typeof c.wantLen === "number") {
    check("tokenize: " + c.name + " length", t.length, c.wantLen);
  }
}

{
  // Outside the table: the assertion is tolerance, not token equality.
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
// The non-nested regex still captures the INNER substitution of a nested pair,
// which is more protective than it looks.
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
