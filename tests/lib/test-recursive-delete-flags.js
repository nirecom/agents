#!/usr/bin/env node
// Tests: hooks/lib/bash-write-targets/rm.js, hooks/lib/bash-write-targets/pwsh.js, hooks/lib/bash-write-targets/cmd-exe.js  (lang-check: ignore)
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
// #2210 — unit tests for the three per-segment recursive-delete judgments.
// false=out of scope/no flag, true=recursive flag found, null=unresolvable
// flag content on a recursive-capable command (fail-closed); all three
// verdicts are asserted per function (test-design.md "Classifier / guard").
// Style mirrors tests/lib/test-command-ir.js — plain Node, no framework.
// TL3 gap (dropped `pwsh-not-required`, test-design.md:131): pwsh semantics
// never run real pwsh.exe; mitigated at verification-gate preflight, pwsh-required.
// round9 C11: mutation-probe results and findings are noted inline below, near the regexes they cover.

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

// checkDeep — structural (JSON) equality for array/null-shaped return values
// (extractRmTargets/extractPwshWriteTargets return string[]|null, never a
// primitive check() can compare with ===).
function checkDeep(label, actual, expected) {
  if (JSON.stringify(actual) === JSON.stringify(expected)) pass(label);
  else fail(label, expected, actual);
}

// TL3 gap: pure Node unit calls against parse()'d segments only — no real
// bash/pwsh/cmd.exe process expands these payloads (see the dispatcher's
// `# TL3 gap` block for the closest-to-action mitigation).

// Load a not-yet-implemented export without aborting the whole file: a missing
// module or export yields a stub returning a marker, so every case still runs
// and fails individually with a readable diagnosis instead of a require throw.
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

// C1: extractRmTargets/extractPwshWriteTargets are PRE-EXISTING exports of the
// same two files Step 1/2 extend with the functions above. Neither function's
// own source changes, but nothing pinned their output before this suite —
// loaded the same tolerant way so a real regression fails readably instead of
// aborting the whole file via require().
const extractRmTargets = loadFn("../../hooks/lib/bash-write-targets/rm", "extractRmTargets");
const extractPwshWriteTargets = loadFn("../../hooks/lib/bash-write-targets/pwsh", "extractPwshWriteTargets");

// seg(cmd) — the first IR segment of a command string, the shape all three
// judgments consume.
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

// ---------------------------------------------------------------------------
// hasRecursiveRmFlag — POSIX rm
// ---------------------------------------------------------------------------
runTable("hasRecursiveRmFlag", hasRecursiveRmFlag, [
  // true: every spelling / ordering / long-short form of the recursive flag
  { cmd: "rm -r dir", want: true },
  { cmd: "rm -r -f dir", want: true },
  { cmd: "rm -Rf dir", want: true },
  { cmd: "rm -fR dir", want: true },
  { cmd: "rm --recursive dir", want: true },
  { cmd: "rm -rf/tmp/x", want: true },
  // The two literal forms the settings.json deny globs used to carry — they must
  // stay blocked once those globs are removed (stage 2 of #2210).
  { cmd: "rm -rf dir", want: true },
  { cmd: "rm -fr dir", want: true },
  // C5: absolute path, env wrapper, and flags split with -f before -r.
  { cmd: "/bin/rm -rf dir", want: true },
  { cmd: "env rm -rf dir", want: true },
  { cmd: "rm -f -r dir", want: true },
  // C4: the flag trails the target — argv-walking must be position-independent.
  { cmd: "rm dir -r", want: true },

  // false: non-recursive rm, and commands outside the judgment's scope
  { cmd: "rm -f dir", want: false },
  { cmd: "rm dir", want: false },
  { cmd: "rm -i -v dir", want: false },
  { cmd: "ls -r dir", want: false },
  // `--` ends flag parsing: a later `-r` is a filename, not a recursion request.
  { cmd: "rm -- -r dir", want: false },
  // Known accepted gap (detail.md Step 1): a bare (non `-`-leading) variable
  // token is a target, not a flag. The cross-segment `FLAGS=-rf; rm $FLAGS x`
  // form is caught one layer up — see tests/lib/test-recursive-delete-scan.js.
  { cmd: 'rm "$file"', want: false },

  // null: `-`-leading flag whose content cannot be resolved statically
  { cmd: "rm -$VAR dir", want: null },

  // round9 C8: dequoting variants of the SAME recursive flag — the command-ir
  // tokenizer strips quotes before the flag classifier ever sees the token,
  // so a glued/split/escaped spelling must resolve identically to the plain
  // `-rf` form (each verified directly against the live tokenizer first).
  { cmd: 'rm "-rf" dir', want: true },
  { cmd: "rm '-rf' dir", want: true },
  { cmd: 'rm -"rf" dir', want: true },
  { cmd: 'rm ""-rf dir', want: true },
  { cmd: "rm \\-rf dir", want: true },
  { cmd: "rm \\-r dir", want: true },
  { cmd: 'rm "-r" dir', want: true },
  // Symmetric negative: the same quoting/escaping shapes on a NON-recursive
  // flag must stay approved — the dequoting itself is not what trips block.
  { cmd: 'rm "-f" dir', want: false },

  // round9 C10: escapable-vs-ordinary character set inside double quotes.
  // command-parser.js's tokenizeCore: "POSIX: inside \"...\", backslash
  // escapes only $ ` \" \\ or newline" — an ORDINARY character after a
  // backslash (e.g. `n`) is NOT an escape at all: both the backslash and the
  // following character stay literal in the value, so `"\n-rf"` dequotes to
  // the 5-char token `\n-rf` (backslash, n, -, r, f) — it does NOT start
  // with `-`, so it is a TARGET, not a flag, and must stay approved.
  { cmd: 'rm "\\n-rf" dir', want: false },
  // An escaped double-quote (`\"`, one of the five escapable characters)
  // dequotes to a literal `"` embedded in the token; the token still starts
  // with `-r`, so it must still classify as recursive.
  { cmd: 'rm "-r\\"f" dir', want: true },
  // An escaped backslash (`\\`, also escapable) dequotes to a single literal
  // backslash consumed together with its pair — the resulting token starts
  // with that backslash, not `-`, so it is a target, not a flag.
  { cmd: 'rm "\\\\-rf" dir', want: false },
  // An escaped newline (also escapable) is consumed into the token rather
  // than terminating it; the token still starts with `-r`, so it must still
  // classify as recursive (the embedded newline is not otherwise special).
  { cmd: 'rm "-r\\\nf" dir', want: true },
]);

// ---------------------------------------------------------------------------
// isRecursiveRmFlagToken — single-token classifier reused by the scan layer
// ---------------------------------------------------------------------------
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
  // PARAM_DEFAULT_RE / PARAM_EXPANSION_RE (round9 C11 mutation-probe run:
  // bin/mutation-probe.sh --test-cmd "bash tests/feature-2210-block-recursive-delete.sh"
  // hooks/lib/bash-write-targets/rm.js -> PARAM_EXPANSION_RE and the bare
  // `-([A-Za-z]+)` flag regex are now KILLED by these cases (2/3). PARAM_DEFAULT_RE
  // itself stays LIVE — not a test gap: PARAM_EXPANSION_RE's `[-=?+]` alternation
  // already matches every "-"/":-"-operator input PARAM_DEFAULT_RE does, with an
  // identical captured group, so PARAM_DEFAULT_RE is unreachable-in-effect;
  // reported as a source finding, out of scope for this test-only pass.
  { tok: "${X:--rf}", want: true },   // ${VAR:-default}, default is flag-shaped
  { tok: "${X--rf}", want: true },    // ${VAR-default} (no colon) variant
  { tok: "${X:-rf}", want: false },   // default lacks the leading "-": a target, not a flag
  { tok: "${X:-f}", want: false },    // default is a real flag but not recursive
  { tok: "${X:=-rf}", want: true },   // ${VAR:=default} assign-default operator
  { tok: "${X:+-rf}", want: true },   // ${VAR:+alt} alternate-value operator
  { tok: "${X:?-rf}", want: true },   // ${VAR:?msg} error-message operator (operand still extracted)
  { tok: "${X:-$Y}", want: null },    // default itself references another var: unresolvable
  { tok: "${X:-`cmd`}", want: null }, // default is a command substitution: unresolvable
]) {
  check("isRecursiveRmFlagToken: " + tok + " → " + JSON.stringify(want), isRecursiveRmFlagToken(tok), want);
}

// ---------------------------------------------------------------------------
// hasRecursivePwshFlag — PowerShell Remove-Item family
// ---------------------------------------------------------------------------
runTable("hasRecursivePwshFlag", hasRecursivePwshFlag, [
  // true: cmdlet + alias spellings, short flag form, explicit :$true
  { cmd: "Remove-Item -Recurse dir", want: true },
  { cmd: "Remove-Item -Recurse -Force dir", want: true },
  { cmd: "ri -r dir", want: true },
  { cmd: "rd -Recurse dir", want: true },
  { cmd: "del -Recurse dir", want: true },
  { cmd: "Remove-Item -Recurse:$true dir", want: true },
  // Regression (detail.md Step 2): a variable TARGET must not fail-closed the
  // way an unresolvable FLAG does — this is the everyday PowerShell spelling.
  { cmd: 'Remove-Item -Recurse "$dir"', want: true },
  // C6: rmdir/erase aliases and the -Rec abbreviated form.
  { cmd: "rmdir -Recurse dir", want: true },
  { cmd: "erase -Recurse dir", want: true },
  { cmd: "Remove-Item -Rec dir", want: true },
  // C4: the flag trails the target.
  { cmd: "Remove-Item dir -Recurse", want: true },
  // round-4 C3: PowerShell is case-INSENSITIVE for both cmdlet/alias names and
  // parameter/switch-value spellings. The Step 2 algorithm already lowercases
  // effCmd/flagName/suffix before comparing, so these are regression pins on
  // that case-insensitivity, not a new gap.
  { cmd: "Remove-Item -Recurse:$TRUE dir", want: true },
  { cmd: "Remove-Item -Recurse:$FALSE dir", want: false },
  { cmd: "remove-item -recurse:$true dir", want: true },
  { cmd: "REMOVE-ITEM -ReCuRsE dir", want: true },
  { cmd: "RI -R dir", want: true },

  // false: non-recursive invocation, explicit disable, out-of-scope cmdlet
  // Finding 5: `rd` is a PWSH_RECURSIVE_DELETE_CMDLETS member, but `/s` is not
  // a `-`-leading flag token, so this alone does not make bare `rd /s dir`
  // detected (see the TODO gap pinned in the cmd-exe table above).
  { cmd: "rd /s dir", want: false },
  { cmd: "Remove-Item -Force dir", want: false },
  { cmd: "Remove-Item -Path dir", want: false },
  { cmd: "Remove-Item -Recurse:$false dir", want: false },
  { cmd: "Set-Content -Path x -Value y", want: false },

  // null: flag NAME (not target, not switch value) is unresolvable
  { cmd: "Remove-Item -$VAR dir", want: null },
  { cmd: "Remove-Item -Recurse:$SomeVar dir", want: null },
]);

// ---------------------------------------------------------------------------
// hasRecursiveCmdExeFlag — cmd.exe /c payloads
// ---------------------------------------------------------------------------
runTable("hasRecursiveCmdExeFlag", hasRecursiveCmdExeFlag, [
  // true: rmdir / rd / del with an independent /s token, quoted or bare, /c or /k
  { cmd: "cmd /c rmdir /s dir", want: true },
  { cmd: 'cmd /c "rmdir /s dir"', want: true },
  { cmd: "cmd /c rd /s dir", want: true },
  { cmd: "cmd /c del /s dir", want: true },
  { cmd: "cmd.exe /k rmdir /s dir", want: true },
  { cmd: 'cmd /c "rmdir /s dir & echo done"', want: true },
  // /s as an independent flag AND as a path tail in the same clause: the
  // independent token still triggers (round-2 C4).
  { cmd: "cmd /c rd /s C:/s", want: true },
  // C8: clause separators beyond & (&&/||/|), uppercase /C, and cmd.exe's
  // own /S switch (before /c) coexisting with a real /s in the /c payload.
  { cmd: 'cmd /c "rmdir /s dir && echo done"', want: true },
  { cmd: 'cmd /c "rmdir /s dir || echo fail"', want: true },
  { cmd: 'cmd /c "echo start | rmdir /s dir"', want: true },
  { cmd: "cmd /C rmdir /S dir", want: true },
  { cmd: "cmd /s /c rd /s dir", want: true },
  // C4: the flag trails the target.
  { cmd: "cmd /c rd dir /s", want: true },
  // round-4 fix (detail.md Step 3 item 2/4): `/c`/`/k` is matched by PREFIX,
  // not exact equality. The outer bash-style tokenizer joins `/c"..."` (no
  // space before the quote) into ONE argv token ("/crd /s dir"), which is a
  // prefix match on `/c`; the remainder after stripping the 2-char prefix
  // ("rd /s dir") becomes the innerText, so this now detects and blocks.
  { cmd: 'cmd /c"rd /s dir"', want: true },

  // false: no /s, no /c, unrelated verb, mention-only, and cross-clause /s
  { cmd: "cmd /c rmdir dir", want: false },
  { cmd: "cmd /c dir", want: false },
  { cmd: "cmd", want: false },
  // The delete verb appears as an ECHO ARGUMENT, not at the clause head.
  { cmd: 'cmd /c "echo rmdir /s test"', want: false },
  // The /s belongs to a DIFFERENT clause (xcopy), not to the rd clause.
  { cmd: 'cmd /c "rd dir & xcopy /s foo"', want: false },
  // Round-2 C4 regression: `C:/s` is a path, not an independent /s flag.
  { cmd: "cmd /c rd C:/s", want: false },
  // C8: cmd.exe's own /S switch precedes /c; the /c payload itself has no /s.
  { cmd: "cmd /s /c rd dir", want: false },
  // round-4 C2, documented non-goal: cmd.exe's OWN `^` escape character
  // (`r^d /^s`) is explicitly out of scope (detail.md Step 3 + Out of scope:
  // "cmd.exe自身のエスケープ／引用符処理の追跡"). Pinned as the CURRENT
  // (accepted-gap) behavior, not a required one — do not silently drop it.
  { cmd: "cmd /c r^d /^s dir", want: false },

  // SKIPPED: bare `rd /s dir` (no `cmd /c` head) — not a real vector.
  // Because: effCmd resolves to "rd", not "cmd"/"cmd.exe", so
  // hasRecursiveCmdExeFlag's own guard (step 1) returns false; `rd` is a
  // cmd.exe internal command with no standalone executable reachable from
  // git-bash, and real PowerShell has no `/s` switch (only `-Recurse`), so
  // this is not a working recursive-delete invocation in any reachable
  // shell. `cmd /c rd /s dir` is covered separately. See detail.md Risks &
  // edge cases.
  // L3 gap: no (not a real vector, not a coverage gap)
  { cmd: "rd /s dir", want: false },

  // null: payload after /c cannot be resolved statically
  { cmd: "cmd /c rmdir /s $(echo x)", want: null },
  // round-4 fix (detail.md Step 3 item 7): a FLAG-POSITION token that starts
  // with `/` and contains `%`/`!` (cannot be resolved to exactly `/s`
  // statically) upgrades the clause verdict to null (fail-closed), symmetric
  // to rm.js's `-`-leading unresolvable-token rule (CPR-ORTH).
  { cmd: "cmd /c rd /%F% dir", want: null },
  { cmd: "cmd /c rd dir /!F!", want: null },
  // These three bare (non-`/`-leading) tokens are TARGET/verb-position, not
  // flag-position — the round-4 rule above only inspects `/`-leading tokens
  // (a bare token can never literally equal "/s" after expansion), so they
  // are correctly out of its scope and stay approved.
  { cmd: "cmd /c rd %F% dir", want: false },
  { cmd: "cmd /c %CMD% /s dir", want: false },
  { cmd: "cmd /c rd dir !F!", want: false },
  // Target-position %VAR% expansion: a literal /s elsewhere in the clause
  // still blocks; with no /s anywhere the clause approves.
  { cmd: "cmd /c rd %TEMP%\\dir /s", want: true },
  { cmd: "cmd /c rd %TEMP%\\dir", want: false },
]);

// ---------------------------------------------------------------------------
// C1: extractRmTargets / extractPwshWriteTargets — regression pins.
// Step 1/2 only ADD hasRecursiveRmFlag/hasRecursivePwshFlag to rm.js/pwsh.js;
// these two pre-existing extractors must keep returning exactly what they
// return today. Representative inputs mirror
// tests/fix-enforce-worktree-bundle-a-targets-rm.sh (rm) and pwsh.js's own
// doc comment (pwsh) — a deliberately small pin set, not full coverage.
// ---------------------------------------------------------------------------
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
