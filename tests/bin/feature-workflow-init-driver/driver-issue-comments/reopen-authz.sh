#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments/reopen-authz.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/lib/workflow-init/issue-comments.js
# Tags: workflow-init, driver, issue-comments, checkpoint-resume, answer-validation, reopen, prompt-injection, scope:issue-specific

# C21-C23 (#2063): the AUTHORIZATION (C21) and EXECUTION (C22/C23) arms of
# `closed_reopen_<N>`, which sibling reopen-cache.sh (C7-C10) leaves open.
# Injection seams: ../HARNESS-CONTRACT.md

# TL3 gap: no real `claude -p` ask_user round-trip and no live gh, so `gh issue reopen`
# is the mock's exit code, not GitHub's. Mitigated at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

plans_inventory() { find "$PLANS" -type f 2>/dev/null | LC_ALL=C sort; }

count_any_reopen() { count_gh_calls '^issue reopen'; }
count_reopen_of() { count_gh_calls "^issue reopen $1(\$| )"; }

tamper_ask_id() {  # <ckpt-path> <new-ask-id>
    WID_ASK_IN="$2" node -e '
const fs = require("fs");
const p = process.argv[1];
const j = JSON.parse(fs.readFileSync(p, "utf8"));
j.ask_id = process.env.WID_ASK_IN;
fs.writeFileSync(p, JSON.stringify(j));
' "$1"
}

# --- C21 (security): a tampered closed_reopen_<N> ask_id authorizes nothing ---------
# The checkpoint is a caller-supplied path whose contents nothing signs, so its `ask_id`
# is attacker-reachable input on --resume. `closed_reopen_` + anything used to be sliced
# and handed to `gh issue reopen` on the strength of `Number()` alone, which turns
# " 930", "930.0" and "0x3a2" into numbers — a substituted suffix would then WRITE to an
# issue the session never touched. Every row must be refused by the rejection contract
# the other invalid answers use, with nothing reopened, nothing removed, and the
# checkpoint byte-identical afterwards.
check_c21() {  # <id> <tampered-ask-id> <answer> [expected-diagnostic] — full rejection assertion set
    local id="$1" ask="$2" ans="$3" diag="${4:-not a known issue in this session}"
    local before_reopen after_reopen before_view after_view before_inv
    setup_case "wid-c2063-c21$id"
    mock_issue 930 CLOSED "type:task"
    mock_issue 931 CLOSED "type:task"
    set_wip 930 same
    set_wip 931 same
    run_driver '#930' '#931'
    assert_kv "C21$id: the closed issue raises the reopen gate" ASK_ID closed_reopen_930
    C21_CKPT="$(get_kv CHECKPOINT)" || true
    if [ -z "$C21_CKPT" ] || [ ! -f "$C21_CKPT" ]; then
        fail "C21$id: no CHECKPOINT to tamper with — the rejection assertions are unfalsifiable"
        teardown_case
        return
    fi
    tamper_ask_id "$C21_CKPT" "$ask"
    cp "$C21_CKPT" "$CASE_DIR/ckpt.snapshot"
    before_reopen="$(count_any_reopen)"
    before_view="$(count_gh_calls '^issue view')"
    before_inv="$(plans_inventory)"
    run_driver --resume "$C21_CKPT" --answer "$ans"
    assert_kv "C21$id: ask_id '$ask' + '$ans' → ACTION=blocked" ACTION blocked
    assert_kv "C21$id: ask_id '$ask' + '$ans' → REASON=invalid-answer" REASON invalid-answer
    assert_single_action_line "C21$id: the rejection emits exactly one ACTION= line"
    assert_no_uncaught "C21$id: the rejection is controlled, not a crash"
    if [ "$DRIVER_RC" = "0" ]; then
        pass "C21$id: a controlled rejection exits 0 (the caller reads the directive, not the rc)"
    else
        fail "C21$id: exited rc=$DRIVER_RC; err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
    fi
    # The diagnostic separates the reject arms: this must fail on the ASK_ID contract,
    # never on the answer-vocabulary one — the latter would mean the tampered suffix was
    # accepted as authorized and only the answer string was refused. The expected text
    # also separates the MEMBERSHIP arm from the PENDING-ASK arm, which are different
    # guards that a single "some rejection happened" check would conflate.
    if printf '%s\n%s' "$DRIVER_OUT" "$DRIVER_ERR" | grep -qF "$diag"; then
        pass "C21$id: the diagnostic names the ask_id contract ('$diag')"
    else
        fail "C21$id: diagnostic does not name '$diag': err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
    fi
    after_reopen="$(count_any_reopen)"
    if [ "$after_reopen" = "$before_reopen" ]; then
        pass "C21$id: not one 'gh issue reopen' was issued ($before_reopen → $after_reopen)"
    else
        fail "C21$id: a tampered ask_id reached 'gh issue reopen' ($before_reopen → $after_reopen)"
    fi
    # `count_any_reopen` is a delta over the whole log; these two name the individual
    # issues, so the C21k substitution — where BOTH numbers are real, in-session and
    # CLOSED — states which write was refused rather than only that the total held.
    assert_count "C21$id: 'gh issue reopen 930' was never invoked" 0 "$(count_reopen_of 930)"
    assert_count "C21$id: 'gh issue reopen 931' was never invoked" 0 "$(count_reopen_of 931)"
    after_view="$(count_gh_calls '^issue view')"
    if [ "$after_view" = "$before_view" ]; then
        pass "C21$id: no refetch was triggered by the rejected resume ($before_view → $after_view)"
    else
        fail "C21$id: the rejected resume re-entered fetch-issues ($before_view → $after_view)"
    fi
    if cmp -s "$C21_CKPT" "$CASE_DIR/ckpt.snapshot"; then
        pass "C21$id: the checkpoint is byte-identical after the rejection"
    else
        fail "C21$id: the rejected resume rewrote the checkpoint"
    fi
    # Byte-identity implies both, but naming them states WHICH mutation each answer arm
    # would otherwise have performed.
    # `[]` is the initial-state value: the override list must still be EMPTY, not absent.
    assert_ckpt "C21$id: no reopen override was recorded" "$C21_CKPT" state.reopen_state_override '[]'
    assert_ckpt "C21$id: the issue list is untouched — nothing was removed" "$C21_CKPT" state.issues '[930,931]'
    # The `reopen` arm's first mutation is `delete state.issue_json_cache[N]`; naming both
    # entries states that neither issue's cached discussion was dropped on the way out.
    assert_ckpt "C21$id: #930's cache entry survives the rejection" "$C21_CKPT" state.issue_json_cache.930.state CLOSED
    assert_ckpt "C21$id: #931's cache entry survives the rejection" "$C21_CKPT" state.issue_json_cache.931.state CLOSED
    if [ "$(plans_inventory)" = "$before_inv" ]; then
        pass "C21$id: the rejected resume wrote no new artifact"
    else
        fail "C21$id: the rejected resume left artifacts behind: $(plans_inventory | tr '\n' ';')"
    fi
    if [ -f "$(ctx_file)" ]; then
        fail "C21$id: a context.md was produced by the rejected resume"
    else
        pass "C21$id: no context.md from the rejected resume"
    fi
    teardown_case
}
# Garbage suffixes: each is a live issue number under a `Number()`-only check.
check_c21 a  'closed_reopen_930junk'  reopen   # trailing tail
check_c21 b  'closed_reopen_ 930'     reopen   # leading space — Number(" 930") === 930
check_c21 c  'closed_reopen_930.0'    reopen   # decimal spelling — Number() === 930
check_c21 d  'closed_reopen_+930'     reopen   # signed spelling — Number() === 930
check_c21 e  'closed_reopen_0x3a2'    reopen   # hex spelling — Number() === 930
check_c21 f  'closed_reopen_'         reopen   # empty suffix — Number("") === 0
# Well-formed digits that simply are not this session's issues: the MEMBERSHIP arm,
# which no format check can catch.
check_c21 g  'closed_reopen_999'      reopen
check_c21 h  'closed_reopen_0'        reopen   # the value the empty suffix coerces to
# CPR-ORTH: the guard sits ahead of the answer dispatch, so the `remove` arm — which
# mutates state.issues rather than the remote — must be refused on the same grounds.
check_c21 i  'closed_reopen_930junk'  remove
check_c21 j  'closed_reopen_999'      remove
# C21k (the arm no format or membership check can reach): a WELL-FORMED suffix naming a
# real, in-session, genuinely CLOSED SIBLING. #931 passes `/^\d+$/`, passes `Number()`,
# and passes `state.issues.indexOf()` — every guard C21a-j exercises — yet the ask the
# user actually answered was #930 (issues[0], the one closedDetection picks first). A
# membership-only check would take the substituted suffix as authorization and reopen an
# issue the user was never shown a question about. Authorization must therefore be the
# CURRENTLY PENDING ask recomputed from state, not mere session membership.
check_c21 k  'closed_reopen_931'      reopen  'does not match the current pending closed-issue ask'
# CPR-ORTH with C21i/C21j: the substitution is refused ahead of the answer dispatch, so
# the state-mutating `remove` arm is refused on the same grounds as the remote-writing one.
check_c21 l  'closed_reopen_931'      remove  'does not match the current pending closed-issue ask'

# --- C21m (fail-closed): no CLOSED issue is pending at all -------------------------
# The other half of the recomputation contract. C21k pins "the ask names the wrong
# issue"; this pins "there is no ask". `normalizeResumedState` repairs an absent / null /
# array `issue_json_cache` down to `{}` (C19), and over an empty container
# `closedDetection` finds nothing CLOSED and returns `{done:false}` — so a resumed
# `closed_reopen_N` answer is authorized by nothing at all. A guard that only compared
# `recomputed.askId` would read `undefined` and, on the absent-ask path, must still
# refuse: `recomputed.ask !== true` is the condition that has to fail closed. Membership
# alone cannot catch this — #N really is in `state.issues`.
C21M_VERSION="$(node -e '
try {
  const v = require(process.argv[1]).CHECKPOINT_VERSION;
  process.stdout.write(typeof v === "number" ? String(v) : "<not-a-number>");
} catch (e) { process.stdout.write("<unreadable>"); }
' "$AGENTS_DIR/bin/workflow/lib/workflow-init/checkpoint.js")"
case "$C21M_VERSION" in
    ''|*[!0-9]*) fail "C21m: checkpoint.js names no numeric CHECKPOINT_VERSION ('$C21M_VERSION') — a current-version checkpoint cannot be staged" ;;
    *) pass "C21m: checkpoint.js names its current schema version ($C21M_VERSION) — the fixture can match it" ;;
esac

check_c21m() {  # <id> <issue> <container-json-or-__DELETE__> <what> <answer>
    local id="$1" n="$2" raw="$3" what="$4" ans="$5" ck shape
    setup_case "wid-c2063-c21m$id"
    mock_issue "$n" CLOSED "type:task"
    set_wip "$n" same
    ck="$PLANS/wid-c2063-c21m$id-wi-checkpoint.json"
    node -e '
const fs = require("fs");
const [p, n, sid, raw, ver] = process.argv.slice(1);
const ck = {
  version: Number(ver), session_id: sid, phase: "closed-detection",
  ask_id: `closed_reopen_${n}`,
  state: {
    issues: [Number(n)], repo_map: {}, sid_pass: null,
    issue_json_cache: {}, wip_results: { [n]: "same" }, label_sets: {},
    force_path_b: false, path_decision: null, adopt_candidate: null, adopt_decision: null,
    meta_select_offered: [], meta_select_pending: [], reopen_state_override: []
  }
};
if (raw === "__DELETE__") delete ck.state.issue_json_cache;
else ck.state.issue_json_cache = JSON.parse(raw);
fs.writeFileSync(p, JSON.stringify(ck, null, 2) + "\n");
' "$ck" "$n" "wid-c2063-c21m$id" "$raw" "$C21M_VERSION"
    # Three fixture probes, or the case is about a checkpoint it never staged: the
    # version must be CURRENT (otherwise this only re-runs the version gate), the ask_id
    # must really be the reopen one, and #N must really be in the session (so the
    # rejection can only come from the recomputation, never from the membership arm).
    assert_ckpt "C21m$id: the staged checkpoint is at the CURRENT version" "$ck" version "$C21M_VERSION"
    assert_ckpt "C21m$id: the staged ask_id is the reopen gate" "$ck" ask_id "closed_reopen_$n"
    assert_ckpt "C21m$id: #$n IS a member of the session — membership cannot be the reason" "$ck" state.issues "[$n]"
    shape="$(ckpt_get "$ck" state.issue_json_cache)"
    case "$shape" in
        '<missing>'|'[]'|'{}') pass "C21m$id: the staged checkpoint really carries $what (the probe is live)" ;;
        *) fail "C21m$id: the staged container is '$shape', not the shape under test" ;;
    esac
    cp "$ck" "$CASE_DIR/ckpt.snapshot"
    run_driver --resume "$ck" --answer "$ans"
    assert_kv "C21m$id: $what + '$ans' → ACTION=blocked" ACTION blocked
    assert_kv "C21m$id: $what + '$ans' → REASON=invalid-answer" REASON invalid-answer
    assert_single_action_line "C21m$id: the rejection emits exactly one ACTION= line"
    assert_no_uncaught "C21m$id: $what is handled, not thrown"
    if printf '%s\n%s' "$DRIVER_OUT" "$DRIVER_ERR" | grep -qF 'does not match the current pending closed-issue ask'; then
        pass "C21m$id: the diagnostic names the pending-ask contract, not membership"
    else
        fail "C21m$id: diagnostic does not name the pending-ask contract: err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
    fi
    assert_count "C21m$id: 'gh issue reopen $n' was never invoked" 0 "$(count_reopen_of "$n")"
    assert_count "C21m$id: not one 'gh issue reopen' was issued at all" 0 "$(count_any_reopen)"
    if cmp -s "$ck" "$CASE_DIR/ckpt.snapshot"; then
        pass "C21m$id: the checkpoint is byte-identical after the rejection"
    else
        fail "C21m$id: the rejected resume rewrote the checkpoint"
    fi
    assert_ckpt "C21m$id: no reopen override was recorded" "$ck" state.reopen_state_override '[]'
    assert_ckpt "C21m$id: the issue list is untouched — nothing was removed" "$ck" state.issues "[$n]"
    if [ -f "$(ctx_file)" ]; then
        fail "C21m$id: a context.md was produced by the rejected resume"
    else
        pass "C21m$id: no context.md from the rejected resume"
    fi
    teardown_case
}
check_c21m a 970 '__DELETE__' 'a checkpoint whose issue_json_cache key is absent' reopen
check_c21m b 971 'null'       'a null issue_json_cache container'                reopen
check_c21m c 972 '[]'         'an array where the issue_json_cache object belongs' reopen
check_c21m d 973 '{}'         'an already-empty issue_json_cache container'       reopen
# CPR-ORTH: the `remove` arm mutates state.issues rather than the remote, and is refused
# by the same guard — a reopen ask that no longer exists authorizes no state edit either.
check_c21m e 974 '{}'         'an already-empty issue_json_cache container'       remove

# --- C22: a VALID reopen actually performs the remote write ------------------------
# C7 asserts the cache reads OPEN afterwards, which a driver that only rewrote its own
# cache satisfies — the issue would stay CLOSED on GitHub while context.md claimed
# otherwise. The invocation log is the observable that separates them, and so is the
# ORDER in it: the contract is "reopen the authoritative issue FIRST, then refetch".
setup_case wid-c2063-c22
mock_issue 940 CLOSED "type:task"
mock_issue 941 OPEN "type:task"
set_wip 940 same
set_wip 941 same
run_driver '#940' '#941'
assert_kv "C22: the closed issue raises the reopen gate" ASK_ID closed_reopen_940
C22_CKPT="$(get_kv CHECKPOINT)" || true
assert_count "C22: no reopen was issued merely by raising the gate" 0 "$(count_any_reopen)"
run_driver --resume "$C22_CKPT" --answer reopen
assert_kv "C22: the reopened session runs to completion" ACTION done
assert_count "C22: 'gh issue reopen 940' was invoked exactly once" 1 "$(count_reopen_of 940)"
assert_count "C22: no other issue was reopened" 1 "$(count_any_reopen)"
C22_REOPEN_LINE="$(grep -n '^issue reopen 940' "$GH_LOG" | head -1 | cut -d: -f1)"
C22_LAST_VIEW_LINE="$(grep -n '^issue view 940' "$GH_LOG" | tail -1 | cut -d: -f1)"
if [ -n "$C22_REOPEN_LINE" ] && [ -n "$C22_LAST_VIEW_LINE" ] && [ "$C22_REOPEN_LINE" -lt "$C22_LAST_VIEW_LINE" ]; then
    pass "C22: the remote reopen precedes the refetch (the cache never claims more than the remote holds)"
else
    fail "C22: reopen/refetch order wrong — reopen at line '$C22_REOPEN_LINE', last view at '$C22_LAST_VIEW_LINE'"
fi
teardown_case

# --- C22b (CPR-ORTH): the 'remove' answer performs NO remote write ------------------
# The counterpart of C22 on the answer axis. `remove` drops the issue from the session;
# a driver that reopened first and then removed would leave a permanent, unrequested
# mutation on someone else's repository.
setup_case wid-c2063-c22b
mock_issue 942 CLOSED "type:task"
mock_issue 943 OPEN "type:task"
set_wip 942 same
set_wip 943 same
run_driver '#942' '#943'
assert_kv "C22b: the closed issue raises the reopen gate" ASK_ID closed_reopen_942
C22B_CKPT="$(get_kv CHECKPOINT)" || true
run_driver --resume "$C22B_CKPT" --answer remove
assert_count "C22b: 'remove' issues no 'gh issue reopen' at all" 0 "$(count_any_reopen)"
C22B_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C22b: the removed issue is gone from the session" "$C22B_CKPT2" state.issues '[943]'
teardown_case

# --- C23: a FAILING remote reopen blocks; no artifact, no leaked stderr -------------
# Proceeding past a failed `gh issue reopen` is the C8 hazard one step earlier: the cache
# entry would be dropped and refilled while the issue is still CLOSED remotely. And gh's
# failure text is third-party output that can carry a token from the transport, so the
# third observable is that none of it reaches stdout, stderr or any artifact.
C23_SECRET='ghp_C23LEAKCANARY0000000000000000000000'
setup_case wid-c2063-c23
mock_issue 950 CLOSED "type:task"
mock_issue_comments 950 '[{"author":{"login":"carol"},"body":"remark before the failed reopen","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 950 same
run_driver '#950'
assert_kv "C23: the closed issue raises the reopen gate" ASK_ID closed_reopen_950
C23_CKPT="$(get_kv CHECKPOINT)" || true
if [ -z "$C23_CKPT" ] || [ ! -f "$C23_CKPT" ]; then
    fail "C23: no CHECKPOINT from the gating run — the failure assertions are unfalsifiable"
else
    cp "$C23_CKPT" "$CASE_DIR/ckpt.snapshot"
    C23_INV_BEFORE="$(plans_inventory)"
    C23_VIEW_BEFORE="$(count_gh_calls '^issue view')"
    mock_reopen_rc 950 1
    mock_reopen_stderr 950 "gh: failed to reopen issue #950 (HTTP 403) using token $C23_SECRET"
    run_driver --resume "$C23_CKPT" --answer reopen
    assert_kv "C23: a failing remote reopen → ACTION=blocked" ACTION blocked
    assert_kv "C23: a failing remote reopen → REASON=issue_reopen_failed" REASON issue_reopen_failed
    assert_single_action_line "C23: the failure emits exactly one ACTION= line"
    assert_no_uncaught "C23: the subprocess failure is handled, not thrown"
    if [ "$DRIVER_RC" = "0" ]; then
        pass "C23: a controlled block exits 0 (the caller reads the directive, not the rc)"
    else
        fail "C23: exited rc=$DRIVER_RC; err='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
    fi
    # Proof the block above is the mock's forced failure and not some earlier, unrelated
    # rejection that never reached the remote write at all.
    assert_count "C23: the failing reopen was actually attempted, exactly once" 1 "$(count_reopen_of 950)"
    if [ "$(count_gh_calls '^issue view')" = "$C23_VIEW_BEFORE" ]; then
        pass "C23: no refetch followed the failed reopen ($C23_VIEW_BEFORE unchanged)"
    else
        fail "C23: the driver refetched after the reopen failed ($C23_VIEW_BEFORE → $(count_gh_calls '^issue view'))"
    fi
    if [ -f "$(ctx_file)" ]; then
        fail "C23: a context.md was produced by the run whose reopen failed"
    else
        pass "C23: the failed run produces no context.md"
    fi
    if [ "$(plans_inventory)" = "$C23_INV_BEFORE" ]; then
        pass "C23: the failed reopen wrote no new artifact under the plans dir"
    else
        fail "C23: the failed reopen left artifacts behind: $(plans_inventory | tr '\n' ';')"
    fi
    if cmp -s "$C23_CKPT" "$CASE_DIR/ckpt.snapshot"; then
        pass "C23: the checkpoint is byte-identical after the failed reopen"
    else
        fail "C23: the failed reopen rewrote the checkpoint"
    fi
    assert_ckpt "C23: no reopen override was recorded for the failed write" \
        "$C23_CKPT" state.reopen_state_override '[]'
    # The cache entry is dropped only once the remote write succeeds; dropping it first
    # would lose comments already held for an issue that is still CLOSED.
    assert_ckpt "C23: the cache entry survives the failed reopen" "$C23_CKPT" state.issue_json_cache.950.state CLOSED
    if printf '%s\n%s' "$DRIVER_OUT" "$DRIVER_ERR" | grep -qF -- "$C23_SECRET"; then
        fail "C23: gh's failure text leaked a credential into the driver's own output"
    else
        pass "C23: no credential from gh's stderr reaches stdout or stderr"
    fi
    C23_LEAK="$(grep -rlF -- "$C23_SECRET" "$PLANS" 2>/dev/null | tr '\n' ' ')"
    if [ -n "$C23_LEAK" ]; then
        fail "C23: gh's failure text leaked a credential into workflow artifacts: $C23_LEAK"
    else
        pass "C23: no credential from gh's stderr survives anywhere under the plans dir"
    fi
fi
teardown_case

# --- C23b (idempotency): re-answering after a transient failure succeeds cleanly -----
# A reopen that failed on a rate limit is retried by answering the same gate again. The
# retry must not double-apply anything: one override entry, and the session completing.
setup_case wid-c2063-c23b
mock_issue 951 CLOSED "type:task"
set_wip 951 same
run_driver '#951'
assert_kv "C23b: the closed issue raises the reopen gate" ASK_ID closed_reopen_951
C23B_CKPT="$(get_kv CHECKPOINT)" || true
mock_reopen_rc 951 1
run_driver --resume "$C23B_CKPT" --answer reopen
assert_kv "C23b: the first attempt blocks on the transient failure" REASON issue_reopen_failed
mock_reopen_rc 951 0
mock_issue_comments 951 '[{"author":{"login":"carol"},"body":"remark after the retried reopen","createdAt":"2026-07-05T00:00:00Z"}]'
run_driver --resume "$C23B_CKPT" --answer reopen
assert_kv "C23b: the retry runs to completion" ACTION done
assert_count "C23b: exactly two reopen attempts — the failure and the retry" 2 "$(count_reopen_of 951)"
C23B_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C23b: the override records the issue exactly once" "$C23B_CKPT2" state.reopen_state_override '[951]'
assert_ckpt "C23b: the retried refetch reads OPEN" "$C23B_CKPT2" state.issue_json_cache.951.state OPEN
assert_ctx_has "C23b: the post-reopen comment reached context.md" 'remark after the retried reopen'
teardown_case

finish
