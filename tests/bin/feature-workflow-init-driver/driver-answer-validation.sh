#!/bin/bash
# tests/feature-workflow-init-driver/driver-answer-validation.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/phases/meta-classify.js
# Tags: workflow-init, driver, checkpoint-resume, answer-validation, meta-classify, scope:issue-specific

# C15-C16, C18-C20 — --resume/--answer REJECTION arms, continuing the C-series of the sibling
# driver-checkpoint-resume.sh (which owns the accept arms C1-C14). Pattern A split:
# together the two files exceed the 500-line hard limit.

# TL3 gap: no real `claude -p` AskUserQuestion → --resume --answer round-trip, so
# the answer strings here are synthetic rather than whatever the real UI emits.
# Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- C15: 'abort' is honored on a STALE checkpoint too -------------------------------
# CPR-ORTH counterpart of C3 (abort on a CURRENT checkpoint) along the staleness axis,
# and of C14a (a NON-abort answer on a stale checkpoint). "Stop" is the one answer whose
# meaning cannot depend on the checkpoint's version: the user typed it before any version
# was inspected. main() reads the checkpoint first, so the version_mismatch branch is
# reached ahead of applyAnswer's abort arm — a restart there re-fetches the issues,
# re-checks WIP ownership and overwrites the checkpoint, all after the user said stop.
setup_case wid-c15
mock_issue 700 OPEN "type:task"
mock_issue 701 OPEN "type:task"
set_wip 700 other
run_driver '#700' '#701'
assert_kv "C15: initial run interrupts at wip_conflict" ASK_ID wip_conflict
CKPT="$(get_kv CHECKPOINT)" || true
if ! node -e 'const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));j.version=999999;fs.writeFileSync(p,JSON.stringify(j));' "$CKPT" 2>/dev/null; then
    fail "C15: could not tamper checkpoint version (missing/unreadable: '$CKPT')"
fi
cp "$CKPT" "$CASE_DIR/ckpt.snapshot"
C15_GH_BEFORE="$(count_gh_calls '.')"
C15_WIP_BEFORE="$(wip_calls | grep -c . || true)"
run_driver --resume "$CKPT" --answer abort
assert_kv "C15: abort on a stale checkpoint → ACTION=blocked" ACTION blocked
assert_kv "C15: abort on a stale checkpoint → REASON=user_aborted" REASON user_aborted
if [ -f "$CKPT" ] && cmp -s "$CKPT" "$CASE_DIR/ckpt.snapshot"; then
    pass "C15: aborted resume left the stale checkpoint byte-identical"
else
    fail "C15: aborted resume rewrote (or deleted) the stale checkpoint"
fi
C15_GH_AFTER="$(count_gh_calls '.')"
if [ "$C15_GH_AFTER" = "$C15_GH_BEFORE" ]; then
    pass "C15: abort issued no gh call ($C15_GH_BEFORE → $C15_GH_AFTER)"
else
    fail "C15: abort restarted the pipeline and issued gh calls ($C15_GH_BEFORE → $C15_GH_AFTER)"
fi
C15_WIP_AFTER="$(wip_calls | grep -c . || true)"
if [ "$C15_WIP_AFTER" = "$C15_WIP_BEFORE" ]; then
    pass "C15: abort issued no wip-state.sh call ($C15_WIP_BEFORE → $C15_WIP_AFTER)"
else
    fail "C15: abort re-entered wip-check ($C15_WIP_BEFORE → $C15_WIP_AFTER)"
fi
teardown_case

# --- C16a/b/c: meta_select answers that are not '#N'-SHAPED at all --------------------
# C13 covers the other meta_select reject arm: a well-formed number outside the offered
# set. These three cover the format arm — the answer never reaches the offered-set check
# because /^#?(\d+)$/ does not match. The diagnostic text is what separates the two arms,
# so each case asserts it: collapsing them would let the offered-set branch answer for
# the format branch (and vice versa) without either being exercised.
check_c16() {  # <id> <answer> — full malformed-meta_select assertion set
    local id="$1" ans="$2" before after
    setup_case "wid-c16$id"
    mock_issue 710 OPEN "meta"
    mock_issue 711 OPEN "type:task"
    set_wip 711 same
    mock_sub_issues 710 '[{"number":711,"title":"Open child","state":"open"}]'
    run_driver '#710'
    assert_kv "C16$id: meta parent with an open child → meta_select ask" ASK_ID meta_select
    CKPT="$(get_kv CHECKPOINT)" || true
    if [ -n "$CKPT" ] && [ -f "$CKPT" ]; then cp "$CKPT" "$CASE_DIR/ckpt.snapshot"; fi
    before="$(count_gh_calls 'issue view')"
    run_driver --resume "$CKPT" --answer "$ans"
    assert_kv "C16$id: malformed answer '$ans' → ACTION=blocked" ACTION blocked
    assert_kv "C16$id: malformed answer '$ans' → REASON=invalid-answer" REASON invalid-answer
    assert_single_action_line "C16$id: rejection emits exactly one ACTION= line"
    if printf '%s\n%s' "$DRIVER_OUT" "$DRIVER_ERR" | grep -qF 'Expected #N (issue number)'; then
        pass "C16$id: diagnostic names the FORMAT contract, not the offered set"
    else
        fail "C16$id: diagnostic does not name the '#N' format contract: err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
    fi
    after="$(count_gh_calls 'issue view')"
    if [ "$after" = "$before" ]; then
        pass "C16$id: no gh issue view fetch on a malformed answer ($before → $after)"
    else
        fail "C16$id: malformed answer triggered a fetch ($before → $after)"
    fi
    if [ -f "$CKPT" ] && [ -f "$CASE_DIR/ckpt.snapshot" ] && cmp -s "$CKPT" "$CASE_DIR/ckpt.snapshot"; then
        pass "C16$id: checkpoint unchanged after the malformed answer"
    else
        fail "C16$id: checkpoint mutated by a malformed meta_select answer"
    fi
    teardown_case
}
check_c16 a ''         # empty answer — the shape an unanswered AskUserQuestion produces
check_c16 b 'garbage'  # non-numeric word
check_c16 c '#12abc'   # partially numeric: a real number with a trailing tail
check_c16 d '12,34'    # partially numeric: two numbers, the multi-select spelling

# --- C18/C19/C20: unreadable, empty, and structurally CORRUPT checkpoint files --------
# --resume takes a path from the caller, so the file may be anything. C14 covers the
# stale-version arm; these cover the read path itself. C18/C19 are the controlled arms
# (readCheckpoint's unreadable/malformed kinds → a blocked directive, exit 0). C20 is
# the gap between them: readCheckpoint validates only `version`, so a current-version
# checkpoint whose `state` is corrupt sails past it and reaches applyAnswer.
# An uncaught TypeError there satisfies "not ACTION=done", writes no artifact and calls
# no WIP — a crash would pass a weaker C20 while the session dies. So C20 demands the
# same controlled outcome C18/C19 do: one blocked directive naming checkpoint_invalid,
# exit 0, and no stack trace on either stream.
plans_inventory() { find "$PLANS" -type f 2>/dev/null | LC_ALL=C sort; }
assert_no_stack_in_directives() {  # <label>
    if printf '%s\n' "$DRIVER_OUT" | grep -qE 'TypeError|^ +at '; then
        fail "$1: a stack trace leaked into the directive stream: '$(printf '%s' "$DRIVER_OUT" | head -c 200)'"
    else
        pass "$1"
    fi
}
# Stderr coverage lives in _lib.sh's assert_no_uncaught (shared with the #2063 cases).

setup_case wid-c18
mkdir -p "$PLANS/is-a-directory.json"
C18_BEFORE="$(plans_inventory)"
run_driver --resume "$PLANS/is-a-directory.json" --answer continue
assert_kv "C18: an unreadable checkpoint path → ACTION=blocked" ACTION blocked
assert_kv "C18: an unreadable checkpoint path → REASON=checkpoint_invalid" REASON checkpoint_invalid
assert_single_action_line "C18: the rejection emits exactly one ACTION= line"
assert_no_stack_in_directives "C18: the read failure is reported as a directive, not a trace"
if [ "$DRIVER_RC" = "0" ]; then
    pass "C18: a controlled rejection exits 0 (the caller reads the directive, not the rc)"
else
    fail "C18: unreadable checkpoint exited rc=$DRIVER_RC; err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
fi
if [ "$(plans_inventory)" = "$C18_BEFORE" ]; then
    pass "C18: no checkpoint or context file written for an unreadable resume"
else
    fail "C18: the rejected resume left artifacts behind: $(plans_inventory | tr '\n' ';')"
fi
teardown_case

setup_case wid-c19
: > "$PLANS/empty.json"
C19_BEFORE="$(plans_inventory)"
run_driver --resume "$PLANS/empty.json" --answer continue
assert_kv "C19: an empty checkpoint file → ACTION=blocked" ACTION blocked
assert_kv "C19: an empty checkpoint file → REASON=checkpoint_invalid" REASON checkpoint_invalid
assert_no_stack_in_directives "C19: the parse failure is reported as a directive, not a trace"
if [ "$DRIVER_RC" = "0" ]; then
    pass "C19: an empty checkpoint is a controlled rejection, exit 0"
else
    fail "C19: empty checkpoint exited rc=$DRIVER_RC; err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
fi
if [ "$(plans_inventory)" = "$C19_BEFORE" ]; then
    pass "C19: no checkpoint or context file written for an unparseable resume"
else
    fail "C19: the rejected resume left artifacts behind: $(plans_inventory | tr '\n' ';')"
fi
teardown_case

check_c20() {  # <id> <checkpoint-json> — a CURRENT-version checkpoint with a corrupt state
    local id="$1" json="$2" before
    setup_case "wid-c20$id"
    printf '%s' "$json" > "$PLANS/corrupt.json"
    before="$(plans_inventory)"
    run_driver --resume "$PLANS/corrupt.json" --answer continue
    if [ "$(get_kv ACTION)" = "done" ]; then
        fail "C20$id: a corrupt-state checkpoint reported success (ACTION=done)"
    else
        pass "C20$id: a corrupt-state checkpoint never reports success"
    fi
    # The positive half: not-done is also what a crash produces, so name the directive.
    assert_single_action_line "C20$id: the rejection emits exactly one ACTION= line"
    assert_kv "C20$id: a corrupt-state checkpoint → ACTION=blocked" ACTION blocked
    assert_kv "C20$id: a corrupt-state checkpoint → REASON=checkpoint_invalid" REASON checkpoint_invalid
    if [ "$DRIVER_RC" = "0" ]; then
        pass "C20$id: a controlled rejection exits 0 (the caller reads the directive, not the rc)"
    else
        fail "C20$id: corrupt state exited rc=$DRIVER_RC — a crash, not a rejection; err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
    fi
    assert_no_uncaught "C20$id: no uncaught error on stdout or stderr"
    if [ "$(plans_inventory)" = "$before" ]; then
        pass "C20$id: no checkpoint or context file written from unusable state"
    else
        fail "C20$id: unusable state still produced artifacts: $(plans_inventory | tr '\n' ';')"
    fi
    if [ -z "$(wip_calls)" ]; then
        pass "C20$id: no WIP ownership claimed from unusable state"
    else
        fail "C20$id: wip-state.sh ran on unusable state: [$(wip_calls | tr '\n' ';')]"
    fi
    teardown_case
}
# Must track CHECKPOINT_VERSION (#2063 bumped 2 → 3): a stale literal here would
# route these cases through version_mismatch and silently stop testing the corrupt-
# state path they exist for.
C20_HEAD='"version":3,"session_id":"wid-c20","phase":"wip-check","ask_id":"wip_conflict"'
check_c20 a "{$C20_HEAD}"                                   # `state` absent entirely
check_c20 b "{$C20_HEAD,\"state\":{}}"                      # present but empty: no issues
check_c20 c "{$C20_HEAD,\"state\":{\"issues\":\"400\"}}"    # issues present, wrong type
check_c20 d "{$C20_HEAD,\"state\":null}"                    # present but null — the shape a
                                                            # half-written checkpoint leaves
# A corrupt `issue_json_cache` under an otherwise usable `state` is deliberately NOT
# listed here: refetching is a legitimate recovery for it, so demanding a blocked
# directive would over-constrain the design. Its contract is asserted where it is
# actually observable — driver-issue-comments.sh C11, through write-context.

finish
