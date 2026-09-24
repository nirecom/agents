# wip-session-id-543.sh — #543 --session-id option tests: wip-state.sh (C1..C5)
# and wip-set-single.sh passthrough (D1..D2). E1/F1 live in wip-resume-check-543.sh.
# Sourced by fix-session-id-fixes-451-469-543.sh; inherits globals and helpers.

# === #543 wip-state.sh --session-id option ===

WIP_TMP=""

setup_wip_mock() {
    WIP_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipfix543)"
    mkdir -p "$WIP_TMP/mock-bin"
    cat > "$WIP_TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  auth\ status*) echo "Token scopes: 'project', 'repo'"; exit 0 ;;
  repo\ view\ *) echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo 1; exit 0 ;;
      *) printf '{"id":"PVT_resolved","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac
    ;;
  api\ graphql\ *projectItems*) printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID:-PVTI_existing}"; exit 0 ;;
  api\ graphql\ *)
    case "$ARGS" in
      *"| .name"*) echo "${GH_MOCK_STATUS:-In Progress}"; exit 0 ;;
      *"| .text"*) echo "${GH_MOCK_FINGERPRINT:-}"; exit 0 ;;
      *) echo ""; exit 0 ;;
    esac
    ;;
  project\ item-edit\ *) exit 0 ;;
  project\ item-add\ *) echo "PVTI_added"; exit 0 ;;
  issue\ view\ *) echo "${GH_MOCK_ISSUE_URL:-https://github.com/nirecom/agents/issues/42}"; exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
    chmod +x "$WIP_TMP/mock-bin/gh"
    export PATH="$WIP_TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$WIP_TMP/gh-args.log"
    : > "$GH_MOCK_ARGS_LOG"

    export AGENTS_CONFIG_DIR="$WIP_TMP/agents-config"
    mkdir -p "$AGENTS_CONFIG_DIR/bin"
    export PLANS_DIR="$WIP_TMP/plans"
    mkdir -p "$PLANS_DIR"
    cat > "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" <<EOF
#!/bin/bash
echo "$PLANS_DIR"
EOF
    chmod +x "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir"

    export WIP_STATE_STATUS_FIELD_ID="PVTSSF_status"
    export WIP_STATE_IN_PROGRESS_OPTION_ID="OPT_inprog"
    export WIP_STATE_DONE_OPTION_ID="OPT_done"
    export WIP_STATE_TODO_OPTION_ID="OPT_todo"
    export WIP_STATE_FINGERPRINT_FIELD_ID="PVTF_fp"

    export ISSUE_CREATE_PROJECT_ID="PVT_kwHOAMF_jc4BXf9E"
    export ISSUE_CREATE_PROJECT_NUM="1"
    export ISSUE_CREATE_OWNER="nirecom"

    export CLAUDE_SESSION_ID="default-sid-fixture"
    unset CLAUDE_ENV_FILE 2>/dev/null || true
}

teardown_wip_mock() {
    if [ -n "${WIP_TMP:-}" ] && [ -d "$WIP_TMP" ]; then
        rm -rf "$WIP_TMP" 2>/dev/null || true
    fi
    WIP_TMP=""
    PATH="${PATH#*mock-bin:}"
    unset GH_MOCK_ARGS_LOG GH_MOCK_PROJECT_ITEM_ID GH_MOCK_STATUS GH_MOCK_FINGERPRINT \
          AGENTS_CONFIG_DIR PLANS_DIR \
          WIP_STATE_STATUS_FIELD_ID WIP_STATE_IN_PROGRESS_OPTION_ID \
          WIP_STATE_DONE_OPTION_ID WIP_STATE_TODO_OPTION_ID \
          WIP_STATE_FINGERPRINT_FIELD_ID \
          ISSUE_CREATE_PROJECT_ID ISSUE_CREATE_PROJECT_NUM ISSUE_CREATE_OWNER \
          CLAUDE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true
}

expected_fp() {
    printf '%s:%s' "$1" "$2" | sha256sum | cut -c1-8
}

# C1
setup_wip_mock
EXP_FP=$(expected_fp "testSID" "42")
run_with_timeout 30 bash "$WIP_STATE" set 42 --session-id testSID >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--text $EXP_FP" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "C1: set <N> --session-id testSID writes fingerprint computed from testSID"
else
    fail "C1: rc=$RC exp_fp=$EXP_FP log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_wip_mock

# C2
setup_wip_mock
EXP_FP=$(expected_fp "testSID" "42")
export GH_MOCK_STATUS="In Progress"
export GH_MOCK_FINGERPRINT="$EXP_FP"
OUT=$(run_with_timeout 30 bash "$WIP_STATE" check 42 --session-id testSID 2>/dev/null)
RC=$?
if [ "$RC" -eq 0 ] && [ "$OUT" = "same" ]; then
    pass "C2: check <N> --session-id testSID matches testSID-derived fingerprint"
else
    fail "C2: rc=$RC out='$OUT' exp_fp=$EXP_FP"
fi
teardown_wip_mock

# C3
setup_wip_mock
run_with_timeout 30 bash "$WIP_STATE" set 42 --session-id "" >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "C3: set <N> --session-id '' rejected with exit 2"
else
    fail "C3: expected exit 2 for empty --session-id, got rc=$RC"
fi
teardown_wip_mock

# C4
setup_wip_mock
run_with_timeout 30 bash "$WIP_STATE" clear 42 --session-id testSID >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 2 ]; then
    pass "C4: clear <N> --session-id rejected (exit 2)"
else
    fail "C4: expected exit 2 (clear should not accept --session-id), got rc=$RC"
fi
teardown_wip_mock

# C5
setup_wip_mock
EXP_FP=$(expected_fp "testSID" "42")
run_with_timeout 30 bash "$WIP_STATE" set --session-id testSID 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--text $EXP_FP" "$GH_MOCK_ARGS_LOG" 2>/dev/null; then
    pass "C5: --session-id can appear before <N> (position independence)"
else
    fail "C5: rc=$RC exp_fp=$EXP_FP log=$(cat "$GH_MOCK_ARGS_LOG" 2>/dev/null)"
fi
teardown_wip_mock

# === #543 D — wip-set-single.sh --session-id passthrough ===

D_TMP=""

setup_d_mock() {
    D_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipfix543d)"
    mkdir -p "$D_TMP/mock-bin" "$D_TMP/agents-config/bin/github-issues"

    cat > "$D_TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
case "$*" in
  issue\ view\ *--json\ labels*) echo '["type:task","intent:clarified"]'; exit 0 ;;
  *) echo '[]'; exit 0 ;;
esac
MOCKGH
    chmod +x "$D_TMP/mock-bin/gh"

    cat > "$D_TMP/agents-config/bin/github-issues/wip-state.sh" <<'MOCKWIP'
#!/bin/bash
printf '%s\n' "$*" >> "${WIP_STATE_ARGS_LOG:-/dev/null}"
exit "${GH_MOCK_WIP_RC:-0}"
MOCKWIP
    chmod +x "$D_TMP/agents-config/bin/github-issues/wip-state.sh"

    export AGENTS_CONFIG_DIR="$D_TMP/agents-config"
    export PATH="$D_TMP/mock-bin:$PATH"
    export WIP_STATE_ARGS_LOG="$D_TMP/wip-state-args.log"
    : > "$WIP_STATE_ARGS_LOG"
}

teardown_d_mock() {
    if [ -n "${D_TMP:-}" ] && [ -d "$D_TMP" ]; then
        rm -rf "$D_TMP" 2>/dev/null || true
    fi
    D_TMP=""
    PATH="${PATH#*mock-bin:}"
    unset AGENTS_CONFIG_DIR WIP_STATE_ARGS_LOG GH_MOCK_WIP_RC 2>/dev/null || true
}

# D1
setup_d_mock
run_with_timeout 30 bash "$WIP_SET_SINGLE" --session-id testSID 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q -- "--session-id testSID" "$WIP_STATE_ARGS_LOG" 2>/dev/null; then
    pass "D1: wip-set-single.sh --session-id passes through to wip-state.sh"
else
    fail "D1: rc=$RC log=$(cat "$WIP_STATE_ARGS_LOG" 2>/dev/null)"
fi
teardown_d_mock

# D2
setup_d_mock
run_with_timeout 30 bash "$WIP_SET_SINGLE" 42 >/dev/null 2>&1
RC=$?
if [ "$RC" -eq 0 ] && grep -q "^set 42" "$WIP_STATE_ARGS_LOG" 2>/dev/null; then
    pass "D2: wip-set-single.sh <N> without --session-id still calls 'set <N>'"
else
    fail "D2: rc=$RC log=$(cat "$WIP_STATE_ARGS_LOG" 2>/dev/null)"
fi
teardown_d_mock
