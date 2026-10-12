#!/usr/bin/env bash
# tests/skills/feature-1465-scriptify-clarify-intent/run-completion-approval.sh
# Tests: skills/clarify-intent/scripts/run-completion.sh
# Tags: scope:issue-specific, plan-approval, confirm-intent
#
# #2277 (S11): run-completion.sh asks check-plan-approval for clarify_intent before any
# side effect. Only APPROVAL=approved reaches clarify-commit-scope.sh / clarify-guard-loop.sh;
# unapproved -> UNAPPROVED, anything else (unknown, not-applicable, skipped, CLI failure,
# unreadable output) -> APPROVAL_UNKNOWN, both fail-closed with exit 0.
# Sourced by dispatcher (feature-1465-scriptify-clarify-intent.sh); can also run standalone.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

RCA_SUT_REL="$F1465_SUT_REL_DIR/run-completion.sh"

# Side-effect stubs that touch a marker when run; sets SCOPE_MARK / GUARD_MARK.
_rca_side_effect_stubs() {
    SCOPE_MARK="$TEST_DIR/scope_invoked"
    GUARD_MARK="$TEST_DIR/guard_invoked"
    printf '%s\n' "process.stdout.write(JSON.stringify([{number:1,repo:null}]));" \
        > "$TEST_DIR/hooks/lib/parse-closes-issues.js"
    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0
    printf '%s\n' '#!/usr/bin/env bash' "touch \"$SCOPE_MARK\"" 'exit 0' \
        > "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh"
    printf '%s\n' '#!/usr/bin/env bash' "touch \"$GUARD_MARK\"" 'echo PROCEED' 'exit 0' \
        > "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh"
    chmod +x "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh"
}

# _rca_run <sid> — runs the SUT copy; sets OUT, RC, TOKEN.
_rca_run() {
    mkdir -p "$TEST_DIR/plans"
    OUT="$(run_with_timeout 30 bash "$TEST_DIR/$RCA_SUT_REL" --session-id "$1" --plans-dir "$TEST_DIR/plans" 2>/dev/null)"
    RC=$?
    TOKEN="$(printf '%s\n' "$OUT" | tail -1)"
}

_rca_yes_no() { [ -f "$1" ] && echo yes || echo no; }

# RCA-1: approved -> proceeds; both side effects run; CLI called with the planned args.
test_RCA_1_approved_proceeds() {
    local label="RCA-1: APPROVAL=approved → PROCEED, side effects run, CLI gets --session/--step clarify_intent"
    setup_test_dir
    _rca_side_effect_stubs
    local args_file="$TEST_DIR/approval_args.txt"
    mock_plan_approval "APPROVAL=approved" 0 "$args_file"
    _rca_run "rca-approved"
    local args=""; [ -f "$args_file" ] && args="$(tr '\n' ' ' < "$args_file")"
    if [ "$TOKEN" = "PROCEED" ] && [ "$RC" -eq 0 ] && [ -f "$SCOPE_MARK" ] && [ -f "$GUARD_MARK" ] \
        && [ "$args" = "--session rca-approved --step clarify_intent " ]; then
        pass "$label"
    else
        fail "$label — token='$TOKEN' rc=$RC scope=$(_rca_yes_no "$SCOPE_MARK") guard=$(_rca_yes_no "$GUARD_MARK") cli_args='$args'"
    fi
    cleanup_test_dir
}

# _rca_blocked <id> <expected-token> <stdout> <exit> [no-mock] — fail-closed case.
_rca_blocked() {
    local id="$1" want="$2" stdout_text="$3" exit_code="$4" no_mock="${5:-}"
    local label="$id: check-plan-approval '${stdout_text:-<none>}' exit=$exit_code${no_mock:+ (CLI missing)} → $want, no side effects"
    setup_test_dir
    _rca_side_effect_stubs
    [ -z "$no_mock" ] && mock_plan_approval "$stdout_text" "$exit_code"
    _rca_run "rca-${id,,}"
    if [ "$TOKEN" = "$want" ] && [ "$RC" -eq 0 ] && [ ! -f "$SCOPE_MARK" ] && [ ! -f "$GUARD_MARK" ]; then
        pass "$label"
    else
        fail "$label — token='$TOKEN' rc=$RC scope=$(_rca_yes_no "$SCOPE_MARK") guard=$(_rca_yes_no "$GUARD_MARK")"
    fi
    cleanup_test_dir
}

echo "=== run-completion.sh approval gate (#2277) ==="
test_RCA_1_approved_proceeds
_rca_blocked "RCA-2" "UNAPPROVED" "APPROVAL=unapproved" 0
_rca_blocked "RCA-3" "APPROVAL_UNKNOWN" "APPROVAL=unknown" 0
_rca_blocked "RCA-4" "APPROVAL_UNKNOWN" "APPROVAL=not-applicable" 0
_rca_blocked "RCA-5" "APPROVAL_UNKNOWN" "APPROVAL=skipped" 0
_rca_blocked "RCA-6" "APPROVAL_UNKNOWN" "APPROVAL=approved" 1
_rca_blocked "RCA-7" "APPROVAL_UNKNOWN" "garbage output" 0
_rca_blocked "RCA-8" "APPROVAL_UNKNOWN" "" 0 no-mock
# The CLI contract is exactly one APPROVAL=<v> line; contradictory or noisy output is unreadable,
# so it must fail closed even when an `approved` line is present (`\n` is a JS escape in the mock).
_rca_blocked "RCA-9" "APPROVAL_UNKNOWN" 'APPROVAL=approved\nAPPROVAL=unapproved' 0
_rca_blocked "RCA-10" "APPROVAL_UNKNOWN" 'APPROVAL=unapproved\nAPPROVAL=approved' 0
_rca_blocked "RCA-11" "APPROVAL_UNKNOWN" 'APPROVAL=approved\ntrailing noise line' 0
_rca_blocked "RCA-12" "APPROVAL_UNKNOWN" 'leading noise line\nAPPROVAL=approved' 0
_rca_blocked "RCA-13" "APPROVAL_UNKNOWN" 'APPROVAL=approved trailing-noise' 0
