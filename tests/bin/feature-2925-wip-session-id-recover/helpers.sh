# Tests: bin/github-issues/wip-state.sh
# Tags: wip-state, github, projects-v2, scope:issue-specific, shared-helper
# Sourced by tests/bin/feature-2925-wip-session-id-recover{,-verbs}.sh after _lib.sh + harness.sh; not executed directly.
# Fixture + assertion helpers for the #2925 session-id field recover cases (R1-R14).
# shellcheck source=/dev/null
. "$SCRIPT_CHECKOUT_ROOT/tests/agents/feature-wip-state/abandon/mock.sh"

KEY="nirecom/agents"

# rc_prep [abandon] — fresh mock, no session-id env, strict text-field check, origin fixture CWD.
rc_prep() {
    setup_mock
    if [ "${1:-}" = "abandon" ]; then mint_abandon_mock; export GH_MOCK_STATE="OPEN"; fi
    unset ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER WIP_STATE_SESSION_ID_FIELD_ID
    export GH_MOCK_PROJECT_ITEM_ID="PVTI_existing" GH_MOCK_STRICT_TEXT_FIELD=1
    make_origin_fixture "$TMP/repo"
    CACHE="$(node "$SCRIPT_CHECKOUT_ROOT/bin/workflow-state-dir" --global)/cache/project-resolve.tsv"
    mkdir -p "$(dirname "$CACHE")"
    OUT="$TMP/out" ERR="$TMP/err"
}
# seed_cache <sid-field-id> — one valid 11-column row (schema tag sid1) for $KEY.
seed_cache() {
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$KEY" nirecom 1 PVT_resolved "" \
        PVTSSF_status OPT_todo OPT_inprog OPT_done "$1" sid1 > "$CACHE"
}
run_verb() { (cd "$TMP/repo" && run_with_timeout 60 bash "$TARGET" "$@" >"$OUT" 2>"$ERR"); RC=$?; }
n_ops() { local n; n=$(grep -c "^$1" "$GH_MOCK_FIELDS_LOG" 2>/dev/null); echo "${n:-0}"; }
item_edits() { grep -- "project item-edit" "$GH_MOCK_ARGS_LOG" 2>/dev/null; }
text_edits() { item_edits | grep -- "--text"; }
n_text() { local n; n=$(text_edits | grep -c .); echo "${n:-0}"; }
last_text_field() { text_edits | tail -1 | sed -nE 's/.*--field-id ([^ ]+).*/\1/p'; }
has_status() { item_edits | grep -q -- "--single-select-option-id $1"; }
cache_col() { awk -F'\t' -v k="$KEY" -v c="$1" '$1==k {print $c; exit}' "$CACHE" 2>/dev/null; }
cache_nf() { awk -F'\t' -v k="$KEY" '$1==k {print NF; exit}' "$CACHE" 2>/dev/null; }
# dump — compact failure context: rc, stderr head, field-model ops, item-edit lines only.
dump() {
    printf 'rc=%s err=[%s] ops=[%s] edits=[%s]' "$RC" "$(head -3 "$ERR" 2>/dev/null)" \
        "$(grep -v '^list-' "$GH_MOCK_FIELDS_LOG" 2>/dev/null)" "$(item_edits)"
}
