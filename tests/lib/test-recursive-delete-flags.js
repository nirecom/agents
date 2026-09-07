#!/usr/bin/env node
// Tests: hooks/lib/bash-write-targets/rm.js, hooks/lib/bash-write-targets/pwsh.js, hooks/lib/bash-write-targets/cmd-exe.js  (lang-check: ignore)
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
// #2210 — the three per-segment recursive-delete judgments.
// Verdicts: false=no flag/out of scope, true=recursive, null=unresolvable (fail-closed).

const { parse } = require("../../hooks/lib/command-ir");

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

// Structural equality: the extractors return string[]|null, not primitives.
function checkDeep(label, actual, expected) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) pass(label);
  else fail(label, expected, actual);
}

// TL3 gap: no real shell process ever expands these payloads (see the
// dispatcher's `# TL3 gap` block for the closest-to-action mitigation).

// Stub a missing module/export instead of throwing, so every case still runs.
function loadFn(modPath, fnName) {
  let mod = null;
  try {
    mod = require(modPath);
  } catch (e) {
    return function () { return "UNAVAILABLE(require " + modPath + ": " + e.message + ")"; };
  }
  const fn = mod && mod[fnName];
  if (typeof fn !== "function") {
    return function () { return "UNAVAILABLE(" + modPath + " exports no " + fnName + ")"; };
  }
  return fn;
}

const hasRecursiveRmFlag = loadFn("../../hooks/lib/bash-write-targets/rm", "hasRecursiveRmFlag");
const isRecursiveRmFlagToken = loadFn("../../hooks/lib/bash-write-targets/rm", "isRecursiveRmFlagToken");
const hasRecursivePwshFlag = loadFn("../../hooks/lib/bash-write-targets/pwsh", "hasRecursivePwshFlag");
const hasRecursiveCmdExeFlag = loadFn("../../hooks/lib/bash-write-targets/cmd-exe", "hasRecursiveCmdExeFlag");

// Pre-existing exports of the same two files, unpinned by any suite until now.
const extractRmTargets = loadFn("../../hooks/lib/bash-write-targets/rm", "extractRmTargets");
const extractPwshWriteTargets = loadFn("../../hooks/lib/bash-write-targets/pwsh", "extractPwshWriteTargets");

function seg(cmd) {
  const ir = parse(cmd);
  return (ir && Array.isArray(ir.segments) && ir.segments[0]) || null;
}

function runTable(title, fn, cases) {
  console.log("");
  console.log("=== " + title + " ===");
  for (const { cmd, want } of cases) {
    check(title + ": " + cmd + " → " + JSON.stringify(want), fn(seg(cmd)), want);
  }
}

runTable("hasRecursiveRmFlag", hasRecursiveRmFlag, [
  { cmd: "rm -r dir", want: true },
  { cmd: "rm -r -f dir", want: true },
  { cmd: "rm -Rf dir", want: true },
  { cmd: "rm -fR dir", want: true },
  { cmd: "rm --recursive dir", want: true },
  { cmd: "rm -rf/tmp/x", want: true },
  // The literal forms the settings.json deny globs carried; they must stay
  // blocked once those globs are removed (#2210 stage 2).
  { cmd: "rm -rf dir", want: true },
  { cmd: "rm -fr dir", want: true },
  { cmd: "/bin/rm -rf dir", want: true },
  { cmd: "env rm -rf dir", want: true },
  { cmd: "rm -f -r dir", want: true },
  // Argv-walking must be position-independent: the flag may trail the target.
  { cmd: "rm dir -r", want: true },

  { cmd: "rm -f dir", want: false },
  { cmd: "rm dir", want: false },
  { cmd: "rm -i -v dir", want: false },
  { cmd: "ls -r dir", want: false },
  // `--` ends flag parsing: a later `-r` is a filename, not a recursion request.
  { cmd: "rm -- -r dir", want: false },
  // Accepted gap: a bare variable token is a target, not a flag; the
  // cross-segment `FLAGS=-rf; rm $FLAGS x` form is caught one layer up
  // (tests/lib/test-recursive-delete-scan.js).
  { cmd: 'rm "$file"', want: false },

  { cmd: "rm -$VAR dir", want: null },

  // The tokenizer dequotes before the flag classifier sees the token, so every
  // glued/split/escaped spelling must resolve identically to plain `-rf`.
  { cmd: 'rm "-rf" dir', want: true },
  { cmd: "rm '-rf' dir", want: true },
  { cmd: 'rm -"rf" dir', want: true },
  { cmd: 'rm ""-rf dir', want: true },
  { cmd: "rm \\-rf dir", want: true },
  { cmd: "rm \\-r dir", want: true },
  { cmd: 'rm "-r" dir', want: true },
  // Symmetric negative: dequoting alone must not trip the block.
  { cmd: 'rm "-f" dir', want: false },

  // Inside "..." only $ ` " \ and newline are escapable. After an ordinary
  // char the backslash stays literal, so a token that ends up backslash-led is
  // a target, not a flag; the escapable pairs keep the token `-r`-led.
  { cmd: 'rm "\\n-rf" dir', want: false },
  { cmd: 'rm "-r\\"f" dir', want: true },
  { cmd: 'rm "\\\\-rf" dir', want: false },
  { cmd: 'rm "-r\\\nf" dir', want: true },
]);

console.log("");
console.log("=== isRecursiveRmFlagToken ===");
for (const { tok, want } of [
  { tok: "-r", want: true },
  { tok: "-R", want: true },
  { tok: "-rf", want: true },
  { tok: "-fr", want: true },
  { tok: "-rf/tmp/x", want: true },
  { tok: "--recursive", want: true },
  { tok: "--rec", want: true },
  { tok: "--r", want: true },
  { tok: "-f", want: false },
  { tok: "-i", want: false },
  { tok: "-fdv", want: false },
  { tok: "--force", want: false },
  { tok: "-$VAR", want: null },
  { tok: "-$(echo r)", want: null },
  { tok: "-`echo r`", want: null },
  // Mutation probing leaves PARAM_DEFAULT_RE live — not a test gap:
  // PARAM_EXPANSION_RE's `[-=?+]` already matches the same inputs with an
  // identical capture, so it is unreachable-in-effect (a source finding).
  { tok: "${X:--rf}", want: true },
  { tok: "${X--rf}", want: true },
  { tok: "${X:-rf}", want: false },   // default has no leading "-": a target
  { tok: "${X:-f}", want: false },    // a real flag, but not recursive
  { tok: "${X:=-rf}", want: true },
  { tok: "${X:+-rf}", want: true },
  { tok: "${X:?-rf}", want: true },
  { tok: "${X:-$Y}", want: null },
  { tok: "${X:-`cmd`}", want: null },
]) {
  check("isRecursiveRmFlagToken: " + tok + " → " + JSON.stringify(want), isRecursiveRmFlagToken(tok), want);
}

runTable("hasRecursivePwshFlag", hasRecursivePwshFlag, [
  { cmd: "Remove-Item -Recurse dir", want: true },
  { cmd: "Remove-Item -Recurse -Force dir", want: true },
  { cmd: "ri -r dir", want: true },
  { cmd: "rd -Recurse dir", want: true },
  { cmd: "del -Recurse dir", want: true },
  { cmd: "Remove-Item -Recurse:$true dir", want: true },
  // A variable TARGET must not fail-closed the way an unresolvable FLAG does —
  // this is the everyday PowerShell spelling.
  { cmd: 'Remove-Item -Recurse "$dir"', want: true },
  { cmd: "rmdir -Recurse dir", want: true },
  { cmd: "erase -Recurse dir", want: true },
  { cmd: "Remove-Item -Rec dir", want: true },
  { cmd: "Remove-Item dir -Recurse", want: true },
  // PowerShell is case-insensitive for cmdlet, parameter and switch-value alike.
  { cmd: "Remove-Item -Recurse:$TRUE dir", want: true },
  { cmd: "Remove-Item -Recurse:$FALSE dir", want: false },
  { cmd: "remove-item -recurse:$true dir", want: true },
  { cmd: "REMOVE-ITEM -ReCuRsE dir", want: true },
  { cmd: "RI -R dir", want: true },

  // `rd` is a recursive-delete cmdlet here, but `/s` is not a `-`-leading flag
  // token, so this judgment alone never catches bare `rd /s dir`.
  { cmd: "rd /s dir", want: false },
  { cmd: "Remove-Item -Force dir", want: false },
  { cmd: "Remove-Item -Path dir", want: false },
  { cmd: "Remove-Item -Recurse:$false dir", want: false },
  { cmd: "Set-Content -Path x -Value y", want: false },

  // Unresolvable flag NAME (unlike a target or a switch value) fails closed.
  { cmd: "Remove-Item -$VAR dir", want: null },
  { cmd: "Remove-Item -Recurse:$SomeVar dir", want: null },
]);

runTable("hasRecursiveCmdExeFlag", hasRecursiveCmdExeFlag, [
  { cmd: "cmd /c rmdir /s dir", want: true },
  { cmd: 'cmd /c "rmdir /s dir"', want: true },
  { cmd: "cmd /c rd /s dir", want: true },
  { cmd: "cmd /c del /s dir", want: true },
  { cmd: "cmd.exe /k rmdir /s dir", want: true },
  { cmd: 'cmd /c "rmdir /s dir & echo done"', want: true },
  // An independent flag token still triggers when a path tail spells it too.
  { cmd: "cmd /c rd /s C:/s", want: true },
  { cmd: 'cmd /c "rmdir /s dir && echo done"', want: true },
  { cmd: 'cmd /c "rmdir /s dir || echo fail"', want: true },
  { cmd: 'cmd /c "echo start | rmdir /s dir"', want: true },
  { cmd: "cmd /C rmdir /S dir", want: true },
  { cmd: "cmd /s /c rd /s dir", want: true },
  { cmd: "cmd /c rd dir /s", want: true },
  // The switch is matched by PREFIX: the outer tokenizer glues `/c"..."` into
  // one argv token, and the remainder after the 2-char prefix is the payload.
  { cmd: 'cmd /c"rd /s dir"', want: true },

  { cmd: "cmd /c rmdir dir", want: false },
  { cmd: "cmd /c dir", want: false },
  { cmd: "cmd", want: false },
  // The delete verb is an echo ARGUMENT, not at the clause head.
  { cmd: 'cmd /c "echo rmdir /s test"', want: false },
  // The flag belongs to the xcopy clause, not to the rd clause.
  { cmd: 'cmd /c "rd dir & xcopy /s foo"', want: false },
  // A path tail is not an independent flag token.
  { cmd: "cmd /c rd C:/s", want: false },
  // Here the leading switch is cmd.exe's own; the payload carries no flag.
  { cmd: "cmd /s /c rd dir", want: false },
  // Accepted non-goal: cmd.exe's own `^` escape is out of scope. Pinned as
  // current behavior, not required behavior — do not silently drop it.
  { cmd: "cmd /c r^d /^s dir", want: false },

  // Not a real vector: no standalone `rd` executable is reachable from
  // git-bash, and PowerShell spells recursion `-Recurse`, never a slash switch.
  { cmd: "rd /s dir", want: false },

  { cmd: "cmd /c rmdir /s $(echo x)", want: null },
  // A flag-position token led by a slash and carrying `%` or `!` cannot be
  // resolved statically, so it fails closed — symmetric to rm.js (CPR-ORTH).
  { cmd: "cmd /c rd /%F% dir", want: null },
  { cmd: "cmd /c rd dir /!F!", want: null },
  // Bare tokens are target/verb-position and can never expand to the flag
  // spelling, so that rule leaves them approved.
  { cmd: "cmd /c rd %F% dir", want: false },
  { cmd: "cmd /c %CMD% /s dir", want: false },
  { cmd: "cmd /c rd dir !F!", want: false },
  { cmd: "cmd /c rd %TEMP%\\dir /s", want: true },
  { cmd: "cmd /c rd %TEMP%\\dir", want: false },
]);

// Regression pins only: #2210 merely ADDS exports to rm.js/pwsh.js, so these
// extractors must keep returning exactly what they return today.
console.log("");
console.log("=== extractRmTargets (C1 regression pin) ===");
for (const { cmd, want } of [
  { cmd: "rm /non/repo/path", want: ["/non/repo/path"] },
  { cmd: 'rm "/non/repo/path with spaces"', want: ["/non/repo/path with spaces"] },
  { cmd: "rm -- /tmp/path", want: ["/tmp/path"] },
  { cmd: "rm $VAR", want: null },
  { cmd: 'rm ""', want: [] },
]) {
  checkDeep(
    "extractRmTargets: " + cmd + " → " + JSON.stringify(want),
    extractRmTargets(seg(cmd)),
    want
  );
}

console.log("");
console.log("=== extractPwshWriteTargets (C1 regression pin) ===");
for (const { cmd, want } of [
  { cmd: "Set-Content -Path /tmp/a -Value hi", want: ["/tmp/a"] },
  { cmd: "New-Item /tmp/b", want: ["/tmp/b"] },
  { cmd: "Move-Item /tmp/src /tmp/dst", want: ["/tmp/dst"] },
  { cmd: "Copy-Item /tmp/src /tmp/dst", want: ["/tmp/dst"] },
  { cmd: "Remove-Item $VAR", want: null },
  { cmd: "Set-Content -Path x -Value y", want: ["x"] },
]) {
  checkDeep(
    "extractPwshWriteTargets: " + cmd + " → " + JSON.stringify(want),
    extractPwshWriteTargets(seg(cmd)),
    want
  );
}

console.log("");
console.log("=== Summary ===");
console.log("Passed: " + passed);
console.log("Failed: " + failed);
if (failed > 0) process.exit(1);
