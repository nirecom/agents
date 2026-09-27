#!/bin/bash
# tests/install/feature-2284-install-cc-claude-codex-cli/wait-helper.sh
# Sub-file: wait-cc-exit.sh/.ps1 behavioral tests (Group A) plus static assertions
# for default values (A7/A9) and process name (A8/A10).
# Testability contract the implementation MUST honor:
#   bash: WAIT_CC_POLL_INTERVAL / WAIT_CC_MAX_POLLS override 3s x 10 defaults.
#   pwsh: same two vars plus WAIT_CC_PROCESS_OVERRIDE (none / alive / alive:N).
# Tests: install/lib/wait-cc-exit.sh, install/lib/wait-cc-exit.ps1
# Tags: installer, wait-cc-exit, pwsh-required, scope:issue-specific
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
WAIT_SH="$AGENTS_DIR/install/lib/wait-cc-exit.sh"
WAIT_PS="$AGENTS_DIR/install/lib/wait-cc-exit.ps1"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

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

    # A8: must detect process by the exact name "claude", not "claude-code" or similar.
    if grep -qE 'pgrep[[:space:]].*-x[[:space:]]+"?claude"?' "$WAIT_SH"; then
        pass "A8: wait-cc-exit.sh detects process via pgrep -x \"claude\""
    else
        fail "A8: wait-cc-exit.sh does not use pgrep -x \"claude\" (wrong/missing process name)"
    fi
fi

# --- Group A (PowerShell) ---

if ! command -v pwsh > /dev/null 2>&1; then
    echo "SKIP: A4-A6, A9-A10 require pwsh (not installed)"
elif [ ! -f "$WAIT_PS" ]; then
    fail "A4: install/lib/wait-cc-exit.ps1 does not exist"
    fail "A5: install/lib/wait-cc-exit.ps1 does not exist"
    fail "A6: install/lib/wait-cc-exit.ps1 does not exist"
    fail "A9: install/lib/wait-cc-exit.ps1 does not exist"
    fail "A10: install/lib/wait-cc-exit.ps1 does not exist"
else
    run_wait_ps() {
        local override="$1" rc=0
        local start=$SECONDS
        env WAIT_CC_PROCESS_OVERRIDE="$override" \
            WAIT_CC_POLL_INTERVAL=1 \
            WAIT_CC_MAX_POLLS=3 \
            pwsh -NoProfile -File "$WAIT_PS" > "$TMP_DIR/ps-stdout" 2> "$TMP_DIR/ps-stderr" || rc=$?
        ELAPSED=$((SECONDS - start))
        echo "$rc"
    }

    _rc="$(run_wait_ps none)"
    if [ "$_rc" = "0" ] && [ "$ELAPSED" -lt 4 ]; then
        pass "A4: pwsh helper, no CC -> exit 0 immediately (rc=$_rc, ${ELAPSED}s)"
    else
        fail "A4: pwsh helper, no CC -> expected exit 0 quickly, got rc=$_rc in ${ELAPSED}s"
    fi

    _rc="$(run_wait_ps alive)"
    _out="$(cat "$TMP_DIR/ps-stdout" "$TMP_DIR/ps-stderr")"
    if [ "$_rc" = "1" ] && [ -n "$_out" ]; then
        pass "A5: pwsh helper, CC alive throughout -> exit 1 with warning"
    else
        fail "A5: pwsh helper, CC alive -> expected exit 1 + warning, got rc=$_rc"
    fi

    _rc="$(run_wait_ps "alive:2")"
    if [ "$_rc" = "0" ]; then
        pass "A6: pwsh helper, CC exits before timeout -> exit 0"
    else
        fail "A6: pwsh helper, CC exits -> expected exit 0, got rc=$_rc"
    fi

    # A9: default values
    if grep -iE 'WAIT_CC_POLL_INTERVAL' "$WAIT_PS" | grep -qE '[-=,][[:space:]]*3[^0-9]' \
    && grep -iE 'WAIT_CC_MAX_POLLS' "$WAIT_PS" | grep -qE '[-=,][[:space:]]*10[^0-9]'; then
        pass "A9: wait-cc-exit.ps1 has 3s × 10 defaults"
    else
        fail "A9: wait-cc-exit.ps1 missing WAIT_CC_POLL_INTERVAL=3 or WAIT_CC_MAX_POLLS=10 defaults"
    fi

    # A10: must use "claude" as the exact process name
    if grep -iE 'Get-Process[[:space:]]+-Name' "$WAIT_PS" | grep -qi '"claude"'; then
        pass "A10: wait-cc-exit.ps1 detects process via Get-Process -Name \"claude\""
    else
        fail "A10: wait-cc-exit.ps1 does not use Get-Process -Name \"claude\""
    fi
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
