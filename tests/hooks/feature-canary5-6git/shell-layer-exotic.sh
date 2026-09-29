#!/usr/bin/env bash
# tests/hooks/feature-canary5-6git/shell-layer-exotic.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-patterns/classify.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, classify, write-patterns, ir-migration, interpreter-c, security, scope:issue-specific, hook-registration, pwsh-not-required
# FINAL shell-layer round: a write verb riding as an ARGUMENT (eval body, xargs
# target, find -exec/-execdir/-ok/-okdir/-delete) is re-parsed; dynamic or
# unparseable bodies fail-closed to WRITE. pwsh cases drive node over parsed IR.
# L3 gap (every L2 case): real PreToolUse dispatch only fires in a live claude -p
# session; live-session env / payload paths / backslash normalization differ.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# BYPASS → isExoticExecWriteIR true (L1): a write hidden in an eval/xargs/find
# action clause, or a dynamic/unparseable body (fail-closed), must be flagged.
bq_hdr "=== EXOTIC: BYPASS — isExoticExecWriteIR true (L1) ==="
case_begin "exotic-exec-write-bypass" "hooks/lib/bash-write-targets.js"
bq_table green isExoticExecWriteIR <<'BYPASS_TABLE'
EX.1 eval "rm f"^eval "rm f"^true
EX.2 eval rm f (unquoted)^eval rm f^true
EX.3 eval 'rm f' (single-quoted body still executes)^eval 'rm f'^true
EX.4 eval "$DYNAMIC" (dynamic → fail-closed)^eval "$DYNAMIC"^true
EX.5 xargs rm (piped)^echo f | xargs rm^true
EX.6 xargs -I{} rm {} < list^xargs -I{} rm {} < list^true
EX.7 xargs -0 -n1 git commit^xargs -0 -n1 git commit^true
EX.8 find -exec rm^find . -exec rm {} \;^true
EX.9 find -delete^find . -delete^true
EX.10 find -execdir git commit^find . -execdir git commit \;^true
EX.11 find -exec sh -c 'rm f' (nested interpreter)^find . -exec sh -c 'rm f' \;^true
EX.12 xargs -n1 tee out (write target)^echo x | xargs -n1 tee out^true
EX.13 eval with redirect write^eval "echo x > out"^true
FC1679-C eval "$(bash /tmp/x.sh)" (non-allowlisted interpreter)^eval "$(bash /tmp/x.sh)"^true
FC1679-D eval "$(python3 gen.py)" (arbitrary generator)^eval "$(python3 gen.py)"^true
FC1679-D2 eval "$(node -e ...writeFileSync)" (inline write)^eval "$(node -e 'require("fs").writeFileSync("x","y")')"^true
FC1679-D5 eval "$(/opt/tool/gen.sh)" (arbitrary executable)^eval "$(/opt/tool/gen.sh)"^true
BYPASS_TABLE
case_end

# NO OVER-BLOCK → isExoticExecWriteIR false (L1): genuine inner READs and find
# without an action clause must stay false.
bq_hdr "=== EXOTIC: NO OVER-BLOCK — isExoticExecWriteIR false (L1) ==="
case_begin "exotic-exec-no-over-block" "hooks/lib/bash-write-targets.js"
bq_table green isExoticExecWriteIR <<'READ_TABLE'
XR.1 eval "git log" (static read)^eval "git log"^false
XR.2 eval git log (unquoted read)^eval git log^false
XR.3 xargs cat (read target)^echo f | xargs cat^false
XR.4 xargs -n1 git log (read target)^echo f | xargs -n1 git log^false
XR.5 find -name (no action)^find . -name '*.js'^false
XR.6 find -type f -exec cat (read action)^find . -type f -exec cat {} \;^false
XR.7 bare find^find .^false
XR.8 command substitution read (not exotic here)^x=$(git log)^false
XR.9 process-sub reads (handled elsewhere, not exotic)^diff <(git show a) <(git show b)^false
FP1679-J eval "$(ssh-agent -s)" (shell-init idiom)^eval "$(ssh-agent -s)"^false
FP1679-K eval "$(fnm env --use-on-cd)" (shell-init idiom)^eval "$(fnm env --use-on-cd)"^false
FP1679-K2 eval "$(direnv hook bash)" (shell-init idiom)^eval "$(direnv hook bash)"^false
READ_TABLE
case_end

# Process substitution + interpreter-c are ALREADY covered; lock the full
# fast-allow write-signal (classify==write OR any wired predicate) so dropping
# that coverage is caught here.
bq_hdr "=== EXOTIC: process-sub + interpreter-c write-signal (L1) ==="
case_begin "exotic-write-signal" "hooks/lib/bash-write-patterns/classify.js"
bq_table write_signal <<'PS_TABLE'
PS.1 tee >(rm f) → write^tee >(rm f)^true
PS.2 diff <(rm f) x → write^diff <(rm f) x^true
PS.3 diff <(git show a) <(git show b) → read^diff <(git show a) <(git show b)^false
PS.4 sh -c "rm f" → write^sh -c "rm f"^true
PS.5 dash -c "rm f" → write^dash -c "rm f"^true
PS.6 pwsh -Command Remove-Item → write^pwsh -Command "Remove-Item f"^true
PS.7 pwsh -c Remove-Item → write^pwsh -c "Remove-Item f"^true
PS.8 /bin/sh -c "rm f" (basename) → write^/bin/sh -c "rm f"^true
PS.9 bash -c "cat x && grep y" → read^bash -c "cat x && grep y z"^false
PS.10 pwsh -c "Get-Content f" → read^pwsh -c "Get-Content f"^false
PS_TABLE
case_end

# L2 hook-boundary — exotic bypass forms from MAIN worktree → BLOCK; genuine
# inner reads → ALLOW. Drives the real hook over stdin JSON.
bq_hdr "=== EXOTIC L2: bypass forms from MAIN worktree → BLOCK ==="
TMP_ROOT="$(mk_tmp_root exotic)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { bq_flush; skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }
echo "f" > "$TMP_ROOT/main/f"

case_begin "exotic-l2-bypass-block" "hooks/enforce-worktree.js"
bq_row "XL2.1 eval \"rm f\" from main → block" block guard "$REPO" 'eval "rm f"'
bq_row "XL2.2 eval rm f from main → block" block guard "$REPO" 'eval rm f'
bq_row "XL2.3 xargs rm from main → block" block guard "$REPO" 'echo f | xargs rm'
bq_row "XL2.4 xargs -I{} rm from main → block" block guard "$REPO" 'xargs -I{} rm {} < list'
bq_row "XL2.5 find -exec rm from main → block" block guard "$REPO" 'find . -exec rm {} \;'
bq_row "XL2.6 find -delete from main → block" block guard "$REPO" 'find . -delete'
bq_row "XL2.7 find -execdir git commit from main → block" block guard "$REPO" 'find . -execdir git commit \;'
bq_row "XL2.8 sh -c \"rm f\" from main → block" block guard "$REPO" 'sh -c "rm f"'
bq_row "XL2.9 dash -c \"rm f\" from main → block" block guard "$REPO" 'dash -c "rm f"'
bq_row "XL2.10 pwsh -Command Remove-Item from main → block" block guard "$REPO" 'pwsh -Command "Remove-Item f"'
bq_row "XL2.11 eval \"\$DYNAMIC\" from main → block (fail-closed)" block guard "$REPO" 'eval "$DYNAMIC"'
case_end

bq_hdr "=== EXOTIC L2 controls: genuine inner reads → ALLOW (no over-block) ==="
case_begin "exotic-l2-read-controls-allow" "hooks/enforce-worktree/bash-write-scope.js"
bq_row "XL2.C1 eval \"git log\" from main → allow" allow guard "$REPO" 'eval "git log"'
bq_row "XL2.C2 xargs cat from main → allow" allow guard "$REPO" 'echo f | xargs cat'
bq_row "XL2.C3 find -name (no action) from main → allow" allow guard "$REPO" "find . -name '*.js'"
bq_row "XL2.C4 find -exec cat (read action) from main → allow" allow guard "$REPO" 'find . -type f -exec cat {} \;'
case_end
bq_flush

report_totals
exit "$FAIL"
