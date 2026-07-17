#!/bin/bash
# tests/feature-workflow-init-driver/driver-malformed-tokens.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/directive.js
# Tags: workflow-init, driver, validation, scope:issue-specific
#
# Validation guard for raw-token CLI arguments:
#   Stage 1: /[\r\n]/ → invalid_token_newline
#   Stage 2: !ISSUE_TOKEN_CLI_GUARD_RE || !/^[^#]*#\d+$/ → invalid_token_format
#   Stage 3: tok.length > MAX_TOKEN_LEN → invalid_token_format
#
# L3 gap (what this test does NOT catch):
# - A real `claude -p` session driving the workflow-init SKILL.md driver loop
#   (ACTION= dispatch, AskUserQuestion rendering, --resume re-invocation).
# - Real gh calls (issue view / sub_issues endpoint / Projects v2) on live GitHub.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# Helper: assert NEXT_HINT mentions '#N' or 'raw-tokens' or 'user prompt'
assert_next_hint_content() {  # <label>
    local got
    got="$(get_kv NEXT_HINT)" || true
    if printf '%s' "$got" | grep -qE '#|raw.token|user.prompt'; then
        pass "$1: NEXT_HINT contains substantive guidance"
    else
        fail "$1: NEXT_HINT='$got' lacks #N / raw-token / user-prompt guidance"
    fi
}

# Helper: assert no gh calls were made (guard must block before downstream)
assert_no_gh_calls() {  # <label>
    local c
    c="$(count_gh_calls '.')"
    if [ "$c" -eq 0 ]; then
        pass "$1: no gh calls (blocked before downstream)"
    else
        fail "$1: expected 0 gh calls but got $c"
    fi
}

# === Stage 1: newline/CR tokens → invalid_token_newline ========================

# M1: LF-injection (the ds4 bug — multi-line prompt passed as single token)
setup_case wid-m1
run_driver $'line1\nline2'
assert_kv "M1: LF token → ACTION=blocked" ACTION blocked
assert_kv "M1: LF token → REASON=invalid_token_newline" REASON invalid_token_newline
assert_nonempty_kv "M1: LF token → NEXT_HINT non-empty" NEXT_HINT
assert_next_hint_content "M1"
assert_no_gh_calls "M1"
teardown_case

# M-CR: CR-only injection (Windows line-ending variant)
setup_case wid-mcr
run_driver $'line1\rline2'
assert_kv "MCR: CR token → ACTION=blocked" ACTION blocked
assert_kv "MCR: CR token → REASON=invalid_token_newline" REASON invalid_token_newline
assert_no_gh_calls "MCR"
teardown_case

# === Stage 2+3: invalid_token_format cases (table-driven) ======================
#
# Each token must yield ACTION=blocked, REASON=invalid_token_format, no gh calls.
# Table-driven to minimise repetition per test-design.md parser/regex pattern.

OVER64="$(printf '#%065d' 0)"  # '#' + 65 zeros → length 66 > MAX_TOKEN_LEN(64)

# Array: (description | token)  — IFS='|'
INVALID_FMT_CASES=(
    "no '#' prefix|hello"
    "bare digit|42"
    "trailing non-digit junk after #N|#1488abc"
    "trailing non-digit junk after repo#N|repo#15suffix"
    "trailing non-digit junk after owner/repo#N|owner/repo#15x"
    "empty string|"
    "over MAX_TOKEN_LEN|$OVER64"
)

fmt_i=0
while IFS='|' read -r desc tok; do
    fmt_i=$((fmt_i + 1))
    setup_case "wid-fmt-$fmt_i"
    run_driver "$tok"
    assert_kv "fmt-$fmt_i ($desc) → ACTION=blocked" ACTION blocked
    assert_kv "fmt-$fmt_i ($desc) → REASON=invalid_token_format" REASON invalid_token_format
    assert_nonempty_kv "fmt-$fmt_i ($desc) → NEXT_HINT" NEXT_HINT
    assert_no_gh_calls "fmt-$fmt_i ($desc)"
    teardown_case
done < <(printf '%s\n' "${INVALID_FMT_CASES[@]}")

# === Prefix+prose case: passes CLI_GUARD prefix but fails end-anchor ===========
# '#1488 rest of prompt text' matches /^...#\d/ but fails /^[^#]*#\d+$/
# Regression guard: verifies the end-anchor closes the whitespace gap.

setup_case wid-m5
run_driver '#1488 rest of prompt text'
assert_kv "M5: prefix+prose → ACTION=blocked" ACTION blocked
assert_kv "M5: prefix+prose → REASON=invalid_token_format" REASON invalid_token_format
assert_next_hint_content "M5"
assert_no_gh_calls "M5"
teardown_case

# === Mixed valid + invalid input ===============================================
# Guard must fire on the invalid token even when a valid '#15' precedes it.
# Verifies that '#15' is NOT processed via gh before the guard blocks.

setup_case wid-m4
run_driver '#15' 'notanissue'
assert_kv "M4: mixed valid/invalid → ACTION=blocked" ACTION blocked
assert_kv "M4: mixed valid/invalid → REASON=invalid_token_format" REASON invalid_token_format
assert_nonempty_kv "M4: mixed valid/invalid → NEXT_HINT" NEXT_HINT
assert_no_gh_calls "M4"
teardown_case

# === Classifier symmetry: valid tokens must NOT be blocked =====================

# M6: local '#N' — canonical form
setup_case wid-m6
mock_issue 15 OPEN "type:task"
set_wip 15 same
run_driver '#15'
got_a="$(get_kv ACTION)" || true; got_r="$(get_kv REASON)" || true
if [ "$got_a" = "blocked" ] && { [ "$got_r" = "invalid_token_format" ] || [ "$got_r" = "invalid_token_newline" ]; }; then
    fail "M6: '#15' blocked by validation guard (false positive)"
else
    pass "M6: '#15' not blocked by validation guard"
fi
teardown_case

# M7: cross-repo short form 'repo#N' (ISSUE_TOKEN_CLI_GUARD_RE accepts this)
setup_case wid-m7
run_driver 'repo#15'
got_a="$(get_kv ACTION)" || true; got_r="$(get_kv REASON)" || true
if [ "$got_a" = "blocked" ] && { [ "$got_r" = "invalid_token_format" ] || [ "$got_r" = "invalid_token_newline" ]; }; then
    fail "M7: 'repo#15' blocked by validation guard (false positive)"
else
    pass "M7: 'repo#15' not blocked by validation guard"
fi
teardown_case

# M8: cross-repo full form 'owner/repo#N'
setup_case wid-m8
run_driver 'owner/repo#15'
got_a="$(get_kv ACTION)" || true; got_r="$(get_kv REASON)" || true
if [ "$got_a" = "blocked" ] && { [ "$got_r" = "invalid_token_format" ] || [ "$got_r" = "invalid_token_newline" ]; }; then
    fail "M8: 'owner/repo#15' blocked by validation guard (false positive)"
else
    pass "M8: 'owner/repo#15' not blocked by validation guard"
fi
teardown_case

# === Zero-token edge case: Path C (valid, not blocked) =========================

setup_case wid-m9
run_driver
assert_kv "M9: zero tokens → ACTION=done" ACTION done
assert_kv "M9: zero tokens → PATH_DECISION=C" PATH_DECISION C
teardown_case

finish
