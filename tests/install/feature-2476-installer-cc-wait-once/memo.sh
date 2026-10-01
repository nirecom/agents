# Sourced by tests/install/feature-2476-installer-cc-wait-once.sh.
# WAIT_CC_RESULT memo contract (POSIX helper here; the pwsh helper is in the .Tests.ps1):
#   clear -> exit 0 at once, silent; timeout -> exit 1 at once, silent;
#   unset/empty -> poll as before; any other value (case-sensitive) -> one
#   "Ignoring invalid WAIT_CC_RESULT" diagnostic, then poll.
# The process probe is set to contradict the memo so only a honored memo passes.

# _memo_sh <memo|-> <mock-mode> <max-polls>  -> MEMO_RC, MEMO_OUT, MEMO_SECS
_memo_sh() {
    local memo="$1" mode="$2" polls="$3" start=$SECONDS
    MEMO_RC=0
    if [ "$memo" = "-" ]; then
        env -u WAIT_CC_RESULT MOCK_PGREP_MODE="$mode" WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS="$polls" \
            bash "$WAIT_SH" > "$TMP/memo-sh.out" 2>&1 || MEMO_RC=$?
    else
        env WAIT_CC_RESULT="$memo" MOCK_PGREP_MODE="$mode" WAIT_CC_POLL_INTERVAL=1 WAIT_CC_MAX_POLLS="$polls" \
            bash "$WAIT_SH" > "$TMP/memo-sh.out" 2>&1 || MEMO_RC=$?
    fi
    MEMO_SECS=$((SECONDS - start))
    MEMO_OUT="$(cat "$TMP/memo-sh.out")"
}

_memo_has_poll() { printf '%s' "$MEMO_OUT" | grep -q 'poll [0-9]'; }
_memo_has_diag() { printf '%s' "$MEMO_OUT" | grep -q "Ignoring invalid WAIT_CC_RESULT.*$1"; }
# Exactly one diagnostic per run (not one per poll).
_memo_diag_once() { [ "$(printf '%s\n' "$MEMO_OUT" | grep -c "Ignoring invalid WAIT_CC_RESULT.*$1")" = "1" ]; }

# --- POSIX helper ---
if [ ! -f "$WAIT_SH" ]; then
    fail "M-sh: install/lib/wait-cc-exit.sh does not exist"
else
    _memo_sh clear alive 3
    if [ "$MEMO_RC" = "0" ] && [ "$MEMO_SECS" -lt 2 ] && ! _memo_has_poll && [ -z "$MEMO_OUT" ]; then
        pass "M-sh-clear: clear + CC alive -> exit 0 at once, silent"
    else
        fail "M-sh-clear: want rc=0 <2s silent" "rc=$MEMO_RC ${MEMO_SECS}s out=$(printf '%s' "$MEMO_OUT" | head -n 2)"
    fi

    _memo_sh timeout absent 3
    if [ "$MEMO_RC" = "1" ] && ! _memo_has_poll && [ -z "$MEMO_OUT" ]; then
        pass "M-sh-timeout: timeout + CC absent -> exit 1 at once, silent"
    else
        fail "M-sh-timeout: want rc=1 silent" "rc=$MEMO_RC out=$(printf '%s' "$MEMO_OUT" | head -n 2)"
    fi

    _memo_sh - absent 3
    if [ "$MEMO_RC" = "0" ] && ! _memo_has_diag ""; then
        pass "M-sh-unset: unset + CC absent -> exit 0 (unchanged polling path)"
    else
        fail "M-sh-unset: want rc=0 no diagnostic" "rc=$MEMO_RC out=$(printf '%s' "$MEMO_OUT" | head -n 2)"
    fi

    _memo_sh "" absent 3
    if [ "$MEMO_RC" = "0" ] && ! _memo_has_diag ""; then
        pass "M-sh-empty: empty + CC absent -> exit 0, no diagnostic"
    else
        fail "M-sh-empty: want rc=0 no diagnostic" "rc=$MEMO_RC out=$(printf '%s' "$MEMO_OUT" | head -n 2)"
    fi

    _memo_sh "" alive 1
    if [ "$MEMO_RC" = "1" ] && _memo_has_poll && ! _memo_has_diag ""; then
        pass "M-sh-empty-alive: empty + CC alive -> polls, exit 1, no diagnostic"
    else
        fail "M-sh-empty-alive: want rc=1, poll line, no diagnostic" "rc=$MEMO_RC out=$(printf '%s' "$MEMO_OUT" | head -n 2)"
    fi

    _memo_sh CLEAR alive 1
    if [ "$MEMO_RC" = "1" ] && _memo_diag_once CLEAR; then
        pass "M-sh-invalid-upper: CLEAR (case-sensitive) + CC alive -> diagnostic, polls, exit 1"
    else
        fail "M-sh-invalid-upper: want diagnostic + rc=1" "rc=$MEMO_RC out=$(printf '%s' "$MEMO_OUT" | head -n 2)"
    fi

    _memo_sh yes absent 3
    if [ "$MEMO_RC" = "0" ] && _memo_diag_once yes; then
        pass "M-sh-invalid-yes: yes + CC absent -> diagnostic, polls, exit 0"
    else
        fail "M-sh-invalid-yes: want diagnostic + rc=0" "rc=$MEMO_RC out=$(printf '%s' "$MEMO_OUT" | head -n 2)"
    fi
fi
# wait-cc-exit.ps1 memo cases (M-ps-*): tests/install/feature-2476-installer-cc-wait-once.Tests.ps1.
