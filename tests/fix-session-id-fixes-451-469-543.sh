#!/bin/bash
# tests/fix-session-id-fixes-451-469-543.sh
# Tests: fix/session-id-fixes-451-469-543
# Tags: session-id, wip-state, cleanup-zombies
#
# RED suite — three combined fixes:
#   #451 — clarify-intent/workflow-init SKILL.md must mention CLAUDE_SESSION_ID
#           in the session-id-failure hint text.
#   #469 — hooks/lib/workflow-state/state-io.js cleanupZombies must also delete
#           stale .workflow-off and .worktree-off marker files.
#   #543 — wip-state.sh / wip-set-single.sh / wip-set-resume.sh /
#           aggregate-wip-check.sh must accept and propagate a --session-id
#           option so callers can pin the resolved SID.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WIP_STATE="$AGENTS_DIR/bin/github-issues/wip-state.sh"
WIP_SET_SINGLE="$AGENTS_DIR/bin/github-issues/wip-set-single.sh"
WIP_SET_RESUME="$AGENTS_DIR/skills/workflow-init/scripts/wip-set-resume.sh"
AGG_WIP_CHECK="$AGENTS_DIR/skills/workflow-init/scripts/aggregate-wip-check.sh"
STATE_IO_JS="$AGENTS_DIR/hooks/lib/workflow-state/state-io.js"
CLARIFY_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
WI_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# === #451 grep tests ===

if [ -f "$CLARIFY_SKILL" ]; then
    if grep -nE 'rc=2' "$CLARIFY_SKILL" | grep -q 'CLAUDE_SESSION_ID'; then
        pass "A1: clarify-intent SKILL.md rc=2 hint mentions CLAUDE_SESSION_ID"
    else
        fail "A1: clarify-intent SKILL.md rc=2 hint does NOT mention CLAUDE_SESSION_ID"
    fi
else
    fail "A1: $CLARIFY_SKILL not found"
fi

if [ -f "$WI_SKILL" ]; then
    if grep -nE 'session-id resolution failure|WIP check failed' "$WI_SKILL" \
            | grep -q 'CLAUDE_SESSION_ID'; then
        pass "A2: workflow-init SKILL.md session-id error hint mentions CLAUDE_SESSION_ID"
    else
        fail "A2: workflow-init SKILL.md session-id error hint does NOT mention CLAUDE_SESSION_ID"
    fi
else
    fail "A2: $WI_SKILL not found"
fi

# === #469 cleanupZombies extension ===

run_cleanup_node() {
    local wfdir="$1"
    local days="${2:-7}"
    (cd "$AGENTS_DIR" && CLAUDE_WORKFLOW_DIR="$wfdir" node -e "
const wf = require('./hooks/lib/workflow-state/state-io.js');
wf.cleanupZombies($days);
" 2>/dev/null) || true
}

backdate_file() {
    local f="$1" days="$2"
    touch -d "$days days ago" "$f" 2>/dev/null \
        || touch -t "$(date -v-${days}d +%Y%m%d%H%M 2>/dev/null \
            || date -d "$days days ago" +%Y%m%d%H%M 2>/dev/null \
            || echo '202001010000')" "$f" 2>/dev/null \
        || true
}

mtime_age_ms() {
    node -e "try{const s=require('fs').statSync('$1');console.log(Date.now()-s.mtimeMs)}catch(e){console.log(0)}" 2>/dev/null || echo 0
}

# B1
B1_DIR="$AGENTS_DIR/tests/.tmp-b1-$$"
mkdir -p "$B1_DIR"
B1_FILE="$B1_DIR/sid-stale.workflow-off"
echo "stale" > "$B1_FILE"
backdate_file "$B1_FILE" 14
run_cleanup_node "$B1_DIR" 7
if [ ! -f "$B1_FILE" ]; then
    pass "B1: stale (14-day-old) .workflow-off deleted by cleanupZombies"
else
    DIFF=$(mtime_age_ms "$B1_FILE")
    if [ "${DIFF:-0}" -lt 86400000 ]; then
        echo "SKIP: B1 backdate failed on this platform (age=$DIFF ms)"
    else
        fail "B1: stale .workflow-off was NOT deleted (age=$DIFF ms)"
    fi
fi
rm -rf "$B1_DIR" 2>/dev/null || true

# B2
B2_DIR="$AGENTS_DIR/tests/.tmp-b2-$$"
mkdir -p "$B2_DIR"
B2_FILE="$B2_DIR/sid-stale.worktree-off"
echo "stale" > "$B2_FILE"
backdate_file "$B2_FILE" 14
run_cleanup_node "$B2_DIR" 7
if [ ! -f "$B2_FILE" ]; then
    pass "B2: stale (14-day-old) .worktree-off deleted by cleanupZombies"
else
    DIFF=$(mtime_age_ms "$B2_FILE")
    if [ "${DIFF:-0}" -lt 86400000 ]; then
        echo "SKIP: B2 backdate failed on this platform (age=$DIFF ms)"
    else
        fail "B2: stale .worktree-off was NOT deleted (age=$DIFF ms)"
    fi
fi
rm -rf "$B2_DIR" 2>/dev/null || true

# B3
B3_DIR="$AGENTS_DIR/tests/.tmp-b3-$$"
mkdir -p "$B3_DIR"
B3_FILE="$B3_DIR/sid-fresh.workflow-off"
echo "fresh" > "$B3_FILE"
run_cleanup_node "$B3_DIR" 7
if [ -f "$B3_FILE" ]; then
    pass "B3: fresh .workflow-off preserved by cleanupZombies"
else
    fail "B3: fresh .workflow-off was incorrectly deleted"
fi
rm -rf "$B3_DIR" 2>/dev/null || true

# B4
B4_DIR="$AGENTS_DIR/tests/.tmp-b4-$$"
mkdir -p "$B4_DIR"
B4_FILE="$B4_DIR/sid-fresh.worktree-off"
echo "fresh" > "$B4_FILE"
run_cleanup_node "$B4_DIR" 7
if [ -f "$B4_FILE" ]; then
    pass "B4: fresh .worktree-off preserved by cleanupZombies"
else
    fail "B4: fresh .worktree-off was incorrectly deleted"
fi
rm -rf "$B4_DIR" 2>/dev/null || true

# B5
B5_DIR="$AGENTS_DIR/tests/.tmp-b5-$$"
mkdir -p "$B5_DIR"
B5_FILE="$B5_DIR/stale-sid.json"
cat > "$B5_FILE" <<'JSON'
{
  "version": 1,
  "session_id": "stale-sid",
  "created_at": "2020-01-01T00:00:00.000Z",
  "steps": {
    "workflow_init": { "status": "pending", "updated_at": "2020-01-01T00:00:00.000Z" }
  }
}
JSON
run_cleanup_node "$B5_DIR" 7
if [ ! -f "$B5_FILE" ]; then
    pass "B5: regression — stale .json deleted by cleanupZombies"
else
    fail "B5: stale .json was NOT deleted (existing behavior broken)"
fi
rm -rf "$B5_DIR" 2>/dev/null || true

# B6
B6_DIR="$AGENTS_DIR/tests/.tmp-b6-$$"
mkdir -p "$B6_DIR"
B6_FILE="$B6_DIR/stale.json.tmp"
touch "$B6_FILE"
backdate_file "$B6_FILE" 2
run_cleanup_node "$B6_DIR" 7
if [ ! -f "$B6_FILE" ]; then
    pass "B6: regression — stale .tmp deleted by cleanupZombies"
else
    DIFF=$(mtime_age_ms "$B6_FILE")
    if [ "${DIFF:-0}" -lt 86400000 ]; then
        echo "SKIP: B6 backdate failed on this platform"
    else
        fail "B6: stale .tmp was NOT deleted (existing behavior broken)"
    fi
fi
rm -rf "$B6_DIR" 2>/dev/null || true

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

# === #543 E — wip-set-resume.sh SID resolution ===

setup_e_mock() {
    D_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipfix543e)"
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
exit 0
MOCKWIP
    chmod +x "$D_TMP/agents-config/bin/github-issues/wip-state.sh"

    cat > "$D_TMP/agents-config/bin/github-issues/wip-set-single.sh" <<'MOCKWSS'
#!/bin/bash
printf '%s\n' "$*" >> "${WIP_SET_SINGLE_ARGS_LOG:-/dev/null}"
"$AGENTS_CONFIG_DIR/bin/github-issues/wip-state.sh" set "$@"
exit $?
MOCKWSS
    chmod +x "$D_TMP/agents-config/bin/github-issues/wip-set-single.sh"

    export AGENTS_CONFIG_DIR="$D_TMP/agents-config"
    export PATH="$D_TMP/mock-bin:$PATH"
    export WIP_STATE_ARGS_LOG="$D_TMP/wip-state-args.log"
    export WIP_SET_SINGLE_ARGS_LOG="$D_TMP/wip-set-single-args.log"
    : > "$WIP_STATE_ARGS_LOG"
    : > "$WIP_SET_SINGLE_ARGS_LOG"

    export CLAUDE_ENV_FILE="$D_TMP/claude-env"
    echo "CLAUDE_SESSION_ID=testSID" > "$CLAUDE_ENV_FILE"
    unset CLAUDE_SESSION_ID 2>/dev/null || true
}

teardown_e_mock() {
    if [ -n "${D_TMP:-}" ] && [ -d "$D_TMP" ]; then
        rm -rf "$D_TMP" 2>/dev/null || true
    fi
    D_TMP=""
    PATH="${PATH#*mock-bin:}"
    unset AGENTS_CONFIG_DIR WIP_STATE_ARGS_LOG WIP_SET_SINGLE_ARGS_LOG \
          CLAUDE_ENV_FILE CLAUDE_SESSION_ID 2>/dev/null || true
}

# E1
setup_e_mock
run_with_timeout 30 bash "$WIP_SET_RESUME" 42 >/dev/null 2>&1
RC=$?
if grep -q -- "--session-id testSID" "$WIP_SET_SINGLE_ARGS_LOG" 2>/dev/null \
   || grep -q -- "--session-id testSID" "$WIP_STATE_ARGS_LOG" 2>/dev/null; then
    pass "E1: wip-set-resume.sh resolves SID from CLAUDE_ENV_FILE and passes --session-id testSID"
else
    fail "E1: rc=$RC wss_log=$(cat "$WIP_SET_SINGLE_ARGS_LOG" 2>/dev/null) ws_log=$(cat "$WIP_STATE_ARGS_LOG" 2>/dev/null)"
fi
teardown_e_mock

# === #543 F — aggregate-wip-check.sh SID resolution ===

setup_f_mock() {
    D_TMP="$(mktemp -d 2>/dev/null || mktemp -d -t wipfix543f)"
    mkdir -p "$D_TMP/agents-config/bin/github-issues"

    cat > "$D_TMP/agents-config/bin/github-issues/wip-state.sh" <<'MOCKWIP'
#!/bin/bash
printf '%s\n' "$*" >> "${WIP_STATE_ARGS_LOG:-/dev/null}"
echo "same"
exit 0
MOCKWIP
    chmod +x "$D_TMP/agents-config/bin/github-issues/wip-state.sh"

    export AGENTS_CONFIG_DIR="$D_TMP/agents-config"
    export WIP_STATE_ARGS_LOG="$D_TMP/wip-state-args.log"
    : > "$WIP_STATE_ARGS_LOG"

    export CLAUDE_ENV_FILE="$D_TMP/claude-env"
    echo "CLAUDE_SESSION_ID=testSID" > "$CLAUDE_ENV_FILE"
    unset CLAUDE_SESSION_ID 2>/dev/null || true
}

teardown_f_mock() {
    if [ -n "${D_TMP:-}" ] && [ -d "$D_TMP" ]; then
        rm -rf "$D_TMP" 2>/dev/null || true
    fi
    D_TMP=""
    unset AGENTS_CONFIG_DIR WIP_STATE_ARGS_LOG CLAUDE_ENV_FILE CLAUDE_SESSION_ID 2>/dev/null || true
}

# F1
setup_f_mock
run_with_timeout 30 bash "$AGG_WIP_CHECK" 42 >/dev/null 2>&1
RC=$?
if grep -q -- "--session-id testSID" "$WIP_STATE_ARGS_LOG" 2>/dev/null; then
    pass "F1: aggregate-wip-check.sh passes --session-id testSID through to wip-state.sh check"
else
    fail "F1: rc=$RC log=$(cat "$WIP_STATE_ARGS_LOG" 2>/dev/null)"
fi
teardown_f_mock

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
