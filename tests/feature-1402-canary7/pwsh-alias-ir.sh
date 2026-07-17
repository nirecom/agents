#!/usr/bin/env bash
# Tests: hooks/lib/bash-write-patterns/patterns.js, hooks/lib/bash-write-patterns/classify.js, hooks/lib/bash-write-targets.js
# Tags: scope:issue-specific, canary-7, ir-migration, pwsh-alias, pwsh-not-required
#
# pwsh-alias retire verification (#1402 canary-7 Step 1):
# - sc/ac/ni/ri/mi/ci WRITE_PATTERNS entries retired; isPwshWriteIR owns detection.
# - mi/ci added to QUOTED_COMMAND_WORD_WRITE_NAMES (CPR-5 symmetry).
# - WRITE_PATTERNS must NOT contain pwsh-alias kind entries post-retire.
#
# L3 gap: real enforce-worktree hook invocation in a live claude session not tested.
# Closest-to-action: bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

echo "=== PA: pwsh-alias classify → read (IR predicate handles detection) ==="
# Post-retire design: pwsh-alias entries retired from WRITE_PATTERNS.
# classify() returns "read"; isPwshWriteIR=true handles detection at hook level.
# Consistent with the WRITE_PATTERNS retire pattern: git-write, posix-redir, pwsh (canary-5),
# file-op (rm/cp/mv), pkg-mgr, interpreter-c all follow the same "classify=read + IR=true" SSOT.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'PA_TABLE'
PA-sc^sc foo.txt^read
PA-ac^ac foo.txt^read
PA-ni^ni -Type File -Path foo.txt^read
PA-ri^ri foo.txt^read
PA-mi^mi src.txt dst.txt^read
PA-ci^ci src.txt dst.txt^read
PA_TABLE

echo "=== PA-IR: isPwshWriteIR detects pwsh aliases (true at IR level) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(pwsh_write_ir "$cmd")"
done <<'PA_IR_TABLE'
PA-IR-sc^sc foo.txt^true
PA-IR-ac^ac foo.txt^true
PA-IR-ni^ni -Type File -Path foo.txt^true
PA-IR-ri^ri foo.txt^true
PA-IR-mi^mi src.txt dst.txt^true
PA-IR-ci^ci src.txt dst.txt^true
PA_IR_TABLE

echo "=== PA-QCWW: mi/ci in QUOTED_COMMAND_WORD_WRITE_NAMES (CPR-5) ==="
# mi/ci at command position in double quotes → write (CPR-5 symmetric with sc/ac/ni/ri).
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'QCWW_TABLE'
PA-QCWW-mi-dq^"mi" src.txt dst.txt^write
PA-QCWW-ci-dq^"ci" src.txt dst.txt^write
PA-QCWW-ni-dq^"ni" -Path foo.txt^write
PA-QCWW-ri-dq^"ri" foo.txt^write
QCWW_TABLE

echo "=== PA-FP: quoted-arg context does NOT false-positive ==="
# mi/ci inside an echo string is NOT a write command.
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(classify_ir "$cmd")"
done <<'FP_TABLE'
PA-FP-echo-mi^echo "mi foo"^read
PA-FP-echo-ci^echo "ci foo"^read
FP_TABLE

echo "=== PA-PATTERNS: WRITE_PATTERNS must NOT contain pwsh-alias kind ==="
# Post-retire: no entry with kind "pwsh-alias" should remain in WRITE_PATTERNS.
pwsh_alias_count="$(run_with_timeout 30 node -e "
  const {WRITE_PATTERNS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  const count=(WRITE_PATTERNS||[]).filter(p=>p.kind==='pwsh-alias').length;
  process.stdout.write(String(count));
" 2>/dev/null)"
assert_eq "PA-PATTERNS-no-pwsh-alias-entries" "0" "$pwsh_alias_count"

# STRIP_KINDS must NOT contain "pwsh-alias" post-retire.
strip_has_pwsh_alias="$(run_with_timeout 30 node -e "
  const {STRIP_KINDS}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  process.stdout.write(String(STRIP_KINDS.has('pwsh-alias')));
" 2>/dev/null)"
assert_eq "PA-STRIP_KINDS-no-pwsh-alias" "false" "$strip_has_pwsh_alias"

# QUOTED_COMMAND_WORD_WRITE_NAMES must include mi and ci (symmetry addition).
mi_present="$(run_with_timeout 30 node -e "
  const {QUOTED_COMMAND_WORD_WRITE_NAMES}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  process.stdout.write(String(QUOTED_COMMAND_WORD_WRITE_NAMES.has('mi')));
" 2>/dev/null)"
assert_eq "PA-QCWW-mi-present" "true" "$mi_present"

ci_present="$(run_with_timeout 30 node -e "
  const {QUOTED_COMMAND_WORD_WRITE_NAMES}=require('${WT_NODE}/hooks/lib/bash-write-patterns/patterns');
  process.stdout.write(String(QUOTED_COMMAND_WORD_WRITE_NAMES.has('ci')));
" 2>/dev/null)"
assert_eq "PA-QCWW-ci-present" "true" "$ci_present"

report_totals
exit "$FAIL"
