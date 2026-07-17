#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-targets/encoded.js, hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js
# Tags: scope:issue-specific, canary-7, ir-migration, encoded-ir, pwsh-not-required
#
# encoded.js IR predicate for pwsh-encoded retire (#1402 canary-7 Step 3).
#
# Contract under test (C2 is-correction):
# - isEncodedCommandWriteIR() is SCOPED to pwsh/powershell interpreters.
#   It returns true ONLY when a pwsh/powershell segment carries -EncodedCommand/-enc
#   OR the --%  stop-parsing operator.
# - echo hello → false (not a pwsh interpreter).
# - ffmpeg -enc x264 → false (ffmpeg is not pwsh, even though flag name matches).
# - WRITE_PATTERNS must NOT contain pwsh-encoded kind entries post-retire.
# - STRIP_KINDS must NOT contain "pwsh-encoded" post-retire.
#
# L3 gap: real enforce-worktree hook invocation in a live claude session not tested.
# Closest-to-action: bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

if ! encoded_module_present; then
  skip "encoded.js not yet implemented — isEncodedCommandWriteIR unavailable (RED-pending, fail-before-fix)"
  report_totals
  exit 0
fi

echo "=== EC: isEncodedCommandWriteIR — pwsh/powershell with encoded flags → true ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(encoded_write_ir "$cmd")"
done <<'EC_TABLE'
EC-pwsh-EncodedCommand^powershell -EncodedCommand SGVsbG8=^true
EC-pwsh-enc-short^pwsh -enc abc123^true
EC-pwsh-stop-parsing^pwsh --% Get-Item C:\path^true
EC-powershell-enc^powershell -enc SGVsbG8=^true
EC_TABLE

echo "=== EC-FP: isEncodedCommandWriteIR — non-pwsh interpreters → false (C2 core) ==="
# The critical C2 false-positive tests: these must return false, not true.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(encoded_write_ir "$cmd")"
done <<'ECFP_TABLE'
EC-FP-echo^echo hello^false
EC-FP-ffmpeg-enc^ffmpeg -enc video.mp4^false
EC-FP-pwsh-no-flag^pwsh Get-Item C:\file.txt^false
EC-FP-bash-enc^bash -enc ignored^false
EC-FP-git-status^git status^false
ECFP_TABLE

echo "=== EC-CL: classify() of pwsh-encoded → read (IR predicate handles detection) ==="
# Post-retire design: pwsh-encoded retired from WRITE_PATTERNS.
# classify() returns "read"; isEncodedCommandWriteIR=true handles detection at hook level.
# Consistent with the WRITE_PATTERNS retire pattern: git-write, posix-redir, pwsh,
# file-op (rm/cp/mv), pkg-mgr, interpreter-c all follow the same "classify=read + IR=true" SSOT.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'ECCL_TABLE'
EC-CL-pwsh-EncodedCommand^powershell -EncodedCommand SGVsbG8=^read
EC-CL-pwsh-enc-short^pwsh -enc abc123^read
EC-CL-pwsh-stop-parsing^pwsh --% rm -rf /^read
ECCL_TABLE

echo "=== EP: WRITE_PATTERNS — pwsh-encoded entries MUST be retired ==="
# Post-retire: no entry with kind "pwsh-encoded" should remain in WRITE_PATTERNS.
pwsh_encoded_count="$(run_with_timeout 30 node -e "
  const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  const count=(WRITE_PATTERNS||[]).filter(p=>p.kind==='pwsh-encoded').length;
  process.stdout.write(String(count));
" 2>/dev/null)"
assert_eq "EP-PATTERNS-no-pwsh-encoded-entries" "0" "$pwsh_encoded_count"

# STRIP_KINDS must NOT contain "pwsh-encoded" post-retire.
strip_has_pwsh_encoded="$(run_with_timeout 30 node -e "
  const {STRIP_KINDS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  process.stdout.write(String(STRIP_KINDS.has('pwsh-encoded')));
" 2>/dev/null)"
assert_eq "EP-STRIP_KINDS-no-pwsh-encoded" "false" "$strip_has_pwsh_encoded"

# Specific retired names must not be present.
for rname in "encoded-command" "ps-stop-parsing"; do
  rpresent="$(run_with_timeout 30 node -e "
    const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
    const count=(WRITE_PATTERNS||[]).filter(p=>p.name===process.argv[1]).length;
    process.stdout.write(String(count));
  " -- "$rname" 2>/dev/null)"
  assert_eq "EP-retired-$rname-absent" "0" "$rpresent"
done

report_totals
exit "$FAIL"
