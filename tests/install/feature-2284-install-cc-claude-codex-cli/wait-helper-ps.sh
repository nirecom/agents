# Sourced by tests/install/feature-2284-install-cc-claude-codex-cli.sh inside the
# wait-cc-exit.ps1 case span: static half of Group A (A9-A10) over the pwsh helper source.
# Executing cases A4-A6 live in tests/install/feature-2284-install-cc-claude-codex-cli.Tests.ps1.

# --- Group A (PowerShell, static) ---

if [ ! -f "$WAIT_PS" ]; then
    fail "A9: install/lib/wait-cc-exit.ps1 does not exist"
    fail "A10: install/lib/wait-cc-exit.ps1 does not exist"
else
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
