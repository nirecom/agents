#!/bin/bash
# tests/install/feature-2284-install-cc-claude-codex-cli/wait-helper.sh
# Sub-file: wait-cc-exit.sh/.ps1 behavioral tests (Group A) plus static assertions
# for default values (A7/A9) and process name (A8/A10).
# Testability contract the implementation MUST honor:
#   bash: WAIT_CC_POLL_INTERVAL / WAIT_CC_MAX_POLLS override 3s x 10 defaults.
#   pwsh: same two vars plus WAIT_CC_PROCESS_OVERRIDE (none / alive / alive:N).
# Tests: install/lib/wait-cc-exit.sh, install/lib/wait-cc-exit.ps1
# Tags: installer, wait-cc-exit, pwsh-required, scope:issue-specific
# Sourced inside the dispatcher's wait-cc-exit.sh span; the pwsh half is wait-helper-ps.sh.

MOCK_BIN="$TMP_DIR/bin"
mkdir -p "$MOCK_BIN"
COUNTER_FILE="$TMP_DIR/pgrep-calls"

cat > "$MOCK_BIN/pgrep" << 'MOCK_EOF'
#!/bin/bash
case "${MOCK_PGREP_MODE:-absent}" in
    absent) exit 1 ;;
    alive)  echo 12345; exit 0 ;;
    alive-until)
        _n=0
        [ -f "${MOCK_PGREP_COUNTER:?}" ] && _n="$(cat "$MOCK_PGREP_COUNTER")"
        _n=$((_n + 1))
        echo "$_n" > "$MOCK_PGREP_COUNTER"
        if [ "$_n" -le "${MOCK_PGREP_ALIVE_CALLS:-2}" ]; then
            echo 12345; exit 0
        fi
        exit 1
        ;;
    *) exit 1 ;;
esac
MOCK_EOF
chmod +x "$MOCK_BIN/pgrep"

ELAPSED=0
run_wait_sh() {
    local mode="$1" alive_calls="${2:-0}"
    rm -f "$COUNTER_FILE"
    local start=$SECONDS rc=0
    env PATH="$MOCK_BIN:$PATH" \
        MOCK_PGREP_MODE="$mode" \
        MOCK_PGREP_COUNTER="$COUNTER_FILE" \
        MOCK_PGREP_ALIVE_CALLS="$alive_calls" \
        WAIT_CC_POLL_INTERVAL=1 \
        WAIT_CC_MAX_POLLS=3 \
        bash "$WAIT_SH" > "$TMP_DIR/helper-stdout" 2> "$TMP_DIR/helper-stderr" || rc=$?
    ELAPSED=$((SECONDS - start))
    echo "$rc"
}

# --- Group A: wait-cc-exit.sh ---

if [ ! -f "$WAIT_SH" ]; then
    fail "A1: install/lib/wait-cc-exit.sh does not exist"
    fail "A2: install/lib/wait-cc-exit.sh does not exist"
    fail "A3: install/lib/wait-cc-exit.sh does not exist"
    fail "A7: install/lib/wait-cc-exit.sh does not exist"
    fail "A8: install/lib/wait-cc-exit.sh does not exist"
else
    _rc="$(run_wait_sh absent)"
    if [ "$_rc" = "0" ] && [ "$ELAPSED" -lt 2 ]; then
        pass "A1: no CC process -> exit 0 immediately (rc=$_rc, ${ELAPSED}s)"
    else
        fail "A1: no CC process -> expected exit 0 in under 2s, got rc=$_rc in ${ELAPSED}s"
    fi

    _rc="$(run_wait_sh alive)"
    _err="$(cat "$TMP_DIR/helper-stderr")"
    if [ "$_rc" != "1" ]; then
        fail "A2: CC alive throughout -> expected exit 1, got rc=$_rc"
    elif [ -z "$_err" ]; then
        fail "A2: CC alive throughout -> exit 1 but no warning on stderr"
    else
        pass "A2: CC alive throughout -> exit 1 with stderr warning"
    fi

    _rc="$(run_wait_sh alive-until 2)"
    _a3_err="$(cat "$TMP_DIR/helper-stderr")"
    _calls=0
    [ -f "$COUNTER_FILE" ] && _calls="$(cat "$COUNTER_FILE")"
    if [ "$_rc" = "0" ] && [ "$_calls" -gt 1 ]; then
        pass "A3: CC exits before timeout -> exit 0 after $_calls probes"
    else
        fail "A3: CC exits before timeout -> expected exit 0 after >1 probe, got rc=$_rc probes=$_calls"
    fi

    # A7: default poll parameters must be 3s x 10 = 30s (the requirement's core numbers).
    if grep -qE '\$\{?WAIT_CC_POLL_INTERVAL[^}]*:-[[:space:]]*3[[:space:]]*\}?' "$WAIT_SH" \
    && grep -qE '\$\{?WAIT_CC_MAX_POLLS[^}]*:-[[:space:]]*10[[:space:]]*\}?' "$WAIT_SH"; then
        pass "A7: wait-cc-exit.sh defaults are 3s × 10 polls (30s total)"
    else
        fail "A7: wait-cc-exit.sh missing WAIT_CC_POLL_INTERVAL:-3 or WAIT_CC_MAX_POLLS:-10"
    fi

    # A8: must detect process by the exact name "claude", not "claude-code" or similar,
    # and (#2476) list the PID pgrep reported (the alive-until run above).
    if ! grep -qE 'pgrep[[:space:]].*-x[[:space:]]+"?claude"?' "$WAIT_SH"; then
        fail "A8: wait-cc-exit.sh does not use pgrep -x \"claude\" (wrong/missing process name)"
    elif ! printf '%s' "$_a3_err" | grep -q 'PID 12345'; then
        fail "A8: wait-cc-exit.sh does not list the waited PID (no 'PID 12345' on stderr)"
    else
        pass "A8: wait-cc-exit.sh detects process via pgrep -x \"claude\" and lists PID 12345"
    fi
fi
