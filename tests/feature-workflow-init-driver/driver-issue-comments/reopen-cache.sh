#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments/reopen-cache.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, issue-comments, fetch-issues, write-context, sentinel-strip, prompt-injection, scope:issue-specific

# C7-C10 (#2063): cache coherence across reopen (single, sequential, and one that empties the list), visible degradation on a failed refetch, and the Path A rendering scope for a multi-issue session. The fetch-count floor itself lives in fetch-render.sh.
# Injection seams: ../HARNESS-CONTRACT.md

# TL3 gap: no real `claude -p` ask_user round-trip (answers are replayed through
# --resume/--answer) and no live gh, so the `comments` payload is the mock's shape.
# Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- C7: single CLOSED → reopen cycle ------------------------------------------
# What #2063 was filed about: a comment added while the issue was closed must reach
# context.md after the user answers `reopen`. Six observables kept separate
# (CPR-SC): a refetch happened, exactly once, the override is recorded, the cached
# state reads OPEN, the new comment landed, the same gate is not re-raised.
setup_case wid-c2063-c7
mock_issue 906 CLOSED "type:task"
set_wip 906 same
run_driver '#906'
assert_kv "C7: a closed issue raises the reopen gate" ASK_ID closed_reopen_906
C7_CKPT="$(get_kv CHECKPOINT)" || true
mock_issue_comments 906 '[{"author":{"login":"carol"},"body":"added after the close","createdAt":"2026-07-05T00:00:00Z"}]'
run_driver --resume "$C7_CKPT" --answer reopen
assert_kv "C7(vi): the reopened session runs to completion" ACTION done
if [ "$(get_kv ASK_ID)" = "closed_reopen_906" ]; then
    fail "C7(v): closed_reopen_906 was raised again — reopen loop guard missing"
else
    pass "C7(v): closed_reopen_906 is not re-asked after the refetch"
fi
assert_count "C7(i): exactly two 'gh issue view' calls for #906" 2 "$(count_issue_view 906)"
C7_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C7(ii): reopen_state_override records the issue" "$C7_CKPT2" state.reopen_state_override '[906]'
assert_ckpt "C7(iii): the refetched cache entry reads OPEN" "$C7_CKPT2" state.issue_json_cache.906.state OPEN
assert_ctx_has "C7(iv): the post-close comment reached context.md" 'added after the close'
teardown_case

# --- C8: a failing reopen refetch degrades visibly, never silently -------------
# The rejected alternative was falling back to the stale cache, which would render
# a context.md that looks complete while missing exactly the comments the reopen
# was performed to collect. The failure must surface as the existing ask instead.
# "Surfaced the ask" alone does not prove the stale data stayed out: a driver can
# raise the ask AND still have written the pre-reopen snapshot. So the pre-reopen
# comment carries a signature string, confirmed present before the reopen and then
# hunted for after it — no artifact, an invalidated cache entry, no byte under $PLANS.
setup_case wid-c2063-c8
mock_issue 907 CLOSED "type:task"
mock_issue_comments 907 '[{"author":{"login":"carol"},"body":"STALE-PRE-REOPEN-REMARK-907","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 907 same
run_driver '#907'
assert_kv "C8: a closed issue raises the reopen gate" ASK_ID closed_reopen_907
C8_CKPT="$(get_kv CHECKPOINT)" || true
# The seed must be provably PRESENT before the reopen, or the leak hunt below is a
# probe for something that was never there and passes no matter what the driver does.
if [ -n "$(grep -rlF -- 'STALE-PRE-REOPEN-REMARK-907' "$PLANS" 2>/dev/null)" ]; then
    pass "C8: the pre-reopen comment is in the artifacts before the reopen (the leak probe is live)"
else
    fail "C8: the pre-reopen comment never reached any artifact — the leak assertion below cannot fail"
fi
mock_issue_rc 907 1
run_driver --resume "$C8_CKPT" --answer reopen
assert_kv "C8: a failed reopen refetch raises fetch_failed_path_c" ASK_ID fetch_failed_path_c
if [ "$(get_kv ACTION)" = "done" ]; then
    fail "C8: the session completed on stale cache instead of surfacing the fetch failure"
else
    pass "C8: no silent completion from the stale cache"
fi
if [ -f "$(ctx_file)" ]; then
    fail "C8: a context.md was produced by the run whose refetch failed"
else
    pass "C8: the failed run produces no context.md"
fi
C8_CKPT2="$(get_kv CHECKPOINT)" || true
if [ -n "$C8_CKPT2" ]; then
    assert_ckpt "C8: the reopen-invalidated cache entry is not restored from the stale copy" \
        "$C8_CKPT2" state.issue_json_cache.907 '<missing>'
else
    fail "C8: the failed resume emitted no CHECKPOINT — the cache-state assertion is unfalsifiable"
fi
C8_LEAK="$(grep -rlF -- 'STALE-PRE-REOPEN-REMARK-907' "$PLANS" 2>/dev/null | tr '\n' ' ')"
if [ -n "$C8_LEAK" ]; then
    fail "C8: the pre-reopen comment leaked into workflow artifacts: $C8_LEAK"
else
    pass "C8: no pre-reopen comment text survives anywhere under the plans dir"
fi
teardown_case

# --- C9: two CLOSED issues reopened in sequence --------------------------------
# The regression this file exists to prevent: if the PERMANENT override set is also
# consulted when deciding whether to refetch, #908 is refetched again while #909's
# reopen re-enters fetch-issues — three calls for #908, not two. "Exactly 2" is the
# assertion, never ">= 2": a lower bound cannot see this regression.
setup_case wid-c2063-c9
mock_issue 908 CLOSED "type:task"
mock_issue 909 CLOSED "type:task"
set_wip 908 same
set_wip 909 same
run_driver '#908' '#909'
assert_kv "C9: the first closed issue gates the session" ASK_ID closed_reopen_908
C9_CKPT="$(get_kv CHECKPOINT)" || true
mock_issue_comments 908 '[{"author":{"login":"carol"},"body":"comment on the first reopened issue","createdAt":"2026-07-05T00:00:00Z"}]'
run_driver --resume "$C9_CKPT" --answer reopen
assert_kv "C9: the second closed issue gates next" ASK_ID closed_reopen_909
C9_CKPT2="$(get_kv CHECKPOINT)" || true
run_driver --resume "$C9_CKPT2" --answer reopen
assert_kv "C9(v): both reopens accepted, session completes" ACTION done
case "$(get_kv ASK_ID)" in
    closed_reopen_908|closed_reopen_909)
        fail "C9(v): a closed gate was re-raised after both reopens: $(get_kv ASK_ID)" ;;
    *)
        pass "C9(v): neither closed gate is re-raised" ;;
esac
assert_count "C9(i): exactly two 'gh issue view' calls for #908 (no third from #909's re-entry)" 2 "$(count_issue_view 908)"
assert_count "C9(ii): exactly two 'gh issue view' calls for #909" 2 "$(count_issue_view 909)"
C9_CKPT3="$(get_kv CHECKPOINT)" || true
assert_ckpt "C9(iii): reopen_state_override holds both, in answer order, no duplicates" "$C9_CKPT3" state.reopen_state_override '[908,909]'
assert_ckpt "C9(iv): #908 stays OPEN across the second reopen" "$C9_CKPT3" state.issue_json_cache.908.state OPEN
assert_ckpt "C9(iv): #909 reads OPEN after its own reopen" "$C9_CKPT3" state.issue_json_cache.909.state OPEN
assert_ctx_has "C9(vi): the first issue's post-reopen comment reached context.md" 'comment on the first reopened issue'
teardown_case

# --- C9b: a sequential reopen REPLACES each issue's cached comments -------------
# C9 counts the fetches and C7 checks one issue's context.md, so a driver that
# refetched both issues and then merged the response into the existing cache entry —
# or kept the stale entry and only appended to context.md — passes both. Here each
# issue is seeded with its own signature comment, that seed is proved present in the
# cache BEFORE any reopen, the mock is then mutated, and the FINAL cache is required
# to hold the new text and none of the old for BOTH issues.
setup_case wid-c2063-c9b
mock_issue 912 CLOSED "type:task"
mock_issue 913 CLOSED "type:task"
mock_issue_comments 912 '[{"author":{"login":"carol"},"body":"STALE-CACHED-REMARK-912","createdAt":"2026-07-02T00:00:00Z"}]'
mock_issue_comments 913 '[{"author":{"login":"dave"},"body":"STALE-CACHED-REMARK-913","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 912 same
set_wip 913 same
run_driver '#912' '#913'
assert_kv "C9b: the first closed issue gates the session" ASK_ID closed_reopen_912
C9B_CKPT="$(get_kv CHECKPOINT)" || true
# Without this the "no stale text survives" assertions below probe for something that
# was never cached, and pass however the driver behaves.
C9B_SEED_912="$(ckpt_get "$C9B_CKPT" state.issue_json_cache.912.comments)"
C9B_SEED_913="$(ckpt_get "$C9B_CKPT" state.issue_json_cache.913.comments)"
case "$C9B_SEED_912" in
    *STALE-CACHED-REMARK-912*) pass "C9b: #912's stale comment is cached before its reopen (the probe is live)" ;;
    *) fail "C9b: #912's pre-reopen cache never held the seed — the replace assertion cannot fail: '$C9B_SEED_912'" ;;
esac
case "$C9B_SEED_913" in
    *STALE-CACHED-REMARK-913*) pass "C9b: #913's stale comment is cached before its reopen (the probe is live)" ;;
    *) fail "C9b: #913's pre-reopen cache never held the seed — the replace assertion cannot fail: '$C9B_SEED_913'" ;;
esac
mock_issue_comments 912 '[{"author":{"login":"carol"},"body":"FRESH-POST-REOPEN-REMARK-912","createdAt":"2026-07-05T00:00:00Z"}]'
run_driver --resume "$C9B_CKPT" --answer reopen
assert_kv "C9b: the second closed issue gates next" ASK_ID closed_reopen_913
C9B_CKPT2="$(get_kv CHECKPOINT)" || true
mock_issue_comments 913 '[{"author":{"login":"dave"},"body":"FRESH-POST-REOPEN-REMARK-913","createdAt":"2026-07-06T00:00:00Z"}]'
run_driver --resume "$C9B_CKPT2" --answer reopen
assert_kv "C9b: both reopens accepted, session completes" ACTION done
C9B_CKPT3="$(get_kv CHECKPOINT)" || true
C9B_FINAL_912="$(ckpt_get "$C9B_CKPT3" state.issue_json_cache.912.comments)"
C9B_FINAL_913="$(ckpt_get "$C9B_CKPT3" state.issue_json_cache.913.comments)"
check_replaced() {  # <label-prefix> <final-cache-json> <fresh-needle> <stale-needle>
    case "$2" in
        *"$3"*) pass "$1: the refetched comment is in the final cache" ;;
        *)      fail "$1: '$3' missing from the final cache: '$(printf '%s' "$2" | head -c 200)'" ;;
    esac
    case "$2" in
        *"$4"*) fail "$1: the stale comment survived beside the refetched one: '$(printf '%s' "$2" | head -c 200)'" ;;
        *)      pass "$1: no stale comment text survives in the final cache" ;;
    esac
}
check_replaced "C9b(#912)" "$C9B_FINAL_912" FRESH-POST-REOPEN-REMARK-912 STALE-CACHED-REMARK-912
check_replaced "C9b(#913)" "$C9B_FINAL_913" FRESH-POST-REOPEN-REMARK-913 STALE-CACHED-REMARK-913
# Replaced, not appended: a merge that kept both would still match the two checks above
# if the stale needle happened to be rewritten, so the element count is pinned too.
assert_ckpt "C9b(#912): the cache holds exactly the one refetched comment" "$C9B_CKPT3" state.issue_json_cache.912.comments.length 1
assert_ckpt "C9b(#913): the cache holds exactly the one refetched comment" "$C9B_CKPT3" state.issue_json_cache.913.comments.length 1
# issues[0] is the rendered one (C10), so context.md is the second, independent
# witness that #912's refreshed text — not its stale seed — reached the artifact.
assert_ctx_has "C9b: #912's refetched comment reached context.md" 'FRESH-POST-REOPEN-REMARK-912'
assert_ctx_lacks "C9b: #912's stale comment is absent from context.md" 'STALE-CACHED-REMARK-912'
teardown_case

# --- C9c: a reopen whose refetch returns ZERO comments must EMPTY the cache -------
# C9b replaces one non-empty list with another, which a driver that MERGES the response
# into the existing entry can also satisfy whenever the new text happens to sit where
# the old did. The empty response is the shape that separates merge from replace: the
# discussion was deleted while the issue was closed, so `[]` is the only correct final
# state and any merge leaves the stale text standing — in the cache and in context.md.
setup_case wid-c2063-c9c
mock_issue 915 CLOSED "type:task"
mock_issue_comments 915 '[{"author":{"login":"carol"},"body":"STALE-BEFORE-EMPTYING-915","createdAt":"2026-07-02T00:00:00Z"}]'
set_wip 915 same
run_driver '#915'
assert_kv "C9c: the closed issue raises the reopen gate" ASK_ID closed_reopen_915
C9C_CKPT="$(get_kv CHECKPOINT)" || true
# Same unfalsifiability guard as C8/C9b: without the seed provably cached first, the
# "no stale text survives" hunt below probes for something that was never there.
C9C_SEED="$(ckpt_get "$C9C_CKPT" state.issue_json_cache.915.comments)"
case "$C9C_SEED" in
    *STALE-BEFORE-EMPTYING-915*)
        pass "C9c: the stale comment is cached before the reopen (the emptying probe is live)" ;;
    *)
        fail "C9c: the pre-reopen cache never held the seed — the emptying assertions cannot fail: '$C9C_SEED'" ;;
esac
mock_issue_comments 915 '[]'
run_driver --resume "$C9C_CKPT" --answer reopen
assert_kv "C9c: the reopened session runs to completion" ACTION done
assert_count "C9c: exactly two 'gh issue view' calls for #915 — one refetch, not a retry loop" 2 "$(count_issue_view 915)"
C9C_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "C9c: the refetched entry holds an EMPTY comments array" "$C9C_CKPT2" state.issue_json_cache.915.comments '[]'
assert_ckpt "C9c: the emptied entry still reads OPEN" "$C9C_CKPT2" state.issue_json_cache.915.state OPEN
# The whole section, not "(none) occurs somewhere": a section that kept the stale entry
# AND gained a `(none)` line would satisfy any presence check.
C9C_SECTION='## Issue comments
(none)'
assert_section_eq "C9c: context.md's section is exactly the heading and (none)" "$C9C_SECTION"
C9C_LEAK="$(grep -rlF -- 'STALE-BEFORE-EMPTYING-915' "$PLANS" 2>/dev/null | tr '\n' ' ')"
if [ -n "$C9C_LEAK" ]; then
    fail "C9c: the pre-reopen comment survived the emptying refetch: $C9C_LEAK"
else
    pass "C9c: no pre-reopen comment text survives anywhere under the plans dir"
fi
teardown_case

# --- C10: multi-issue Path A rendering scope -----------------------------------
# The scope is a SETTLED design decision, not an oversight: detail.md S4 adopts
# "fetch every issue, but render only issues[0] into context.md" and lists making `## Issue body` /
# `## Issue metadata` multi-issue-aware under Out of scope. Rendering every issue's
# comments would leave one file carrying one issue's body beside another issue's
# discussion — asymmetry inside a single context.md (CPR-ORTH). Hence: the cache still
# holds #911's comments (iv) though context.md does not show them (ii), and the
# omission is announced with per-issue attribution rather than silent (iii).
setup_case wid-c2063-c10
mock_issue 910 OPEN "type:task"
mock_issue 911 OPEN "type:task"
mock_issue_comments 910 '[{"author":{"login":"alice"},"body":"alpha remark on the first issue","createdAt":"2026-07-02T00:00:00Z"},{"author":{"login":"bob"},"body":"beta remark on the first issue","createdAt":"2026-07-03T00:00:00Z"}]'
mock_issue_comments 911 '[{"author":{"login":"dave"},"body":"remark belonging to the second issue","createdAt":"2026-07-04T00:00:00Z"}]'
set_wip 910 same
set_wip 911 same
run_driver '#910' '#911'
assert_kv "C10: the two-issue session completes" ACTION done
assert_ctx_has "C10(i): the first issue's comment 1 is rendered" 'alpha remark on the first issue'
assert_ctx_has "C10(i): the first issue's comment 2 is rendered" 'beta remark on the first issue'
assert_ctx_lacks_live "C10(ii): the second issue's comment is NOT rendered" 'remark belonging to the second issue'
# Asserted on ONE line, not on the file: '#911' and 'render-issue-comments' each
# appear elsewhere in context.md for unrelated reasons, so a file-wide grep would
# stay green with no announcement at all.
C10_NOTE="$(grep -F -- 'comments shown for #910 only' "$(ctx_file)" 2>/dev/null | head -1)"
if [ -n "$C10_NOTE" ]; then
    pass "C10(iii): the omission is announced, naming the issue that IS rendered"
else
    fail "C10(iii): no 'comments shown for #910 only' announcement in $(ctx_file)"
fi
case "$C10_NOTE" in
    *'#911'*) pass "C10(iii): the announcement line names the omitted issue" ;;
    *) fail "C10(iii): the announcement line does not name #911: '$C10_NOTE'" ;;
esac
case "$C10_NOTE" in
    *'render-issue-comments'*) pass "C10(iii): the announcement line names the CLI that can retrieve it" ;;
    *) fail "C10(iii): the announcement line does not name render-issue-comments: '$C10_NOTE'" ;;
esac
# The gh mock replays its fixture whole, ignoring --json, so (iv) alone cannot prove
# the field was requested — C1 asserts that on the call log and is its counterpart.
C10_CKPT="$(get_kv CHECKPOINT)" || true
C10_BCACHE="$(ckpt_get "$C10_CKPT" state.issue_json_cache.911.comments)"
case "$C10_BCACHE" in
    *"remark belonging to the second issue"*)
        pass "C10(iv): the second issue's comment is still cached (fetch stayed symmetric)" ;;
    *)
        fail "C10(iv): #911's comments missing from the cache: '$C10_BCACHE'" ;;
esac
assert_ctx_count_live "C10(v): no per-issue '### Issue #' subheading was introduced" '^### Issue #' 0
# Attribution has to be readable where the comments are, not merely present somewhere
# in the file: a note stranded in another section leaves the rendered thread unlabelled.
case "$(comments_section)" in
    *"${C10_NOTE:-<<NO-ANNOUNCEMENT>>}"*)
        pass "C10(vi): the attribution line sits inside the '## Issue comments' section" ;;
    *)
        fail "C10(vi): the '#910 only' attribution is not inside the comments section: [$(comments_section | head -c 200)]" ;;
esac
teardown_case

finish
