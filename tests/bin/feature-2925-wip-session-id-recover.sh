#!/bin/bash
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/field-recover.sh, bin/github-issues/lib/session-id-field.sh, bin/github-issues/lib/resolve-project.sh
# Tags: wip-state, github, projects-v2, scope:issue-specific, static
# #2925 R1-R7, R14-R15 (`set`): the session-id field is recovered by set only (rename legacy, else
# create); a stale cached field id is re-resolved and retried once. check/clear/abandon: -verbs.sh.
# G5-*: static call-site contract (who may recover / rename / create; retired identifiers gone).
# Mocks: tests/agents/feature-wip-state/setup.sh (gh) + tests/lib/gh-projectv2-fields-mock.sh
# (field model; GH_MOCK_STRICT_TEXT_FIELD=1 makes a --text edit on an unknown field fail).
# TL3 gap: a live board's rename/create permissions, latency and consistency are not mocked.
#   Closest-to-action: before merge, `wip-state set <N>` on a scratch board with only the legacy
#   session-fingerprint field; confirm it is renamed to session-id and written.

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

# r2_body <pages> — legacy session-fingerprint only: renamed in place, written, never created.
r2_body() {
    rc_prep; export GH_MOCK_SID_FIELD=legacy GH_MOCK_FIELD_PAGES="$1"
    run_verb set 42
    if [ "$RC" -eq 0 ] && [ "$(n_ops rename)" -eq 1 ] && grep -q "^rename fieldId=PVTF_legacy" "$GH_MOCK_FIELDS_LOG" \
       && [ "$(n_ops create)" -eq 0 ] && [ "$(last_text_field)" = "PVTF_legacy" ]; then
        pass "R2(pages=$1): legacy field renamed, written, no create"
    else fail "R2(pages=$1)" "$(dump)"; fi
    teardown_mock
}
# r4_body <create-denied|list-fails> — recover fails → rc 1, error + /issue-setup Hint, no Status write.
r4_body() {
    rc_prep; export GH_MOCK_SID_FIELD=absent
    if [ "$1" = "create-denied" ]; then export GH_MOCK_FAIL=create-field; else export GH_MOCK_FIELD_LIST_FAIL=paged; fi
    run_verb set 42
    local rest creates; rest="$(sed 's#/issue-setup##g' "$ERR")"; creates="$(n_ops create)"
    if [ "$RC" -eq 1 ] && grep -q "session-id field unavailable for this project" "$ERR" \
       && grep -q "Hint:.*/issue-setup" "$ERR" && ! printf '%s' "$rest" | grep -qw "setup" \
       && ! has_status OPT_inprog && { [ "$1" = "create-denied" ] || [ "$creates" -eq 0 ]; }; then
        pass "R4($1): rc=1, error + /issue-setup Hint, no Status write"
    else fail "R4($1)" "$(dump)"; fi
    teardown_mock
}
# r5_body <rw|ro> — cached id points at a deleted field: re-resolve, recover, exactly one retry.
r5_body() {
    rc_prep; export GH_MOCK_SID_FIELD=absent
    seed_cache PVTF_gone
    if [ "$1" = "ro" ]; then
        chmod 444 "$CACHE"; chmod 555 "$(dirname "$CACHE")"
        if [ -w "$CACHE" ] || [ -w "$(dirname "$CACHE")" ]; then
            chmod 755 "$(dirname "$CACHE")"; chmod 644 "$CACHE"
            skip "R5(ro): chmod does not make the cache read-only on this host"; teardown_mock; return 0
        fi
    fi
    run_verb set 42
    chmod 755 "$(dirname "$CACHE")" 2>/dev/null; chmod 644 "$CACHE" 2>/dev/null
    if [ "$RC" -eq 0 ] && [ "$(n_text)" -eq 2 ] && [ "$(last_text_field)" = "PVTF_sid_new" ] \
       && [ "$(n_ops create)" -eq 1 ] && has_status OPT_inprog \
       && { [ "$1" = "ro" ] || [ "$(cache_col 10)" = "PVTF_sid_new" ]; }; then
        pass "R5($1): stale id → 2 --text edits, retry hits the recovered id, exit 0"
    else fail "R5($1)" "$(dump) cache=[$(cat "$CACHE" 2>/dev/null)]"; fi
    teardown_mock
}
# r6_body <exists|query-fails> — write fails but the field exists / existence query fails: no retry.
r6_body() {
    rc_prep; export GH_MOCK_SID_FIELD=present GH_MOCK_FAIL=item-edit-sid-once
    seed_cache PVTF_fp
    if [ "$1" = "query-fails" ]; then export GH_MOCK_FIELD_LIST_FAIL=all; fi
    run_verb set 42
    if [ "$RC" -eq 1 ] && [ "$(n_text)" -eq 1 ] && [ "$(n_ops create)" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ] \
       && ! has_status OPT_inprog; then
        pass "R6($1): exactly 1 --text edit, no recover, no Status write, rc=1"
    else fail "R6($1)" "$(dump)"; fi
    teardown_mock
}

case_begin "set-absent-field-creates-and-caches" "bin/github-issues/wip-state/field-recover.sh"
rc_prep; export GH_MOCK_SID_FIELD=absent
run_verb set 42
if [ "$RC" -eq 0 ] && [ "$(n_ops create)" -eq 1 ] && [ "$(n_ops rename)" -eq 0 ] \
   && [ "$(last_text_field)" = "PVTF_sid_new" ] && text_edits | grep -q -- "--text test-sid-fixture" \
   && has_status OPT_inprog && [ "$(cache_col 10)" = "PVTF_sid_new" ] && [ "$(cache_nf)" = "11" ] \
   && [ "$(cache_col 11)" = "sid1" ]; then
    pass "R1: absent → create once, --text to PVTF_sid_new, 11-col cache row"
else fail "R1" "$(dump) cache=[$(cat "$CACHE" 2>/dev/null)]"; fi
teardown_mock
case_end

case_begin "set-legacy-field-renamed-single-page" "bin/github-issues/wip-state/field-recover.sh"
r2_body 1
case_end

case_begin "set-legacy-field-renamed-second-page" "bin/github-issues/lib/session-id-field.sh"
r2_body 2
case_end

case_begin "set-both-fields-uses-session-id" "bin/github-issues/wip-state/field-recover.sh"
rc_prep; export GH_MOCK_SID_FIELD=both
run_verb set 42
if [ "$RC" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ] && [ "$(n_ops create)" -eq 0 ] \
   && [ "$(last_text_field)" = "PVTF_fp" ]; then
    pass "R3: both present → session-id (PVTF_fp) used, legacy untouched"
else fail "R3" "$(dump)"; fi
teardown_mock
case_end

case_begin "set-legacy-rename-fails-exits-1-no-writes" "bin/github-issues/wip-state/field-recover.sh"
rc_prep; export GH_MOCK_SID_FIELD=legacy GH_MOCK_FAIL=rename-field
run_verb set 42
if [ "$RC" -eq 1 ] && [ "$(n_ops rename)" -eq 1 ] && [ "$(n_ops create)" -eq 0 ] \
   && [ "$(n_text)" -eq 0 ] && ! has_status OPT_inprog; then
    pass "R2-fail: rename denied → rc=1, no create, no session-id write, no Status update"
else fail "R2-fail" "$(dump)"; fi
teardown_mock
case_end

case_begin "set-twice-creates-field-once" "bin/github-issues/wip-state/field-recover.sh"
rc_prep; export GH_MOCK_SID_FIELD=absent
run_verb set 42; RC1=$RC
rm -f "$CACHE"
run_verb set 42
if [ "$RC1" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$(n_ops create)" -eq 1 ] && [ "$(n_ops rename)" -eq 0 ] \
   && [ "$(n_text)" -eq 2 ] && [ "$(last_text_field)" = "PVTF_sid_new" ]; then
    pass "R1-idem: set twice (cache dropped between) → field created exactly once, both writes hit it"
else fail "R1-idem" "rc1=$RC1 $(dump)"; fi
teardown_mock
case_end

case_begin "set-create-denied-exits-1-with-hint" "bin/github-issues/wip-state.sh"
r4_body create-denied
case_end

case_begin "set-field-list-fails-no-blind-create" "bin/github-issues/lib/session-id-field.sh"
r4_body list-fails
case_end

case_begin "set-stale-cached-id-recovers-and-retries" "bin/github-issues/wip-state.sh"
r5_body rw
case_end

case_begin "set-stale-cached-id-read-only-cache" "bin/github-issues/lib/resolve-project.sh"
r5_body ro
case_end

case_begin "set-write-fails-field-exists-no-retry" "bin/github-issues/wip-state.sh"
r6_body exists
case_end

case_begin "set-write-fails-existence-query-fails" "bin/github-issues/lib/session-id-field.sh"
r6_body query-fails
case_end

case_begin "set-valid-cache-no-field-queries" "bin/github-issues/lib/resolve-project.sh"
rc_prep; export GH_MOCK_SID_FIELD=present
seed_cache PVTF_fp
run_verb set 42
if [ "$RC" -eq 0 ] && [ ! -s "$GH_MOCK_FIELDS_LOG" ] && [ "$(n_text)" -eq 1 ] && [ "$(last_text_field)" = "PVTF_fp" ]; then
    pass "R7: cached 11-col row → zero field-model calls, one write to PVTF_fp"
else fail "R7" "$(dump)"; fi
teardown_mock
case_end

case_begin "retired-fingerprint-env-name-ignored" "bin/github-issues/wip-state.sh"
rc_prep; export GH_MOCK_SID_FIELD=present WIP_STATE_FINGERPRINT_FIELD_ID="PVTF_legacy_env"
run_verb set 42
if [ "$RC" -eq 0 ] && [ "$(last_text_field)" = "PVTF_fp" ] && ! grep -q "PVTF_legacy_env" "$GH_MOCK_ARGS_LOG"; then
    pass "R14: retired env name never read; resolver id PVTF_fp used"
else fail "R14" "$(dump)"; fi
unset WIP_STATE_FINGERPRINT_FIELD_ID
teardown_mock
case_end

# R15: WIP_STATE_SESSION_ID_FIELD_ID differs from the resolver id (PVTF_fp). Normal path: the env
# value is the write target. Failure path: the field is judged missing, the re-resolve replaces the
# env value with RESOLVED_SESSION_ID_FIELD_ID, and the single retry hits PVTF_fp (detail Step 4).
first_text_field() { text_edits | head -1 | sed -nE 's/.*--field-id ([^ ]+).*/\1/p'; }

case_begin "session-id-env-override-is-write-target" "bin/github-issues/wip-state.sh"
rc_prep; unset GH_MOCK_STRICT_TEXT_FIELD
export GH_MOCK_SID_FIELD=present WIP_STATE_SESSION_ID_FIELD_ID="PVTF_env_override"
run_verb set 42
if [ "$RC" -eq 0 ] && [ "$(n_text)" -eq 1 ] && [ "$(last_text_field)" = "PVTF_env_override" ] \
   && [ "$(n_ops create)" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ] && has_status OPT_inprog; then
    pass "R15(normal): env WIP_STATE_SESSION_ID_FIELD_ID wins over the resolver id"
else fail "R15(normal)" "$(dump)"; fi
unset WIP_STATE_SESSION_ID_FIELD_ID
teardown_mock
case_end

case_begin "session-id-env-override-stale-reresolve-wins" "bin/github-issues/wip-state/field-recover.sh"
rc_prep; export GH_MOCK_SID_FIELD=present WIP_STATE_SESSION_ID_FIELD_ID="PVTF_env_stale"
run_verb set 42
if [ "$RC" -eq 0 ] && [ "$(n_text)" -eq 2 ] && [ "$(first_text_field)" = "PVTF_env_stale" ] \
   && [ "$(last_text_field)" = "PVTF_fp" ] && [ "$(n_ops create)" -eq 0 ] && [ "$(n_ops rename)" -eq 0 ] \
   && has_status OPT_inprog; then
    pass "R15(stale): env id write fails → re-resolve ignores env, retry hits PVTF_fp"
else fail "R15(stale)" "$(dump)"; fi
unset WIP_STATE_SESSION_ID_FIELD_ID
teardown_mock
case_end

# ---------------------------------------------------------------------------
# G5 static contract (text-only by design: the contract is about call sites in source).
# ---------------------------------------------------------------------------
R="$SCRIPT_CHECKOUT_ROOT"
GI="bin/github-issues"
REC="$GI/wip-state/field-recover.sh"
SIF="$GI/lib/session-id-field.sh"

# prod_hits <ERE> — "path:line:text" hits in production code (bin/, skills/ scripts), comments excluded.
prod_hits() {
    (cd "$R" && grep -rnE --include='*.sh' --include='*.js' --include='*.py' -- "$1" bin skills 2>/dev/null) \
        | grep -vE '^[^:]+:[0-9]+:[[:space:]]*#'
}
# files_of — unique paths from prod_hits output on stdin.
files_of() { cut -d: -f1 | sort -u; }
# outside <allowed-path>... — paths on stdin not in the allowed list.
outside() {
    local f a ok
    while IFS= read -r f; do
        ok=0
        for a in "$@"; do [ "$f" = "$a" ] && ok=1; done
        [ "$ok" -eq 1 ] || printf '%s\n' "$f"
    done
}

case_begin "recover-called-only-from-cmd-set" "bin/github-issues/wip-state/field-recover.sh"
DEF="$(prod_hits 'wip_recover_session_id_field[[:space:]]*\(\)' | files_of)"
CALLERS="$(prod_hits '(^|[^_[:alnum:]])wip_recover_session_id_field([^_[:alnum:](]|$)' | grep -v '()' | files_of)"
BAD="$(printf '%s\n' "$CALLERS" | grep . | outside "$GI/wip-state/cmd-set.sh")"
if [ "$DEF" = "$REC" ] && printf '%s\n' "$CALLERS" | grep -qx "$GI/wip-state/cmd-set.sh" && [ -z "$BAD" ]; then
    pass "G5-1a: wip_recover_session_id_field defined in field-recover.sh, called only from cmd-set.sh"
else fail "G5-1a" "def=[$DEF] callers=[$CALLERS] outside=[$BAD]"; fi
case_end

case_begin "rename-helper-called-only-inside-recover" "bin/github-issues/wip-state/field-recover.sh"
CALLS="$(prod_hits '_wip_rename_legacy_session_field' | grep -v '_wip_rename_legacy_session_field[[:space:]]*()')"
BADF="$(printf '%s\n' "$CALLS" | grep . | files_of | outside "$REC")"
# Inside field-recover.sh every call must sit in the wip_recover_session_id_field body.
INSIDE_BAD="$(awk '/^wip_recover_session_id_field[[:space:]]*\(\)/{inb=1; next} /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/{inb=0} /^[[:space:]]*#/{next} /_wip_rename_legacy_session_field/ && !/_wip_rename_legacy_session_field[[:space:]]*\(\)/ && !inb {print NR}' "$R/$REC" 2>/dev/null)"
if [ -f "$R/$REC" ] && [ -n "$CALLS" ] && [ -z "$BADF" ] && [ -z "$INSIDE_BAD" ]; then
    pass "G5-1b: _wip_rename_legacy_session_field called only inside wip_recover_session_id_field"
else fail "G5-1b" "file=$([ -f "$R/$REC" ] && echo present || echo missing) outside-files=[$BADF] outside-lines=[$INSIDE_BAD]"; fi
case_end

case_begin "rename-mutation-and-legacy-name-confined" "bin/github-issues/lib/session-id-field.sh"
# The rename form is updateProjectV2Field carrying `name:` (EPR's Status-options update has none).
RENAME_F="$(prod_hits 'updateProjectV2Field\([^)]*name:' | files_of)"
HAS_RENAME="$(cd "$R" && grep -l 'updateProjectV2Field' "$REC" "$SIF" 2>/dev/null)"
LEGACY_F="$(prod_hits 'LEGACY_SESSION_FIELD_NAME' | files_of)"
BAD1="$(printf '%s\n' "$RENAME_F" | grep . | outside "$REC" "$SIF")"
BAD2="$(printf '%s\n' "$LEGACY_F" | grep . | outside "$REC" "$SIF")"
EPR_RP="$(printf '%s\n%s\n' "$RENAME_F" "$LEGACY_F" | grep -E '(ensure-project-ready|resolve-project)\.sh$')"
if [ -n "$HAS_RENAME" ] && [ -n "$LEGACY_F" ] && [ -z "$BAD1" ] && [ -z "$BAD2" ] && [ -z "$EPR_RP" ]; then
    pass "G5-2: updateProjectV2Field + LEGACY_SESSION_FIELD_NAME only in field-recover.sh / session-id-field.sh"
else fail "G5-2" "rename=[$RENAME_F] legacy=[$LEGACY_F] outside=[$BAD1|$BAD2]"; fi
case_end

case_begin "create-if-absent-callers-confined" "bin/github-issues/lib/session-id-field.sh"
DEF="$(prod_hits 'session_id_field_create_if_absent[[:space:]]*\(\)' | files_of)"
CALLERS="$(prod_hits 'session_id_field_create_if_absent' | grep -v 'session_id_field_create_if_absent[[:space:]]*()' | files_of)"
BAD="$(printf '%s\n' "$CALLERS" | grep . | outside "$GI/lib/ensure-project-ready.sh" "$REC")"
if [ "$DEF" = "$SIF" ] && [ -n "$CALLERS" ] && [ -z "$BAD" ]; then
    pass "G5-3: session_id_field_create_if_absent called only from lib/ensure-project-ready.sh / field-recover.sh"
else fail "G5-3" "def=[$DEF] callers=[$CALLERS] outside=[$BAD]"; fi
case_end

case_begin "field-name-literals-only-in-session-id-field" "bin/github-issues/lib/session-id-field.sh"
LIT_F="$(prod_hits 'session-fingerprint|name == "session-id"|name=session-id' | files_of)"
BAD="$(printf '%s\n' "$LIT_F" | grep . | outside "$SIF")"
if [ -f "$R/$SIF" ] && printf '%s\n' "$LIT_F" | grep -qx "$SIF" && [ -z "$BAD" ]; then
    pass "G5-4: field-name literals live only in session-id-field.sh"
else fail "G5-4" "files=[$LIT_F] outside=[$BAD]"; fi
case_end

# SESSION_HASH is not listed: #2925 changes its value to the raw sid, not its name; the reopen
# raw-sid contract lives in tests/bin/fix-1591-forge-write-scan.sh (reopen-session-*).
case_begin "retired-fingerprint-identifiers-gone" "bin/github-issues/lib/session-id-field.sh"
RETIRED="$(prod_hits 'compute_fingerprint|WIP_STATE_FINGERPRINT_FIELD_ID|RESOLVED_FINGERPRINT_FIELD_ID|EPR_FINGERPRINT_FIELD_ID')"
if [ -z "$RETIRED" ]; then
    pass "G5-5: no retired fingerprint identifier remains in bin/ or skills/"
else fail "G5-5" "hits=[$(printf '%s\n' "$RETIRED" | head -10)]"; fi
case_end

wip_finish
