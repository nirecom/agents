#!/bin/bash
# tests/feature-workflow-init-driver/driver-routing.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/detect-issues.js, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/wip-check.js, bin/workflow/lib/workflow-init/phases/closed-detection.js, bin/workflow/lib/workflow-init/phases/label-extract.js, bin/workflow/lib/workflow-init/phases/meta-classify.js, bin/workflow/lib/workflow-init/phases/route-decision.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/spawn-env.js, hooks/lib/parse-remote-url.js
# Tags: workflow-init, driver, routing, directive-contract, meta-classify, origin-resolution, fail-closed, scope:issue-specific
#
# R1-R14 — routing branch tests (TDD red phase: driver not yet implemented).
#
# TL3 gap: no real `claude -p` driver loop (ACTION= dispatch, AskUserQuestion,
# --resume) or live gh calls. Mitigated at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- R1: zero issue tokens → full pipeline → done / Path C + context.md -------
# Asserts no early-jump semantics: write-context (WI-9) must run for Path C too.
setup_case wid-r1
run_driver
assert_kv "R1: zero issues → ACTION=done" ACTION done
assert_kv "R1: zero issues → PATH_DECISION=C" PATH_DECISION C
if [ -f "$PLANS/wid-r1-context.md" ]; then
    pass "R1: context.md written under WORKFLOW_PLANS_DIR (write-context phase ran)"
else
    fail "R1: context.md missing at $PLANS/wid-r1-context.md (WI-3 early-jump regression?)"
fi
teardown_case

# --- R2: NON_GITHUB=1 → immediate done / Path C, no gh calls ------------------
setup_case wid-r2
export NON_GITHUB=1
run_driver
assert_kv "R2: NON_GITHUB=1 → ACTION=done" ACTION done
assert_kv "R2: NON_GITHUB=1 → PATH_DECISION=C" PATH_DECISION C
if [ ! -s "$GH_LOG" ]; then
    pass "R2: zero gh invocations under NON_GITHUB=1 (immediate return)"
else
    fail "R2: expected zero gh calls, got: $(tr '\n' ';' < "$GH_LOG")"
fi
teardown_case

# --- R3: one issue WITH intent:clarified → Path A ------------------------------
setup_case wid-r3
mock_issue 123 OPEN "type:task,intent:clarified"
set_wip 123 same
run_driver '#123'
assert_kv "R3: intent:clarified issue → ACTION=done" ACTION done
assert_kv "R3: intent:clarified issue → PATH_DECISION=A" PATH_DECISION A
teardown_case

# --- R4: one issue WITHOUT intent:clarified → Path B ---------------------------
setup_case wid-r4
mock_issue 124 OPEN "type:task"
set_wip 124 same
run_driver '#124'
assert_kv "R4: unclarified issue → ACTION=done" ACTION done
assert_kv "R4: unclarified issue → PATH_DECISION=B" PATH_DECISION B
teardown_case

# --- R4b: non-meta routing succeeds without an origin remote (#1899) -----------
# resolveOwnerRepoFromOrigin() is only invoked from the all-meta branch (R5-R5c);
# this pins that non-meta paths never acquire an implicit origin dependency.
setup_case wid-r4b
case_unset_origin
mock_issue 125 OPEN "type:task"
set_wip 125 same
run_driver '#125'
assert_kv "R4b: non-meta routing, no origin → ACTION=done" ACTION done
assert_kv "R4b: non-meta routing, no origin → PATH_DECISION=B" PATH_DECISION B
teardown_case

# --- R5: all meta-labeled + no open sub-issues → Path META ---------------------
# #1899: the sub-issue endpoint is addressed with the owner/repo derived from the
# checkout's ORIGIN remote. The gh mock still answers `repo view` with
# mockorg/mockrepo, so an api call naming mockorg/mockrepo means the resolver
# regressed to the API path.
setup_case wid-r5
mock_issue 200 OPEN "meta"
set_wip 200 same
mock_sub_issues 200 '[]'
run_driver '#200'
assert_kv "R5: meta with no open children → ACTION=done" ACTION done
assert_kv "R5: meta with no open children → PATH_DECISION=META" PATH_DECISION META
if grep -q "api repos/$CASE_ORIGIN_OWNER_REPO/issues/200/sub_issues" "$GH_LOG"; then
    pass "R5: sub_issues endpoint addressed with origin-derived owner/repo"
else
    fail "R5: sub_issues endpoint not origin-derived; gh calls were: $(tr '\n' ';' < "$GH_LOG")"
fi
if grep -q "repo view" "$GH_LOG"; then
    fail "R5: 'gh repo view' still invoked — repo identity must come from origin"
else
    pass "R5: no 'gh repo view' invocation (origin-only resolution)"
fi
teardown_case

# --- R5a: origin + upstream diverge → origin wins (#1899 regression pin) --------
# The exact shape of the bug: a fork where `gh repo view` would report the
# upstream repository. The api call must still name origin.
setup_case wid-r5a
case_set_origin "https://github.com/fork-owner/fork-repo.git"
case_add_upstream "https://github.com/upstream-owner/upstream-repo.git"
mock_issue 202 OPEN "meta"
set_wip 202 same
mock_sub_issues 202 '[]'
run_driver '#202'
assert_kv "R5a: fork with upstream → ACTION=done" ACTION done
if grep -q "api repos/fork-owner/fork-repo/issues/202/sub_issues" "$GH_LOG"; then
    pass "R5a: origin wins over upstream for sub_issues addressing"
else
    fail "R5a: sub_issues not addressed to origin; gh calls were: $(tr '\n' ';' < "$GH_LOG")"
fi
if grep -q "upstream-owner/upstream-repo" "$GH_LOG"; then
    fail "R5a: upstream repository leaked into a gh call (#1899 defect)"
else
    pass "R5a: upstream repository never addressed"
fi
teardown_case

# --- R5b: no origin remote → blocked, never a hardcoded fallback ----------------
# The old resolver returned the literal "mockorg/mockrepo" on failure, silently
# pointing every downstream write at a repository that does not exist. Failure
# must now surface as a blocked directive carrying a recovery hint.
setup_case wid-r5b
case_unset_origin
mock_issue 203 OPEN "meta"
set_wip 203 same
mock_sub_issues 203 '[]'
run_driver '#203'
assert_kv "R5b: no origin → ACTION=blocked" ACTION blocked
assert_kv "R5b: no origin → REASON=origin_repo_unresolved" REASON origin_repo_unresolved
R5B_HINT="$(get_kv NEXT_HINT)" || R5B_HINT=""
if [ -n "$R5B_HINT" ]; then
    pass "R5b: NEXT_HINT emitted for the blocked directive"
else
    fail "R5b: NEXT_HINT missing — emitBlocked must receive result.nextHint"
fi
if grep -q "mockorg/mockrepo" "$GH_LOG"; then
    fail "R5b: hardcoded 'mockorg/mockrepo' fallback still reached gh"
else
    pass "R5b: no hardcoded owner/repo fallback"
fi
# Fail-closed is a statement about the ROUTE, not only about the directive: an
# unresolved repository must produce ZERO sub-issue API calls. A resolver that
# blocked only after already asking GitHub about some other repository would
# satisfy every assertion above.
if [ "$(count_gh_calls 'issues/[0-9]+/sub_issues')" = "0" ]; then
    pass "R5b: no origin → zero sub_issues API calls"
else
    fail "R5b: sub_issues API called despite unresolved origin: $(tr '\n' ';' < "$GH_LOG")"
fi
teardown_case

# --- R5c: non-github origin → blocked, not silently proceeded ------------------
setup_case wid-r5c
case_set_origin "https://gitlab.com/someorg/somerepo.git"
mock_issue 204 OPEN "meta"
set_wip 204 same
mock_sub_issues 204 '[]'
run_driver '#204'
assert_kv "R5c: non-github origin → ACTION=blocked" ACTION blocked
assert_kv "R5c: non-github origin → REASON=origin_repo_unresolved" REASON origin_repo_unresolved
if [ "$(count_gh_calls 'issues/[0-9]+/sub_issues')" = "0" ]; then
    pass "R5c: non-github origin → zero sub_issues API calls"
else
    fail "R5c: sub_issues API called for a non-github origin: $(tr '\n' ';' < "$GH_LOG")"
fi
# The non-github owner/repo must not leak into ANY gh call either — the host is
# what was rejected, and someorg/somerepo is a perfectly well-shaped owner/repo
# that a host-blind parser would happily hand to `gh api`.
if grep -q "someorg/somerepo" "$GH_LOG"; then
    fail "R5c: non-github owner/repo reached a gh call"
else
    pass "R5c: non-github owner/repo never addressed"
fi
teardown_case

# --- R5d: github.com origin with a malformed path → blocked --------------------
# The host clears the github.com check but the path names no owner/repo. This is
# the arm between R5b (nothing to parse) and R5c (wrong host), and it is the one
# a host-only check would wave through: whatever partial string the parser
# salvaged would be interpolated straight into `gh api repos/<that>/issues/...`.
setup_case wid-r5d
case_set_origin "https://github.com/onlyowner"
mock_issue 205 OPEN "meta"
set_wip 205 same
mock_sub_issues 205 '[]'
run_driver '#205'
assert_kv "R5d: malformed github origin → ACTION=blocked" ACTION blocked
assert_kv "R5d: malformed github origin → REASON=origin_repo_unresolved" REASON origin_repo_unresolved
assert_nonempty_kv "R5d: malformed github origin → NEXT_HINT emitted" NEXT_HINT
if [ "$(count_gh_calls 'issues/[0-9]+/sub_issues')" = "0" ]; then
    pass "R5d: malformed github origin → zero sub_issues API calls"
else
    fail "R5d: sub_issues API called with a salvaged owner/repo: $(tr '\n' ';' < "$GH_LOG")"
fi
if grep -q "onlyowner" "$GH_LOG"; then
    fail "R5d: the unparsable path fragment reached a gh call"
else
    pass "R5d: unparsable path fragment never addressed"
fi
teardown_case

# --- R5e: cwd is not a git checkout at all → blocked ----------------------------
# The environment-caused failure: `git remote get-url origin` itself fails rather
# than returning something unparsable. Same fail-closed verdict — never a
# fallback to `gh repo view`, which would answer for whatever repository the
# ambient credentials happen to resolve.
setup_case wid-r5e
rm -rf "$CASE_DIR/.git"
if git -C "$CASE_DIR" rev-parse --git-dir >/dev/null 2>&1; then
    fail "R5e: fixture not isolated — \$CASE_DIR still resolves to a git repository"
else
    pass "R5e: fixture is genuinely outside any git repository"
    mock_issue 206 OPEN "meta"
    set_wip 206 same
    mock_sub_issues 206 '[]'
    run_driver '#206'
    assert_kv "R5e: no git repo → ACTION=blocked" ACTION blocked
    assert_kv "R5e: no git repo → REASON=origin_repo_unresolved" REASON origin_repo_unresolved
    if [ "$(count_gh_calls 'issues/[0-9]+/sub_issues')" = "0" ]; then
        pass "R5e: no git repo → zero sub_issues API calls"
    else
        fail "R5e: sub_issues API called outside a git checkout: $(tr '\n' ';' < "$GH_LOG")"
    fi
    if grep -q "mockorg/mockrepo" "$GH_LOG"; then
        fail "R5e: fell back to the API's repo identity outside a git checkout"
    else
        pass "R5e: no API-derived repo identity fallback"
    fi
fi
teardown_case

# --- R5f: origin carries a credential AND is unparsable → blocked, no leak ------
# Why this arm on top of R5b-R5e: origin can be an HTTPS URL whose userinfo is an
# access token, and the parse failure `.message` is spliced verbatim into
# NEXT_HINT= and may persist alongside the checkpoint. R5b-R5e all use
# credential-free origins, so that echo-back chain was never checked against a
# secret-bearing input. parse-remote-url.js redacts the userinfo (redactUserinfo
# → "***@") before building any message; this pins that it holds through the real
# driver on a real git fixture. The token is a FAKE `ghp_EXAMPLEEXAMPLE`
# placeholder, matching tests/fix-1899-parse-remote-url/redaction.sh.
setup_case wid-r5f
R5F_TOKEN='ghp_EXAMPLEEXAMPLE'
# github.com host (so the host check passes) but no owner/repo in the path, so the
# parse fails AFTER the userinfo has been seen — the message-building path.
case_set_origin "https://x-access-token:${R5F_TOKEN}@github.com/onlyowner"
mock_issue 207 OPEN "meta"
set_wip 207 same
mock_sub_issues 207 '[]'
run_driver '#207'
assert_kv "R5f: credential-bearing unparsable origin → ACTION=blocked" ACTION blocked
assert_kv "R5f: credential-bearing unparsable origin → REASON=origin_repo_unresolved" REASON origin_repo_unresolved
assert_nonempty_kv "R5f: credential-bearing unparsable origin → NEXT_HINT emitted" NEXT_HINT
R5F_HINT="$(get_kv NEXT_HINT)" || R5F_HINT=""
# Positive marker: the hint DOES quote the offending URL — in redacted form. Without
# this, the absence assertions below could be satisfied by a hint that says nothing.
case "$R5F_HINT" in
    *"***@github.com"*) pass "R5f: NEXT_HINT quotes the origin URL with the userinfo redacted" ;;
    *) fail "R5f: NEXT_HINT does not carry a redacted origin URL: $R5F_HINT" ;;
esac
# The credential must not survive into ANY surface the driver produces. Failure
# messages deliberately never echo the needle — this assertion exists for secrets.
for R5F_SURFACE in "stdout:$DRIVER_OUT" "stderr:$DRIVER_ERR" "next_hint:$R5F_HINT"; do
    case "${R5F_SURFACE#*:}" in
        *"$R5F_TOKEN"*) fail "R5f: raw credential present in driver ${R5F_SURFACE%%:*}" ;;
        *) pass "R5f: no raw credential in driver ${R5F_SURFACE%%:*}" ;;
    esac
done
# On-disk artifacts: everything the driver writes under WORKFLOW_PLANS_DIR
# (checkpoint JSON, context.md, any state file). $CASE_DIR itself is NOT scanned —
# .git/config legitimately holds the fixture's own remote URL.
if grep -rqF -- "$R5F_TOKEN" "$PLANS" 2>/dev/null; then
    fail "R5f: raw credential written into a driver artifact under $PLANS"
else
    pass "R5f: no raw credential in any driver artifact under WORKFLOW_PLANS_DIR"
fi
# Fail-closed on the ROUTE too: an unresolved origin must reach zero sub-issue
# API calls, and the salvaged path fragment must not address anything.
if [ "$(count_gh_calls 'issues/[0-9]+/sub_issues')" = "0" ]; then
    pass "R5f: credential-bearing unparsable origin → zero sub_issues API calls"
else
    fail "R5f: sub_issues API called despite an unresolved origin: $(tr '\n' ';' < "$GH_LOG")"
fi
if grep -qF -- "$R5F_TOKEN" "$GH_LOG" 2>/dev/null; then
    fail "R5f: raw credential reached a gh invocation"
else
    pass "R5f: no raw credential in any gh invocation"
fi
teardown_case

# --- R6: meta + open sub-issues → ask_user meta_select --------------------------
setup_case wid-r6
mock_issue 201 OPEN "meta"
set_wip 201 same
mock_sub_issues 201 '[{"number":42,"title":"Open child","state":"open"}]'
run_driver '#201'
assert_kv "R6: meta with open children → ACTION=ask_user" ACTION ask_user
assert_kv "R6: meta with open children → ASK_ID=meta_select" ASK_ID meta_select
if grep -q "api repos/$CASE_ORIGIN_OWNER_REPO/issues/201/sub_issues" "$GH_LOG"; then
    pass "R6: sub_issues endpoint addressed with origin-derived owner/repo"
else
    fail "R6: sub_issues endpoint not origin-derived; gh calls were: $(tr '\n' ';' < "$GH_LOG")"
fi
teardown_case

# --- R7: mixed meta/non-meta → meta stripped, remainder routed (B) --------------
setup_case wid-r7
mock_issue 210 OPEN "meta"
mock_issue 211 OPEN "type:task"
set_wip 210 same
set_wip 211 same
run_driver '#210' '#211'
assert_kv "R7: mixed meta/non-meta → ACTION=done" ACTION done
assert_kv "R7: mixed meta/non-meta → PATH_DECISION=B (non-meta remainder)" PATH_DECISION B
CKPT_R7="$(get_kv CHECKPOINT)" || true
assert_ckpt "R7: meta issue stripped from checkpoint state.issues" "$CKPT_R7" state.issues "[211]"
teardown_case

# --- R8: two issues → both retained in insertion order in checkpoint ------------
setup_case wid-r8
mock_issue 7 OPEN "type:task,intent:clarified"
mock_issue 9 OPEN "type:task,intent:clarified"
set_wip 7 same
set_wip 9 same
run_driver '#7' '#9'
assert_kv "R8: two issues → ACTION=done" ACTION done
CKPT_R8="$(get_kv CHECKPOINT)" || true
assert_ckpt "R8: checkpoint state.issues retains both in insertion order" "$CKPT_R8" state.issues "[7,9]"
teardown_case

# --- R9: gh issue view failure → ask_user fetch_failed_path_c -------------------
setup_case wid-r9
mock_issue_rc 300 1
run_driver '#300'
assert_kv "R9: fetch failure → ACTION=ask_user" ACTION ask_user
assert_kv "R9: fetch failure → ASK_ID=fetch_failed_path_c" ASK_ID fetch_failed_path_c
teardown_case

# --- R10: issue state CLOSED → ask_user closed_reopen_<N> ------------------------
setup_case wid-r10
mock_issue 301 CLOSED "type:task"
set_wip 301 same
run_driver '#301'
assert_kv "R10: CLOSED issue → ACTION=ask_user" ACTION ask_user
assert_kv "R10: CLOSED issue → ASK_ID=closed_reopen_301" ASK_ID closed_reopen_301
teardown_case

# --- R11: ALL_NONE + missing intent:clarified → force_path_b + Path B ------------
setup_case wid-r11
mock_issue 302 OPEN "type:task"
# wip state intentionally unset → mock 'check' returns default 'none' (ALL_NONE)
run_driver '#302'
assert_kv "R11: ALL_NONE unclarified → ACTION=done" ACTION done
assert_kv "R11: ALL_NONE unclarified → PATH_DECISION=B" PATH_DECISION B
CKPT_R11="$(get_kv CHECKPOINT)" || true
assert_ckpt "R11: checkpoint records force_path_b=true" "$CKPT_R11" state.force_path_b "true"
teardown_case

# --- R12: #2087 — a meta issue is stripped BEFORE it is wip-checked ---------------
# #220 is owned by another session. Under the old phase order wip-check ran first
# and raised wip_conflict for an issue that classification was about to discard;
# it could even take WIP ownership of it. Classification must come first, so #220
# never reaches wip-state.sh at all — neither `check` nor `set`.
setup_case wid-r12
mock_issue 220 OPEN "meta"
mock_issue 221 OPEN "type:task"
set_wip 220 other
set_wip 221 same
run_driver '#220' '#221'
assert_kv "R12: mixed meta/non-meta with a conflicted meta issue → ACTION=done" ACTION done
assert_kv "R12: remainder routed → PATH_DECISION=B" PATH_DECISION B
CKPT_R12="$(get_kv CHECKPOINT)" || true
assert_ckpt "R12: meta issue stripped from checkpoint state.issues" "$CKPT_R12" state.issues "[221]"
if wip_calls | grep -qE '(^| )220( |$)'; then
    fail "R12: wip-state.sh touched the stripped meta issue #220: $(wip_calls | tr '\n' ';')"
else
    pass "R12: wip-state.sh never invoked for the stripped meta issue #220"
fi
teardown_case

# --- R13: #2087 — an all-meta issue is classified BEFORE it is wip-checked --------
setup_case wid-r13
mock_issue 230 OPEN "meta"
set_wip 230 other
mock_sub_issues 230 '[{"number":231,"title":"Open child of 230","state":"open"}]'
run_driver '#230'
assert_kv "R13: meta with an open child → ACTION=ask_user" ACTION ask_user
assert_kv "R13: ask is meta_select, not wip_conflict" ASK_ID meta_select
if wip_calls | grep -qE '(^| )230( |$)'; then
    fail "R13: wip-state.sh touched meta issue #230 before classification: $(wip_calls | tr '\n' ';')"
else
    pass "R13: wip-state.sh never invoked for meta issue #230"
fi
teardown_case

# --- R14: an all-meta session never reaches wip-check at all -----------------------
# 4th-audit BLOCK correction: state.issues is NOT stripped for META (write-context.js
# needs the meta issue as the session's subject downstream). Instead wip-check.js
# filters meta-labelled issues out of its own working set via state.label_sets, so
# #240 is never checked, never owned, and the ALL_NONE branch cannot fire — force_path_b
# stays false. wip is deliberately left UNSET here (mock `check` would answer 'none' →
# ALL_NONE → `set`), so a driver that still ran wip-check over the meta issue would
# visibly flip force_path_b to true.
setup_case wid-r14
mock_issue 240 OPEN "meta"
mock_sub_issues 240 '[]'
run_driver '#240'
assert_kv "R14: all-meta with no open children → ACTION=done" ACTION done
assert_kv "R14: all-meta with no open children → PATH_DECISION=META" PATH_DECISION META
CKPT_R14="$(get_kv CHECKPOINT)" || true
assert_ckpt "R14: state.issues stays populated for META (write-context needs it)" "$CKPT_R14" state.issues "[240]"
assert_ckpt "R14: force_path_b stays false (wip-check filters the meta issue out)" "$CKPT_R14" state.force_path_b "false"
if wip_calls | grep -qE '(^| )240( |$)'; then
    fail "R14: wip-state.sh touched the meta-filtered issue #240: $(wip_calls | tr '\n' ';')"
else
    pass "R14: wip-state.sh never invoked for the meta-filtered issue #240"
fi
teardown_case

# --- R15: same no-op outcome from the opposite starting WIP state ------------------
# R14 enters with wip UNSET (the state that would have produced ALL_NONE →
# force_path_b). R15 enters with ownership ALREADY ours, the other side of the
# wip-check input space, and must land on the identical outcome: META, state.issues
# still populated, no WIP ownership taken, force_path_b false. Together they pin
# that wip-check's label_sets filter makes the meta issue a no-op regardless of
# what wip-state.sh would have answered — not that one particular mock reply
# happened to produce the right verdict.
setup_case wid-r15
mock_issue 250 OPEN "meta"
set_wip 250 same
mock_sub_issues 250 '[]'
run_driver '#250'
assert_kv "R15: all-meta, WIP already ours → ACTION=done" ACTION done
assert_kv "R15: all-meta, force_path_b not triggered → PATH_DECISION=META" PATH_DECISION META
CKPT_R15="$(get_kv CHECKPOINT)" || true
assert_ckpt "R15: state.issues stays populated for META (write-context needs it)" "$CKPT_R15" state.issues "[250]"
assert_ckpt "R15: force_path_b stays false from the pre-owned WIP state too" "$CKPT_R15" state.force_path_b "false"
if [ -n "$(wip_set_calls)" ]; then
    fail "R15: WIP ownership taken for an all-meta session: $(wip_set_calls | tr '\n' ';')"
else
    pass "R15: no WIP ownership taken for an all-meta session"
fi
teardown_case

finish
