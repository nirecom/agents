# wip-resume-check-543.sh — #543 SID-resolution tests for wip-set-resume.sh (E1)
# and aggregate-wip-check.sh (F1).
# Sourced by fix-session-id-fixes-451-469-543.sh; inherits globals and helpers.

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
    # #1251: CLAUDE_CODE_SESSION_ID (P2) now outranks CLAUDE_ENV_FILE (P3);
    # unset it so the leaked real-session id cannot shadow testSID.
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
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
    # #1251: CLAUDE_CODE_SESSION_ID (P2) now outranks CLAUDE_ENV_FILE (P3);
    # unset it so the leaked real-session id cannot shadow testSID.
    unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
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
