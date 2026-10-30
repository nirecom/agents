# Sourced by tests/install/feature-2284-install-cc-claude-codex-cli.sh inside the
# wait-cc-exit.ps1 case span: static half of Group A (A9-A10) over the pwsh helper source.
# Executing cases A4-A6 live in tests/install/feature-2284-install-cc-claude-codex-cli.Tests.ps1.

# --- Group A (PowerShell, static) ---

if [ ! -f "$WAIT_PS" ]; then
    fail "A9: install/lib/wait-cc-exit.ps1 does not exist"
    fail "A10: install/lib/wait-cc-exit.ps1 does not exist"
    fail "A11: install/lib/wait-cc-exit.ps1 does not exist"
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
    # #2808: the name is now the -ProcessName parameter (default 'claude'); the claude
    # stage keeps the Test-CCWaitTarget filter.
    if grep -iE 'Get-Process[[:space:]]+-Name' "$WAIT_PS" | grep -qiE '"claude"|\$ProcessName|\$_?[a-z]*[Nn]ame' \
    && grep -qE "ValidateSet\('claude'[[:space:]]*,[[:space:]]*'codex'\)" "$WAIT_PS" \
    && grep -qE "ProcessName[[:space:]]*=[[:space:]]*'claude'" "$WAIT_PS" \
    && grep -q 'Test-CCWaitTarget' "$WAIT_PS"; then
        pass "A10: wait-cc-exit.ps1 takes -ProcessName (ValidateSet claude|codex, default claude) and keeps the Test-CCWaitTarget filter"
    else
        fail "A10: wait-cc-exit.ps1 lacks the -ProcessName ValidateSet('claude','codex') param (default 'claude') or the Test-CCWaitTarget filter"
    fi

    # A11: separate codex seam, distinct from the claude seam; claude-only memo; display names.
    if grep -q 'WAIT_CODEX_PROCESS_OVERRIDE' "$WAIT_PS" \
    && grep -q 'WAIT_CC_PROCESS_OVERRIDE' "$WAIT_PS" \
    && grep -q 'Codex' "$WAIT_PS" && grep -q 'Claude Code' "$WAIT_PS"; then
        pass "A11: wait-cc-exit.ps1 has a separate WAIT_CODEX_PROCESS_OVERRIDE seam and Codex/Claude Code display names"
    else
        fail "A11: wait-cc-exit.ps1 lacks WAIT_CODEX_PROCESS_OVERRIDE or the Codex / Claude Code display names"
    fi
fi
