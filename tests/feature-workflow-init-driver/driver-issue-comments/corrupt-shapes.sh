#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments/corrupt-shapes.sh
# Tests: bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/phases/fetch-issues.js, bin/workflow/lib/workflow-init/phases/write-context.js, bin/workflow/lib/workflow-init/issue-comments.js, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, issue-comments, fetch-issues, write-context, sentinel-strip, prompt-injection, scope:issue-specific

# C11, C15, C16, C19 (#2063, fail-closed): a corrupt comments container, corrupt elements, unparseable gh bytes and a wrong-shape top-level payload each degrade context.md visibly instead of crashing the driver; a version-2 checkpoint migrates to 3 by refetching; a resume over a version-3 checkpoint whose issue_json_cache CONTAINER is gone recovers or fails controlled; a secret on gh's stderr reaches no artifact.
# Injection seams: ../HARNESS-CONTRACT.md

# TL3 gap: no real `claude -p` ask_user round-trip (answers are replayed through
# --resume/--answer) and no live gh, so the `comments` payload is the mock's shape.
# Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

# --- C11 (fail-closed): a corrupt comments CONTAINER through the driver ---------
# The CLI's own corrupt-container contract is covered in feature-2063-render-issue-comments.sh,
# but that path exits 3 and prints nothing. Path A is the asymmetric half: context.md is a
# diagnosable artifact for humans, so it must SAY the cache is broken rather than omit the
# section or — worse — render `(none)`, which is indistinguishable from "no discussion yet".
# The container is corrupt for reasons outside this session's control (a hand-edited
# checkpoint, a gh schema change), so the run must degrade, never crash.
check_c11() {  # <id> <issue> <raw-comments-json-or-__DELETE__> <want-token>
    local id="$1" n="$2" raw="$3" token="$4"
    setup_case "wid-c2063-c11$id"
    mock_issue "$n" OPEN "type:task"
    mock_issue_comments "$n" "$raw"
    set_wip "$n" same
    run_driver "#$n"
    assert_kv "C11$id: a corrupt comments container still completes the pipeline" ACTION done
    assert_no_uncaught "C11$id: the corrupt container is handled, not thrown"
    assert_ctx_has "C11$id: the section header is still written" '## Issue comments'
    assert_ctx_has "C11$id: the breakage is named, with its defect token" \
        "(comments unavailable — malformed cache entry: $token)"
    # Scoped to the section: context.md writes `(none)` for an empty user prompt and an
    # empty keyword list too, so a file-wide form fails on a correct render.
    assert_section_lacks "C11$id: a broken cache never renders as '(none)'" '(none)'
    assert_ctx_count "C11$id: no partial comment entry is fabricated" '^### Comment ' 0
    teardown_case
}
check_c11 a 920 '__DELETE__' comments_missing   # the key the --json list should have added
check_c11 b 921 '"oops"'     comments_not_array # a string where the array belongs
check_c11 c 922 '{}'         comments_not_array # an object — the shape a schema change gives
check_c11 d 923 '42'         comments_not_array # a scalar

# JSON `null` sits between "absent" and "wrong type" and the two readings are equally
# defensible, so the token is not pinned — only that ONE of them is reported, which is
# what keeps `(none)` and a silent omission out either way.
setup_case wid-c2063-c11e
mock_issue 924 OPEN "type:task"
mock_issue_comments 924 'null'
set_wip 924 same
run_driver '#924'
assert_kv "C11e: a null comments container still completes the pipeline" ACTION done
assert_no_uncaught "C11e: a null container is handled, not thrown"
C11E_LINE="$(grep -F 'comments unavailable — malformed cache entry:' "$(ctx_file)" 2>/dev/null | head -1)"
case "$C11E_LINE" in
    *'comments_missing)'* | *'comments_not_array)'*)
        pass "C11e: a null container is reported with one of the two container tokens" ;;
    *)
        fail "C11e: no malformed-cache line for a null container: '$C11E_LINE'" ;;
esac
assert_section_lacks "C11e: a null container never renders as '(none)'" '(none)'
teardown_case

# --- C11f/C11g: ELEMENT-level corruption degrades per element, not per section ---
# The container is a valid array here, so the section is real; only individual entries
# are unusable. Collapsing the whole section for one bad element would discard the good
# comments beside it — author/createdAt/body are three independent taint surfaces.
setup_case wid-c2063-c11f
mock_issue 925 OPEN "type:task"
mock_issue_comments 925 '[null,{"author":{"login":"alice"},"body":"survives beside the broken one","createdAt":"2026-07-02T00:00:00Z"},"a string, not an object"]'
set_wip 925 same
run_driver '#925'
assert_kv "C11f: malformed elements still complete the pipeline" ACTION done
assert_no_uncaught "C11f: malformed elements are handled, not thrown"
assert_ctx_lacks "C11f: element damage never escalates to a container defect" 'malformed cache entry'
assert_ctx_has "C11f: the healthy element beside them is rendered" '> survives beside the broken one'
assert_ctx_count "C11f: all three elements keep their slot — none is silently dropped" '^### Comment ' 3
assert_ctx_count "C11f: the two unusable bodies are marked, not blank" '^> \(malformed comment\)$' 2
teardown_case

setup_case wid-c2063-c11g
mock_issue 926 OPEN "type:task"
mock_issue_comments 926 '[{"author":null,"body":"body outlives its metadata","createdAt":null},{"author":{"login":null},"body":"login is null but body is fine","createdAt":123}]'
set_wip 926 same
run_driver '#926'
assert_kv "C11g: null metadata still completes the pipeline" ACTION done
assert_no_uncaught "C11g: null metadata is handled, not thrown"
assert_ctx_has "C11g: an unusable author/date falls back without taking the body with it" \
    '### Comment 1 — (unknown) ((unknown))'
assert_ctx_has "C11g: comment 1 body survives its broken metadata" '> body outlives its metadata'
assert_ctx_has "C11g: comment 2 body survives a null login and a numeric date" '> login is null but body is fine'
assert_ctx_count "C11g: a usable body is never marked malformed" '^> \(malformed comment\)$' 0
teardown_case

# --- C11h: gh returns bytes that are not JSON at all ----------------------------
# Upstream of the cache: fetch-issues cannot parse the payload, so there is nothing to
# render. CPR-ORTH with C8 (a non-zero gh rc): an unusable response is a fetch failure,
# and it must surface as the ask, never as a completed session over an empty cache.
setup_case wid-c2063-c11h
mock_issue 927 OPEN "type:task"
printf '%s\n' '{"number":927,"title":"truncated payload","comments":[{"author":' > "$RESP/issue-view-927.json"
set_wip 927 same
run_driver '#927'
assert_kv "C11h: unparseable gh output raises fetch_failed_path_c" ASK_ID fetch_failed_path_c
assert_no_uncaught "C11h: a JSON parse failure is reported, not thrown"
if [ "$(get_kv ACTION)" = "done" ]; then
    fail "C11h: the session completed over an unparseable fetch"
else
    pass "C11h: no silent completion from an unparseable fetch"
fi
if [ -f "$(ctx_file)" ]; then
    fail "C11h: a context.md was written from an unparseable fetch: $(ctx_file)"
else
    pass "C11h: no partial context.md artifact from an unparseable fetch"
fi
teardown_case

# --- C11i: gh returns VALID JSON whose top-level issue is the wrong shape --------
# The gap between C11h (bytes that do not parse) and C11a-e (a good issue object with a
# bad `comments` value): here `JSON.parse` succeeds and hands back something that is not
# an issue at all. `null` is the one that actually bites — `state.issue_json_cache[n] =
# null` is indistinguishable from "not yet fetched" to the cache-skip test, so a driver
# that stores it either re-fetches forever or dereferences null downstream. The array,
# string and number shapes are the same class (CPR-E2C): every non-object payload must be
# rejected at the fetch boundary with the SAME token an unparseable payload gets, because
# by the time the renderer sees it the distinction is no longer recoverable.
check_c11i() {  # <id> <issue> <raw-top-level-json>
    local id="$1" n="$2" raw="$3"
    setup_case "wid-c2063-c11i$id"
    mock_issue "$n" OPEN "type:task"
    printf '%s\n' "$raw" > "$RESP/issue-view-$n.json"
    set_wip "$n" same
    run_driver "#$n"
    assert_kv "C11i$id: a non-object issue payload raises fetch_failed_path_c" ASK_ID fetch_failed_path_c
    assert_no_uncaught "C11i$id: the wrong-shape payload is rejected, not dereferenced"
    if [ "$(get_kv ACTION)" = "done" ]; then
        fail "C11i$id: the session completed over a payload that is not an issue object"
    else
        pass "C11i$id: no silent completion from a wrong-shape payload"
    fi
    if [ -f "$(ctx_file)" ]; then
        fail "C11i$id: a context.md was written from a wrong-shape payload: $(ctx_file)"
    else
        pass "C11i$id: no context.md artifact from a wrong-shape payload"
    fi
    teardown_case
}
check_c11i a 931 'null'      # parses, and then reads as "never fetched" to the cache skip
check_c11i b 932 '[]'        # an array where the object belongs
check_c11i c 933 '"issue"'   # a bare string
check_c11i d 934 '42'        # a bare number

# --- C15 (migration): the IMMEDIATE predecessor schema, version 2 -----------------
# driver-checkpoint-resume.sh C12 covers version 1, which is two bumps behind and can
# only ever be a museum piece. Version 2 is the schema every checkpoint on a developer's
# disk carries the moment #2063 lands, so it is the one migration that actually runs in
# the field. Its distinguishing feature is not a corrupt field but a COMPLETE one: the
# cache entry is well formed for its own version and simply has no `comments` key,
# because nothing had ever fetched the field. Replaying it would render a context.md
# with no discussion and no explanation, which is exactly the bug #2063 was filed about.
# The version bump must therefore discard it and refetch, and the checkpoint left behind
# must be version 3 carrying the comments the v2 entry could not hold.
setup_case wid-c2063-c15
mock_issue 940 OPEN "type:task"
mock_issue_comments 940 '[{"author":{"login":"erin"},"body":"comment the v2 checkpoint could never hold","createdAt":"2026-07-08T00:00:00Z"}]'
set_wip 940 same
C15_OLD="$PLANS/wid-c2063-c15-wi-checkpoint.json"
# Hand-written, not tampered: the SHAPE is the point. Every field makeInitialState()
# produced at version 2 is present, and the cache entry is the pre-#2063 projection —
# `gh issue view --json number,title,body,labels,state,createdAt` with no `comments`.
node -e '
const fs = require("fs");
fs.writeFileSync(process.argv[1], JSON.stringify({
  version: 2,
  session_id: "wid-c2063-c15",
  phase: "wip-check",
  ask_id: "wip_conflict",
  state: {
    issues: [940],
    repo_map: {},
    sid_pass: null,
    issue_json_cache: {
      940: {
        number: 940, title: "Issue 940", body: "STALE-V2-BODY-940",
        labels: [{ name: "type:task" }], state: "OPEN", createdAt: "2026-07-01T00:00:00Z"
      }
    },
    wip_results: { 940: "other" },
    label_sets: {},
    force_path_b: false,
    path_decision: null,
    adopt_candidate: null,
    adopt_decision: null,
    meta_select_offered: [],
    meta_select_pending: []
  }
}, null, 2) + "\n");
' "$C15_OLD"
# Without this the "no v2 content survives" hunt below probes for something that was
# never written and passes however the driver behaves.
if grep -qF -- 'STALE-V2-BODY-940' "$C15_OLD" 2>/dev/null; then
    pass "C15: the version-2 checkpoint carries its own cached body (the migration probe is live)"
else
    fail "C15: the hand-written version-2 checkpoint holds no marker — the survival assertions cannot fail"
fi
# The documented resume invocation passes no positional token, so the restart has to
# recover #940 from the stale checkpoint's own state.issues (HARNESS-CONTRACT.md).
run_driver --resume "$C15_OLD" --answer continue
assert_kv "C15: the migrated session runs to completion" ACTION done
assert_no_uncaught "C15: a version-2 checkpoint is migrated, not thrown on"
assert_count "C15: #940 is refetched exactly once — the v2 cache is discarded, not replayed" 1 "$(count_issue_view 940)"
C15_CKPT="$(get_kv CHECKPOINT)" || true
assert_ckpt "C15: the checkpoint left behind is version 3" "$C15_CKPT" version 3
C15_CACHED="$(ckpt_get "$C15_CKPT" state.issue_json_cache.940.comments)"
case "$C15_CACHED" in
    *'comment the v2 checkpoint could never hold'*)
        pass "C15: the version-3 cache entry holds the refetched comments" ;;
    *)
        fail "C15: the migrated cache entry has no comments: '$(printf '%s' "$C15_CACHED" | head -c 200)'" ;;
esac
assert_ctx_has "C15: the refetched comment reaches context.md" 'comment the v2 checkpoint could never hold'
C15_LEAK="$(grep -rlF -- 'STALE-V2-BODY-940' "$PLANS" 2>/dev/null | tr '\n' ' ')"
if [ -n "$C15_LEAK" ]; then
    fail "C15: version-2 content survived the migration: $C15_LEAK"
else
    pass "C15: no version-2 content survives anywhere under the plans dir"
fi
teardown_case

# --- C19 (resume): the checkpoint is CURRENT but its issue_json_cache CONTAINER is gone
# P13 (feature-2063-render-issue-comments/error-tokens.sh) reads such a checkpoint from
# the standalone CLI, which only reads and exits 3. The driver is the half that has to
# CREATE or REPAIR the container on resume — `fetch-issues` indexes
# `state.issue_json_cache[n]` and `applyAnswer` assigns into it, so an absent / null /
# array container is where a `TypeError` lives. Neither recovery nor a controlled refusal
# is pinned (as C11e leaves `null` unpinned): what IS pinned is that one of the two
# happens, with no stack trace and no half-written artifact. The version comes from the
# schema owner (CPR-SSOT) — staged a bump behind, every case below would instead be
# answered by `version_mismatch` and would prove nothing about the container guard.
C19_VERSION="$(node -e '
try {
  const v = require(process.argv[1]).CHECKPOINT_VERSION;
  process.stdout.write(typeof v === "number" ? String(v) : "<not-a-number>");
} catch (e) { process.stdout.write("<unreadable>"); }
' "$AGENTS_DIR/bin/workflow/lib/workflow-init/checkpoint.js")"
case "$C19_VERSION" in
    ''|*[!0-9]*) fail "C19: checkpoint.js names no numeric CHECKPOINT_VERSION ('$C19_VERSION') — a current-version checkpoint cannot be staged" ;;
    *) pass "C19: checkpoint.js names its current schema version ($C19_VERSION) — the fixture can match it" ;;
esac

check_c19() {  # <id> <issue> <container-json-or-__DELETE__> <what>
    local id="$1" n="$2" raw="$3" what="$4" ck ck2 shape cached
    setup_case "wid-c2063-c19$id"
    mock_issue "$n" OPEN "type:task"
    mock_issue_comments "$n" "[{\"author\":{\"login\":\"erin\"},\"body\":\"REFETCHED-AFTER-C19$id\",\"createdAt\":\"2026-07-09T00:00:00Z\"}]"
    set_wip "$n" same
    ck="$PLANS/wid-c2063-c19$id-wi-checkpoint.json"
    node -e '
const fs = require("fs");
const [p, n, sid, raw, ver] = process.argv.slice(1);
const ck = {
  version: Number(ver), session_id: sid, phase: "wip-check", ask_id: "wip_conflict",
  state: {
    issues: [Number(n)], repo_map: {}, sid_pass: null,
    issue_json_cache: {}, wip_results: { [n]: "other" }, label_sets: {},
    force_path_b: false, path_decision: null, adopt_candidate: null, adopt_decision: null,
    meta_select_offered: [], meta_select_pending: [], reopen_state_override: []
  }
};
if (raw === "__DELETE__") delete ck.state.issue_json_cache;
else ck.state.issue_json_cache = JSON.parse(raw);
fs.writeFileSync(p, JSON.stringify(ck, null, 2) + "\n");
' "$ck" "$n" "wid-c2063-c19$id" "$raw" "$C19_VERSION"
    # Two fixture probes, or the case is about a checkpoint it never actually staged: the
    # version must be the CURRENT one (otherwise this only re-runs C15's version gate) and
    # the container must really carry the corrupt shape under test.
    assert_ckpt "C19$id: the staged checkpoint is at the CURRENT version" "$ck" version "$C19_VERSION"
    shape="$(ckpt_get "$ck" state.issue_json_cache)"
    if [ "$shape" = "<missing>" ] || [ "$shape" = "[]" ]; then
        pass "C19$id: the staged checkpoint really carries $what (the probe is live)"
    else
        fail "C19$id: the staged container is '$shape', not the corrupt shape under test"
    fi
    run_driver --resume "$ck" --answer continue
    assert_no_uncaught "C19$id: $what is handled, not thrown"
    assert_single_action_line "C19$id: $what still emits exactly one directive line"
    ck2="$(get_kv CHECKPOINT)" || true
    if [ "$(get_kv ACTION)" = "done" ]; then
        pass "C19$id: $what recovers — the container is rebuilt and the issue refetched"
        cached="$(ckpt_get "$ck2" "state.issue_json_cache.$n.comments")"
        case "$cached" in
            *"REFETCHED-AFTER-C19$id"*) pass "C19$id: the rebuilt container holds the refetched comments" ;;
            *) fail "C19$id: the completed run left no refetched comments in the cache: '$(printf '%s' "$cached" | head -c 200)'" ;;
        esac
        assert_ctx_has "C19$id: the refetched comment reaches context.md" "REFETCHED-AFTER-C19$id"
        assert_ctx_lacks "C19$id: a recovered run never reports a malformed cache" 'comments unavailable'
    elif [ -n "$(get_kv ASK_ID)" ] || [ "$(get_kv ACTION)" = "abort" ]; then
        pass "C19$id: $what fails controlled, naming an ask or an abort"
        if [ -f "$(ctx_file)" ]; then
            fail "C19$id: a context.md was written by a run that never rebuilt the cache: $(ctx_file)"
        else
            pass "C19$id: no partial context.md artifact from $what"
        fi
    else
        fail "C19$id: $what neither completed nor named a reason (ACTION='$(get_kv ACTION)', rc=$DRIVER_RC)"
        fail "C19$id: with no outcome to classify, the artifact check has nothing to bound"
    fi
    teardown_case
}
check_c19 a 960 '__DELETE__' 'a checkpoint whose issue_json_cache key is absent'
check_c19 b 961 'null'       'a null issue_json_cache container'
check_c19 c 962 '[]'         'an array where the issue_json_cache object belongs'

# --- C16 (secret leakage at the fetch subprocess boundary) ------------------------
# C8/C11h cover WHAT the driver does when gh fails; this covers what it must not carry
# away from the failure. gh's stderr is third-party text the driver never authored: a
# 401 body, a curl trace, a retried URL — any of which can contain the token that was
# sent. A driver that folds the subprocess's stderr into its ask message, its directive
# output, or the checkpoint publishes that credential into a session transcript and into
# a file that outlives the run. The marker is one variable, used for both the injection
# and every hunt, so the two can never drift out of agreement.
C16_MARK='ghp_FAKESECRETTOKENabc123xyz00000000000'
setup_case wid-c2063-c16
mock_issue 941 OPEN "type:task"
mock_issue_rc 941 1
mock_issue_stderr 941 "gh: HTTP 401 Bad credentials (sent Authorization: token $C16_MARK)"
set_wip 941 same
# The mock is exercised directly first: if the marker never reaches gh's stderr, every
# absence assertion below is satisfied by a payload that was never emitted.
C16_PROBE="$(gh issue view 941 --json number,title,comments 2>&1 >/dev/null || true)"
case "$C16_PROBE" in
    *"$C16_MARK"*) pass "C16: the gh mock really emits the secret on stderr (the leak probe is live)" ;;
    *) fail "C16: the gh mock emitted no marker — the leak assertions cannot fail: '$(printf '%s' "$C16_PROBE" | head -c 200)'" ;;
esac
run_driver '#941'
# The failure path must be the one the driver actually took, or the run never touched
# the subprocess stderr it is being asked not to republish.
assert_kv "C16: the failed fetch surfaces as fetch_failed_path_c" ASK_ID fetch_failed_path_c
case "$DRIVER_OUT" in
    *"$C16_MARK"*) fail "C16: the secret reached the driver's stdout" ;;
    *) pass "C16: no secret on the driver's stdout" ;;
esac
case "$DRIVER_ERR" in
    *"$C16_MARK"*) fail "C16: the secret was republished on the driver's stderr" ;;
    *) pass "C16: no secret on the driver's stderr" ;;
esac
# Asserted on the directive lines specifically: the ask QUESTION is the field most
# likely to quote the underlying error verbatim, and it travels percent-encoded, so a
# plain stdout scan can miss it.
C16_DIRECTIVE="$(printf '%s\n' "$DRIVER_OUT" | grep -E '^[A-Z_]+=' | tr '\n' ' ')"
C16_DECODED="$(node -e 'try{process.stdout.write(decodeURIComponent(process.argv[1]||""))}catch(e){process.stdout.write(process.argv[1]||"")}' "$C16_DIRECTIVE")"
case "$C16_DECODED" in
    *"$C16_MARK"*) fail "C16: the secret rode along in a directive value (decoded): '$(printf '%s' "$C16_DECODED" | head -c 200)'" ;;
    *) pass "C16: no directive value carries the secret, encoded or decoded" ;;
esac
C16_LEAK="$(grep -rlF -- "$C16_MARK" "$PLANS" 2>/dev/null | tr '\n' ' ')"
if [ -n "$C16_LEAK" ]; then
    fail "C16: the secret was written into a workflow artifact: $C16_LEAK"
else
    pass "C16: no artifact under the plans dir contains the secret"
fi
teardown_case

finish
