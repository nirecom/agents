#!/bin/bash
# tests/feature-1340-issue-setup/wip-state-migration.sh
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/cmd-set.sh, bin/github-issues/wip-state/cmd-check.sh, bin/github-issues/wip-state/cmd-clear.sh
# Tags: issue-setup, wip-state, github-issues, scope:issue-specific
# N/A (C6): adversarial .env WIP_STATE_* values — .env is trusted user config and this path is being DEPRECATED by the migration block; not an attacker surface.
#
# Tests for wip-state.sh temporary-migration block and ensure_wip_field_ids (step 4 of #1340).
# L2: .env WIP_STATE_* + resolver rc=1 → deprecation warn + ALL values preserved exactly;
#     empty .env + resolver → each WIP_STATE_* (status/in-progress/done/fingerprint) = exact
#     resolver ID, across set/check/clear verbs; env value + different resolver → .env wins
#     for every field (precedence); resolver rc=1 + .env set → preflight passes.
#
# L3 gap (what this test does NOT catch):
# - Whether wip-state.sh set/check/clear actually interact with a live GitHub Projects API.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / AGENTS_DIR provided by _lib.sh.
TARGET_WIP="$AGENTS_DIR/bin/github-issues/wip-state.sh"
TARGET_RESOLVE="$AGENTS_DIR/bin/github-issues/lib/resolve-project.sh"
export TARGET_WIP TARGET_RESOLVE

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"

    # Mock gh for wip-state interactions
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*)
    # cmd_clear's state guard: only proceeds to field mutations on a CLOSED
    # issue. Return CLOSED so the clear verb reaches the item-edit step.
    echo "${GH_MOCK_ISSUE_STATE:-CLOSED}"
    exit 0
    ;;
  issue\ view\ *)
    # cmd_set item-add path resolves the issue URL.
    echo "https://github.com/nirecom/agents/issues/999"
    exit 0
    ;;
  repo\ view\ *--json\ owner,name*)
    if [ "${GH_MOCK_REPO_FAIL:-0}" = "1" ]; then
        echo "error: not a github repo" >&2; exit 1
    fi
    echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"
    exit 0
    ;;
  auth\ status*)
    echo "Logged in to github.com as testuser"
    echo "Token scopes: 'repo', 'project'"
    exit 0
    ;;
  api\ graphql\ *projectsV2*)
    if [ "${GH_MOCK_RESOLVER_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2; exit 1
    fi
    PROJ_OWNER="${GH_MOCK_PROJECT_OWNER:-nirecom}"
    PROJ_NUM="${GH_MOCK_PROJECT_NUM:-1}"
    PROJ_ID="${GH_MOCK_PROJECT_ID:-PVT_mock123}"
    case "$ARGS" in
      *"length == 0 then empty"*|*"{id, number, ownerLogin"*)
        printf '{"id":"%s","number":%s,"ownerLogin":"%s"}\n' "$PROJ_ID" "$PROJ_NUM" "$PROJ_OWNER"
        exit 0
        ;;
      *"| length"*)
        echo "1"; exit 0
        ;;
      *)
        echo "1"; exit 0
        ;;
    esac
    ;;
  api\ graphql\ *projectItems*)
    # Item-id resolution for a given issue → return a fixed item id so the verb
    # reaches the field-referencing gh calls that expose WIP_STATE_* values.
    echo "ITEM_mock_1"; exit 0
    ;;
  api\ graphql\ *fieldValues*)
    # `check` read query — makes TWO fieldValues queries against one item:
    #   1. Status read  → --jq extracts `.name` (filtered by WIP_STATE_STATUS_FIELD_ID)
    #   2. Fingerprint  → --jq extracts `.text` (filtered by WIP_STATE_FINGERPRINT_FIELD_ID)
    # cmd-check exits early ("none") unless the Status read returns "In Progress",
    # so the mock must return "In Progress" for the status read (the query whose
    # --jq extracts `.name`) to let the verb proceed to the fingerprint read.
    # The real gh emits the --jq-filtered scalar, so the mock emits it too.
    case "$ARGS" in
      *"| .name]"*) echo "In Progress"; exit 0 ;;
      *"| .text]"*) echo "${GH_MOCK_CHECK_FINGERPRINT_TEXT:-fp-value}"; exit 0 ;;
      *)            printf '{"data":{"node":{"fieldValues":{"nodes":[]}}}}\n'; exit 0 ;;
    esac
    ;;
  api\ graphql\ *fields*|api\ graphql\ *Content\ Date*|api\ graphql\ *projectId*|api\ graphql\ *Status*|api\ graphql\ *session-fingerprint*)
    if [ "${GH_MOCK_RESOLVER_FAIL:-0}" = "1" ]; then
        echo "error: graphql failed" >&2; exit 1
    fi
    # Distinct known IDs per field/option so tests can assert exact WIP_STATE_* values.
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*) echo ""; exit 0 ;;
      *'"In Progress")'*) echo "${GH_MOCK_RESOLVED_INPROG:-RES_INPROG}"; exit 0 ;;
      *'"Todo")'*)        echo "${GH_MOCK_RESOLVED_TODO:-RES_TODO}"; exit 0 ;;
      *'"Done")'*)        echo "${GH_MOCK_RESOLVED_DONE:-RES_DONE}"; exit 0 ;;
      *'"Status")'*|*'== "Status"'*) echo "${GH_MOCK_RESOLVED_STATUS:-RES_STATUS}"; exit 0 ;;
      *'session-fingerprint'*) echo "${GH_MOCK_RESOLVED_FINGER:-RES_FINGER}"; exit 0 ;;
      *"Content Date"*) echo "${GH_MOCK_CONTENT_DATE_FIELD_ID-PVTF_content}"; exit 0 ;;
      *)
        echo "${GH_MOCK_RESOLVED_STATUS:-RES_STATUS}"; exit 0
        ;;
    esac
    ;;
  project\ item-edit*)
    exit 0
    ;;
  project\ item-list*)
    printf '{"items":[]}\n'; exit 0
    ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2; exit 0
    ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"

    # Create a minimal mock env-os-filter (just passes through)
    mkdir -p "$TMP/bin"
    cat > "$TMP/bin/env-os-filter" <<'FILTER_EOF'
#!/bin/bash
cat "$1" 2>/dev/null || true
FILTER_EOF
    chmod +x "$TMP/bin/env-os-filter"

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
    mkdir -p "$TMP/plans"
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR"
    # Create empty .env so load_env_file doesn't fail
    touch "$AGENTS_CONFIG_DIR/.env"
    cp "$TMP/bin/env-os-filter" "$AGENTS_CONFIG_DIR/bin/env-os-filter" 2>/dev/null || \
        mkdir -p "$AGENTS_CONFIG_DIR/bin" && cp "$TMP/bin/env-os-filter" "$AGENTS_CONFIG_DIR/bin/env-os-filter"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR AGENTS_CONFIG_DIR \
          GH_MOCK_OWNER_REPO GH_MOCK_RESOLVER_FAIL GH_MOCK_REPO_FAIL \
          GH_MOCK_ISSUE_STATE \
          GH_MOCK_PROJECT_OWNER GH_MOCK_PROJECT_NUM GH_MOCK_PROJECT_ID \
          GH_MOCK_RESOLVED_STATUS GH_MOCK_RESOLVED_TODO GH_MOCK_RESOLVED_INPROG \
          GH_MOCK_RESOLVED_DONE GH_MOCK_RESOLVED_FINGER GH_MOCK_CONTENT_DATE_FIELD_ID \
          GH_MOCK_CHECK_FINGERPRINT_TEXT \
          WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
          WIP_STATE_DONE_OPTION_ID WIP_STATE_FINGERPRINT_FIELD_ID \
          WIP_STATE_TODO_OPTION_ID 2>/dev/null || true
}

# Run a wip-state verb as a real subprocess. The WIP_STATE_* field IDs that
# ensure_wip_field_ids populated (from .env or resolver) are exposed as
# arguments to the downstream `gh project item-edit` / `gh api graphql`
# (check) calls, which the gh mock records to MOCK_LOG. Assertions then grep
# MOCK_LOG for the EXACT id values. This avoids the source-then-exit problem
# (the verb dispatcher calls `exit`, which would kill an inline printf).
# Captures the verb's real exit code in WIP_RC (do NOT swallow it — a test
# that asserts success must check WIP_RC, so an early unrelated failure cannot
# pass vacuously).
run_wip_verb() {
    local verb="$1" stderr_file="${2:-/dev/null}"
    WIP_RC=0
    bash "$TARGET_WIP" "$verb" 999 >/dev/null 2>"$stderr_file" || WIP_RC=$?
}

# Assert that an exact id value reached a gh call (proves ensure_wip_field_ids
# populated the corresponding WIP_STATE_* var with that value).
id_in_log() { grep -Fq -- "$1" "$MOCK_LOG" 2>/dev/null; }
# Did a downstream field-referencing gh call actually run? (positive evidence
# that the verb progressed past preflight into the item read/write step).
item_call_made() { grep -qE "project item-edit|fieldValues|item-add" "$MOCK_LOG" 2>/dev/null; }

# ===========================================================================
# TWM-1: .env WIP_STATE_* present → the temporary-migration block emits a
# deprecation warning on stderr (regardless of resolver state). RED now: the
# migration block is not yet implemented, so no deprecation warning is emitted.
# (Exact-value passthrough with resolver rc=1 is covered by TWM-4: when the
# resolver fails, item-edit is unreachable, so the .env values are instead
# observed via preflight_field_ids passing.)
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=1
cat > "$AGENTS_CONFIG_DIR/.env" <<'ENV_EOF'
WIP_STATE_STATUS_FIELD_ID=env-status-id
WIP_STATE_IN_PROGRESS_OPTION_ID=env-inprog-id
WIP_STATE_DONE_OPTION_ID=env-done-id
WIP_STATE_FINGERPRINT_FIELD_ID=env-finger-id
ENV_EOF
STDERR_FILE="$TMP/twm1-stderr.log"
run_wip_verb check "$STDERR_FILE"
STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null)
HAS_DEPRECATION_WARN=0
echo "$STDERR_CONTENT" | grep -qiE "deprecat|非推奨" && HAS_DEPRECATION_WARN=1
if [ "$HAS_DEPRECATION_WARN" = "1" ]; then
    pass "TWM-1: .env WIP_STATE_* present → deprecation warning emitted on stderr"
else
    fail "TWM-1: warn=$HAS_DEPRECATION_WARN (expected RED — temporary-migration deprecation warning not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TWM-2 (set): empty .env + resolver returns known distinct IDs → status +
# in-progress + fingerprint each reach the gh calls with their EXACT resolver
# value (proves ensure_wip_field_ids populated them before preflight).
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
export GH_MOCK_RESOLVED_STATUS="RES_STATUS_V"
export GH_MOCK_RESOLVED_INPROG="RES_INPROG_V"
export GH_MOCK_RESOLVED_FINGER="RES_FINGER_V"
: > "$AGENTS_CONFIG_DIR/.env"
STDERR_FILE="$TMP/twm2-stderr.log"
run_wip_verb set "$STDERR_FILE"
S_OK=0; id_in_log "RES_STATUS_V" && S_OK=1
I_OK=0; id_in_log "RES_INPROG_V" && I_OK=1
F_OK=0; id_in_log "RES_FINGER_V" && F_OK=1
ITEM=0; item_call_made && ITEM=1
if [ "$WIP_RC" = "0" ] && [ "$ITEM" = "1" ] && [ "$S_OK" = "1" ] && [ "$I_OK" = "1" ] && [ "$F_OK" = "1" ]; then
    pass "TWM-2 (set): rc=0 + item call reached + status+inprog+fingerprint = exact resolver IDs"
else
    fail "TWM-2 (set): rc=$WIP_RC item=$ITEM status=$S_OK inprog=$I_OK finger=$F_OK (expected RED — ensure_wip_field_ids not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TWM-2c (check): check consumes status + fingerprint. Both must reach the
# read query with their exact resolver value.
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
export GH_MOCK_RESOLVED_STATUS="RES_STATUS_C"
export GH_MOCK_RESOLVED_FINGER="RES_FINGER_C"
: > "$AGENTS_CONFIG_DIR/.env"
STDERR_FILE="$TMP/twm2c-stderr.log"
run_wip_verb check "$STDERR_FILE"
S_OK=0; id_in_log "RES_STATUS_C" && S_OK=1
F_OK=0; id_in_log "RES_FINGER_C" && F_OK=1
ITEM=0; item_call_made && ITEM=1
# check returns 0 (same) / 0 with state printed — exit code 0 on success path.
if [ "$WIP_RC" = "0" ] && [ "$ITEM" = "1" ] && [ "$S_OK" = "1" ] && [ "$F_OK" = "1" ]; then
    pass "TWM-2c (check): rc=0 + read query reached + status+fingerprint = exact resolver IDs"
else
    fail "TWM-2c (check): rc=$WIP_RC item=$ITEM status=$S_OK finger=$F_OK (expected RED — ensure_wip_field_ids not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TWM-2d (clear): clear consumes status + done + fingerprint. All three must
# reach the gh calls with their exact resolver value.
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
export GH_MOCK_RESOLVED_STATUS="RES_STATUS_D"
export GH_MOCK_RESOLVED_DONE="RES_DONE_D"
export GH_MOCK_RESOLVED_FINGER="RES_FINGER_D"
: > "$AGENTS_CONFIG_DIR/.env"
STDERR_FILE="$TMP/twm2d-stderr.log"
run_wip_verb clear "$STDERR_FILE"
S_OK=0; id_in_log "RES_STATUS_D" && S_OK=1
D_OK=0; id_in_log "RES_DONE_D"   && D_OK=1
F_OK=0; id_in_log "RES_FINGER_D" && F_OK=1
ITEM=0; item_call_made && ITEM=1
if [ "$WIP_RC" = "0" ] && [ "$ITEM" = "1" ] && [ "$S_OK" = "1" ] && [ "$D_OK" = "1" ] && [ "$F_OK" = "1" ]; then
    pass "TWM-2d (clear): rc=0 + item call reached + status+done+fingerprint = exact resolver IDs"
else
    fail "TWM-2d (clear): rc=$WIP_RC item=$ITEM status=$S_OK done=$D_OK finger=$F_OK (expected RED — ensure_wip_field_ids not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TWM-3: .env value set + DIFFERENT resolver value → .env value wins for every
# field (migration precedence: resolver never overwrites a non-empty env value).
# Assert the ENV_* ids reach gh AND the RESOLVER_* ids do NOT.
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
export GH_MOCK_RESOLVED_STATUS="RESOLVER_STATUS"
export GH_MOCK_RESOLVED_INPROG="RESOLVER_INPROG"
export GH_MOCK_RESOLVED_FINGER="RESOLVER_FINGER"
cat > "$AGENTS_CONFIG_DIR/.env" <<'ENV_EOF'
WIP_STATE_STATUS_FIELD_ID=ENV_STATUS_WINS
WIP_STATE_IN_PROGRESS_OPTION_ID=ENV_INPROG_WINS
WIP_STATE_DONE_OPTION_ID=ENV_DONE_WINS
WIP_STATE_FINGERPRINT_FIELD_ID=ENV_FINGER_WINS
ENV_EOF
STDERR_FILE="$TMP/twm3-stderr.log"
run_wip_verb set "$STDERR_FILE"
ENV_STATUS_OK=0; id_in_log "ENV_STATUS_WINS" && ENV_STATUS_OK=1
ENV_INPROG_OK=0; id_in_log "ENV_INPROG_WINS" && ENV_INPROG_OK=1
ENV_FINGER_OK=0; id_in_log "ENV_FINGER_WINS" && ENV_FINGER_OK=1
ITEM=0; item_call_made && ITEM=1
RESOLVER_LEAKED=0
{ id_in_log "RESOLVER_STATUS" || id_in_log "RESOLVER_INPROG" || id_in_log "RESOLVER_FINGER"; } && RESOLVER_LEAKED=1
if [ "$WIP_RC" = "0" ] && [ "$ITEM" = "1" ] \
   && [ "$ENV_STATUS_OK" = "1" ] && [ "$ENV_INPROG_OK" = "1" ] && [ "$ENV_FINGER_OK" = "1" ] \
   && [ "$RESOLVER_LEAKED" = "0" ]; then
    pass "TWM-3: rc=0 + item call reached; .env wins for every field (no resolver overwrite)"
else
    fail "TWM-3: rc=$WIP_RC item=$ITEM env_status=$ENV_STATUS_OK env_inprog=$ENV_INPROG_OK env_finger=$ENV_FINGER_OK resolver_leaked=$RESOLVER_LEAKED (expected RED — precedence guard not yet implemented)"
fi
teardown_mock

# ===========================================================================
# TWM-4: resolver rc=1 + .env set → the `check` verb completes its success path
# (preflight_field_ids passes because .env supplied the IDs; resolver failure is
# non-fatal → prints "none" and exits 0). Robustness (C3): assert the ACTUAL rc
# (0) AND positive stdout evidence ("none") AND the ABSENCE of the missing-env
# error — so an unrelated early failure cannot pass this vacuously.
# ===========================================================================
setup_mock
export GH_MOCK_RESOLVER_FAIL=1
cat > "$AGENTS_CONFIG_DIR/.env" <<'ENV_EOF'
WIP_STATE_STATUS_FIELD_ID=preserved-status-id
WIP_STATE_IN_PROGRESS_OPTION_ID=preserved-inprog-id
WIP_STATE_DONE_OPTION_ID=preserved-done-id
WIP_STATE_FINGERPRINT_FIELD_ID=preserved-finger-id
ENV_EOF
STDERR_FILE="$TMP/twm4-stderr.log"
STDOUT_FILE="$TMP/twm4-stdout.log"
WIP_RC=0
bash "$TARGET_WIP" check 999 >"$STDOUT_FILE" 2>"$STDERR_FILE" || WIP_RC=$?
STDERR_CONTENT=$(cat "$STDERR_FILE" 2>/dev/null)
STDOUT_CONTENT=$(cat "$STDOUT_FILE" 2>/dev/null)
HAS_MISSING_ERROR=0
echo "$STDERR_CONTENT" | grep -qi "missing required env" && HAS_MISSING_ERROR=1
PRINTED_NONE=0
printf '%s' "$STDOUT_CONTENT" | grep -qx "none" && PRINTED_NONE=1
if [ "$WIP_RC" = "0" ] && [ "$PRINTED_NONE" = "1" ] && [ "$HAS_MISSING_ERROR" = "0" ]; then
    pass "TWM-4: resolver rc=1 + .env set → check rc=0, prints 'none', no missing-env error"
else
    fail "TWM-4: rc=$WIP_RC printed_none=$PRINTED_NONE missing_err=$HAS_MISSING_ERROR stdout='$STDOUT_CONTENT' stderr='$STDERR_CONTENT'"
fi
teardown_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
