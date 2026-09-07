"use strict";

// Tests: hooks/lib/bash-write-targets/recursive-delete-scan/scan.js
// Tags: scope:issue-specific, recursive-delete, bash-write-targets, guard, TL1
//
// Baseline judgments, newline injection, keyword heads, command substitution,
// and the zero-false-positive "mention" table.

const { runTable } = require("./harness");

runTable("direct", [
  { label: "rm -rf x", cmd: "rm -rf x", want: true },
  { label: "rm -r dir", cmd: "rm -r dir", want: true },
  { label: "Remove-Item -Recurse dir", cmd: "Remove-Item -Recurse dir", want: true },
  { label: "cmd /c rmdir /s dir", cmd: "cmd /c rmdir /s dir", want: true },
  { label: "rm -f file (non-recursive)", cmd: "rm -f file", want: false },
  { label: "ls -la (unrelated)", cmd: "ls -la", want: false },
  { label: "empty string", cmd: "", want: false },
  { label: "unterminated quote → parseFailure fail-closed", cmd: 'rm "unterminated', want: true },
  // The null fold must happen HERE, not only in the underlying flag classifier.
  { label: "rm -$VAR x (unresolvable rm flag, null -> block)", cmd: "rm -$VAR x", want: true },
  { label: "Remove-Item -$VAR dir (unresolvable pwsh flag NAME, null -> block)", cmd: "Remove-Item -$VAR dir", want: true },
  { label: "cmd /c rmdir /s $(echo x) (unresolvable cmd.exe payload, null -> block)", cmd: "cmd /c rmdir /s $(echo x)", want: true },
]);

// runCommands elements are joined with "\n" before reaching the scan.
runTable("newline", [
  { label: "second line carries rm -rf", cmd: "echo done\nrm -rf x", want: true },
  { label: "newline present but no recursive delete", cmd: "echo done\necho ok", want: false },
  // A naive pre-split would cut this quoted span into unbalanced halves.
  { label: "newline inside a double-quoted string is data", cmd: 'echo "line1\nline2"', want: false },
  { label: "three lines, recursive delete last", cmd: "cd /tmp\necho go\nrm -r dir", want: true },
  // stripHeredocBody must drop the BODY only, never the trailing statements.
  { label: "heredoc terminator followed by a real rm -rf still blocks",
    cmd: "cat <<'EOF'\nrm -rf inside body, ignored\nEOF\nrm -rf dir", want: true },
  { label: "heredoc body alone mentioning rm -rf does not block",
    cmd: "cat <<'EOF'\nrm -rf inside body, ignored\nEOF\necho done", want: false },
]);

runTable("keyword-heads", [
  // cmd0 is the keyword itself; argv holds the wrapped command's own tokens.
  { label: "if rm -rf /tmp/x; then echo ok; fi", cmd: "if rm -rf /tmp/x; then echo ok; fi", want: true },
  { label: "while rm -rf /tmp/x; do break; done", cmd: "while rm -rf /tmp/x; do break; done", want: true },
  { label: "until rm -rf /tmp/x; do break; done", cmd: "until rm -rf /tmp/x; do break; done", want: true },
  { label: "coproc rm -rf /tmp/x", cmd: "coproc rm -rf /tmp/x", want: true },
  // These heads take their own options, so the wrapped command is not at argv[0].
  { label: "exec -a foo rm -rf /tmp/x (exec -a NAME option)", cmd: "exec -a foo rm -rf /tmp/x", want: true },
  { label: "exec -c rm -rf /tmp/x (exec -c option)", cmd: "exec -c rm -rf /tmp/x", want: true },
  { label: "time -p rm -rf /tmp/x (time -p option)", cmd: "time -p rm -rf /tmp/x", want: true },
  { label: "trap -- 'rm -rf /tmp/x' EXIT (trap body as full script)", cmd: "trap -- 'rm -rf /tmp/x' EXIT", want: true },
  { label: "eval -- 'rm -rf /tmp/x' (eval body as full script)", cmd: "eval -- 'rm -rf /tmp/x'", want: true },
  // Brace-glue-peel is an ADDITIONAL hypothesis, never a replacement judgment.
  { label: "rm {a,b} -rf (brace-glue must not discard the rm judgment)", cmd: "rm {a,b} -rf", want: true },
  { label: "rm {a,b}/ -r (brace-glue, single -r)", cmd: "rm {a,b}/ -r", want: true },
  // Scope guard: PWSH_BLOCK_HEADS must stay narrow enough that unrelated heads
  // never reach the brace-glue-peel path.
  { label: "nice -5 npm test (unrelated wrapper, not a pwsh block head)", cmd: "nice -5 npm test", want: false },
  { label: "env --bogusopt ls (ambiguous option, no rm hiding underneath, N4)", cmd: "env --bogusopt ls", want: false },
  { label: "env --bogusopt rm -rf /tmp/x (ambiguous option WITH rm hiding underneath, N4)", cmd: "env --bogusopt rm -rf /tmp/x", want: true },
]);

runTable("cmdsubst", [
  // Double-quoted $(...) stays a single IR token, so only the span walk sees it.
  { label: 'echo "$(rm -rf x)"', cmd: 'echo "$(rm -rf x)"', want: true },
  { label: "echo $(rm -rf x)", cmd: "echo $(rm -rf x)", want: true },
  { label: "backtick substitution", cmd: 'echo "`rm -rf x`"', want: true },
  { label: 'echo "$(ls -la)" (harmless substitution)', cmd: 'echo "$(ls -la)"', want: false },
  // Single-quoted or escaped substitution syntax is literal text, so the shell
  // that later runs it prints it verbatim instead of executing it.
  { label: "echo single-quoted $(rm -rf x) literal", cmd: "echo '$(rm -rf x)'", want: false },
  { label: 'echo escaped \\$(rm -rf x) inside double quotes, literal', cmd: 'echo "\\$(rm -rf x)"', want: false },
  { label: "echo escaped backtick substitution, literal", cmd: 'echo "\\`rm -rf x\\`"', want: false },
]);

// Zero false positives: MENTIONING a recursive delete is not performing one.
runTable("mention", [
  { label: 'grep -r "rm -rf" .', cmd: 'grep -r "rm -rf" .', want: false },
  { label: 'git log -S "Bash(*rm -rf *)"', cmd: 'git log -S "Bash(*rm -rf *)"', want: false },
  { label: "gh issue create --body mentioning rm -rf", cmd: 'gh issue create --title "deny" --body "the rm -rf deny rule"', want: false },
  { label: "git commit -m mentioning Remove-Item -Recurse", cmd: 'git commit -m "document Remove-Item -Recurse policy"', want: false },
]);
