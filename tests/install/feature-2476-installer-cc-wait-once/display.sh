# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh.
# PID display contract: "  PID <id>  <path|(unknown)>" on the first poll and whenever
# the PID set changes (sh: stderr); none for the internal mock modes. The sh helper
# decides "running" from the return code only. The pwsh helper's D-ps-* cases live in
# tests/install/feature-2476-installer-cc-wait-once.Tests.ps1.

_DISP_BIN="$TMP/disp-bin"
mkdir -p "$_DISP_BIN"
cat > "$_DISP_BIN/pgrep" << 'MOCK_EOF'
#!/bin/bash
_n=0
[ -f "$DISP_COUNTER" ] && _n="$(cat "$DISP_COUNTER")"
_n=$((_n + 1))
echo "$_n" > "$DISP_COUNTER"
if [ "$_n" -le "${DISP_ALIVE_CALLS:-2}" ]; then
    echo 12345
    [ "$_n" -ge "${DISP_CHANGE_AT:-999}" ] && echo 67890
    exit 0
fi
exit 1
MOCK_EOF
chmod +x "$_DISP_BIN/pgrep"

if [ ! -f "$WAIT_SH" ]; then
    fail "D-sh: install/lib/wait-cc-exit.sh does not exist"
else
    # D-sh-first: alive for 2 polls with an unchanged set -> exactly one PID line.
    rm -f "$TMP/disp-counter"
    _d_rc=0
    env PATH="$_DISP_BIN:$PATH" DISP_COUNTER="$TMP/disp-counter" DISP_ALIVE_CALLS=2 \
        WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS=3 \
        bash "$WAIT_SH" > "$TMP/disp-sh.out" 2> "$TMP/disp-sh.err" || _d_rc=$?
    _d_lines="$(grep -c 'PID 12345' "$TMP/disp-sh.err" 2>/dev/null || true)"
    _d_out="$(cat "$TMP/disp-sh.out")"
    if [ "$_d_rc" = "0" ] && [ "${_d_lines:-0}" = "1" ] && [ -z "$_d_out" ]; then
        pass "D-sh-first: PID 12345 listed once on stderr (unchanged set not repeated)"
    else
        fail "D-sh-first: want rc=0, one 'PID 12345' line on stderr, empty stdout" \
            "rc=$_d_rc lines=${_d_lines:-0} err=$(head -n 3 "$TMP/disp-sh.err")"
    fi

    # D-sh-change: poll 1 sees {12345}, poll 2 sees {12345,67890} -> the block is re-printed.
    rm -f "$TMP/disp-counter"
    _d_rc=0
    env PATH="$_DISP_BIN:$PATH" DISP_COUNTER="$TMP/disp-counter" DISP_ALIVE_CALLS=2 DISP_CHANGE_AT=2 \
        WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS=4 \
        bash "$WAIT_SH" > /dev/null 2> "$TMP/disp-chg.err" || _d_rc=$?
    _d_a="$(grep -c 'PID 12345' "$TMP/disp-chg.err" 2>/dev/null || true)"
    _d_b="$(grep -c 'PID 67890' "$TMP/disp-chg.err" 2>/dev/null || true)"
    if [ "$_d_rc" = "0" ] && [ "${_d_a:-0}" = "2" ] && [ "${_d_b:-0}" = "1" ]; then
        pass "D-sh-change: changed PID set re-prints the block (12345 x2, 67890 x1)"
    else
        fail "D-sh-change: want rc=0, 'PID 12345' twice, 'PID 67890' once" \
            "rc=$_d_rc a=${_d_a:-0} b=${_d_b:-0} err=$(head -n 4 "$TMP/disp-chg.err")"
    fi

    # D-sh-rc-only: MOCK_PGREP_MODE=alive prints nothing yet means running.
    _d_rc=0
    env MOCK_PGREP_MODE=alive WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS=2 \
        bash "$WAIT_SH" > /dev/null 2> "$TMP/disp-sh2.err" || _d_rc=$?
    if [ "$_d_rc" = "1" ] && ! grep -q 'PID ' "$TMP/disp-sh2.err"; then
        pass "D-sh-rc-only: silent mock alive still counts as running (exit 1), no PID line"
    else
        fail "D-sh-rc-only: want rc=1 and no PID line" "rc=$_d_rc err=$(head -n 3 "$TMP/disp-sh2.err")"
    fi
fi

# D-sh-real (Linux/macOS only): a real process named "claude" is listed with its PID.
if [ "$ON_WINDOWS_BASH" = "1" ]; then
    skip "D-sh-real: real pgrep process listing is POSIX-host only (Windows bash)"
elif ! command -v pgrep >/dev/null 2>&1 || [ ! -f "$WAIT_SH" ]; then
    skip "D-sh-real: pgrep or helper unavailable"
else
    cp "$(command -v sleep)" "$TMP/claude"
    "$TMP/claude" 30 &
    _d_pid=$!
    env WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS=1 bash "$WAIT_SH" > /dev/null 2> "$TMP/disp-real.err" || true
    kill "$_d_pid" 2>/dev/null || true
    wait "$_d_pid" 2>/dev/null || true
    if grep -qE "PID $_d_pid( |\$)" "$TMP/disp-real.err"; then
        pass "D-sh-real: real 'claude' process PID $_d_pid listed"
    else
        fail "D-sh-real: PID $_d_pid not listed" "$(head -n 3 "$TMP/disp-real.err")"
    fi
fi
