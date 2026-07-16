#!/usr/bin/env bash
# tests/feature-canary6a-pkgmgr-interpc/interpc-ir.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-patterns/patterns.js
# Tags: scope:issue-specific, interpreter-c, canary-6a, ir-migration, fail-closed, security, pwsh-not-required
#
# isInterpreterCWriteIR IR predicate (#1411): the interpreter-c WRITE_PATTERNS
# entry (bash|sh|zsh|dash|pwsh|powershell|cmd -c/-Command <body>) migrated to a
# fail-closed IR predicate in hooks/lib/bash-write-targets.js. It re-parses the
# inner body and returns true when the body is a write (rm / redirect / git / npm /
# pwsh cmdlet …), false when the body is read-only, and fail-closed (true) for
# unrecognized / dynamic forms.
#
# RED-pending: isInterpreterCWriteIR is not exported yet → the bridge emits
# ERROR:not-exported → every predicate row FAILs cleanly (fail-before-fix). The
# module (bash-write-targets.js) already exists, so no SKIP path is needed here.
#
# L3 gap (what this test does NOT catch):
# - Real enforce-worktree hook invocation with an actual bash -c command going through the full PreToolUse pipeline
# - Session-scoped worktree path comparison in a real Claude session
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== IW: interpreter-c WRITE bodies → true ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(interpreter_c_write_ir "$cmd")"
done <<'IW_TABLE'
IW-rm^bash -c "rm foo"^true
IW-redir^sh -c "echo hi > out"^true
IW-pwsh-remove^pwsh -Command "Remove-Item foo"^true
IW-git-commit^bash -c "git commit"^true
IW-npm-install^bash -c "npm install"^true
IW_TABLE

echo "=== IR: interpreter-c READ bodies → false ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(interpreter_c_write_ir "$cmd")"
done <<'IR_TABLE'
IR-echo^sh -c "echo hello"^false
IR-getcontent^pwsh -Command "Get-Content foo"^false
IR-ls^zsh -c "ls"^false
IR_TABLE

echo "=== C3: IR position — no false positive on argument text ==="
# The write verb appears only inside a QUOTED argument to a read command, NOT as an
# actual interpreter -c invocation. isInterpreterCWriteIR must look at the parsed IR
# position (an echo/grep segment), not a raw-string 'bash -c' substring match.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(interpreter_c_write_ir "$cmd")"
done <<'C3_TABLE'
C3-echo-argtext^echo "run bash -c rm"^false
C3-grep-argtext^grep "bash -c" file^false
C3_TABLE

echo "=== ANSI: ANSI-C quoted bash -c \$'...' → true or fail-closed ==="
# ANSI-C quoting ($'...') is an unsafe/exotic form: isReadOnlyInterpreterC rejects
# it, so isInterpreterCWriteIR must NOT demote it to read. Expect fail-closed true.
assert_eq "ANSI-ansic-quote bash -c \$'rm foo' → true (fail-closed)" \
  "true" "$(interpreter_c_write_ir "bash -c \$'rm foo'")"

echo "=== FCU: unrecognized interpreter-c form → fail-closed true ==="
# A -c invocation whose body cannot be cleanly parsed to a single read segment must
# fail closed to write (never a silent demotion). Nested interpreter is one such form.
assert_eq "FCU-nested bash -c \"sh -c 'rm x'\" → true (fail-closed)" \
  "true" "$(interpreter_c_write_ir 'bash -c "sh -c '"'"'rm x'"'"'"')"

report_totals
exit "$FAIL"
