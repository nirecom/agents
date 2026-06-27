
# ---------------------------------------------------------------------------
# N1: settings.json has 0 occurrences of old path $DOTFILES_DIR/claude-global/hooks/
# ---------------------------------------------------------------------------
echo ""
echo "=== N1: settings.json — old path absent ==="

OLD_COUNT=$(grep -o '\$DOTFILES_DIR/claude-global/hooks/' "$SETTINGS" 2>/dev/null | wc -l || true)
if [ "$OLD_COUNT" -eq 0 ]; then
    pass "N1. settings.json contains 0 occurrences of \$DOTFILES_DIR/claude-global/hooks/"
else
    fail "N1. settings.json still contains $OLD_COUNT occurrence(s) of \$DOTFILES_DIR/claude-global/hooks/ (expected 0)"
fi

# ---------------------------------------------------------------------------
# N2: settings.json has exactly 11 occurrences of $AGENTS_CONFIG_DIR/hooks/
# ---------------------------------------------------------------------------
echo ""
echo "=== N2: settings.json — new path count ==="

NEW_COUNT=$(grep -o '\$AGENTS_CONFIG_DIR/hooks/' "$SETTINGS" 2>/dev/null | wc -l || true)
if [ "$NEW_COUNT" -eq 11 ]; then
    pass "N2. settings.json contains exactly 11 occurrences of \$AGENTS_CONFIG_DIR/hooks/"
else
    fail "N2. settings.json contains $NEW_COUNT occurrence(s) of \$AGENTS_CONFIG_DIR/hooks/ (expected 11)"
fi

# ---------------------------------------------------------------------------
# N3: .profile_common — compat block removed (no BEGIN temporary marker)
# ---------------------------------------------------------------------------
echo ""
echo "=== N3: .profile_common — dotfiles→agents compat block removed ==="

if [ -z "$PROFILE_COMMON" ] || [ ! -f "$PROFILE_COMMON" ]; then
    skip "N3. .profile_common not available (dotfiles repo not adjacent)"
elif grep -qE 'BEGIN temporary: dotfiles.*agents' "$PROFILE_COMMON"; then
    fail "N3. .profile_common still contains 'BEGIN temporary: dotfiles → agents' compat block"
else
    pass "N3. .profile_common no longer contains the dotfiles→agents compat block"
fi

# ---------------------------------------------------------------------------
# N4: .profile_common — no remaining export AGENTS_CONFIG_DIR= line
# ---------------------------------------------------------------------------
echo ""
echo "=== N4: .profile_common — AGENTS_CONFIG_DIR export removed ==="

if [ -z "$PROFILE_COMMON" ] || [ ! -f "$PROFILE_COMMON" ]; then
    skip "N4. .profile_common not available (dotfiles repo not adjacent)"
elif grep -qE '^[[:space:]]*export[[:space:]]+AGENTS_CONFIG_DIR=' "$PROFILE_COMMON"; then
    fail "N4. .profile_common still defines 'export AGENTS_CONFIG_DIR=' (compat block not removed)"
else
    pass "N4. .profile_common no longer defines export AGENTS_CONFIG_DIR="
fi

# ---------------------------------------------------------------------------
# N5: profile.ps1 — compat block removed (no BEGIN temporary marker)
# ---------------------------------------------------------------------------
echo ""
echo "=== N5: profile.ps1 — dotfiles→agents compat block removed ==="

if [ -z "$PROFILE_PS1" ] || [ ! -f "$PROFILE_PS1" ]; then
    skip "N5. profile.ps1 not available (dotfiles repo not adjacent)"
elif grep -qE 'BEGIN temporary: dotfiles.*agents' "$PROFILE_PS1"; then
    fail "N5. profile.ps1 still contains 'BEGIN temporary: dotfiles → agents' compat block"
else
    pass "N5. profile.ps1 no longer contains the dotfiles→agents compat block"
fi

# ---------------------------------------------------------------------------
# N6: profile.ps1 — no remaining $env:AGENTS_CONFIG_DIR assignment
# ---------------------------------------------------------------------------
echo ""
echo "=== N6: profile.ps1 — \$env:AGENTS_CONFIG_DIR removed ==="

if [ -z "$PROFILE_PS1" ] || [ ! -f "$PROFILE_PS1" ]; then
    skip "N6. profile.ps1 not available (dotfiles repo not adjacent)"
elif grep -qE '\$env:AGENTS_CONFIG_DIR' "$PROFILE_PS1"; then
    fail "N6. profile.ps1 still references \$env:AGENTS_CONFIG_DIR (compat block not removed)"
else
    pass "N6. profile.ps1 no longer references \$env:AGENTS_CONFIG_DIR"
fi

# ---------------------------------------------------------------------------
# E1: .profile_common uses sibling detection + sources profile-snippet.sh
# ---------------------------------------------------------------------------
echo ""
echo "=== E1: .profile_common — sibling detection + sources profile-snippet.sh ==="

if [ -z "$PROFILE_COMMON" ] || [ ! -f "$PROFILE_COMMON" ]; then
    skip "E1. .profile_common not available (dotfiles repo not adjacent)"
elif grep -qE '_agents_dir=' "$PROFILE_COMMON" \
        && grep -qE '(\.\s+|source\s+).*profile-snippet\.sh' "$PROFILE_COMMON"; then
    pass "E1. .profile_common uses sibling detection and sources profile-snippet.sh"
else
    fail "E1. .profile_common does not use sibling detection + profile-snippet.sh sourcing (Option B)"
fi

# ---------------------------------------------------------------------------
# E2: profile.ps1 uses sibling detection + sources profile-snippet.ps1
# ---------------------------------------------------------------------------
echo ""
echo "=== E2: profile.ps1 — sibling detection + sources profile-snippet.ps1 ==="

if [ -z "$PROFILE_PS1" ] || [ ! -f "$PROFILE_PS1" ]; then
    skip "E2. profile.ps1 not available (dotfiles repo not adjacent)"
elif grep -qE 'AgentsDir.*=.*Split-Path.*DotfilesDir' "$PROFILE_PS1" \
        && grep -qE 'Test-Path.*AgentsDir.*profile-snippet\.ps1' "$PROFILE_PS1"; then
    pass "E2. profile.ps1 uses sibling detection (AgentsDir) and references profile-snippet.ps1"
else
    fail "E2. profile.ps1 does not use sibling detection + profile-snippet.ps1 sourcing (Option B)"
fi

# ---------------------------------------------------------------------------
# E3: settings.json is valid JSON
# ---------------------------------------------------------------------------
echo ""
echo "=== E3: settings.json — valid JSON ==="

if node -e "JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'))" -- "$SETTINGS" 2>/dev/null; then
    pass "E3. settings.json is valid JSON"
else
    fail "E3. settings.json failed JSON parse"
fi

# ---------------------------------------------------------------------------
# N7: pre-commit uses AGENTS_CONFIG_DIR to locate scanner (no old DOTFILES_DIR path)
# ---------------------------------------------------------------------------
echo ""
echo "=== N7: pre-commit — scanner path uses AGENTS_CONFIG_DIR ==="

PRE_COMMIT="$AGENTS_ROOT/hooks/pre-commit"
if [ ! -f "$PRE_COMMIT" ]; then
    fail "N7. pre-commit not found at $PRE_COMMIT"
elif grep -q 'SCANNER=.*_cfg_dir.*bin/scan-outbound' "$PRE_COMMIT"; then
    pass "N7. pre-commit locates scan-outbound.sh via _cfg_dir relative to hook location"
else
    fail "N7. pre-commit does not locate scan-outbound.sh via _cfg_dir"
fi

# ---------------------------------------------------------------------------
# N8: commit-msg uses AGENTS_CONFIG_DIR to locate scanner
# ---------------------------------------------------------------------------
echo ""
echo "=== N8: commit-msg — scanner path uses AGENTS_CONFIG_DIR ==="

COMMIT_MSG="$AGENTS_ROOT/hooks/commit-msg"
if [ ! -f "$COMMIT_MSG" ]; then
    fail "N8. commit-msg not found at $COMMIT_MSG"
elif grep -q 'SCANNER=.*_cfg_dir.*bin/scan-outbound' "$COMMIT_MSG"; then
    pass "N8. commit-msg locates scan-outbound.sh via _cfg_dir relative to hook location"
else
    fail "N8. commit-msg does not locate scan-outbound.sh via _cfg_dir"
fi

# ---------------------------------------------------------------------------
# N9: scan-outbound.sh uses DOTFILES_PRIVATE_DIR optional fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N9: scan-outbound.sh — dotfiles-private uses DOTFILES_PRIVATE_DIR fallback ==="

SCAN_OUTBOUND="$AGENTS_ROOT/bin/scan-outbound.sh"
if [ ! -f "$SCAN_OUTBOUND" ]; then
    fail "N9. scan-outbound.sh not found at $SCAN_OUTBOUND"
elif grep -q 'DOTFILES_PRIVATE_DIR:-' "$SCAN_OUTBOUND"; then
    pass "N9. scan-outbound.sh uses \${DOTFILES_PRIVATE_DIR:-...} fallback for private allowlist"
else
    fail "N9. scan-outbound.sh does not use DOTFILES_PRIVATE_DIR fallback"
fi

# ---------------------------------------------------------------------------
# N10: .profile_common session-sync uses AGENTS_DIR fallback
# ---------------------------------------------------------------------------
echo ""
echo "=== N10: .profile_common — session-sync uses AGENTS_DIR ==="

if [ -z "$PROFILE_COMMON" ] || [ ! -f "$PROFILE_COMMON" ]; then
    skip "N10. .profile_common not available (dotfiles repo not adjacent)"
elif grep -q 'AGENTS_DIR.*DOTFILES_DIR.*bin/session-sync' "$PROFILE_COMMON"; then
    pass "N10. .profile_common session-sync uses \${AGENTS_DIR:-\$DOTFILES_DIR}/bin/session-sync.sh"
else
    fail "N10. .profile_common session-sync does not use AGENTS_DIR fallback"
fi
