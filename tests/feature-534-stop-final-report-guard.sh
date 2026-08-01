#!/bin/bash
# tests/feature-534-stop-final-report-guard.sh
# Tests: hooks/stop-final-report-guard.js, hooks/lib/final-report-schema.js, skills/session-close/SKILL.md, hooks/stop-premature-stop-guard.js, bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: settings, config, hook, tests, scope:issue-specific, TL2
#
# Issue #534 / #626 / #771 — Stop hook: stop-final-report-guard.js
#
# Contract after #771 (renderer abolition), updated for #1114 (13 headings):
# all 13 headings from getSectionHeadings(sid) required after last
# `## Final Report — <sid>` in transcript; residual <TOKEN> check;
# no env-file `reported` flag check.
#
# 1. env file absent → 系統B trigger (#1611): consult `bin/workflow/next-step`.
#    ACTION=invoke + REASON='pre_final_report_gate' means the close procedure was
#    never started → exit 2 + decision:block unconditionally (the transcript is
#    NOT scanned, so a hand-written Final Report is rejected too). Escape hatches:
#    session-close gate `yield`, `<sid>.workflow-off`, gate marked complete.
#    Any other next-step verdict → exit 0 (no-op, as before).
# 2. env file malformed JSON → exit 0 (fail-open; no 系統B fall-through)
# 3. stop_hook_active:true → exit 0
# 4. last `## Final Report — <sid>` absent in transcript → exit 0
# 5. any of the 12 `###` headings missing AFTER that position → exit 2 + decision:block
# 6. residual `<[A-Z][A-Z_]+>` token in post-header region → exit 2 + decision:block
# 7. otherwise → exit 0
#
# G1, G4, G6, I1 unchanged from pre-#771 contract.
# G2, G7, G8 rewritten for new contract; G16–G20 added.
# Old `reported` flag tests (G3 G5 G10 G11 G12 G13 G14 G15 G16-old) deleted.
#
# Layer: L2 (broad integration — real node subprocess, real JSONL fixtures, real hook file)
# L3 gap: does not verify the hook fires in a real Claude Code Stop event. L3 would require
#         a live `claude -p` session with the hook registered; see rules/test/claude-e2e.md.
# Known gap: resolveSessionId fallback (SID derived from transcript filename when session_id
#            absent from stdin) tests hooks/workflow-state.js — out of scope for this file.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi

HOOK_JS="${_AGENTS_DIR_NODE}/hooks/stop-final-report-guard.js"
SETTINGS_JSON="${AGENTS_DIR}/settings.json"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'f534-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# Guard: skip all G-tests when the hook is not yet implemented.
require_hook() {
    if [ ! -f "$HOOK_JS" ]; then
        skip "$1 (hook not implemented yet)"
        return 1
    fi
    return 0
}

# ---------------------------------------------------------------------------
# Load sub-files
# ---------------------------------------------------------------------------
TESTS_SUBDIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-534-stop-final-report-guard"
source "$TESTS_SUBDIR/helpers.sh"
source "$TESTS_SUBDIR/g01-g08.sh"
source "$TESTS_SUBDIR/g16-i1.sh"
source "$TESTS_SUBDIR/g21-g27.sh"
source "$TESTS_SUBDIR/g28-trigger.sh"

# ---------------------------------------------------------------------------
# Run all tests
# ---------------------------------------------------------------------------

test_G1_envfile_absent
test_G2_all_headings_present_passes
test_G3_empty_env_object_no_header
test_G4_stop_hook_active
test_G6_envfile_malformed_json
test_G7_header_present_subheading_missing
test_G8_legacy_key_yes
test_G16_only_header_no_subheadings
test_G17_nine_of_ten_headings
test_G18_all_ten_reordered
test_G19_residual_tokens
test_G20_header_absent_no_block
test_G21_tool_result_sentinel_after_report
test_G22_token_outside_final_report_section
test_G23_fr_in_prior_turn_latest_has_no_fr_exit0
test_G23b_no_fr_anywhere_exit0
test_G24_token_before_fr_heading_exit0
test_G25_transcript_missing_exit0
test_G26_latest_turn_incomplete_fr_blocks
test_G27_heading_found_empty_body_blocks
test_G28_invalid_sid_exit0
test_G29_transcript_path_absent_exit0
test_G30_envfile_no_gate_no_header_blocks
test_G31_envfile_gate_yield_no_header_exit0
test_G32_envfile_gate_proceed_no_header_blocks
test_G33_no_env_gate_reached_no_report_blocks
test_G34_no_env_handwritten_full_report_still_blocks
test_G35_no_env_midworkflow_exit0
test_G36_no_env_no_state_exit0
test_G37_no_env_gate_yield_exit0
test_G38_no_env_workflow_off_exit0
test_G39_no_env_gate_complete_exit0
test_G40_nondefault_workflow_dir_env_inheritance
test_G41_env_present_full_report_exit0
test_G42_env_present_missing_heading_blocks
test_G43_env_malformed_does_not_fall_through_to_B
test_G44_stop_hook_active_exit0
test_G45_premature_guard_delegates_gate_reason
test_G46_premature_guard_other_invoke_still_blocks
test_G47_settings_stop_timeout_is_10
test_G48_corrupt_state_fails_open
test_G49_state_without_steps_fails_open
test_G50_unusable_workflow_dir_fails_open
test_I1_settings_json_stop_hook

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"

exit $FAIL
