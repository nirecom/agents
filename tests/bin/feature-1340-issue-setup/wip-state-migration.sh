#!/bin/bash
# tests/bin/feature-1340-issue-setup/wip-state-migration.sh
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/cmd-set.sh, bin/github-issues/wip-state/cmd-check.sh, bin/github-issues/wip-state/cmd-clear.sh
# Tags: issue-setup, wip-state, github-issues, scope:issue-specific
# C6: a `;`-valued .env line must never execute commands — SEMI-1 (#2408).
# L2: resolver → each WIP_STATE_* = exact resolver ID across set/check/clear
#     (ensure_wip_field_ids, #1340). TWM-1/3/4 (.env sourcing) retired by #2408.
# L3 gap: no live GitHub Projects API; mitigated by the WORKFLOW_USER_VERIFIED
# preflight (bin/check-verification-gate.sh category: skill-orchestration).

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
. "$AGENTS_DIR/tests/lib/harness.sh"

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

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
    mkdir -p "$TMP/plans"
    export AGENTS_CONFIG_DIR="$TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR"
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
# ensure_wip_field_ids populated (from the resolver) are exposed as
# arguments to the downstream `gh project item-edit` / `gh api graphql`
# (check) calls, which the gh mock records to MOCK_LOG. Assertions then grep
# MOCK_LOG for the EXACT id values. This avoids the source-then-exit problem
# (the verb dispatcher calls `exit`, which would kill an inline printf).
# Captures the verb's real exit code in WIP_RC (do NOT swallow it — a test
# that asserts success must check WIP_RC, so an early unrelated failure cannot
# pass vacuously).
run_wip_verb() {
    local verb="$1" stderr_file="${2:-/dev/null}"
    local -a sid_args=()
    # clear/abandon reject --session-id; only set/check consume it.
    case "$verb" in set|check) sid_args=(--session-id "twm-test") ;; esac
    WIP_RC=0
    bash "$TARGET_WIP" "$verb" 999 "${sid_args[@]}" >/dev/null 2>"$stderr_file" || WIP_RC=$?
}

# Assert that an exact id value reached a gh call (proves ensure_wip_field_ids
# populated the corresponding WIP_STATE_* var with that value).
id_in_log() { grep -Fq -- "$1" "$MOCK_LOG" 2>/dev/null; }
# Did a downstream field-referencing gh call actually run? (positive evidence
# that the verb progressed past preflight into the item read/write step).
item_call_made() { grep -qE "project item-edit|fieldValues|item-add" "$MOCK_LOG" 2>/dev/null; }

# TWM-1: retired by #2408 — load_env_file removed; .env source no longer occurs

# ===========================================================================
# TWM-2 (set): empty .env + resolver returns known distinct IDs → status +
# in-progress + fingerprint each reach the gh calls with their EXACT resolver
# value (proves ensure_wip_field_ids populated them before preflight).
# ===========================================================================
case_begin "twm2-set-field-ids" "bin/github-issues/wip-state/cmd-set.sh"
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
case_end

# ===========================================================================
# TWM-2c (check): check consumes status + fingerprint. Both must reach the
# read query with their exact resolver value.
# ===========================================================================
case_begin "twm2c-check-field-ids" "bin/github-issues/wip-state/cmd-check.sh"
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
case_end

# ===========================================================================
# TWM-2d (clear): clear consumes status + done + fingerprint. All three must
# reach the gh calls with their exact resolver value.
# ===========================================================================
case_begin "twm2d-clear-field-ids" "bin/github-issues/wip-state/cmd-clear.sh"
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
case_end

# TWM-3: retired by #2408 — load_env_file removed; .env source no longer occurs
# TWM-4: retired by #2408 — load_env_file removed; .env source no longer occurs

# ===========================================================================
# SEMI-1 (#2408): a .env line whose value carries `;` (CODE_FILE_EXTENSIONS=
# js;sh;py;md) must not be sourced — sourcing runs `sh`/`py`/`md` as commands and
# their output pollutes check's stdout. Sentinels on PATH record any execution.
# ===========================================================================
case_begin "semi1-env-semicolon-not-executed" "bin/github-issues/wip-state.sh"
setup_mock
export GH_MOCK_RESOLVER_FAIL=0
SEMI_BIN="$TMP/semi-bin"
SEMI_FLAGS="$TMP/semi-flags"
SEMI_REPO="$TMP/semi-repo"
mkdir -p "$SEMI_BIN" "$SEMI_FLAGS"
for s in sh py md; do
    printf '#!/bin/bash\n: > "%s/%s.ran"\necho "SENTINEL_%s_RAN"\n' "$SEMI_FLAGS" "$s" "$s" > "$SEMI_BIN/$s"
    chmod +x "$SEMI_BIN/$s"
done
cat > "$SEMI_BIN/gh" <<'SEMI_GH_EOF'
#!/bin/bash
ARGS="$*"
case "$ARGS" in
  auth\ status*) echo "Logged in to github.com"; echo "Token scopes: 'repo', 'project'"; exit 0 ;;
  repo\ view\ *--json\ owner,name*) echo "nirecom/agents"; exit 0 ;;
  api\ graphql\ *projectsV2*) echo '{"id":"PVT_semi1","number":1,"ownerLogin":"nirecom"}'; exit 0 ;;
  api\ graphql\ *projectItems*) exit 0 ;;
  api\ graphql\ *)
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*) echo ""; exit 0 ;;
      *'"In Progress")'*) echo "SEMI_INPROG"; exit 0 ;;
      *'"Todo")'*) echo "SEMI_TODO"; exit 0 ;;
      *'"Done")'*) echo "SEMI_DONE"; exit 0 ;;
      *'"Status")'*|*'== "Status"'*) echo "SEMI_STATUS"; exit 0 ;;
      *'session-fingerprint'*) echo "SEMI_FINGER"; exit 0 ;;
      *"Content Date"*) echo "PVTF_semi"; exit 0 ;;
      *) echo "SEMI_STATUS"; exit 0 ;;
    esac ;;
  *) exit 0 ;;
esac
SEMI_GH_EOF
chmod +x "$SEMI_BIN/gh"
printf 'CODE_FILE_EXTENSIONS=js;sh;py;md\n' > "$AGENTS_CONFIG_DIR/.env"
git init -q "$SEMI_REPO"
git -C "$SEMI_REPO" config core.hooksPath /dev/null
git -C "$SEMI_REPO" remote add origin https://github.com/nirecom/agents.git
STDOUT_FILE="$TMP/semi1-stdout.log"
STDERR_FILE="$TMP/semi1-stderr.log"
WIP_RC=0
( cd "$SEMI_REPO" && export PATH="$SEMI_BIN:$PATH" && run_with_timeout 60 bash "$TARGET_WIP" check 999 --session-id semi1sid ) \
    >"$STDOUT_FILE" 2>"$STDERR_FILE" || WIP_RC=$?
SEMI_OUT="$(cat "$STDOUT_FILE" 2>/dev/null)"
SEMI_RAN=""
for f in "$SEMI_FLAGS"/*.ran; do [ -e "$f" ] && SEMI_RAN="$SEMI_RAN${f##*/} "; done
if [ -z "$SEMI_RAN" ] && [ "$WIP_RC" = "0" ] && [[ "$SEMI_OUT" =~ ^(none|same|other)$ ]]; then
    pass "SEMI-1: ;-valued .env → check rc=0, stdout valid ($SEMI_OUT), no sentinel executed"
else
    fail "SEMI-1: rc=$WIP_RC stdout='$(printf '%s' "$SEMI_OUT" | tr '\n' ';')' sentinels_ran='$SEMI_RAN' stderr='$(head -c 300 "$STDERR_FILE" 2>/dev/null)'"
fi
teardown_mock
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
