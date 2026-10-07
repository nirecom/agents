#!/usr/bin/env bash
# tests/bin/feature-2434-control-dir-form.sh
# Tests: bin/lib/safe-state-path.sh, bin/workflow-control-dir, hooks/lib/temporary-migrations/control-dir-split/index.js, hooks/workflow-state/state-io/control-dir.js
# Tags: TL2, scope:issue-specific, control-dir, migration, safe-state-path, parity
# TL3 gap (what this test does NOT catch):
# - A real caller (review loop, ledger) sourcing the deployed ~/.claude copy of safe-state-path.sh
# - The stripped-install bash fallback (no resolver CLI): deliberately unpinned, open design question
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: migration

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

WCD_CLI="$AGENTS_DIR/bin/workflow-control-dir"
SAFE_LIB="$AGENTS_DIR/bin/lib/safe-state-path.sh"
SID="aabbccdd-1111-2222-3333-444455556666"
RND="detail-plan-round-number.txt"
LEDGER="review-security-shared-concern-ledger.txt"

unset CONTROL_MIGRATION_FAULT AGENTS_CONFIG_DIR CLAUDE_TRANSCRIPT_BASE_DIR 2>/dev/null || true
ROOT_TMP="$(make_tmp)"
trap 'rm -rf "$ROOT_TMP"' EXIT
cd "$ROOT_TMP" || exit 1

# new_fx — a fresh fixture root with its own HOME, workflow dir, plans dir and neutral CWD.
new_fx() {
  local d
  d="$(mktemp -d "$ROOT_TMP/fx.XXXXXX")" || return 1
  mkdir -p "$d/home" "$d/workflow-state" "$d/plans" "$d/cwd"
  printf '%s\n' "$d"
}

# fx_env <fx> — pin every state root to the fixture (run inside a subshell only).
fx_env() {
  cd "$1/cwd" || exit 99
  export HOME="$1/home"
  WORKFLOW_STATE_DIR="$(np "$1/workflow-state")"
  WORKFLOW_PLANS_DIR="$(np "$1/plans")"
  export WORKFLOW_STATE_DIR WORKFLOW_PLANS_DIR
  export CONTROL_MIGRATION_FAULT="${FX_FAULT:-}"
}

# run_cli <fx> <sid> [args...] / run_sp <fx> <sid> [file] — stdout to <fx>/out, stderr to <fx>/err.
run_cli() {
  local fx="$1" sid="$2"
  shift 2
  ( fx_env "$fx"; node "$WCD_CLI" --session "$sid" "$@" > "$fx/out" 2> "$fx/err" )
}
run_sp() {
  local fx="$1"
  shift
  ( fx_env "$fx"; source "$SAFE_LIB"; sp_control_dir "$@" > "$fx/out" 2> "$fx/err" )
}

out_of() { tr -d '\r' < "$1/out"; }
ctl_of() { printf '%s\n' "$1/workflow-state/$SID.control"; }

check() { # <label> <got> <want>
  if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$3") got=$(printf '%q' "$2")"; fi
}

# listing <dir> — sorted "name cksum" of every regular file directly in <dir>.
listing() {
  local f
  [[ -d "$1" ]] || { echo "<no-dir>"; return 0; }
  for f in "$1"/* "$1"/.[!.]*; do
    [[ -f "$f" ]] || continue
    printf '%s %s\n' "${f##*/}" "$(cksum < "$f")"
  done | LC_ALL=C sort
}

seed_control() { # <fx>
  printf '3\n' > "$1/plans/$SID-$RND"
  printf 'C1 open ledger-line\n' > "$1/plans/$SID-$LEDGER"
}

assert_migrated() { # <label> <fx>
  local ctl
  ctl="$(ctl_of "$2")"
  check "$1:round-content" "$(cat "$ctl/$RND" 2>/dev/null)" "3"
  check "$1:ledger-content" "$(cat "$ctl/$LEDGER" 2>/dev/null)" "C1 open ledger-line"
  if [[ -e "$2/plans/$SID-$RND" || -e "$2/plans/$SID-$LEDGER" ]]; then
    fail "$1:legacy-gone" "legacy copy still in plans dir: $(listing "$2/plans" | tr '\n' ' ')"
  else
    pass "$1:legacy-gone"
  fi
}

case_begin "cli-dir-only-migrates-whole-session" "bin/workflow-control-dir"
FX="$(new_fx)"
seed_control "$FX"
run_cli "$FX" "$SID" --for-write
check "cli-dir-only:rc" "$?" "0"
check "cli-dir-only:path" "$(np "$(out_of "$FX")")" "$(np "$(ctl_of "$FX")")"
assert_migrated "cli-dir-only" "$FX"
case_end

case_begin "sp-dir-only-fresh-migrates" "bin/lib/safe-state-path.sh"
FX="$(new_fx)"
seed_control "$FX"
run_sp "$FX" "$SID"
check "sp-dir-only-fresh:rc" "$?" "0"
check "sp-dir-only-fresh:path" "$(np "$(out_of "$FX")")" "$(np "$(ctl_of "$FX")")"
assert_migrated "sp-dir-only-fresh" "$FX"
case_end

# Regression: an existing, empty control dir used to satisfy the dir-only fast path,
# so the caller got the empty dir while the legacy ledger stayed behind.
case_begin "sp-dir-only-empty-existing-dir-still-migrates" "bin/lib/safe-state-path.sh"
FX="$(new_fx)"
seed_control "$FX"
mkdir -p "$(ctl_of "$FX")"
run_sp "$FX" "$SID"
check "sp-dir-only-existing:rc" "$?" "0"
check "sp-dir-only-existing:path" "$(np "$(out_of "$FX")")" "$(np "$(ctl_of "$FX")")"
assert_migrated "sp-dir-only-existing" "$FX"
case_end

case_begin "cli-dir-only-fault-fails-closed" "hooks/workflow-state/state-io/control-dir.js"
FX="$(new_fx)"
seed_control "$FX"
FX_FAULT="link-fail" run_cli "$FX" "$SID" --for-write
check "cli-fault:rc" "$?" "3"
if grep -qF "legacy path:" "$FX/err"; then pass "cli-fault:stderr-legacy-path"
else fail "cli-fault:stderr-legacy-path" "stderr: $(cat "$FX/err")"; fi
if grep -q "failed" "$FX/workflow-state/control-migration.log" 2>/dev/null; then pass "cli-fault:log-failed"
else fail "cli-fault:log-failed" "control-migration.log missing or has no 'failed' line"; fi
check "cli-fault:stdout-empty" "$(out_of "$FX")" ""
check "cli-fault:legacy-kept" "$(cat "$FX/plans/$SID-$LEDGER" 2>/dev/null)" "C1 open ledger-line"
check "cli-fault:no-published-dst" "$(listing "$(ctl_of "$FX")" | grep -v '^<no-dir>$')" ""
case_end

case_begin "sp-dir-only-fault-returns-3" "bin/lib/safe-state-path.sh"
FX="$(new_fx)"
seed_control "$FX"
FX_FAULT="link-fail" run_sp "$FX" "$SID"
check "sp-fault:rc" "$?" "3"
check "sp-fault:stdout-empty" "$(out_of "$FX")" ""
check "sp-fault:legacy-kept" "$(cat "$FX/plans/$SID-$RND" 2>/dev/null)" "3"
check "sp-fault:no-published-dst" "$(listing "$(ctl_of "$FX")" | grep -v '^<no-dir>$')" ""
case_end

# seed_variant <fx> <variant> — none | control | artifact | both.
seed_variant() {
  case "$2" in
    control) seed_control "$1" ;;
    artifact) printf '# intent\n' > "$1/plans/$SID-intent.md" ;;
    both) seed_control "$1"; printf '# intent\n' > "$1/plans/$SID-intent.md" ;;
  esac
}

case_begin "js-bash-parity-dir-form" "hooks/lib/temporary-migrations/control-dir-split/index.js"
for V in none control artifact both; do
  FA="$(new_fx)"
  FB="$(new_fx)"
  seed_variant "$FA" "$V"
  seed_variant "$FB" "$V"
  run_cli "$FA" "$SID" --for-write
  RC_A=$?
  run_sp "$FB" "$SID"
  RC_B=$?
  check "parity:$V:rc-zero" "$RC_A" "0"
  check "parity:$V:rc-equal" "$RC_B" "$RC_A"
  REL_A="$(np "$(out_of "$FA")")"
  REL_B="$(np "$(out_of "$FB")")"
  check "parity:$V:path" "${REL_B#"$(np "$FB")"}" "${REL_A#"$(np "$FA")"}"
  check "parity:$V:path-shape" "${REL_A#"$(np "$FA")"}" "/workflow-state/$SID.control"
  check "parity:$V:control-set" "$(listing "$(ctl_of "$FB")")" "$(listing "$(ctl_of "$FA")")"
  check "parity:$V:plans-set" "$(listing "$FB/plans")" "$(listing "$FA/plans")"
  case "$V" in
    artifact|both)
      [[ -f "$FB/plans/$SID-intent.md" && ! -e "$(ctl_of "$FB")/intent.md" ]] \
        && pass "parity:$V:artifact-stays-in-plans" || fail "parity:$V:artifact-stays-in-plans" "intent.md moved or lost"
      ;;
  esac
  case "$V" in
    control|both) check "parity:$V:control-files-migrated" "$(ls "$(ctl_of "$FB")" 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')" "$RND $LEDGER " ;;
  esac
done
case_end

case_begin "sp-file-form-legacy-present-migrates" "bin/lib/safe-state-path.sh"
FX="$(new_fx)"
seed_control "$FX"
run_sp "$FX" "$SID" "$RND"
check "sp-file-present:rc" "$?" "0"
check "sp-file-present:path" "$(np "$(out_of "$FX")")" "$(np "$(ctl_of "$FX")/$RND")"
check "sp-file-present:content" "$(cat "$(ctl_of "$FX")/$RND" 2>/dev/null)" "3"
if [[ -e "$FX/plans/$SID-$RND" ]]; then fail "sp-file-present:legacy-gone" "legacy round-number still present"
else pass "sp-file-present:legacy-gone"; fi
case_end

case_begin "sp-file-form-legacy-absent-prints-path" "bin/lib/safe-state-path.sh"
FX="$(new_fx)"
run_sp "$FX" "$SID" "$RND"
check "sp-file-absent:rc" "$?" "0"
check "sp-file-absent:path" "$(np "$(out_of "$FX")")" "$(np "$(ctl_of "$FX")/$RND")"
if [[ -d "$(ctl_of "$FX")" && ! -h "$(ctl_of "$FX")" ]]; then pass "sp-file-absent:dir-created"
else fail "sp-file-absent:dir-created" "control dir not created as a real directory"; fi
case_end

case_begin "sp-file-form-invalid-token-rejected" "bin/lib/safe-state-path.sh"
for BAD in "../x" "a/b" ".hidden" ""; do
  FX="$(new_fx)"
  seed_control "$FX"
  LBL="${BAD:-invalid-sid}"
  if [[ -z "$BAD" ]]; then run_sp "$FX" "../$SID"; else run_sp "$FX" "$SID" "$BAD"; fi
  check "sp-invalid:[$LBL]:rc" "$?" "2"
  check "sp-invalid:[$LBL]:stdout-empty" "$(out_of "$FX")" ""
  check "sp-invalid:[$LBL]:legacy-untouched" "$(cat "$FX/plans/$SID-$RND" 2>/dev/null)" "3"
  check "sp-invalid:[$LBL]:no-control-dir" "$(listing "$(ctl_of "$FX")")" "<no-dir>"
done
case_end

echo ""
echo "feature-2434-control-dir-form: PASS=$PASS FAIL=$FAIL"
[[ "$FAIL" -eq 0 ]]
