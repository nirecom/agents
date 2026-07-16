#!/usr/bin/env bash
# tests/feature-1465-scriptify-clarify-intent/check-complexity-skip.sh
# Tests: skills/clarify-intent/scripts/check-complexity-skip.sh
# Tags: scope:issue-specific
#
# Stdout contract:
#   - Optional sentinel line: <<WORKFLOW_OUTLINE_NOT_NEEDED: ...>>
#   - FINAL line: SENTINEL_EMITTED or NO_SENTINEL
# SKILL.md uses `tail -1` to read the status token.
#
# Sourced by dispatcher (feature-1465-scriptify-clarify-intent.sh).
# Can also run standalone.

set -uo pipefail

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

REPO_ROOT="$(git -C "$(dirname "${BASH_SOURCE[0]}")" rev-parse --show-toplevel)"
CHECK_COMPLEXITY_SKIP="$REPO_ROOT/skills/clarify-intent/scripts/check-complexity-skip.sh"

# CCS-N1: SKIP_MODE=auto → sentinel echoed on a non-final line + last line SENTINEL_EMITTED
test_CCS_N1_skip_mode_auto() {
    local label="CCS-N1: SKIP_MODE=auto → sentinel + SENTINEL_EMITTED"
    setup_test_dir

    local SESSION_ID="test-session-ccs-n1"
    write_mock "$TEST_DIR/bin/workflow/record-skip-judgment" 0

    OUT="$(AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=auto run_with_timeout 30 bash "$CHECK_COMPLEXITY_SKIP" \
        --session "$SESSION_ID" 2>/dev/null)"
    RC=$?

    local last_line; last_line="$(printf '%s\n' "$OUT" | tail -1)"
    local has_sentinel=false
    printf '%s\n' "$OUT" | grep -q "<<WORKFLOW_OUTLINE_NOT_NEEDED:" && has_sentinel=true

    if [ "$last_line" = "SENTINEL_EMITTED" ] && [ "$has_sentinel" = "true" ]; then
        pass "$label"
    else
        fail "$label — last_line='$last_line' has_sentinel=$has_sentinel rc=$RC (out='$OUT')"
    fi
    cleanup_test_dir
}

# CCS-N2: SKIP_MODE=judgment + so_c1=true + so_c2=true → record-skip-judgment called + sentinel + SENTINEL_EMITTED
test_CCS_N2_judgment_both_true() {
    local label="CCS-N2: SKIP_MODE=judgment so_c1=true so_c2=true → sentinel + SENTINEL_EMITTED"
    setup_test_dir

    local SESSION_ID="test-session-ccs-n2"

    local judgment_marker="$TEST_DIR/record_skip_judgment_called"
    cat > "$TEST_DIR/bin/workflow/record-skip-judgment" <<MOCK
#!/usr/bin/env bash
touch "$judgment_marker"
exit 0
MOCK
    chmod +x "$TEST_DIR/bin/workflow/record-skip-judgment"

    OUT="$(AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=judgment run_with_timeout 30 bash "$CHECK_COMPLEXITY_SKIP" \
        --session "$SESSION_ID" --so-c1 true --so-c2 true 2>/dev/null)"
    RC=$?

    local last_line; last_line="$(printf '%s\n' "$OUT" | tail -1)"
    local has_sentinel=false
    printf '%s\n' "$OUT" | grep -q "<<WORKFLOW_OUTLINE_NOT_NEEDED:" && has_sentinel=true
    local judgment_called=false
    [ -f "$judgment_marker" ] && judgment_called=true

    if [ "$last_line" = "SENTINEL_EMITTED" ] && [ "$has_sentinel" = "true" ] && [ "$judgment_called" = "true" ]; then
        pass "$label"
    else
        fail "$label — last='$last_line' sentinel=$has_sentinel judgment=$judgment_called rc=$RC"
    fi
    cleanup_test_dir
}

# CCS-N3: SKIP_MODE=judgment + so_c1=false → no sentinel, last line NO_SENTINEL
test_CCS_N3_judgment_c1_false() {
    local label="CCS-N3: SKIP_MODE=judgment so_c1=false → NO_SENTINEL"
    setup_test_dir

    local SESSION_ID="test-session-ccs-n3"
    write_mock "$TEST_DIR/bin/workflow/record-skip-judgment" 0

    OUT="$(AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=judgment run_with_timeout 30 bash "$CHECK_COMPLEXITY_SKIP" \
        --session "$SESSION_ID" --so-c1 false --so-c2 true 2>/dev/null)"
    RC=$?

    local last_line; last_line="$(printf '%s\n' "$OUT" | tail -1)"
    local has_sentinel=false
    printf '%s\n' "$OUT" | grep -q "<<WORKFLOW_OUTLINE_NOT_NEEDED:" && has_sentinel=true

    if [ "$last_line" = "NO_SENTINEL" ] && [ "$has_sentinel" = "false" ]; then
        pass "$label"
    else
        fail "$label — last='$last_line' has_sentinel=$has_sentinel rc=$RC"
    fi
    cleanup_test_dir
}

# CCS-N4: SKIP_MODE=judgment + so_c2=false → no sentinel, last line NO_SENTINEL
test_CCS_N4_judgment_c2_false() {
    local label="CCS-N4: SKIP_MODE=judgment so_c2=false → NO_SENTINEL"
    setup_test_dir

    local SESSION_ID="test-session-ccs-n4"
    write_mock "$TEST_DIR/bin/workflow/record-skip-judgment" 0

    OUT="$(AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=judgment run_with_timeout 30 bash "$CHECK_COMPLEXITY_SKIP" \
        --session "$SESSION_ID" --so-c1 true --so-c2 false 2>/dev/null)"
    RC=$?

    local last_line; last_line="$(printf '%s\n' "$OUT" | tail -1)"
    local has_sentinel=false
    printf '%s\n' "$OUT" | grep -q "<<WORKFLOW_OUTLINE_NOT_NEEDED:" && has_sentinel=true

    if [ "$last_line" = "NO_SENTINEL" ] && [ "$has_sentinel" = "false" ]; then
        pass "$label"
    else
        fail "$label — last='$last_line' has_sentinel=$has_sentinel rc=$RC"
    fi
    cleanup_test_dir
}

# CCS-N5: SKIP_MODE=judgment + both false → NO_SENTINEL
test_CCS_N5_judgment_both_false() {
    local label="CCS-N5: SKIP_MODE=judgment so_c1=false so_c2=false → NO_SENTINEL"
    setup_test_dir

    local SESSION_ID="test-session-ccs-n5"
    write_mock "$TEST_DIR/bin/workflow/record-skip-judgment" 0

    OUT="$(AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=judgment run_with_timeout 30 bash "$CHECK_COMPLEXITY_SKIP" \
        --session "$SESSION_ID" --so-c1 false --so-c2 false 2>/dev/null)"
    RC=$?

    local last_line; last_line="$(printf '%s\n' "$OUT" | tail -1)"
    local has_sentinel=false
    printf '%s\n' "$OUT" | grep -q "<<WORKFLOW_OUTLINE_NOT_NEEDED:" && has_sentinel=true

    if [ "$last_line" = "NO_SENTINEL" ] && [ "$has_sentinel" = "false" ]; then
        pass "$label"
    else
        fail "$label — last='$last_line' has_sentinel=$has_sentinel rc=$RC"
    fi
    cleanup_test_dir
}

# CCS-E1: invalid SKIP_MODE → non-zero exit
test_CCS_E1_invalid_skip_mode() {
    local label="CCS-E1: invalid SKIP_MODE → non-zero exit"
    require_script "$label" "$CHECK_COMPLEXITY_SKIP" || return
    setup_test_dir

    AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=invalid run_with_timeout 10 bash "$CHECK_COMPLEXITY_SKIP" \
        --session "some-session" >/dev/null 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        pass "$label"
    else
        fail "$label — expected non-zero exit, got 0"
    fi
    cleanup_test_dir
}

# CCS-E2: missing --session → non-zero exit
test_CCS_E2_missing_session() {
    local label="CCS-E2: missing --session → non-zero exit"
    require_script "$label" "$CHECK_COMPLEXITY_SKIP" || return
    setup_test_dir

    AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=auto run_with_timeout 10 bash "$CHECK_COMPLEXITY_SKIP" \
        >/dev/null 2>&1
    local rc=$?

    if [ "$rc" -ne 0 ]; then
        pass "$label"
    else
        fail "$label — expected non-zero exit, got 0"
    fi
    cleanup_test_dir
}

# CCS-SEC1: shell metacharacters in --session value → no injection
test_CCS_SEC1_metachar_session() {
    local label="CCS-SEC1: shell metacharacters in --session → no injection (safe exit)"
    require_script "$label" "$CHECK_COMPLEXITY_SKIP" || return
    setup_test_dir

    local danger_marker="$TEST_DIR/injection_marker"
    local EVIL_SESSION="\$(touch $danger_marker);evil"

    write_mock "$TEST_DIR/bin/workflow/record-skip-judgment" 0

    AGENTS_CONFIG_DIR="$TEST_DIR" SKIP_MODE=auto run_with_timeout 10 bash "$CHECK_COMPLEXITY_SKIP" \
        --session "$EVIL_SESSION" >/dev/null 2>&1 || true

    if [ ! -f "$danger_marker" ]; then
        pass "$label"
    else
        fail "$label — injection_marker was created (shell injection succeeded)"
    fi
    cleanup_test_dir
}

echo ""
echo "=== check-complexity-skip.sh tests ==="
test_CCS_N1_skip_mode_auto
test_CCS_N2_judgment_both_true
test_CCS_N3_judgment_c1_false
test_CCS_N4_judgment_c2_false
test_CCS_N5_judgment_both_false
test_CCS_E1_invalid_skip_mode
test_CCS_E2_missing_session
test_CCS_SEC1_metachar_session
