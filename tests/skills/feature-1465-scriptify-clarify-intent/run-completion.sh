#!/usr/bin/env bash
# tests/feature-1465-scriptify-clarify-intent/run-completion.sh
# Tests: skills/clarify-intent/scripts/run-completion.sh
# Tags: scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - Real clarify-commit-scope.sh / clarify-guard-loop.sh network calls against GitHub API
# - AGENTS_CONFIG_DIR resolution in a real claude -p session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration
#
# Sourced by dispatcher (feature-1465-scriptify-clarify-intent.sh).
# Can also run standalone.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
RUN_COMPLETION="$REPO_ROOT/skills/clarify-intent/scripts/run-completion.sh"

# Helper: run run-completion.sh with a given AGENTS_CONFIG_DIR and args
# Sets OUT and RC
run_completion() {
    local agents_dir="$1"; shift
    OUT="$(AGENTS_CONFIG_DIR="$agents_dir" run_with_timeout 30 bash "$RUN_COMPLETION" "$@" 2>/dev/null)"
    RC=$?
}

# ============================================================================
# Token contract:
#   - clarify-commit-scope.sh exit 0 + empty stdout → call guard-loop → emit guard token
#   - clarify-commit-scope.sh exit 0 + "CREATED:N"  → emit "CREATED:N" (no guard call)
#   - clarify-commit-scope.sh exit 2 + "CLOSED:N"   → emit "CLOSED:N" (no guard call)
#   - clarify-commit-scope.sh exit 2 + "RC2"        → emit "RC2" (no guard call)
# The LAST line of stdout is the single token.
# ============================================================================

# RC-N1..N4: commit-scope exit 0 + empty stdout → guard token propagates
# Parameterized helper; called once per expected guard token.
_test_RC_guard_token() {
    local test_id="$1" guard_token="$2"
    local label="${test_id}: commit-scope exit 0 empty → guard ${guard_token}"
    setup_test_dir

    local SESSION_ID="test-session-${test_id,,}"
    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([{number:1,repo:null}]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0
    write_mock "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" 0 ""
    write_mock "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" 0 "$guard_token"

    run_completion "$TEST_DIR" \
        --session-id "$SESSION_ID" \
        --plans-dir "$PLANS_DIR"

    local token; token="$(printf '%s\n' "$OUT" | tail -1)"
    if [ "$token" = "$guard_token" ]; then
        pass "$label"
    else
        fail "$label — token='$token' rc=$RC (full out='$OUT')"
    fi
    cleanup_test_dir
}

test_RC_N1_guard_proceed()        { _test_RC_guard_token "RC-N1" "PROCEED"; }
test_RC_N2_guard_need_issue()     { _test_RC_guard_token "RC-N2" "NEED_ISSUE"; }
test_RC_N3_guard_retry_exhausted(){ _test_RC_guard_token "RC-N3" "RETRY_EXHAUSTED"; }
test_RC_N4_guard_closed_entry()   { _test_RC_guard_token "RC-N4" "CLOSED_ENTRY"; }

# RC-N5: commit-scope exit 0 + "CREATED:42" → emit "CREATED:42" without calling guard
test_RC_N5_created_no_guard() {
    local label="RC-N5: commit-scope exit 0 CREATED:42 → CREATED:42 (guard NOT invoked)"
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0
    write_mock "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" 0 "CREATED:42"

    local guard_marker="$TEST_DIR/guard_invoked"
    cat > "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" <<MOCK
#!/usr/bin/env bash
touch "$guard_marker"
echo "PROCEED"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh"

    run_completion "$TEST_DIR" \
        --session-id "test-session-rc-n5" \
        --plans-dir "$PLANS_DIR"

    local token; token="$(printf '%s\n' "$OUT" | tail -1)"
    if [ "$token" = "CREATED:42" ] && [ ! -f "$guard_marker" ]; then
        pass "$label"
    else
        fail "$label — token='$token' guard_invoked=$([ -f "$guard_marker" ] && echo yes || echo no)"
    fi
    cleanup_test_dir
}

# RC-N6: commit-scope exit 2 + "CLOSED:7" → emit "CLOSED:7" without calling guard
test_RC_N6_closed_no_guard() {
    local label="RC-N6: commit-scope exit 2 CLOSED:7 → CLOSED:7 (guard NOT invoked)"
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([{number:7,repo:null}]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0
    write_mock "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" 2 "CLOSED:7"

    local guard_marker="$TEST_DIR/guard_invoked"
    cat > "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" <<MOCK
#!/usr/bin/env bash
touch "$guard_marker"
echo "PROCEED"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh"

    run_completion "$TEST_DIR" \
        --session-id "test-session-rc-n6" \
        --plans-dir "$PLANS_DIR"

    local token; token="$(printf '%s\n' "$OUT" | tail -1)"
    if [ "$token" = "CLOSED:7" ] && [ ! -f "$guard_marker" ]; then
        pass "$label"
    else
        fail "$label — token='$token' guard_invoked=$([ -f "$guard_marker" ] && echo yes || echo no)"
    fi
    cleanup_test_dir
}

# RC-N7: commit-scope exit 2 + "RC2" → emit "RC2" without calling guard
test_RC_N7_rc2_no_guard() {
    local label="RC-N7: commit-scope exit 2 RC2 → RC2 (guard NOT invoked)"
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([{number:1,repo:null}]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0
    write_mock "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" 2 "RC2"

    local guard_marker="$TEST_DIR/guard_invoked"
    cat > "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" <<MOCK
#!/usr/bin/env bash
touch "$guard_marker"
echo "PROCEED"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh"

    run_completion "$TEST_DIR" \
        --session-id "test-session-rc-n7" \
        --plans-dir "$PLANS_DIR"

    local token; token="$(printf '%s\n' "$OUT" | tail -1)"
    if [ "$token" = "RC2" ] && [ ! -f "$guard_marker" ]; then
        pass "$label"
    else
        fail "$label — token='$token' guard_invoked=$([ -f "$guard_marker" ] && echo yes || echo no)"
    fi
    cleanup_test_dir
}

# RC-N8: NON_GITHUB gate rc=1 → --non-github passed to downstream → PROCEED
test_RC_N8_non_github_proceed() {
    local label="RC-N8: NON_GITHUB gate rc=1 → --non-github passed → PROCEED"
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 1

    local scope_args_file="$TEST_DIR/scope_args.txt"
    cat > "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$scope_args_file"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh"

    local guard_args_file="$TEST_DIR/guard_args.txt"
    cat > "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$guard_args_file"
echo "PROCEED"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh"

    run_completion "$TEST_DIR" \
        --session-id "test-session-rc-n8" \
        --plans-dir "$PLANS_DIR"

    local token; token="$(printf '%s\n' "$OUT" | tail -1)"
    local scope_has_flag=false guard_has_flag=false
    [ -f "$scope_args_file" ] && grep -q "\-\-non-github" "$scope_args_file" && scope_has_flag=true
    [ -f "$guard_args_file" ] && grep -q "\-\-non-github" "$guard_args_file" && guard_has_flag=true

    if [ "$token" = "PROCEED" ] && [ "$scope_has_flag" = "true" ] && [ "$guard_has_flag" = "true" ]; then
        pass "$label"
    else
        fail "$label — token='$token' scope_non_github=$scope_has_flag guard_non_github=$guard_has_flag"
    fi
    cleanup_test_dir
}

# RC-N9: is-github-dotcom-remote rc=2 → fail-open as GitHub, --non-github NOT passed
test_RC_N9_github_dotcom_fail_open() {
    local label="RC-N9: is-github-dotcom-remote rc=2 → fail-open as GitHub (--non-github NOT passed)"
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([{number:1,repo:null}]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 2

    local scope_args_file="$TEST_DIR/scope_args.txt"
    cat > "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$scope_args_file"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh"

    local guard_args_file="$TEST_DIR/guard_args.txt"
    cat > "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$guard_args_file"
echo "PROCEED"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh"

    run_completion "$TEST_DIR" \
        --session-id "test-session-rc-n9" \
        --plans-dir "$PLANS_DIR"

    local token; token="$(printf '%s\n' "$OUT" | tail -1)"
    local scope_has_flag=false guard_has_flag=false
    [ -f "$scope_args_file" ] && grep -q "\-\-non-github" "$scope_args_file" && scope_has_flag=true
    [ -f "$guard_args_file" ] && grep -q "\-\-non-github" "$guard_args_file" && guard_has_flag=true

    if [ "$token" = "PROCEED" ] && [ "$scope_has_flag" = "false" ] && [ "$guard_has_flag" = "false" ]; then
        pass "$label"
    else
        fail "$label — token='$token' scope_non_github=$scope_has_flag guard_non_github=$guard_has_flag"
    fi
    cleanup_test_dir
}

# RC-N10: closes_issues parsed → --issues CSV passed to clarify-commit-scope.sh
test_RC_N10_issues_csv_propagation() {
    local label="RC-N10: closes_issues parsed → --issues CSV passed to clarify-commit-scope.sh"
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    # parse-closes-issues.js emits two issues: 3 and 7
    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([{number:3,repo:null},{number:7,repo:null}]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0

    # Record args passed to clarify-commit-scope.sh (--issues <csv> per script interface)
    local scope_args_file="$TEST_DIR/scope_args.txt"
    cat > "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" <<MOCK
#!/usr/bin/env bash
printf '%s\n' "\$@" > "$scope_args_file"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh"

    write_mock "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" 0 "PROCEED"

    run_completion "$TEST_DIR" \
        --session-id "test-session-rc-n10" \
        --plans-dir "$PLANS_DIR"

    # clarify-commit-scope.sh accepts --issues <csv> (e.g. "3,7")
    # Verify: --issues flag present AND value contains both 3 and 7
    local has_issues_flag=false has_3=false has_7=false issues_val=""
    if [ -f "$scope_args_file" ]; then
        grep -q "^\-\-issues$" "$scope_args_file" && has_issues_flag=true
        issues_val="$(grep -A1 "^\-\-issues$" "$scope_args_file" | tail -1)"
        echo "$issues_val" | grep -q "3" && has_3=true
        echo "$issues_val" | grep -q "7" && has_7=true
    fi

    if [ "$has_issues_flag" = "true" ] && [ "$has_3" = "true" ] && [ "$has_7" = "true" ]; then
        pass "$label"
    else
        local scope_args_dump
        scope_args_dump="$(cat "$scope_args_file" 2>/dev/null || echo '(missing)')"
        fail "$label — has_issues=$has_issues_flag has_3=$has_3 has_7=$has_7 scope_args='$scope_args_dump'"
    fi
    cleanup_test_dir
}

# RC-SEC1: shell metacharacters in --session-id → no injection
test_RC_SEC1_metachar_session_id() {
    local label="RC-SEC1: shell metacharacters in --session-id → no injection (safe exit)"
    require_script "$label" "$RUN_COMPLETION" || return
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    cat > "$TEST_DIR/hooks/lib/parse-closes-issues.js" <<'JS'
process.stdout.write(JSON.stringify([]));
JS

    write_mock "$TEST_DIR/bin/is-github-dotcom-remote" 0
    write_mock "$TEST_DIR/bin/github-issues/clarify-commit-scope.sh" 0 ""
    write_mock "$TEST_DIR/bin/github-issues/clarify-guard-loop.sh" 0 "PROCEED"

    local danger_marker="$TEST_DIR/injection_marker"
    local EVIL_SESSION="\$(touch $danger_marker);evil-session"

    AGENTS_CONFIG_DIR="$TEST_DIR" run_with_timeout 10 bash "$RUN_COMPLETION" \
        --session-id "$EVIL_SESSION" \
        --plans-dir "$PLANS_DIR" >/dev/null 2>&1 || true

    if [ ! -f "$danger_marker" ]; then
        pass "$label"
    else
        fail "$label — injection_marker was created (shell injection succeeded)"
    fi
    cleanup_test_dir
}

# RC-E1: missing --session-id → non-zero exit
test_RC_E1_missing_session_id() {
    local label="RC-E1: missing --session-id → non-zero exit"
    require_script "$label" "$RUN_COMPLETION" || return
    setup_test_dir

    local PLANS_DIR="$TEST_DIR/plans"
    mkdir -p "$PLANS_DIR"

    AGENTS_CONFIG_DIR="$TEST_DIR" run_with_timeout 10 bash "$RUN_COMPLETION" \
        --plans-dir "$PLANS_DIR" >/dev/null 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        pass "$label"
    else
        fail "$label — expected non-zero exit, got 0"
    fi
    cleanup_test_dir
}

# RC-E2: missing --plans-dir → non-zero exit
test_RC_E2_missing_plans_dir() {
    local label="RC-E2: missing --plans-dir → non-zero exit"
    require_script "$label" "$RUN_COMPLETION" || return
    setup_test_dir

    AGENTS_CONFIG_DIR="$TEST_DIR" run_with_timeout 10 bash "$RUN_COMPLETION" \
        --session-id "some-session" >/dev/null 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        pass "$label"
    else
        fail "$label — expected non-zero exit, got 0"
    fi
    cleanup_test_dir
}

echo "=== run-completion.sh tests ==="
test_RC_N1_guard_proceed
test_RC_N2_guard_need_issue
test_RC_N3_guard_retry_exhausted
test_RC_N4_guard_closed_entry
test_RC_N5_created_no_guard
test_RC_N6_closed_no_guard
test_RC_N7_rc2_no_guard
test_RC_N8_non_github_proceed
test_RC_N9_github_dotcom_fail_open
test_RC_N10_issues_csv_propagation
test_RC_SEC1_metachar_session_id
test_RC_E1_missing_session_id
test_RC_E2_missing_plans_dir
