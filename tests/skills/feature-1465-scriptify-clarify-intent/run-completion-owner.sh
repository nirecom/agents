#!/usr/bin/env bash
# tests/skills/feature-1465-scriptify-clarify-intent/run-completion-owner.sh
# Tests: skills/clarify-intent/scripts/run-completion.sh
# Tags: scope:issue-specific, plan-artifact, resume-session, workflow-state
#
# #2631: run-completion.sh resolves INTENT_PATH through bin/plan-artifact-path, so a resumed
# (downstream) session parses its upstream's intent. Observed through the --issues CSV the real
# hooks/lib/parse-closes-issues.js hands to a recording clarify-commit-scope.sh stub.
# Sourced by dispatcher (feature-1465-scriptify-clarify-intent.sh); can also run standalone.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Node reads these paths, so on Windows they take the drive-letter form (cygpath -m).
_rco_np() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
readonly RCO_TMP_ROOT="$(_rco_np "$(mktemp -d)")"
mkdir -p "$RCO_TMP_ROOT/state" "$RCO_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$RCO_TMP_ROOT/state" WORKFLOW_PLANS_DIR="$RCO_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID

RCO_SUT_REL="$F1465_SUT_REL_DIR/run-completion.sh"
RCO_REAL_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"

_rco_sid() { node -e 'process.stdout.write(require("crypto").randomUUID())'; }
# _rco_state <sid> [<upstream-sid>] [<first-sid>] — a raw v5 state file.
_rco_state() {
    local up=""
    [ -n "${2:-}" ] && up=",\"upstream_session_id\":\"$2\",\"upstream_copy_seq\":0"
    [ -n "${3:-}" ] && up="$up,\"first_session_id\":\"$3\""
    printf '{"version":5,"session_id":"%s","created_at":"2026-01-01T00:00:00.000Z","session_start_context":{"cwd":"%s","git_branch":"feature/f2631"},"events":[]%s}\n' \
        "$1" "$RCO_TMP_ROOT" "$up" >"$WORKFLOW_STATE_DIR/$1.json"
}
# _rco_intent <sid> <issue> — an intent under the case's plans dir listing #<issue>.
_rco_intent() { printf '# Intent\n\n## Goal\n\ng\n\n## Issues\n\n- #%s fixture issue\n' "$2" >"$TEST_DIR/plans/$1-intent.md"; }

# _rco_setup — a fake root with the real resolver and parser, recording side-effect stubs.
_rco_setup() {
    setup_test_dir
    mkdir -p "$TEST_DIR/plans"
    cp -r "$RCO_REAL_ROOT/hooks/." "$TEST_DIR/hooks/"
    cp "$RCO_REAL_ROOT/bin/plan-artifact-path" "$TEST_DIR/bin/plan-artifact-path"
    # The resolver's only bin/ dependency outside itself (via hooks/lib/confirm-gate/plan-gate.js).
    mkdir -p "$TEST_DIR/bin/workflow/lib/next-step"
    cp "$RCO_REAL_ROOT/bin/workflow/lib/next-step/gate-line.js" "$TEST_DIR/bin/workflow/lib/next-step/gate-line.js"
    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0
    mock_plan_approval "APPROVAL=approved"
    RCO_SCOPE_ARGS="$TEST_DIR/scope_args.txt"
    printf '%s\n' '#!/usr/bin/env bash' "printf '%s\\n' \"\$@\" >\"$RCO_SCOPE_ARGS\"" 'exit 0' \
        >"$TEST_DIR/bin/github-issues/clarify-commit-scope.sh"
    write_mock "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" 0 "PROCEED"
    chmod +x "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh"
}

# _rco_issues <sid> — runs the SUT copy; echoes the --issues value the scope stub received.
_rco_issues() {
    run_with_timeout 60 bash "$TEST_DIR/$RCO_SUT_REL" --session-id "$1" --plans-dir "$(_rco_np "$TEST_DIR/plans")" >/dev/null 2>&1
    [ -f "$RCO_SCOPE_ARGS" ] && grep -A1 '^--issues$' "$RCO_SCOPE_ARGS" | tail -n 1
}

# RCO-1: resumed D (no own intent) parses U's intent.
test_RCO_1_resumed_reads_upstream_intent() {
    local label="RCO-1: resumed session without its own intent parses the upstream's (#4321)"
    _rco_setup
    local U D got
    U="$(_rco_sid)"; D="$(_rco_sid)"
    _rco_state "$U"; _rco_state "$D" "$U"
    _rco_intent "$U" 4321
    got="$(_rco_issues "$D")"
    if [ "$got" = "4321" ] && [ ! -f "$TEST_DIR/plans/$D-intent.md" ]; then pass "$label"
    else fail "$label — issues='$got'"; fi
    cleanup_test_dir
}

# RCO-2: the upstream's existing intent wins over the own one; an upstream without a file
# yields no issues (the own intent is never parsed).
test_RCO_2_upstream_intent_wins_over_own() {
    local label="RCO-2: a resumed session parses the upstream's intent (#4321) over its own (#5555); upstream without a file → no issues, never own (#5656)"
    _rco_setup
    local U D L LU got legacy
    U="$(_rco_sid)"; D="$(_rco_sid)"
    _rco_state "$U"; _rco_state "$D" "$U"
    _rco_intent "$U" 4321
    _rco_intent "$D" 5555
    got="$(_rco_issues "$D")"
    LU="$(_rco_sid)"; L="$(_rco_sid)"
    _rco_state "$LU"; _rco_state "$L" "$LU"
    _rco_intent "$L" 5656
    rm -f "$RCO_SCOPE_ARGS"
    legacy="$(_rco_issues "$L")"
    if [ "$got" = "4321" ] && [ -z "$legacy" ]; then pass "$label"
    else fail "$label — both='$got' no-file-upstream='$legacy'"; fi
    cleanup_test_dir
}

# RCO-3: a non-resumed session parses its own intent.
test_RCO_3_non_resumed_own_intent() {
    local label="RCO-3: a non-resumed session parses its own intent (#6060)"
    _rco_setup
    local S got
    S="$(_rco_sid)"
    _rco_state "$S"
    _rco_intent "$S" 6060
    got="$(_rco_issues "$S")"
    if [ "$got" = "6060" ]; then pass "$label"; else fail "$label — issues='$got'"; fi
    cleanup_test_dir
}

# RCO-4: no own-sid fallback (#2748): a failing resolver stops the run before the scope step,
# and a foreign name never makes the own intent (#7070) parsed.
test_RCO_4_resolver_failure_has_no_own_fallback() {
    local label="RCO-4: plan-artifact-path failure → no scope call; foreign output → never own intent (#7070)"
    _rco_setup
    local S got1 got2 called1
    S="$(_rco_sid)"
    _rco_state "$S"
    _rco_intent "$S" 7070
    printf '%s\n' 'process.exit(1);' >"$TEST_DIR/bin/plan-artifact-path"
    got1="$(_rco_issues "$S")"
    called1=no; [ -f "$RCO_SCOPE_ARGS" ] && called1=yes
    printf '%s\n' 'process.stdout.write("/elsewhere/secret.txt\n");' >"$TEST_DIR/bin/plan-artifact-path"
    rm -f "$RCO_SCOPE_ARGS"
    got2="$(_rco_issues "$S")"
    if [ "$called1" = no ] && [ -z "$got1" ] && [ "$got2" != "7070" ]; then pass "$label"
    else fail "$label — failure: scope_called=$called1 issues='$got1'; foreign='$got2'"; fi
    cleanup_test_dir
}

# RCO-5: no intent anywhere (resumed, upstream without a file) → empty --issues, no crash.
test_RCO_5_no_intent_anywhere() {
    local label="RCO-5: no intent anywhere → empty --issues, run reaches the guard"
    _rco_setup
    local U D got
    U="$(_rco_sid)"; D="$(_rco_sid)"
    _rco_state "$D" "$U"
    got="$(_rco_issues "$D")"
    if [ -f "$RCO_SCOPE_ARGS" ] && [ -z "$got" ]; then pass "$label"
    else fail "$label — scope_called=$([ -f "$RCO_SCOPE_ARGS" ] && echo yes || echo no) issues='$got'"; fi
    cleanup_test_dir
}

# RCO-6 (#2748): a session-downstream recording first_session_id only (no upstream_session_id)
# parses the first generation's intent, never its own: a fallback to the legacy field fails here.
test_RCO_6_first_session_id_only_reads_first_generation() {
    local label="RCO-6: first_session_id-only downstream parses the first generation's intent (#5151), never its own (#6262)"
    _rco_setup
    local F X got
    F="$(_rco_sid)"; X="$(_rco_sid)"
    _rco_state "$F"; _rco_state "$X" "" "$F"
    _rco_intent "$F" 5151
    _rco_intent "$X" 6262
    got="$(_rco_issues "$X")"
    if [ "$got" = "5151" ]; then pass "$label"; else fail "$label — issues='$got'"; fi
    cleanup_test_dir
}

echo "=== run-completion.sh owner-resolved intent (#2631) ==="
test_RCO_1_resumed_reads_upstream_intent
test_RCO_2_upstream_intent_wins_over_own
test_RCO_3_non_resumed_own_intent
test_RCO_4_resolver_failure_has_no_own_fallback
test_RCO_5_no_intent_anywhere
test_RCO_6_first_session_id_only_reads_first_generation
rm -rf "$RCO_TMP_ROOT"
