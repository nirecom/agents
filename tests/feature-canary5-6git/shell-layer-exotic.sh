#!/usr/bin/env bash
# tests/feature-canary5-6git/shell-layer-exotic.sh
# Tests: hooks/lib/bash-write-targets.js, hooks/lib/bash-write-patterns/classify.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, classify, write-patterns, ir-migration, interpreter-c, security, scope:issue-specific, hook-registration, pwsh-not-required
#
# FINAL shell-layer convergence round. Closes the remaining execution-bearing
# constructs where a retired-command write hid from the IR per-segment predicates
# because the write verb rides as an ARGUMENT to another command:
#   - eval "<body>"          — re-parse the body; dynamic/$-bearing → fail-closed.
#   - ... | xargs <cmd>       — re-parse the xargs target command (after its opts).
#   - find ... -exec <cmd> ;  — re-parse the action command; -delete is a write.
#   - find ... -execdir <cmd> ; / -ok / -okdir — same treatment.
# Process substitution `<(cmd)` / `>(cmd)` and `sh|dash|pwsh -c/-Command "<body>"`
# are ALREADY covered (the IR parser exposes process-sub inner commands as their
# own segments; classify()/isReadOnlyInterpreterC re-parse interpreter-c bodies).
# This part locks all four in: BYPASS forms → BLOCK from main; genuine inner
# READs → no over-block (predicate false / decision matches baseline).
#
# Design posture (user-approved): re-parse the inner/target command where
# statically feasible; DYNAMIC (variable-driven) or UNPARSEABLE bodies fail-closed
# to WRITE ("don't use elaborate syntax from the main worktree").
#
# pwsh-not-required: the pwsh-cmdlet cases drive node classify()/predicates over
# parsed IR — no real pwsh shell is spawned.
#
# L3 gap (every L2 case): real PreToolUse dispatch only fires in a live claude -p
# session. These L2 cases drive `node hooks/enforce-worktree.js` over stdin JSON;
# live-session env / payload-derived path / Windows backslash normalization differ
# from in-process fixtures. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

source "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

# ---------------------------------------------------------------------------
# BYPASS → isExoticExecWriteIR true (L1). A write hidden in an eval/xargs/find
# action clause, or a dynamic/unparseable body (fail-closed), must be flagged.
# ---------------------------------------------------------------------------
echo "=== EXOTIC: BYPASS — isExoticExecWriteIR true (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(green_pred isExoticExecWriteIR "$cmd")"
done <<'BYPASS_TABLE'
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
BYPASS_TABLE

# ---------------------------------------------------------------------------
# NO OVER-BLOCK → isExoticExecWriteIR false (L1). Genuine inner READs and
# find without an action clause must stay false.
# ---------------------------------------------------------------------------
echo "=== EXOTIC: NO OVER-BLOCK — isExoticExecWriteIR false (L1) ==="
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(green_pred isExoticExecWriteIR "$cmd")"
done <<'READ_TABLE'
XR.1 eval "git log" (static read)^eval "git log"^false
XR.2 eval git log (unquoted read)^eval git log^false
XR.3 xargs cat (read target)^echo f | xargs cat^false
XR.4 xargs -n1 git log (read target)^echo f | xargs -n1 git log^false
XR.5 find -name (no action)^find . -name '*.js'^false
XR.6 find -type f -exec cat (read action)^find . -type f -exec cat {} \;^false
XR.7 bare find^find .^false
XR.8 command substitution read (not exotic here)^x=$(git log)^false
XR.9 process-sub reads (handled elsewhere, not exotic)^diff <(git show a) <(git show b)^false
READ_TABLE

# ---------------------------------------------------------------------------
# Process substitution + interpreter-c: ALREADY covered by existing predicates.
# Lock the FULL fast-allow-gate write-signal (any of the wired predicates) so a
# regression that drops process-sub / interpreter-c coverage is caught here.
# write_signal = classify==write OR any green/git/substitution/exotic predicate.
# ---------------------------------------------------------------------------
echo "=== EXOTIC: process-sub + interpreter-c write-signal (L1) ==="
write_signal() {
  run_with_timeout 30 node -e "
    const wt=process.argv[2];
    const {parse}=require(wt+'/hooks/lib/command-ir');
    const {classify,isGitWriteIR}=require(wt+'/hooks/lib/bash-write-patterns');
    const t=require(wt+'/hooks/lib/bash-write-targets');
    const ir=parse(process.argv[1]);
    const w = classify(ir)==='write' || isGitWriteIR(ir) ||
      t.isPosixRedirWriteIR(ir) || t.isPwshWriteIR(ir) || t.isFileOpWriteIR(ir) ||
      t.isCommandSubstWriteIR(ir) || t.isNewlineInjectedWriteIR(ir) || t.isExoticExecWriteIR(ir) ||
      t.isInterpreterCWriteIR(ir);
    process.stdout.write(String(w));
  " -- "$1" "$WT_NODE" 2>/dev/null
}
while IFS='^' read -r name cmd want; do
  [ -z "$name" ] && continue
  assert_eq "$name" "$want" "$(write_signal "$cmd")"
done <<'PS_TABLE'
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

# ---------------------------------------------------------------------------
# L2 hook-boundary — exotic bypass forms from MAIN worktree → BLOCK; genuine
# inner reads → ALLOW. Drives the real hook over stdin JSON.
# ---------------------------------------------------------------------------
echo "=== EXOTIC L2: bypass forms from MAIN worktree → BLOCK ==="
TMP_ROOT="$(mk_tmp_root exotic)"
trap 'rm -rf "$TMP_ROOT"' EXIT
REPO="$(setup_main_checkout "$TMP_ROOT" main)"
[ -z "$REPO" ] && { skip "L2 fixture unavailable"; report_totals; exit "$FAIL"; }
echo "f" > "$TMP_ROOT/main/f"

l2_decision() {
  local cmd="$1" cwd="$2"; shift 2
  local out; out="$(run_bash_guard "$cmd" "$cwd" ENFORCE_WORKTREE=on "$@")"
  echo "$out" | grep -q '"decision":"block"' && { echo block; return; }
  echo allow
}

assert_eq "XL2.1 eval \"rm f\" from main → block" \
  "block" "$(l2_decision 'eval "rm f"' "$REPO")"
assert_eq "XL2.2 eval rm f from main → block" \
  "block" "$(l2_decision 'eval rm f' "$REPO")"
assert_eq "XL2.3 xargs rm from main → block" \
  "block" "$(l2_decision 'echo f | xargs rm' "$REPO")"
assert_eq "XL2.4 xargs -I{} rm from main → block" \
  "block" "$(l2_decision 'xargs -I{} rm {} < list' "$REPO")"
assert_eq "XL2.5 find -exec rm from main → block" \
  "block" "$(l2_decision 'find . -exec rm {} \;' "$REPO")"
assert_eq "XL2.6 find -delete from main → block" \
  "block" "$(l2_decision 'find . -delete' "$REPO")"
assert_eq "XL2.7 find -execdir git commit from main → block" \
  "block" "$(l2_decision 'find . -execdir git commit \;' "$REPO")"
assert_eq "XL2.8 sh -c \"rm f\" from main → block" \
  "block" "$(l2_decision 'sh -c "rm f"' "$REPO")"
assert_eq "XL2.9 dash -c \"rm f\" from main → block" \
  "block" "$(l2_decision 'dash -c "rm f"' "$REPO")"
assert_eq "XL2.10 pwsh -Command Remove-Item from main → block" \
  "block" "$(l2_decision 'pwsh -Command "Remove-Item f"' "$REPO")"
assert_eq "XL2.11 eval \"\$DYNAMIC\" from main → block (fail-closed)" \
  "block" "$(l2_decision 'eval "$DYNAMIC"' "$REPO")"

echo "=== EXOTIC L2 controls: genuine inner reads → ALLOW (no over-block) ==="
assert_eq "XL2.C1 eval \"git log\" from main → allow" \
  "allow" "$(l2_decision 'eval "git log"' "$REPO")"
assert_eq "XL2.C2 xargs cat from main → allow" \
  "allow" "$(l2_decision 'echo f | xargs cat' "$REPO")"
assert_eq "XL2.C3 find -name (no action) from main → allow" \
  "allow" "$(l2_decision "find . -name '*.js'" "$REPO")"
assert_eq "XL2.C4 find -exec cat (read action) from main → allow" \
  "allow" "$(l2_decision 'find . -type f -exec cat {} \;' "$REPO")"

report_totals
exit "$FAIL"
