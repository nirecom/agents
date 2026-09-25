#!/bin/bash
# tests/feature-workflow-init-driver/driver-meta-repo-identity.sh
# Tests: bin/workflow/lib/workflow-init/phases/meta-classify.js, bin/workflow/workflow-init-driver, bin/workflow/lib/workflow-init/checkpoint.js
# Tags: workflow-init, driver, meta-classify, cross-repo, repo-map, scope:issue-specific

# M25-M29 — sub-issue REPOSITORY IDENTITY (#2087) and multi-meta-parent carry-forward,
# continuing the M series of driver-meta-classify.sh (M1-M20) and
# driver-untrusted-title.sh (M21-M24). Pattern A split: the base file is at its limit.

# TL3 gap: no live cross-repository gh sub_issues response, so `repository_url`
# shapes here are fixtures rather than whatever the real API returns. Mitigated at
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category:
# skill-orchestration.

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

MC_MOD="$AGENTS_DIR/bin/workflow/lib/workflow-init/phases/meta-classify.js"

# probe(): mirrors driver-meta-classify.sh — see that file for the base pattern.
probe() {  # <module-path> [extra argv...]; snippet on stdin → PROBE_OUT/PROBE_RC/PROBE_ERR
    local mod="$1"; shift
    cat > "$CASE_DIR/probe.js"
    PROBE_OUT="$(cd "$CASE_DIR" && node "$CASE_DIR/probe.js" "$mod" "$@" 2>"$CASE_DIR/probe.err")"
    PROBE_RC=$?
    PROBE_ERR=""
    [ -f "$CASE_DIR/probe.err" ] && PROBE_ERR="$(cat "$CASE_DIR/probe.err")"
}
assert_probe() {  # <label> <expected-exact-line>
    if printf '%s\n' "$PROBE_OUT" | grep -qxF -- "$2"; then
        pass "$1"
    else
        fail "$1: want line '$2'; got '$(printf '%s' "$PROBE_OUT" | tr '\n' ';')' (rc=$PROBE_RC err='$(printf '%s' "$PROBE_ERR" | head -c 200)')"
    fi
}
assert_probe_contains() {  # <label> <substring-of-PROBE_OUT>
    case "$PROBE_OUT" in
        *"$2"*) pass "$1" ;;
        *) fail "$1: '$2' absent from probe output '$(printf '%s' "$PROBE_OUT" | tr '\n' ';')' (rc=$PROBE_RC)" ;;
    esac
}

# --- M25: the THIRD fetchSubIssues arm — a non-integer issue number ------------------
# Classifier-verdict coverage: fetchSubIssues discriminates invalid_issue_number |
# gh_exec_failed (M17) | parse_failed (M14). This arm is unreachable from CLI input
# (detect-issues types state.issues as numbers), but readCheckpoint validates only
# `version`, so a corrupted or tampered checkpoint can put a string there. It must be
# rejected BEFORE the gh api endpoint string is built — an input the driver-level
# cases cannot express, so this one probes the phase directly.
setup_case wid-m25
probe "$MC_MOD" <<'NODE'
const { metaClassify } = require(process.argv[2]);
const bad = "370; rm -rf /";
const state = { issues: [bad], label_sets: { [bad]: ["meta"] }, path_decision: null };
let threw = "";
let r = {};
try { r = metaClassify(state) || {}; } catch (e) { threw = String((e && e.message) || e); }
console.log("threw=" + JSON.stringify(threw));
console.log("blocked=" + JSON.stringify(!!r.blocked));
console.log("reason=" + JSON.stringify(r.reason));
console.log("hint=" + String(r.nextHint));
console.log("path_decision=" + JSON.stringify(state.path_decision));
NODE
assert_probe "M25: a non-integer issue number does not throw" 'threw=""'
assert_probe "M25: a non-integer issue number blocks the session" "blocked=true"
assert_probe "M25: blocked with reason sub_issues_fetch_failed" 'reason="sub_issues_fetch_failed"'
assert_probe_contains "M25: the hint names the invalid_issue_number arm" "invalid_issue_number"
assert_probe "M25: no META verdict from an unusable issue number" "path_decision=null"
if [ -s "$GH_LOG" ]; then
    fail "M25: gh was invoked with an unvalidated issue number: $(tr '\n' ';' < "$GH_LOG")"
else
    pass "M25: rejected before any gh api endpoint was built (zero gh calls)"
fi
teardown_case

# --- M26: a sub-issue in ANOTHER repository keeps its own identity -------------------
# #N alone does not identify an issue: a cross-repo child answered by number would
# later resolve against the checkout's own origin — a different, unrelated issue that
# happens to share the number. meta_select_offered therefore carries {number,ownerRepo}
# parsed from the API's repository_url, and applyAnswer writes it into state.repo_map.
# repo_map is POSITIONAL (detect-issues.js keys it by index into the token list), so
# the single selected issue belongs at index 0.
setup_case wid-m26
mock_issue 800 OPEN "meta"
mock_issue 801 OPEN "type:task"
set_wip 801 same
mock_sub_issues 800 '[{"number":801,"title":"Child elsewhere","state":"open","repository_url":"https://api.github.com/repos/otherorg/otherrepo"}]'
run_driver '#800'
assert_kv "M26: cross-repo open child → ASK_ID=meta_select" ASK_ID meta_select
M26_CKPT="$(get_kv CHECKPOINT)" || true
assert_ckpt "M26: offered entry carries the child's OWN owner/repo" "$M26_CKPT" \
    state.meta_select_offered '[{"number":801,"ownerRepo":"otherorg/otherrepo"}]'
run_driver --resume "$M26_CKPT" --answer '#801'
assert_kv "M26: cross-repo selection completes the pipeline → ACTION=done" ACTION done
M26_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "M26: state.issues replaced with the selected cross-repo child" "$M26_CKPT2" state.issues "[801]"
assert_ckpt "M26: repo_map keyed POSITIONALLY at index 0 with the child's repo" "$M26_CKPT2" \
    state.repo_map '{"0":"otherorg/otherrepo"}'
teardown_case

# --- M27: a missing or malformed repository_url falls back to the origin repo --------
# CPR-ORTH reject arm of M26 and the edge-case column: the field is absent (#812) or
# not an api.github.com/repos/OWNER/REPO URL (#811). Neither may crash, and neither may
# produce a bad repo_map entry — the fallback is the origin repo, the only identity
# already proven valid at this point. An emptied repo_map would be a silent regression
# too, so the accept side is asserted, not just the absence of a bad value.
setup_case wid-m27
mock_issue 810 OPEN "meta"
mock_issue 811 OPEN "type:task"
mock_issue 812 OPEN "type:task"
set_wip 811 same
set_wip 812 same
mock_sub_issues 810 '[{"number":811,"title":"Malformed url","state":"open","repository_url":"https://evil.example.com/repos/attacker/repo"},{"number":812,"title":"No url at all","state":"open"}]'
run_driver '#810'
assert_kv "M27: malformed/missing repository_url still raises meta_select" ASK_ID meta_select
M27_CKPT="$(get_kv CHECKPOINT)" || true
assert_ckpt "M27: both children fall back to the origin owner/repo" "$M27_CKPT" \
    state.meta_select_offered \
    "[{\"number\":811,\"ownerRepo\":\"$CASE_ORIGIN_OWNER_REPO\"},{\"number\":812,\"ownerRepo\":\"$CASE_ORIGIN_OWNER_REPO\"}]"
run_driver --resume "$M27_CKPT" --answer '#811'
assert_kv "M27: selection on a malformed-url child completes → ACTION=done" ACTION done
M27_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "M27: repo_map falls back to origin, never cleared to {}" "$M27_CKPT2" \
    state.repo_map "{\"0\":\"$CASE_ORIGIN_OWNER_REPO\"}"
if grep -q "attacker/repo" "$GH_LOG"; then
    fail "M27: a non-api.github.com repository_url reached a gh call: $(tr '\n' ';' < "$GH_LOG")"
else
    pass "M27: the off-host repository_url never addressed anything"
fi
teardown_case

# --- M28: sibling meta parents are CARRIED FORWARD, not dropped ----------------------
# metaClassify returns on the FIRST parent with open children, and the meta_select
# answer replaces state.issues wholesale — so without meta_select_pending the other
# meta parents of the same session vanish silently. They are re-appended on answer and
# re-classified by the fetch-issues re-entry: #821 is meta and #822 is not, so the
# re-entry sees a MIXED set and strips #821 with its stderr notice. That notice is the
# proof #821 was present at meta-classify time rather than dropped at answer time.
setup_case wid-m28
mock_issue 820 OPEN "meta"
mock_issue 821 OPEN "meta"
mock_issue 822 OPEN "type:task"
set_wip 822 same
mock_sub_issues 820 '[{"number":822,"title":"Child of 820","state":"open"}]'
mock_sub_issues 821 '[]'
run_driver '#820' '#821'
assert_kv "M28: first parent with an open child raises meta_select" ASK_ID meta_select
M28_CKPT="$(get_kv CHECKPOINT)" || true
assert_ckpt "M28: the OTHER meta parent is recorded as pending" "$M28_CKPT" state.meta_select_pending "[821]"
assert_ckpt "M28: the asked parent is not listed as pending against itself" "$M28_CKPT" \
    state.meta_select_offered '[{"number":822,"ownerRepo":"'"$CASE_ORIGIN_OWNER_REPO"'"}]'
run_driver --resume "$M28_CKPT" --answer '#822'
assert_kv "M28: answering with the pending parent carried forward → ACTION=done" ACTION done
if printf '%s\n' "$DRIVER_ERR" | grep -q '#821'; then
    pass "M28: #821 reached the re-entry's meta-classify (strip notice names it)"
else
    fail "M28: #821 never reached meta-classify — carried-forward parent was dropped; stderr='$(printf '%s' "$DRIVER_ERR" | head -c 200)'"
fi
M28_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "M28: mixed re-entry strips the carried parent, keeping the selection" "$M28_CKPT2" state.issues "[822]"
assert_ckpt "M28: the pending list is spent, not replayed on the next pass" "$M28_CKPT2" state.meta_select_pending "[]"
teardown_case

# --- M29: a carried-forward parent that is STILL meta gets its own ask ---------------
# The other half of M28's re-classification claim. Here the selected child (#832) is
# itself a meta parent with an open child, so the re-entry sees an ALL-meta set again:
# #831 must survive as pending across the SECOND ask too. A carry-forward that only
# worked once would pass M28 and lose #831 here.
setup_case wid-m29
mock_issue 830 OPEN "meta"
mock_issue 831 OPEN "meta"
mock_issue 832 OPEN "meta"
mock_sub_issues 830 '[{"number":832,"title":"Meta child of 830","state":"open"}]'
mock_sub_issues 831 '[]'
mock_sub_issues 832 '[{"number":833,"title":"Grandchild","state":"open"}]'
run_driver '#830' '#831'
M29_CKPT="$(get_kv CHECKPOINT)" || true
assert_ckpt "M29: first ask records #831 as pending" "$M29_CKPT" state.meta_select_pending "[831]"
run_driver --resume "$M29_CKPT" --answer '#832'
assert_kv "M29: the still-meta selection raises a SECOND meta_select" ASK_ID meta_select
M29_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "M29: both the selection and the carried parent are in play" "$M29_CKPT2" state.issues "[832,831]"
assert_ckpt "M29: #831 is carried forward across the second ask too" "$M29_CKPT2" state.meta_select_pending "[831]"
teardown_case

# --- M30: repository_url PARSER table — accepted and rejected shapes -----------------
# M26/M27 cover one accept and two reject shapes end-to-end; the parser itself needs the
# per-shape table (skills/_shared/test-design/parser-regex-tests.md). Reject = fall back
# to the origin repo, so every row asserts a concrete ownerRepo, never merely "not the
# attacker's". The host rows matter most: this string decides which repository a later
# gh call is addressed to, so a lookalike host must not survive the prefix check.
setup_case wid-m30
mock_issue 880 OPEN "meta"
check_repo_url() {  # <row-id> <json-value|OMIT> <expected-ownerRepo>
    local id="$1" val="$2" want="$3" sub='{"number":881,"title":"Child","state":"open"'
    if [ "$val" = "OMIT" ]; then sub="$sub}"; else sub="$sub,\"repository_url\":$val}"; fi
    mock_sub_issues 880 "[$sub]"
    probe "$MC_MOD" <<'NODE'
const { metaClassify } = require(process.argv[2]);
const state = { issues: [880], label_sets: { 880: ["meta"] }, path_decision: null };
try { metaClassify(state); } catch (e) { console.log("threw=" + String((e && e.message) || e)); }
const offered = (state.meta_select_offered || [])[0] || {};
console.log("ownerRepo=" + String(offered.ownerRepo));
NODE
    assert_probe "M30$id: repository_url $val → ownerRepo $want" "ownerRepo=$want"
}
ORG="$CASE_ORIGIN_OWNER_REPO"
check_repo_url a '"https://api.github.com/repos/otherorg/otherrepo"' 'otherorg/otherrepo'
check_repo_url b '"https://api.github.com/repos/other.org_x/other-repo.js"' 'other.org_x/other-repo.js'
check_repo_url c '"https://api.github.com/repos/otherorg/otherrepo/"' 'otherorg/otherrepo'
check_repo_url d '"https://api.github.com/repos/otherorg/otherrepo/issues/5"' "$ORG"
check_repo_url e '"http://api.github.com/repos/otherorg/otherrepo"' "$ORG"
check_repo_url f '"https://api.github.com.evil.example/repos/attacker/repo"' "$ORG"
check_repo_url g '"https://api.github.com/repos/otherorg"' "$ORG"
check_repo_url h '"https://api.github.com/repos//otherrepo"' "$ORG"
check_repo_url i '"https://api.github.com/repos/../../attacker/repo"' "$ORG"
check_repo_url j '"https://api.github.com/repos/other org/other repo"' "$ORG"
check_repo_url k '12345' "$ORG"
check_repo_url l 'null' "$ORG"
check_repo_url m 'OMIT' "$ORG"
teardown_case

# --- M31: two offered children sharing a NUMBER across different repositories --------
# The ambiguity M26's design admits: the ask is answered with '#N', but #N no longer
# identifies one child once a cross-repo sibling shares the number. Pinned as current
# behavior, not as desirable — applyAnswer's .find() takes the FIRST offered match, so
# the second repo is unreachable by any answer the user can type.
setup_case wid-m31
mock_issue 960 OPEN "meta"
mock_issue 961 OPEN "type:task"
set_wip 961 same
mock_sub_issues 960 '[{"number":961,"title":"A here","state":"open","repository_url":"https://api.github.com/repos/alpha/one"},{"number":961,"title":"B there","state":"open","repository_url":"https://api.github.com/repos/beta/two"}]'
run_driver '#960'
assert_kv "M31: duplicate-numbered children still raise meta_select" ASK_ID meta_select
M31_CKPT="$(get_kv CHECKPOINT)" || true
assert_ckpt "M31: both same-numbered children are offered, each with its own repo" "$M31_CKPT" \
    state.meta_select_offered '[{"number":961,"ownerRepo":"alpha/one"},{"number":961,"ownerRepo":"beta/two"}]'
M31_OPTS="$(get_kv OPTIONS_DISPLAY)" || true
if [ "$(opts_field_count "$M31_OPTS")" = "3" ]; then
    pass "M31: the ask offers both children plus abort (no silent de-duplication)"
else
    fail "M31: expected 3 option fields, got $(opts_field_count "$M31_OPTS"): '$(pct_decode "$M31_OPTS")'"
fi
run_driver --resume "$M31_CKPT" --answer '#961'
assert_kv "M31: an ambiguous answer is accepted, not rejected → ACTION=done" ACTION done
M31_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "M31: the FIRST offered match wins; the beta/two child is unreachable" "$M31_CKPT2" \
    state.repo_map '{"0":"alpha/one"}'
teardown_case

# --- M32: a foreign child's identity SURVIVES the meta re-entry ----------------------
# M26 proves repo_map is written; the risk is the rebuild that follows. Answering with a
# still-meta foreign child re-enters fetch-issues and re-runs meta-classify (M29), which
# rewrites state.issues — repo_map must not be reset to the checkout's own origin there,
# or the second ask would be answered against a same-numbered local issue.
setup_case wid-m32
mock_issue 970 OPEN "meta"
mock_issue 971 OPEN "meta"
mock_issue 972 OPEN "meta"
mock_sub_issues 970 '[{"number":972,"title":"Foreign meta child","state":"open","repository_url":"https://api.github.com/repos/foreign/repo"}]'
mock_sub_issues 971 '[]'
mock_sub_issues 972 '[{"number":973,"title":"Grandchild","state":"open"}]'
run_driver '#970' '#971'
M32_CKPT="$(get_kv CHECKPOINT)" || true
assert_ckpt "M32: the foreign child is offered under its own repository" "$M32_CKPT" \
    state.meta_select_offered '[{"number":972,"ownerRepo":"foreign/repo"}]'
run_driver --resume "$M32_CKPT" --answer '#972'
assert_kv "M32: the still-meta foreign child raises a second meta_select" ASK_ID meta_select
M32_CKPT2="$(get_kv CHECKPOINT)" || true
assert_ckpt "M32: repo_map still names the ORIGINAL foreign repo after the re-entry" \
    "$M32_CKPT2" state.repo_map '{"0":"foreign/repo"}'
assert_ckpt "M32: the carried-forward sibling survives the cross-repo hop" "$M32_CKPT2" \
    state.meta_select_pending "[971]"
teardown_case

finish
