#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-targets/here.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js
# Tags: scope:issue-specific, canary-7, ir-migration, here-ir, pwsh-not-required
#
# here.js IR predicate + QUOTING_ONLY contract preservation (#1402 canary-7 Step 2).
#
# Contract under test (C1 is-correction):
# - isHereWriteIR() always returns false — here-shapes (<<EOF, <<<, @'...'@) supply
#   stdin data, not file writes. A co-located write redirect is owned by isPosixRedirWriteIR.
# - The WRITE_PATTERNS here-* 4 entries are RETAINED (not retired) as QUOTING_ONLY markers
#   so that classify()'s Group A override + isSafeHeredocOnly gate remain operational.
# - bash -c 'touch f' → write (C4: innerSegIsWrite wires isExtendedFileOpWriteIR).
# - sh -c 'pwsh -enc SGVsbG8=' → write (C4: innerSegIsWrite wires isEncodedCommandWriteIR).
#
# L3 gap: real enforce-worktree hook invocation in a live claude session not tested.
# Closest-to-action: bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== HC-C4: C4 wiring — interpreter-c wrappers with file-op/encoded inner bodies ==="
# Post-retire design: classify() returns "read" for interpreter-c wrappers (no WRITE_PATTERNS
# entry for bash/sh/pwsh -c since canary-6a retired it). Detection is via isInterpreterCWriteIR=true.
# C4 wiring (isExtendedFileOpWriteIR + isEncodedCommandWriteIR in innerSegIsWrite) ensures
# isReadOnlyInterpreterC("bash -c 'touch f'") returns false → isInterpreterCWriteIR returns true.
# Pre-impl MUST FAIL (RED state): innerSegIsWrite does not yet chain the new predicates.
# Post-impl MUST PASS: C4 wiring added — isInterpreterCWriteIR=true for these forms.
assert_eq "HC-C4-bash-c-touch-classify-read"     "read"  "$(classify_ir "bash -c 'touch f'")"
assert_eq "HC-C4-bash-c-touch-interp-c-true"     "true"  "$(interp_c_write_ir "bash -c 'touch f'")"
assert_eq "HC-C4-sh-c-pwsh-enc-classify-read"    "read"  "$(classify_ir "sh -c 'pwsh -enc SGVsbG8='")"
assert_eq "HC-C4-sh-c-pwsh-enc-interp-c-true"    "true"  "$(interp_c_write_ir "sh -c 'pwsh -enc SGVsbG8='")"

if ! here_module_present; then
  skip "here.js not yet implemented — isHereWriteIR unavailable (RED-pending, fail-before-fix)"
  report_totals
  exit "$FAIL"
fi

echo "=== HI: isHereWriteIR — always false for pure here-shapes ==="
# here-doc: stdin data, not a file write.
assert_eq "HI-heredoc-no-redirect"       "false" "$(here_write_ir 'cat <<EOF
foo
EOF')"

# here-string: stdin data.
assert_eq "HI-herestring-stdin"          "false" "$(here_write_ir 'cmd <<< "input"')"

# pwsh here-string: argument data.
assert_eq "HI-pwsh-here-single"          "false" "$(here_write_ir "Set-Content foo.txt @'
content
'@")"

# Non-here-doc command: also false (isHereWriteIR is not a catch-all).
assert_eq "HI-echo-not-heredoc"          "false" "$(here_write_ir 'echo hello')"
assert_eq "HI-git-status-not-heredoc"    "false" "$(here_write_ir 'git status')"
assert_eq "HI-touch-not-heredoc"         "false" "$(here_write_ir 'touch foo.txt')"

echo "=== HC: classify() — QUOTING_ONLY contract still operational ==="
# here-doc redirect: write (isPosixRedirWriteIR owns the > redirect).
assert_eq "HC-heredoc-with-redirect"     "write" "$(classify_ir 'cat > file.txt <<EOF
content
EOF')"

# Group A gh command with heredoc body → read (QUOTING_ONLY override fires because
# here-* entries are RETAINED in WRITE_PATTERNS as QUOTING_ONLY markers).
assert_eq "HC-gh-pr-create-heredoc-read" "read" "$(classify_ir 'gh pr create --body "$(cat <<EOF
My PR body
EOF
)"')"

# Unsafe heredoc (interpreter + $(rm foo)) → write (isSafeHeredocOnly gate fires).
# This is the C1 core regression test: if here-* were retired from WRITE_PATTERNS,
# the QUOTING_ONLY override path would be dead and this would wrongly return "read".
assert_eq "HC-unsafe-heredoc-write"      "write" "$(classify_ir 'gh pr create --body "$(bash <<EOF
$(rm foo)
EOF
)"')"

echo "=== HP: WRITE_PATTERNS — here-* entries RETAINED (not retired) ==="
# here-doc entry must still be present in WRITE_PATTERNS.
heredoc_count="$(run_with_timeout 30 node -e "
  const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  const count=(WRITE_PATTERNS||[]).filter(p=>p.name==='here-doc').length;
  process.stdout.write(String(count));
" 2>/dev/null)"
assert_eq "HP-here-doc-retained"         "1" "$heredoc_count"

# here-string entry must still be present.
herestring_count="$(run_with_timeout 30 node -e "
  const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  const count=(WRITE_PATTERNS||[]).filter(p=>p.name==='here-string').length;
  process.stdout.write(String(count));
" 2>/dev/null)"
assert_eq "HP-here-string-retained"      "1" "$herestring_count"

# pwsh-here-single entry must still be present.
pwsh_here_single="$(run_with_timeout 30 node -e "
  const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  const count=(WRITE_PATTERNS||[]).filter(p=>p.name==='pwsh-here-single').length;
  process.stdout.write(String(count));
" 2>/dev/null)"
assert_eq "HP-pwsh-here-single-retained" "1" "$pwsh_here_single"

# pwsh-here-double entry must still be present.
pwsh_here_double="$(run_with_timeout 30 node -e "
  const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  const count=(WRITE_PATTERNS||[]).filter(p=>p.name==='pwsh-here-double').length;
  process.stdout.write(String(count));
" 2>/dev/null)"
assert_eq "HP-pwsh-here-double-retained" "1" "$pwsh_here_double"

# QUOTING_ONLY_NAMES must include all 4 here-* names.
for qname in "here-doc" "here-string" "pwsh-here-single" "pwsh-here-double"; do
  qpresent="$(run_with_timeout 30 node -e "
    const {QUOTING_ONLY_NAMES}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    process.stdout.write(String(QUOTING_ONLY_NAMES.has(process.argv[1])));
  " -- "$qname" 2>/dev/null)"
  assert_eq "HP-QUOTING_ONLY_NAMES-$qname" "true" "$qpresent"
done

report_totals
exit "$FAIL"
