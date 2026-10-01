# Sourced by tests/install/feature-2284-install-cc-claude-codex-cli.sh inside the
# wait-cc-exit.ps1 case span: pwsh half of Group A (A4-A6, A9-A10); contract in wait-helper.sh.

# ELAPSED is read under set -u; run_wait_ps assigns it only inside its $(...) subshell.
ELAPSED=0

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

    # A10: must use "claude" as the exact process name and (#2476) filter each
    # process through Test-CCWaitTarget (Desktop app shell exclusion).
    if grep -iE 'Get-Process[[:space:]]+-Name' "$WAIT_PS" | grep -qi '"claude"' \
    && grep -q 'Test-CCWaitTarget' "$WAIT_PS"; then
        pass "A10: wait-cc-exit.ps1 uses Get-Process -Name \"claude\" filtered by Test-CCWaitTarget"
    else
        fail "A10: wait-cc-exit.ps1 lacks Get-Process -Name \"claude\" or the Test-CCWaitTarget filter"
    fi
fi
