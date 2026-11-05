#!/bin/bash
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/field-recover.sh
# Tags: wip-state, github, projects-v2, scope:issue-specific
# #2925 R8-R13: check/clear/abandon never create or rename the session-id field; an absent field
# skips the text step; a stale cached id is re-resolved once. Kept apart from -recover.sh: the
# merged file would exceed the 120 s per-file runtime budget (recover ~85 s + verbs ~53 s).
# Mocks: tests/agents/feature-wip-state/setup.sh + abandon/mock.sh (gh) + tests/lib/gh-projectv2-fields-mock.sh.
# TL3 gap: real Projects v2 field deletion between resolve and write needs a live board; the mock
#   cannot show GitHub's real error text or latency for a deleted field id.
#   Closest-to-action mitigation: before merge, on a scratch board delete the session-id field, then
#   run `wip-state clear <N>` / `abandon <N>` and confirm exit 0 plus a re-resolved cache row.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/agents/feature-wip-state/_lib.sh"
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
harness_isolate "$(make_tmp)"
command -v jq >/dev/null 2>&1 || { echo "SKIP: jq not available (field model needs it)"; exit 77; }
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2925-wip-session-id-recover/helpers.sh"

# r8_body <status> <expected> — check with no session-id field: never reads text, never mutates.
r8_body() {
    rc_prep; export GH_MOCK_SID_FIELD=absent GH_MOCK_STATUS="$1" GH_MOCK_FINGERPRINT="test-sid-fixture"
    run_verb check 42
    if [ "$RC" -eq 0 ] && [ "$(cat "$OUT")" = "$2" ] && [ "$(n_ops create)" -eq 0 ] \
       && [ "$(n_ops rename)" -eq 0 ] && [ -z "$(item_edits)" ]; then
        pass "R8($1): check → '$2' without create/rename/edit"
    else fail "R8($1)" "out=[$(cat "$OUT")] $(dump)"; fi
    teardown_mock
}
# r11_body <clear|abandon> — legacy field is never renamed (nor created) outside set.
r11_body() {
    if [ "$1" = "abandon" ]; then rc_prep abandon; else rc_prep; fi
    export GH_MOCK_SID_FIELD=legacy
    run_verb "$1" 42
    if [ "$RC" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ] && [ "$(n_ops create)" -eq 0 ]; then
        pass "R11($1): legacy field untouched"
    else fail "R11($1)" "$(dump)"; fi
    teardown_mock
}

case_begin "check-absent-field-in-progress-is-other" "bin/github-issues/wip-state.sh"
r8_body "In Progress" other
case_end

case_begin "check-absent-field-todo-is-none" "bin/github-issues/wip-state.sh"
r8_body "Todo" none
case_end

# r8b_body <label> <value> — only the legacy session-fingerprint field exists and holds the caller's
# own identity (raw sid, or its retired sha256 prefix 526b4bd3) → check must not read it: `other`,
# no rename / create / edit.
r8b_body() {
    rc_prep; export GH_MOCK_SID_FIELD=legacy GH_MOCK_STATUS="In Progress" GH_MOCK_FINGERPRINT="$2"
    run_verb check 42
    if [ "$RC" -eq 0 ] && [ "$(cat "$OUT")" = "other" ] && [ "$(n_ops create)" -eq 0 ] \
       && [ "$(n_ops rename)" -eq 0 ] && [ -z "$(item_edits)" ]; then
        pass "R8b($1): legacy field with own identity → check 'other', no rename/create/edit"
    else fail "R8b($1)" "out=[$(cat "$OUT")] $(dump)"; fi
    teardown_mock
}

case_begin "check-legacy-field-own-raw-sid-is-other" "bin/github-issues/wip-state.sh"
r8b_body raw-sid "test-sid-fixture"
case_end

case_begin "check-legacy-field-own-hash-is-other" "bin/github-issues/wip-state.sh"
r8b_body legacy-hash "526b4bd3"
case_end

case_begin "clear-absent-field-done-only" "bin/github-issues/wip-state.sh"
rc_prep; export GH_MOCK_SID_FIELD=absent
run_verb clear 42
if [ "$RC" -eq 0 ] && has_status OPT_done && [ "$(n_text)" -eq 0 ] && [ "$(n_ops create)" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ]; then
    pass "R9: clear with no session-id field → Done only, no --text, no create/rename"
else fail "R9" "$(dump)"; fi
teardown_mock
case_end

case_begin "abandon-absent-field-todo-only" "bin/github-issues/wip-state.sh"
rc_prep abandon; export GH_MOCK_SID_FIELD=absent
run_verb abandon 42
if [ "$RC" -eq 0 ] && has_status OPT_todo && [ "$(n_text)" -eq 0 ] && [ "$(n_ops create)" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ]; then
    pass "R10: abandon with no session-id field → Todo only, exit 0"
else fail "R10" "$(dump)"; fi
teardown_mock
case_end

case_begin "clear-legacy-field-never-renamed" "bin/github-issues/wip-state.sh"
r11_body clear
case_end

case_begin "abandon-legacy-field-never-renamed" "bin/github-issues/wip-state.sh"
r11_body abandon
case_end

case_begin "clear-stale-cached-id-reresolves-and-skips" "bin/github-issues/wip-state/field-recover.sh"
rc_prep; export GH_MOCK_SID_FIELD=absent
seed_cache PVTF_gone
run_verb clear 42
if [ "$RC" -eq 0 ] && has_status OPT_done && [ "$(n_text)" -eq 1 ] && [ "$(n_ops create)" -eq 0 ] \
   && [ "$(n_ops rename)" -eq 0 ] && [ "$(cache_col 10)" != "PVTF_gone" ]; then
    pass "R12: stale id → re-resolved to empty, text clear skipped, cache no longer holds PVTF_gone"
else fail "R12" "$(dump) cache=[$(cat "$CACHE" 2>/dev/null)]"; fi
teardown_mock
case_end

case_begin "abandon-stale-cached-id-retry-fails-exits-1" "bin/github-issues/wip-state/field-recover.sh"
rc_prep abandon; export GH_MOCK_SID_FIELD=present GH_MOCK_FAIL=item-edit-fp
seed_cache PVTF_gone
run_verb abandon 42
if [ "$RC" -eq 1 ] && [ "$(n_text)" -eq 2 ] && [ "$(last_text_field)" = "PVTF_fp" ] && [ "$(n_ops create)" -eq 0 ]; then
    pass "R13: abandon re-resolves to PVTF_fp, retry fails → exit 1"
else fail "R13" "$(dump)"; fi
teardown_mock
case_end

# r12b_body <clear|abandon> — stale cached id, field exists: re-resolve, retry clears (--text "") on the NEW id.
r12b_body() {
    if [ "$1" = "abandon" ]; then rc_prep abandon; else rc_prep; fi
    export GH_MOCK_SID_FIELD=present
    seed_cache PVTF_gone
    run_verb "$1" 42
    if [ "$RC" -eq 0 ] && [ "$(n_text)" -eq 2 ] && [ "$(last_text_field)" = "PVTF_fp" ] \
       && text_edits | tail -1 | grep -qE -- '--text $' && [ "$(n_ops create)" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ]; then
        pass "R12b($1): stale id → retry writes --text \"\" to the new field PVTF_fp, exit 0"
    else fail "R12b($1)" "$(dump)"; fi
    teardown_mock
}

case_begin "clear-stale-cached-id-retry-clears-new-field" "bin/github-issues/wip-state/field-recover.sh"
r12b_body clear
case_end

case_begin "abandon-stale-cached-id-retry-clears-new-field" "bin/github-issues/wip-state/field-recover.sh"
r12b_body abandon
case_end

wip_finish
