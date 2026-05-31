#!/bin/bash
# Tests: agents/install/linux/dotfileslink.sh, agents/install/win/dotfileslink.ps1, agents/profile-snippet.ps1, agents/profile-snippet.sh, bin/scan-outbound, bin/scan-outbound.sh, bin/session-sync, bin/session-sync.sh, bin/split-history.py, hooks/commit-msg, hooks/pre-commit
# Tags: agents-repo-split
# Smoke tests for agents repo split (steps 2, 8, 16).
# Verifies: settings.json hook path uses $AGENTS_CONFIG_DIR/hooks/,
#           dotfiles → agents compat blocks removed,
#           .agents_profile sourcing added on both shells,
#           dotfileslink scripts write profile snippet with AGENTS_CONFIG_DIR
#           and CLAUDE.md/settings.json symlink repair logic.
set -euo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
DOTFILES_ROOT=""
if [ -d "$AGENTS_ROOT/../dotfiles" ]; then
    DOTFILES_ROOT="$(cd "$AGENTS_ROOT/../dotfiles" && pwd)"
fi
SETTINGS="$AGENTS_ROOT/settings.json"
PROFILE_COMMON="${DOTFILES_ROOT:+$DOTFILES_ROOT/.profile_common}"
PROFILE_PS1="${DOTFILES_ROOT:+$DOTFILES_ROOT/install/win/profile.ps1}"
ERRORS=0
SKIPS=0
PASSES=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; PASSES=$((PASSES + 1)); }
skip() { echo "SKIP: $1"; SKIPS=$((SKIPS + 1)); }

# Only the agents-side settings.json is mandatory.
if [ ! -f "$SETTINGS" ]; then
    echo "FATAL: required file not found: $SETTINGS"
    exit 2
fi

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

# ===========================================================================
# Step 16 — additional tests for ~/.agents_profile sourcing and
# dotfileslink snippet content
# ===========================================================================

# ---------------------------------------------------------------------------
# N18: .profile_common uses sibling detection + sources profile-snippet.sh (Normal)
# ---------------------------------------------------------------------------
echo ""
echo "=== N18: .profile_common — sibling detection + sources profile-snippet.sh (non-comment) ==="

if [ -z "$PROFILE_COMMON" ] || [ ! -f "$PROFILE_COMMON" ]; then
    skip "N18. .profile_common not available (dotfiles repo not adjacent)"
elif grep -qE '_agents_dir=' "$PROFILE_COMMON" \
        && grep -qE '(\.\s+|source\s+).*profile-snippet\.sh' "$PROFILE_COMMON"; then
    pass "N18. .profile_common uses sibling detection and sources profile-snippet.sh"
else
    fail "N18. .profile_common does not use sibling detection + profile-snippet.sh (Option B)"
fi

# ---------------------------------------------------------------------------
# N19: profile.ps1 uses sibling detection + sources profile-snippet.ps1 (Normal)
# ---------------------------------------------------------------------------
echo ""
echo "=== N19: profile.ps1 — sibling detection + sources profile-snippet.ps1 ==="

if [ -z "$PROFILE_PS1" ] || [ ! -f "$PROFILE_PS1" ]; then
    skip "N19. profile.ps1 not available (dotfiles repo not adjacent)"
elif grep -qE 'AgentsDir.*=.*Split-Path.*DotfilesDir' "$PROFILE_PS1" \
        && grep -qE 'Test-Path.*AgentsDir.*profile-snippet\.ps1' "$PROFILE_PS1"; then
    pass "N19. profile.ps1 uses sibling detection (AgentsDir) and references profile-snippet.ps1"
else
    fail "N19. profile.ps1 does not use sibling detection + profile-snippet.ps1 (Option B)"
fi

# ---------------------------------------------------------------------------
# N20: profile.ps1 $symlinkFiles array does NOT contain CLAUDE.md (Edge)
# ---------------------------------------------------------------------------
echo ""
echo "=== N20: profile.ps1 — \$symlinkFiles array no longer lists CLAUDE.md ==="

if [ -z "$PROFILE_PS1" ] || [ ! -f "$PROFILE_PS1" ]; then
    skip "N20. profile.ps1 not available (dotfiles repo not adjacent)"
else
    sym_line=$(grep -nE '^\$symlinkFiles[[:space:]]*=' "$PROFILE_PS1" | head -1 || true)
    if [ -z "$sym_line" ]; then
        fail "N20. could not find \$symlinkFiles = ... in profile.ps1"
    else
        line_num="${sym_line%%:*}"
        line_content=$(sed -n "${line_num}p" "$PROFILE_PS1")
        if echo "$line_content" | grep -q 'CLAUDE\.md'; then
            fail "N20. \$symlinkFiles array still contains CLAUDE.md (line $line_num)"
        else
            pass "N20. \$symlinkFiles array does not contain CLAUDE.md"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# N21: profile.ps1 $symlinkFiles array does NOT contain settings.json (Edge)
# ---------------------------------------------------------------------------
echo ""
echo "=== N21: profile.ps1 — \$symlinkFiles array no longer lists settings.json ==="

if [ -z "$PROFILE_PS1" ] || [ ! -f "$PROFILE_PS1" ]; then
    skip "N21. profile.ps1 not available (dotfiles repo not adjacent)"
else
    sym_line=$(grep -nE '^\$symlinkFiles[[:space:]]*=' "$PROFILE_PS1" | head -1 || true)
    if [ -z "$sym_line" ]; then
        fail "N21. could not find \$symlinkFiles = ... in profile.ps1"
    else
        line_num="${sym_line%%:*}"
        line_content=$(sed -n "${line_num}p" "$PROFILE_PS1")
        if echo "$line_content" | grep -q 'settings\.json'; then
            fail "N21. \$symlinkFiles array still contains settings.json (line $line_num)"
        else
            pass "N21. \$symlinkFiles array does not contain settings.json"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# N22: agents dotfileslink.ps1 does NOT generate ~/.agents_profile.ps1 (Option B)
# ---------------------------------------------------------------------------
echo ""
echo "=== N22: agents/install/win/dotfileslink.ps1 — no ~/.agents_profile.ps1 generation ==="

DOTFILESLINK_PS1="$AGENTS_ROOT/install/win/dotfileslink.ps1"
if [ ! -f "$DOTFILESLINK_PS1" ]; then
    fail "N22. dotfileslink.ps1 not found at $DOTFILESLINK_PS1"
elif grep -q 'agents_profile\.ps1' "$DOTFILESLINK_PS1"; then
    fail "N22. dotfileslink.ps1 still generates ~/.agents_profile.ps1 (should be removed in Option B)"
else
    pass "N22. dotfileslink.ps1 does not generate ~/.agents_profile.ps1"
fi

# ---------------------------------------------------------------------------
# N23: agents/profile-snippet.ps1 static file exists with correct content (Option B)
# ---------------------------------------------------------------------------
echo ""
echo "=== N23: agents/profile-snippet.ps1 — static file exists with correct content ==="

SNIPPET_PS1="$AGENTS_ROOT/profile-snippet.ps1"
if [ ! -f "$SNIPPET_PS1" ]; then
    fail "N23. profile-snippet.ps1 not found at $SNIPPET_PS1 (should be committed as static file)"
else
    _n23_ok=1
    # Must use $PSScriptRoot (not hardcoded path)
    if ! grep -q 'PSScriptRoot' "$SNIPPET_PS1"; then
        fail "N23a. profile-snippet.ps1 does not use \$PSScriptRoot (hardcoded path risk)"
        _n23_ok=0
    fi
    # Must set AGENTS_CONFIG_DIR
    if ! grep -q 'AGENTS_CONFIG_DIR' "$SNIPPET_PS1"; then
        fail "N23b. profile-snippet.ps1 does not set AGENTS_CONFIG_DIR"
        _n23_ok=0
    fi
    # Must reference CLAUDE.md (repair logic)
    if ! grep -q 'CLAUDE\.md' "$SNIPPET_PS1"; then
        fail "N23c. profile-snippet.ps1 missing CLAUDE.md repair logic"
        _n23_ok=0
    fi
    # Must NOT reference settings.json in watchlist (#685)
    if grep -qE '\$HOME[/\\]\.claude[/\\]settings\.json' "$SNIPPET_PS1"; then
        fail "N23d. profile-snippet.ps1 must not watch settings.json"
        _n23_ok=0
    fi
    if [ "$_n23_ok" -eq 1 ]; then
        pass "N23. profile-snippet.ps1 exists with PSScriptRoot, AGENTS_CONFIG_DIR, and repair logic"
    fi
fi

# ---------------------------------------------------------------------------
# N24: agents dotfileslink.sh does NOT generate ~/.agents_profile (Option B)
# ---------------------------------------------------------------------------
echo ""
echo "=== N24: agents/install/linux/dotfileslink.sh — no ~/.agents_profile generation ==="

DOTFILESLINK_SH="$AGENTS_ROOT/install/linux/dotfileslink.sh"
if [ ! -f "$DOTFILESLINK_SH" ]; then
    fail "N24. dotfileslink.sh not found at $DOTFILESLINK_SH"
elif grep -q 'PROFILE_SNIPPET=.*agents_profile' "$DOTFILESLINK_SH" \
        || grep -qE "cat\s*>\s*\\\$HOME/\.agents_profile" "$DOTFILESLINK_SH" \
        || grep -qE 'agents_profile[^_]' "$DOTFILESLINK_SH"; then
    fail "N24. dotfileslink.sh still generates ~/.agents_profile (should be removed in Option B)"
else
    pass "N24. dotfileslink.sh does not generate ~/.agents_profile"
fi

# ---------------------------------------------------------------------------
# N25: agents/profile-snippet.sh static file exists with correct content (Option B)
# ---------------------------------------------------------------------------
echo ""
echo "=== N25: agents/profile-snippet.sh — static file exists with correct content ==="

SNIPPET_SH="$AGENTS_ROOT/profile-snippet.sh"
if [ ! -f "$SNIPPET_SH" ]; then
    fail "N25. profile-snippet.sh not found at $SNIPPET_SH (should be committed as static file)"
else
    _n25_ok=1
    # Must use BASH_SOURCE (not hardcoded path)
    if ! grep -q 'BASH_SOURCE' "$SNIPPET_SH"; then
        fail "N25a. profile-snippet.sh does not use BASH_SOURCE (hardcoded path risk)"
        _n25_ok=0
    fi
    # Must export AGENTS_CONFIG_DIR
    if ! grep -qE 'export\s+AGENTS_CONFIG_DIR' "$SNIPPET_SH"; then
        fail "N25b. profile-snippet.sh does not export AGENTS_CONFIG_DIR"
        _n25_ok=0
    fi
    # Must reference CLAUDE.md (repair logic)
    if ! grep -q 'CLAUDE\.md' "$SNIPPET_SH"; then
        fail "N25c. profile-snippet.sh missing CLAUDE.md repair logic"
        _n25_ok=0
    fi
    # Must NOT reference settings.json in watchlist (#685)
    if grep -qE '\$HOME/\.claude/settings\.json' "$SNIPPET_SH"; then
        fail "N25d. profile-snippet.sh must not watch settings.json"
        _n25_ok=0
    fi
    if [ "$_n25_ok" -eq 1 ]; then
        pass "N25. profile-snippet.sh exists with BASH_SOURCE, AGENTS_CONFIG_DIR export, CLAUDE.md repair, and no settings.json watch"
    fi
fi

# ---------------------------------------------------------------------------
# N29: profile-snippet.sh watchlist contains only CLAUDE.md (not settings.json)
# ---------------------------------------------------------------------------
echo ""
echo "=== N29: profile-snippet.sh — watchlist has CLAUDE.md only, not settings.json ==="

if [ ! -f "$SNIPPET_SH" ]; then
    skip "N29. profile-snippet.sh not found"
else
    _n29_line="$(grep -nE '^for[[:space:]]+_f[[:space:]]+in' "$SNIPPET_SH" | head -1)"
    if [ -z "$_n29_line" ]; then
        fail "N29. profile-snippet.sh has no 'for _f in' watchlist line"
    else
        if ! echo "$_n29_line" | grep -q 'CLAUDE\.md'; then
            fail "N29a. watchlist line does not contain CLAUDE.md"
        elif echo "$_n29_line" | grep -q 'settings\.json'; then
            fail "N29b. watchlist line still contains settings.json (should have been removed)"
        else
            pass "N29. profile-snippet.sh watchlist contains CLAUDE.md and not settings.json"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# N30: dotfileslink.sh has MSYS=winsymlinks:nativestrict export
# ---------------------------------------------------------------------------
echo ""
echo "=== N30: dotfileslink.sh — exports MSYS=winsymlinks:nativestrict ==="

if [ ! -f "$DOTFILESLINK_SH" ]; then
    skip "N30. dotfileslink.sh not found"
elif grep -qE 'export[[:space:]]+MSYS=winsymlinks:nativestrict' "$DOTFILESLINK_SH"; then
    pass "N30. dotfileslink.sh exports MSYS=winsymlinks:nativestrict"
else
    fail "N30. dotfileslink.sh missing: export MSYS=winsymlinks:nativestrict"
fi

# ---------------------------------------------------------------------------
# N31: dotfileslink.sh has _dl_is_windows variable assignment
# ---------------------------------------------------------------------------
echo ""
echo "=== N31: dotfileslink.sh — has _dl_is_windows platform detection variable ==="

if [ ! -f "$DOTFILESLINK_SH" ]; then
    skip "N31. dotfileslink.sh not found"
elif grep -qE '_dl_is_windows[[:space:]]*=' "$DOTFILESLINK_SH"; then
    pass "N31. dotfileslink.sh has _dl_is_windows assignment"
else
    fail "N31. dotfileslink.sh missing _dl_is_windows platform detection variable"
fi

# ---------------------------------------------------------------------------
# N32: dotfileslink.sh has no bare ln -snf to ~/.claude/ (replaced by _link_one)
# ---------------------------------------------------------------------------
echo ""
echo "=== N32: dotfileslink.sh — no bare ln -snf for ~/.claude/ directories ==="

if [ ! -f "$DOTFILESLINK_SH" ]; then
    skip "N32. dotfileslink.sh not found"
elif grep -qE 'ln -snf[[:space:]].*~/\.claude/' "$DOTFILESLINK_SH"; then
    fail "N32. dotfileslink.sh still has bare ln -snf to ~/.claude/ (should use _link_one)"
else
    pass "N32. dotfileslink.sh has no bare ln -snf to ~/.claude/"
fi

# ---------------------------------------------------------------------------
# N33: dotfileslink.sh has _link_one() function definition
# ---------------------------------------------------------------------------
echo ""
echo "=== N33: dotfileslink.sh — has _link_one() function definition ==="

if [ ! -f "$DOTFILESLINK_SH" ]; then
    skip "N33. dotfileslink.sh not found"
elif grep -qE '^_link_one\(\)' "$DOTFILESLINK_SH"; then
    pass "N33. dotfileslink.sh has _link_one() function"
else
    fail "N33. dotfileslink.sh missing _link_one() function definition"
fi

# ---------------------------------------------------------------------------
# N34: dotfileslink.sh backs up fake-file CLAUDE.md and replaces with symlink
# ---------------------------------------------------------------------------
echo ""
echo "=== N34: dotfileslink.sh — fake-file CLAUDE.md is backed up and replaced with symlink ==="

if [ ! -f "$DOTFILESLINK_SH" ]; then
    skip "N34. dotfileslink.sh not found"
elif ! command -v node >/dev/null 2>&1; then
    skip "N34. node not available (needed by dotfileslink.sh)"
else
    _n34_td="$(mktemp -d)"
    _n34_ok=1
    mkdir -p "$_n34_td/home/.claude"
    printf 'fake content\n' > "$_n34_td/home/.claude/CLAUDE.md"
    HOME="$_n34_td/home" bash "$DOTFILESLINK_SH" >/dev/null 2>&1 || true
    if [ ! -f "$_n34_td/home/.claude/CLAUDE.md.bak" ]; then
        fail "N34a. dotfileslink.sh did not create CLAUDE.md.bak for fake-file"
        _n34_ok=0
    fi
    if [ ! -L "$_n34_td/home/.claude/CLAUDE.md" ]; then
        fail "N34b. dotfileslink.sh did not replace fake-file CLAUDE.md with a symlink"
        _n34_ok=0
    fi
    rm -rf "$_n34_td"
    if [ "$_n34_ok" -eq 1 ]; then
        pass "N34. dotfileslink.sh backed up fake CLAUDE.md and created symlink"
    fi
fi

# ---------------------------------------------------------------------------
# N35: MSYS export is inside the _dl_is_windows=1 conditional block
# ---------------------------------------------------------------------------
echo ""
echo "=== N35: dotfileslink.sh — MSYS export is inside _dl_is_windows=1 block ==="

if [ ! -f "$DOTFILESLINK_SH" ]; then
    skip "N35. dotfileslink.sh not found"
else
    # Extract the content between 'if [ "$_dl_is_windows" = "1" ]' and its closing 'fi'
    _n35_block="$(awk '/if \[ "\$_dl_is_windows" = "1" \]/{found=1} found{print} found && /^fi$/{exit}' "$DOTFILESLINK_SH")"
    if echo "$_n35_block" | grep -q 'export MSYS=winsymlinks:nativestrict'; then
        pass "N35. MSYS export is inside _dl_is_windows=1 conditional block"
    else
        fail "N35. MSYS export is NOT inside _dl_is_windows=1 conditional block (or block not found)"
    fi
fi

# ---------------------------------------------------------------------------
# N26: profile.ps1 has no literal C:\git\agents hardcoded path
# ---------------------------------------------------------------------------
echo ""
echo "=== N26: profile.ps1 — no hardcoded C:\\git\\agents literal ==="

if [ -z "$PROFILE_PS1" ] || [ ! -f "$PROFILE_PS1" ]; then
    skip "N26. profile.ps1 not available (dotfiles repo not adjacent)"
elif grep -qF 'C:\git\agents' "$PROFILE_PS1" 2>/dev/null; then
    fail "N26. profile.ps1 still contains hardcoded 'C:\\git\\agents' literal"
else
    pass "N26. profile.ps1 contains no hardcoded 'C:\\git\\agents' literal"
fi

# ---------------------------------------------------------------------------
# N27: install.sh idempotent rc-append (BEGIN agents profile sourcing marker once)
# NOTE: install.sh does not yet have rc-append logic — FAIL expected until implemented
# ---------------------------------------------------------------------------
echo ""
echo "=== N27: install.sh — idempotent rc-append (marker appears exactly once) ==="

INSTALL_SH="$AGENTS_ROOT/install.sh"
if [ ! -f "$INSTALL_SH" ]; then
    fail "N27. install.sh not found at $INSTALL_SH"
else
    _n27_td=$(mktemp -d)
    trap 'rm -rf "$_n27_td"' EXIT

    # Set up fake agents root and fake home
    _n27_fake_home="$_n27_td/home"
    _n27_fake_bashrc="$_n27_fake_home/.bashrc"
    mkdir -p "$_n27_fake_home"
    touch "$_n27_fake_bashrc"

    # Run install.sh twice in a subshell with fake HOME and AGENTS_ROOT
    (export HOME="$_n27_fake_home"; export AGENTS_ROOT="$AGENTS_ROOT"; bash "$INSTALL_SH" >/dev/null 2>&1 || true)
    (export HOME="$_n27_fake_home"; export AGENTS_ROOT="$AGENTS_ROOT"; bash "$INSTALL_SH" >/dev/null 2>&1 || true)

    _n27_marker_count=$(grep -c 'BEGIN agents profile sourcing' "$_n27_fake_bashrc" 2>/dev/null; true)
    _n27_marker_count="${_n27_marker_count:-0}"

    trap - EXIT
    rm -rf "$_n27_td"

    if [ "$_n27_marker_count" -eq 1 ]; then
        pass "N27. install.sh rc-append is idempotent (marker appears exactly once)"
    elif [ "$_n27_marker_count" -eq 0 ]; then
        fail "N27. install.sh did not append BEGIN agents profile sourcing marker to ~/.bashrc"
    else
        fail "N27. install.sh appended marker $_n27_marker_count times (not idempotent)"
    fi
fi

# ---------------------------------------------------------------------------
# N28: install.ps1 contains idempotent marker logic (static check)
# NOTE: install.ps1 does not yet have this logic — FAIL expected until implemented
# ---------------------------------------------------------------------------
echo ""
echo "=== N28: install.ps1 — contains BEGIN agents profile sourcing marker logic ==="

INSTALL_PS1="$AGENTS_ROOT/install.ps1"
if [ ! -f "$INSTALL_PS1" ]; then
    fail "N28. install.ps1 not found at $INSTALL_PS1"
elif grep -q 'BEGIN agents profile sourcing' "$INSTALL_PS1"; then
    pass "N28. install.ps1 contains BEGIN agents profile sourcing marker logic"
else
    fail "N28. install.ps1 missing idempotent 'BEGIN agents profile sourcing' marker logic"
fi

# ===========================================================================
# E2E tests (E2E-1 through E2E-6) — isolation via temp repos
# ===========================================================================

# ---------------------------------------------------------------------------
# E2E-1: bash / agents only (dotfiles absent) — AGENTS_CONFIG_DIR set by profile-snippet.sh
# NOTE: Requires profile-snippet.sh to exist — FAIL expected until file is created
# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-1: bash / agents only — AGENTS_CONFIG_DIR set by profile-snippet.sh ==="

if [ ! -f "$SNIPPET_SH" ]; then
    skip "E2E-1. profile-snippet.sh not found (will be created in source code step)"
else
    _e2e1_td=$(mktemp -d)
    trap 'rm -rf "$_e2e1_td"' EXIT

    # Build isolated agents repo with the real snippet
    _e2e1_agents="$_e2e1_td/agents"
    mkdir -p "$_e2e1_agents"
    cp "$SNIPPET_SH" "$_e2e1_agents/profile-snippet.sh"

    # Clean check: dotfiles must NOT exist
    if [ -d "$_e2e1_td/dotfiles" ]; then
        skip "E2E-1. unexpected dotfiles dir in temp root — skipping to avoid false result"
        trap - EXIT; rm -rf "$_e2e1_td"
    else
        _e2e1_result=$(HOME="$_e2e1_td/home" bash --norc --noprofile -c "
            source '$_e2e1_agents/profile-snippet.sh' 2>/dev/null
            echo \"\$AGENTS_CONFIG_DIR\"
        " 2>/dev/null | tail -1 || true)

        trap - EXIT
        rm -rf "$_e2e1_td"

        if [ "$_e2e1_result" = "$_e2e1_agents" ]; then
            pass "E2E-1. sourcing profile-snippet.sh sets AGENTS_CONFIG_DIR to agents dir"
        else
            fail "E2E-1. expected AGENTS_CONFIG_DIR='$_e2e1_agents', got '$_e2e1_result'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# E2E-2: bash / dotfiles only (agents absent) — sibling detection safe (no error)
# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-2: bash / dotfiles only — sibling detection safe when agents absent ==="

_e2e2_td=$(mktemp -d)
trap 'rm -rf "$_e2e2_td"' EXIT

_e2e2_dotfiles="$_e2e2_td/dotfiles"
mkdir -p "$_e2e2_dotfiles"

# Clean check: agents must NOT exist
if [ -d "$_e2e2_td/agents" ]; then
    skip "E2E-2. unexpected agents dir in temp root — skipping to avoid false result"
    trap - EXIT; rm -rf "$_e2e2_td"
else
    # Minimal sibling detection script (Option B pattern — dotfiles only, no agents)
    _e2e2_script='
_agents_dir="$(dirname "$_dotfiles_dir")/agents"
if [ -f "$_agents_dir/profile-snippet.sh" ]; then
    . "$_agents_dir/profile-snippet.sh"
fi
echo "${AGENTS_CONFIG_DIR:-UNSET}"
'
    _e2e2_result=$(env -u AGENTS_CONFIG_DIR bash -c "
        _dotfiles_dir='$_e2e2_dotfiles'
        $_e2e2_script
    " 2>/dev/null || true)

    trap - EXIT
    rm -rf "$_e2e2_td"

    if [ "$_e2e2_result" = "UNSET" ]; then
        pass "E2E-2. no error and AGENTS_CONFIG_DIR unset when agents absent"
    else
        fail "E2E-2. expected AGENTS_CONFIG_DIR=UNSET, got '$_e2e2_result'"
    fi
fi

# ---------------------------------------------------------------------------
# E2E-3: bash / dotfiles + agents — sibling detection sets AGENTS_CONFIG_DIR
# NOTE: Requires profile-snippet.sh to exist — FAIL expected until file is created
# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-3: bash / dotfiles + agents — sibling detection sets AGENTS_CONFIG_DIR ==="

if [ ! -f "$SNIPPET_SH" ]; then
    skip "E2E-3. profile-snippet.sh not found (will be created in source code step)"
else
    _e2e3_td=$(mktemp -d)
    trap 'rm -rf "$_e2e3_td"' EXIT

    _e2e3_dotfiles="$_e2e3_td/dotfiles"
    _e2e3_agents="$_e2e3_td/agents"
    mkdir -p "$_e2e3_dotfiles" "$_e2e3_agents"
    cp "$SNIPPET_SH" "$_e2e3_agents/profile-snippet.sh"

    # Verify only dotfiles + agents exist (clean check)
    _e2e3_extra=$(ls "$_e2e3_td" | grep -vE '^(dotfiles|agents)$' || true)
    if [ -n "$_e2e3_extra" ]; then
        skip "E2E-3. unexpected dirs in temp root: $_e2e3_extra"
        trap - EXIT; rm -rf "$_e2e3_td"
    else
        _e2e3_result=$(HOME="$_e2e3_td/home" env -u AGENTS_CONFIG_DIR bash --norc --noprofile -c "
            _dotfiles_dir='$_e2e3_dotfiles'
            _agents_dir=\"\$(dirname \"\$_dotfiles_dir\")/agents\"
            if [ -f \"\$_agents_dir/profile-snippet.sh\" ]; then
                source \"\$_agents_dir/profile-snippet.sh\" 2>/dev/null
            fi
            echo \"\${AGENTS_CONFIG_DIR:-UNSET}\"
        " 2>/dev/null | tail -1 || true)

        trap - EXIT
        rm -rf "$_e2e3_td"

        if [ "$_e2e3_result" = "$_e2e3_agents" ]; then
            pass "E2E-3. sibling detection sets AGENTS_CONFIG_DIR to agents dir"
        else
            fail "E2E-3. expected AGENTS_CONFIG_DIR='$_e2e3_agents', got '$_e2e3_result'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# E2E-4: pwsh / agents only — profile-snippet.ps1 sets AGENTS_CONFIG_DIR
# NOTE: Requires profile-snippet.ps1 to exist — FAIL expected until file is created
# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-4: pwsh / agents only — profile-snippet.ps1 sets AGENTS_CONFIG_DIR ==="

if ! command -v pwsh >/dev/null 2>&1; then
    skip "E2E-4. pwsh not available"
elif [ ! -f "$SNIPPET_PS1" ]; then
    skip "E2E-4. profile-snippet.ps1 not found (will be created in source code step)"
else
    # Build temp tree inside pwsh so paths are native Windows paths.
    # Pass the host snippet path (converted to a Windows path if available).
    _e2e4_snippet_win="$SNIPPET_PS1"
    if command -v cygpath >/dev/null 2>&1; then
        _e2e4_snippet_win=$(cygpath -w "$SNIPPET_PS1" 2>/dev/null || echo "$SNIPPET_PS1")
    fi

    _e2e4_result=$(SNIPPET_SRC="$_e2e4_snippet_win" pwsh -NoProfile -Command '
        $env:AGENTS_CONFIG_DIR = $null
        $env:AGENTS_DIR = $null
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $agentsDir = Join-Path $tmpRoot "agents"
        New-Item -ItemType Directory -Force $agentsDir | Out-Null
        # Clean check: dotfiles must NOT exist alongside
        if (Test-Path (Join-Path $tmpRoot "dotfiles")) {
            "SKIP_UNEXPECTED_DOTFILES"
            return
        }
        Copy-Item $env:SNIPPET_SRC (Join-Path $agentsDir "profile-snippet.ps1") -Force
        $tempHome = Join-Path $tmpRoot "home"
        New-Item -ItemType Directory -Force $tempHome | Out-Null
        $env:HOME = $tempHome
        $env:USERPROFILE = $tempHome
        . (Join-Path $agentsDir "profile-snippet.ps1") *> $null
        # Emit expected and actual on two lines so the bash side can parse.
        "EXPECTED=$agentsDir"
        "GOT=$($env:AGENTS_CONFIG_DIR)"
        Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
    ' 2>/dev/null || true)

    if echo "$_e2e4_result" | grep -q '^SKIP_UNEXPECTED_DOTFILES'; then
        skip "E2E-4. unexpected dotfiles dir in temp root"
    else
        _e2e4_expected=$(echo "$_e2e4_result" | grep '^EXPECTED=' | head -1 | sed 's/^EXPECTED=//' | tr '\\' '/' | tr -d '\r')
        _e2e4_got=$(echo "$_e2e4_result" | grep '^GOT=' | head -1 | sed 's/^GOT=//' | tr '\\' '/' | tr -d '\r')
        if [ -n "$_e2e4_expected" ] && [ "$_e2e4_got" = "$_e2e4_expected" ]; then
            pass "E2E-4. pwsh profile-snippet.ps1 sets AGENTS_CONFIG_DIR to agents dir"
        else
            fail "E2E-4. expected AGENTS_CONFIG_DIR='$_e2e4_expected', got '$_e2e4_got'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# E2E-5: pwsh / dotfiles only (agents absent) — sibling detection safe
# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-5: pwsh / dotfiles only — sibling detection safe when agents absent ==="

if ! command -v pwsh >/dev/null 2>&1; then
    skip "E2E-5. pwsh not available"
else
    _e2e5_td=$(mktemp -d)
    trap 'rm -rf "$_e2e5_td"' EXIT

    _e2e5_dotfiles="$_e2e5_td/dotfiles"
    mkdir -p "$_e2e5_dotfiles"

    # Clean check: agents must NOT exist
    if [ -d "$_e2e5_td/agents" ]; then
        skip "E2E-5. unexpected agents dir in temp root"
        trap - EXIT; rm -rf "$_e2e5_td"
    else
        _e2e5_result=$(pwsh -NoProfile -Command "
            Remove-Item Env:AGENTS_CONFIG_DIR -ErrorAction SilentlyContinue
            \$DotfilesDir = '$_e2e5_dotfiles'
            \$AgentsDir = (Split-Path \$DotfilesDir -Parent) + [IO.Path]::DirectorySeparatorChar + 'agents'
            if (Test-Path \"\$AgentsDir\profile-snippet.ps1\") {
                . \"\$AgentsDir\profile-snippet.ps1\"
            }
            if (\$env:AGENTS_CONFIG_DIR) { \$env:AGENTS_CONFIG_DIR } else { 'UNSET' }
        " 2>/dev/null || true)

        trap - EXIT
        rm -rf "$_e2e5_td"

        if [ "$_e2e5_result" = "UNSET" ]; then
            pass "E2E-5. pwsh no error and AGENTS_CONFIG_DIR unset when agents absent"
        else
            fail "E2E-5. expected AGENTS_CONFIG_DIR=UNSET, got '$_e2e5_result'"
        fi
    fi
fi

# ---------------------------------------------------------------------------
# E2E-6: pwsh / dotfiles + agents — sibling detection sets AGENTS_CONFIG_DIR
# NOTE: Requires profile-snippet.ps1 to exist — FAIL expected until file is created
# ---------------------------------------------------------------------------
echo ""
echo "=== E2E-6: pwsh / dotfiles + agents — sibling detection sets AGENTS_CONFIG_DIR ==="

if ! command -v pwsh >/dev/null 2>&1; then
    skip "E2E-6. pwsh not available"
elif [ ! -f "$SNIPPET_PS1" ]; then
    skip "E2E-6. profile-snippet.ps1 not found (will be created in source code step)"
else
    _e2e6_snippet_win="$SNIPPET_PS1"
    if command -v cygpath >/dev/null 2>&1; then
        _e2e6_snippet_win=$(cygpath -w "$SNIPPET_PS1" 2>/dev/null || echo "$SNIPPET_PS1")
    fi

    _e2e6_result=$(SNIPPET_SRC="$_e2e6_snippet_win" pwsh -NoProfile -Command '
        $env:AGENTS_CONFIG_DIR = $null
        $env:AGENTS_DIR = $null
        $tmpRoot = Join-Path ([System.IO.Path]::GetTempPath()) ([System.IO.Path]::GetRandomFileName())
        $dotfilesDir = Join-Path $tmpRoot "dotfiles"
        $agentsDir   = Join-Path $tmpRoot "agents"
        New-Item -ItemType Directory -Force $dotfilesDir | Out-Null
        New-Item -ItemType Directory -Force $agentsDir | Out-Null
        # Clean check: only dotfiles + agents
        $extra = Get-ChildItem $tmpRoot | Where-Object { $_.Name -notin @("dotfiles","agents") }
        if ($extra) {
            "SKIP_UNEXPECTED:$($extra.Name -join ",")"
            return
        }
        Copy-Item $env:SNIPPET_SRC (Join-Path $agentsDir "profile-snippet.ps1") -Force
        $tempHome = Join-Path $tmpRoot "home"
        New-Item -ItemType Directory -Force $tempHome | Out-Null
        $env:HOME = $tempHome
        $env:USERPROFILE = $tempHome
        # Sibling detection (the pattern profile.ps1 uses)
        $DotfilesDir = $dotfilesDir
        $SiblingAgents = (Split-Path $DotfilesDir -Parent) + [IO.Path]::DirectorySeparatorChar + "agents"
        if (Test-Path (Join-Path $SiblingAgents "profile-snippet.ps1")) {
            . (Join-Path $SiblingAgents "profile-snippet.ps1") *> $null
        }
        "EXPECTED=$agentsDir"
        "GOT=$($env:AGENTS_CONFIG_DIR)"
        Remove-Item -Recurse -Force $tmpRoot -ErrorAction SilentlyContinue
    ' 2>/dev/null || true)

    if echo "$_e2e6_result" | grep -q '^SKIP_UNEXPECTED'; then
        skip "E2E-6. unexpected dirs in temp root"
    else
        _e2e6_expected=$(echo "$_e2e6_result" | grep '^EXPECTED=' | head -1 | sed 's/^EXPECTED=//' | tr '\\' '/' | tr -d '\r')
        _e2e6_got=$(echo "$_e2e6_result" | grep '^GOT=' | head -1 | sed 's/^GOT=//' | tr '\\' '/' | tr -d '\r')
        if [ -n "$_e2e6_expected" ] && [ "$_e2e6_got" = "$_e2e6_expected" ]; then
            pass "E2E-6. pwsh sibling detection sets AGENTS_CONFIG_DIR to agents dir"
        else
            fail "E2E-6. expected AGENTS_CONFIG_DIR='$_e2e6_expected', got '$_e2e6_got'"
        fi
    fi
fi

# ===========================================================================
# split-history.py tests (N11–N15, E4–E6, I1, ER1–ER2)
# Each test creates its own isolated tmpdir and cleans up on exit.
# ===========================================================================

SPLIT_SCRIPT="$AGENTS_ROOT/bin/split-history.py"

if [ ! -f "$SPLIT_SCRIPT" ]; then
    echo "FATAL: bin/split-history.py not found: $SPLIT_SCRIPT"
    exit 2
fi

# Helper: set up a scratch repo tree under a given tmpdir
#   setup_split_tree <tmpdir> <history_content> <classification_content>
setup_split_tree() {
    local td="$1"
    local hist="$2"
    local cls="$3"
    mkdir -p "$td/bin" "$td/docs"
    cp "$SPLIT_SCRIPT" "$td/bin/split-history.py"
    printf '%s' "$hist" > "$td/docs/history.md"
    printf '%s' "$cls" > "$td/docs/history-classification.md"
}

# ---------------------------------------------------------------------------
# N11: 2 @claude + 1 @dotfiles → agents=2, dotfiles=1
# ---------------------------------------------------------------------------
echo ""
echo "=== N11: split-history.py — 2 @claude + 1 @dotfiles ==="

_n11_td=$(mktemp -d)
trap 'rm -rf "$_n11_td"' EXIT

_n11_hist="# History

### Alpha feature

Alpha body.

### Beta feature

Beta body.

### Gamma feature

Gamma body.
"
_n11_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Alpha feature | @claude |
| 2 | Beta feature | @claude |
| 3 | Gamma feature | @dotfiles |
"

setup_split_tree "$_n11_td" "$_n11_hist" "$_n11_cls"

if uv run "$_n11_td/bin/split-history.py" > /dev/null 2>&1; then
    _n11_agents=$(grep -c '^### ' "$_n11_td/docs/history-agents.md" 2>/dev/null || echo 0)
    _n11_dotfiles=$(grep -c '^### ' "$_n11_td/docs/history-dotfiles.md" 2>/dev/null || echo 0)
    if [ "$_n11_agents" -eq 2 ] && [ "$_n11_dotfiles" -eq 1 ]; then
        pass "N11. agents=2, dotfiles=1 for 2 @claude + 1 @dotfiles"
    else
        fail "N11. expected agents=2 dotfiles=1, got agents=$_n11_agents dotfiles=$_n11_dotfiles"
    fi
else
    fail "N11. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n11_td"

# ---------------------------------------------------------------------------
# N12: @both entry appears in both outputs
# ---------------------------------------------------------------------------
echo ""
echo "=== N12: split-history.py — @both appears in both outputs ==="

_n12_td=$(mktemp -d)
trap 'rm -rf "$_n12_td"' EXIT

_n12_hist="# History

### Shared work

Shared body.
"
_n12_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Shared work | @both |
"

setup_split_tree "$_n12_td" "$_n12_hist" "$_n12_cls"

if uv run "$_n12_td/bin/split-history.py" > /dev/null 2>&1; then
    _n12_agents=$(grep -c '^### ' "$_n12_td/docs/history-agents.md" 2>/dev/null || echo 0)
    _n12_dotfiles=$(grep -c '^### ' "$_n12_td/docs/history-dotfiles.md" 2>/dev/null || echo 0)
    if [ "$_n12_agents" -eq 1 ] && [ "$_n12_dotfiles" -eq 1 ]; then
        pass "N12. @both entry appears in both agents and dotfiles outputs"
    else
        fail "N12. expected agents=1 dotfiles=1, got agents=$_n12_agents dotfiles=$_n12_dotfiles"
    fi
else
    fail "N12. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n12_td"

# ---------------------------------------------------------------------------
# N13: INCIDENT: #N: in history matches INCIDENT #N: in classification
# ---------------------------------------------------------------------------
echo ""
echo "=== N13: split-history.py — INCIDENT: #N: normalized for matching ==="

_n13_td=$(mktemp -d)
trap 'rm -rf "$_n13_td"' EXIT

_n13_hist="# History

### INCIDENT: #1: Server outage

Outage details.
"
# Classification uses normalized form (without colon after INCIDENT)
_n13_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | INCIDENT #1: Server outage | @claude |
"

setup_split_tree "$_n13_td" "$_n13_hist" "$_n13_cls"

if uv run "$_n13_td/bin/split-history.py" > /dev/null 2>&1; then
    _n13_agents=$(grep -c '^### ' "$_n13_td/docs/history-agents.md" 2>/dev/null || echo 0)
    if [ "$_n13_agents" -eq 1 ]; then
        pass "N13. INCIDENT: #N: in history matched INCIDENT #N: in classification"
    else
        fail "N13. expected agents=1, got agents=$_n13_agents (INCIDENT normalization may have failed)"
    fi
else
    fail "N13. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n13_td"

# ---------------------------------------------------------------------------
# N14: Date suffix in history header stripped before matching
# ---------------------------------------------------------------------------
echo ""
echo "=== N14: split-history.py — date suffix stripped before matching ==="

_n14_td=$(mktemp -d)
trap 'rm -rf "$_n14_td"' EXIT

_n14_hist="# History

### Deploy pipeline (2026-04-12, abc1234)

Pipeline body.
"
# Classification key has no date suffix
_n14_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Deploy pipeline | @claude |
"

setup_split_tree "$_n14_td" "$_n14_hist" "$_n14_cls"

if uv run "$_n14_td/bin/split-history.py" > /dev/null 2>&1; then
    _n14_agents=$(grep -c '^### ' "$_n14_td/docs/history-agents.md" 2>/dev/null || echo 0)
    if [ "$_n14_agents" -eq 1 ]; then
        pass "N14. date suffix stripped; entry matched classification key without date"
    else
        fail "N14. expected agents=1, got agents=$_n14_agents (date suffix stripping may have failed)"
    fi
else
    fail "N14. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n14_td"

# ---------------------------------------------------------------------------
# N15: Multi-line body preserved in output
# ---------------------------------------------------------------------------
echo ""
echo "=== N15: split-history.py — multi-line body preserved ==="

_n15_td=$(mktemp -d)
trap 'rm -rf "$_n15_td"' EXIT

_n15_hist="# History

### Multi-line entry

Background: This has multiple lines.
Changes:
- Line one
- Line two
- Line three
"
_n15_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Multi-line entry | @claude |
"

setup_split_tree "$_n15_td" "$_n15_hist" "$_n15_cls"

if uv run "$_n15_td/bin/split-history.py" > /dev/null 2>&1; then
    # Check that specific body lines appear in the agents output
    if grep -q 'Line one' "$_n15_td/docs/history-agents.md" && \
       grep -q 'Line two' "$_n15_td/docs/history-agents.md" && \
       grep -q 'Line three' "$_n15_td/docs/history-agents.md"; then
        pass "N15. multi-line body fully preserved in agents output"
    else
        fail "N15. body lines missing from agents output"
    fi
else
    fail "N15. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n15_td"

# ---------------------------------------------------------------------------
# E4: Empty history → header-only output (no entries)
# ---------------------------------------------------------------------------
echo ""
echo "=== E4: split-history.py — empty history → header-only output ==="

_e4_td=$(mktemp -d)
trap 'rm -rf "$_e4_td"' EXIT

_e4_hist="# History

"
# Classification must be non-empty or script returns early with error
_e4_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Placeholder | @dotfiles |
"

setup_split_tree "$_e4_td" "$_e4_hist" "$_e4_cls"

if uv run "$_e4_td/bin/split-history.py" > /dev/null 2>&1; then
    _e4_agents_entries=$(grep -c '^### ' "$_e4_td/docs/history-agents.md" 2>/dev/null || true)
    _e4_dotfiles_entries=$(grep -c '^### ' "$_e4_td/docs/history-dotfiles.md" 2>/dev/null || true)
    _e4_agents_entries="${_e4_agents_entries:-0}"
    _e4_dotfiles_entries="${_e4_dotfiles_entries:-0}"
    if [ "$_e4_agents_entries" -eq 0 ] && [ "$_e4_dotfiles_entries" -eq 0 ]; then
        pass "E4. empty history produces header-only output (0 entries in both files)"
    else
        fail "E4. expected 0 entries, got agents=$_e4_agents_entries dotfiles=$_e4_dotfiles_entries"
    fi
else
    fail "E4. script exited non-zero on empty history"
fi

trap - EXIT
rm -rf "$_e4_td"

# ---------------------------------------------------------------------------
# E5: Single entry goes to the correct file
# ---------------------------------------------------------------------------
echo ""
echo "=== E5: split-history.py — single entry goes to correct file ==="

_e5_td=$(mktemp -d)
trap 'rm -rf "$_e5_td"' EXIT

_e5_hist="# History

### Solo entry

Solo body.
"
_e5_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Solo entry | @dotfiles |
"

setup_split_tree "$_e5_td" "$_e5_hist" "$_e5_cls"

if uv run "$_e5_td/bin/split-history.py" > /dev/null 2>&1; then
    _e5_agents=$(grep -c '^### ' "$_e5_td/docs/history-agents.md" 2>/dev/null || true)
    _e5_dotfiles=$(grep -c '^### ' "$_e5_td/docs/history-dotfiles.md" 2>/dev/null || true)
    _e5_agents="${_e5_agents:-0}"
    _e5_dotfiles="${_e5_dotfiles:-0}"
    if [ "$_e5_agents" -eq 0 ] && [ "$_e5_dotfiles" -eq 1 ]; then
        pass "E5. single @dotfiles entry goes only to dotfiles output (agents=0)"
    else
        fail "E5. expected agents=0 dotfiles=1, got agents=$_e5_agents dotfiles=$_e5_dotfiles"
    fi
else
    fail "E5. script exited non-zero"
fi

trap - EXIT
rm -rf "$_e5_td"

# ---------------------------------------------------------------------------
# E6: Unmatched entry → @dotfiles + warning to stderr
# ---------------------------------------------------------------------------
echo ""
echo "=== E6: split-history.py — unmatched entry → @dotfiles + stderr warning ==="

_e6_td=$(mktemp -d)
trap 'rm -rf "$_e6_td"' EXIT

_e6_hist="# History

### Unclassified work

Some body.
"
# Classification does NOT include "Unclassified work"
_e6_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Something else | @claude |
"

setup_split_tree "$_e6_td" "$_e6_hist" "$_e6_cls"

_e6_stderr=$(uv run "$_e6_td/bin/split-history.py" 2>&1 >/dev/null || true)
_e6_dotfiles=$(grep -c '^### ' "$_e6_td/docs/history-dotfiles.md" 2>/dev/null || true)
_e6_agents=$(grep -c '^### ' "$_e6_td/docs/history-agents.md" 2>/dev/null || true)
_e6_dotfiles="${_e6_dotfiles:-0}"
_e6_agents="${_e6_agents:-0}"

_e6_ok=1
if [ "$_e6_dotfiles" -ne 1 ]; then
    fail "E6. expected unmatched entry in dotfiles (count=1), got $_e6_dotfiles"
    _e6_ok=0
fi
if [ "$_e6_agents" -ne 0 ]; then
    fail "E6. expected unmatched entry NOT in agents (count=0), got $_e6_agents"
    _e6_ok=0
fi
if ! echo "$_e6_stderr" | grep -qi 'unmatched\|WARNING'; then
    fail "E6. expected WARNING on stderr for unmatched entry, got: $_e6_stderr"
    _e6_ok=0
fi
if [ "$_e6_ok" -eq 1 ]; then
    pass "E6. unmatched entry defaulted to @dotfiles and warning printed to stderr"
fi

trap - EXIT
rm -rf "$_e6_td"

# ---------------------------------------------------------------------------
# I1: Second run produces byte-identical output (idempotency)
# ---------------------------------------------------------------------------
echo ""
echo "=== I1: split-history.py — idempotent (second run identical output) ==="

_i1_td=$(mktemp -d)
trap 'rm -rf "$_i1_td"' EXIT

_i1_hist="# History

### Idempotent entry

Body text.
"
_i1_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Idempotent entry | @both |
"

setup_split_tree "$_i1_td" "$_i1_hist" "$_i1_cls"

# First run
uv run "$_i1_td/bin/split-history.py" > /dev/null 2>&1

# Capture checksums after first run
_i1_agents_sum1=$(md5sum "$_i1_td/docs/history-agents.md" 2>/dev/null | cut -d' ' -f1)
_i1_dotfiles_sum1=$(md5sum "$_i1_td/docs/history-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

# Second run
uv run "$_i1_td/bin/split-history.py" > /dev/null 2>&1

_i1_agents_sum2=$(md5sum "$_i1_td/docs/history-agents.md" 2>/dev/null | cut -d' ' -f1)
_i1_dotfiles_sum2=$(md5sum "$_i1_td/docs/history-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

if [ "$_i1_agents_sum1" = "$_i1_agents_sum2" ] && [ "$_i1_dotfiles_sum1" = "$_i1_dotfiles_sum2" ]; then
    pass "I1. second run produces byte-identical output (idempotent)"
else
    fail "I1. output differs between runs (not idempotent)"
fi

trap - EXIT
rm -rf "$_i1_td"

# ---------------------------------------------------------------------------
# ER1: Missing history.md → exit 1
# ---------------------------------------------------------------------------
echo ""
echo "=== ER1: split-history.py — missing history.md → exit 1 ==="

_er1_td=$(mktemp -d)
trap 'rm -rf "$_er1_td"' EXIT

_er1_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Something | @claude |
"

mkdir -p "$_er1_td/bin" "$_er1_td/docs"
cp "$SPLIT_SCRIPT" "$_er1_td/bin/split-history.py"
# Write only classification, no history.md
printf '%s' "$_er1_cls" > "$_er1_td/docs/history-classification.md"

if uv run "$_er1_td/bin/split-history.py" > /dev/null 2>&1; then
    fail "ER1. expected exit 1 when history.md is missing, but script succeeded"
else
    _er1_exit=$?
    if [ "$_er1_exit" -eq 1 ]; then
        pass "ER1. missing history.md causes exit 1"
    else
        fail "ER1. expected exit 1, got exit $_er1_exit"
    fi
fi

trap - EXIT
rm -rf "$_er1_td"

# ---------------------------------------------------------------------------
# ER2: Missing classification.md → exit 1
# ---------------------------------------------------------------------------
echo ""
echo "=== ER2: split-history.py — missing classification.md → exit 1 ==="

_er2_td=$(mktemp -d)
trap 'rm -rf "$_er2_td"' EXIT

_er2_hist="# History

### Some entry

Body.
"

mkdir -p "$_er2_td/bin" "$_er2_td/docs"
cp "$SPLIT_SCRIPT" "$_er2_td/bin/split-history.py"
# Write only history, no classification.md
printf '%s' "$_er2_hist" > "$_er2_td/docs/history.md"

if uv run "$_er2_td/bin/split-history.py" > /dev/null 2>&1; then
    fail "ER2. expected exit 1 when classification.md is missing, but script succeeded"
else
    _er2_exit=$?
    if [ "$_er2_exit" -eq 1 ]; then
        pass "ER2. missing classification.md causes exit 1"
    else
        fail "ER2. expected exit 1, got exit $_er2_exit"
    fi
fi

trap - EXIT
rm -rf "$_er2_td"

# ---------------------------------------------------------------------------
# N16: Archive source processed correctly
# ---------------------------------------------------------------------------
echo ""
echo "=== N16: split-history.py — archive source processed correctly ==="

_n16_td=$(mktemp -d)
trap 'rm -rf "$_n16_td"' EXIT

_n16_hist="# History

### Alpha feature

Alpha body.
"
_n16_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Alpha feature | @dotfiles |
"

_n16_archive="# History

### Archive only entry

Archive body.
"
_n16_archive_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Archive only entry | @claude |
"

setup_split_tree "$_n16_td" "$_n16_hist" "$_n16_cls"
mkdir -p "$_n16_td/docs/history"
printf '%s' "$_n16_archive" > "$_n16_td/docs/history/2026.md"
printf '%s' "$_n16_archive_cls" > "$_n16_td/docs/history-classification-2026.md"

if uv run "$_n16_td/bin/split-history.py" > /dev/null 2>&1; then
    _n16_agents=$(grep -c '^### ' "$_n16_td/docs/history/2026-agents.md" 2>/dev/null || true)
    _n16_dotfiles=$(grep -c '^### ' "$_n16_td/docs/history/2026-dotfiles.md" 2>/dev/null || true)
    _n16_agents="${_n16_agents:-0}"
    _n16_dotfiles="${_n16_dotfiles:-0}"
    if [ "$_n16_agents" -eq 1 ] && [ "$_n16_dotfiles" -eq 0 ]; then
        pass "N16. archive 2026.md: agents=1, dotfiles=0 for @claude entry"
    else
        fail "N16. expected archive agents=1 dotfiles=0, got agents=$_n16_agents dotfiles=$_n16_dotfiles"
    fi
else
    fail "N16. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n16_td"

# ---------------------------------------------------------------------------
# N17: All 3 source files processed in a single run
# ---------------------------------------------------------------------------
echo ""
echo "=== N17: split-history.py — all 3 source files processed in one run ==="

_n17_td=$(mktemp -d)
trap 'rm -rf "$_n17_td"' EXIT

# Main pair: 1 @dotfiles entry
_n17_hist="# History

### Main dotfiles entry

Main body.
"
_n17_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Main dotfiles entry | @dotfiles |
"

# Legacy archive: 1 @claude entry
_n17_legacy="# History

### Legacy claude entry

Legacy body.
"
_n17_legacy_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Legacy claude entry | @claude |
"

# 2026 archive: 1 @both entry
_n17_2026="# History

### Both entry 2026

Both body.
"
_n17_2026_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Both entry 2026 | @both |
"

setup_split_tree "$_n17_td" "$_n17_hist" "$_n17_cls"
mkdir -p "$_n17_td/docs/history"
printf '%s' "$_n17_legacy" > "$_n17_td/docs/history/legacy.md"
printf '%s' "$_n17_legacy_cls" > "$_n17_td/docs/history-classification-legacy.md"
printf '%s' "$_n17_2026" > "$_n17_td/docs/history/2026.md"
printf '%s' "$_n17_2026_cls" > "$_n17_td/docs/history-classification-2026.md"

if uv run "$_n17_td/bin/split-history.py" > /dev/null 2>&1; then
    _n17_ok=1

    # Main pair
    _n17_main_agents=$(grep -c '^### ' "$_n17_td/docs/history-agents.md" 2>/dev/null || true)
    _n17_main_dotfiles=$(grep -c '^### ' "$_n17_td/docs/history-dotfiles.md" 2>/dev/null || true)
    _n17_main_agents="${_n17_main_agents:-0}"
    _n17_main_dotfiles="${_n17_main_dotfiles:-0}"
    if [ "$_n17_main_agents" -ne 0 ] || [ "$_n17_main_dotfiles" -ne 1 ]; then
        fail "N17. main: expected agents=0 dotfiles=1, got agents=$_n17_main_agents dotfiles=$_n17_main_dotfiles"
        _n17_ok=0
    fi

    # Legacy archive
    _n17_leg_agents=$(grep -c '^### ' "$_n17_td/docs/history/legacy-agents.md" 2>/dev/null || true)
    _n17_leg_dotfiles=$(grep -c '^### ' "$_n17_td/docs/history/legacy-dotfiles.md" 2>/dev/null || true)
    _n17_leg_agents="${_n17_leg_agents:-0}"
    _n17_leg_dotfiles="${_n17_leg_dotfiles:-0}"
    if [ "$_n17_leg_agents" -ne 1 ] || [ "$_n17_leg_dotfiles" -ne 0 ]; then
        fail "N17. legacy: expected agents=1 dotfiles=0, got agents=$_n17_leg_agents dotfiles=$_n17_leg_dotfiles"
        _n17_ok=0
    fi

    # 2026 archive
    _n17_2026_agents=$(grep -c '^### ' "$_n17_td/docs/history/2026-agents.md" 2>/dev/null || true)
    _n17_2026_dotfiles=$(grep -c '^### ' "$_n17_td/docs/history/2026-dotfiles.md" 2>/dev/null || true)
    _n17_2026_agents="${_n17_2026_agents:-0}"
    _n17_2026_dotfiles="${_n17_2026_dotfiles:-0}"
    if [ "$_n17_2026_agents" -ne 1 ] || [ "$_n17_2026_dotfiles" -ne 1 ]; then
        fail "N17. 2026: expected agents=1 dotfiles=1, got agents=$_n17_2026_agents dotfiles=$_n17_2026_dotfiles"
        _n17_ok=0
    fi

    if [ "$_n17_ok" -eq 1 ]; then
        pass "N17. all 6 output files correct (main + legacy + 2026 archives)"
    fi
else
    fail "N17. script exited non-zero"
fi

trap - EXIT
rm -rf "$_n17_td"

# ---------------------------------------------------------------------------
# I2: Archive pair idempotent (second run byte-identical)
# ---------------------------------------------------------------------------
echo ""
echo "=== I2: split-history.py — archive pair idempotent (second run byte-identical) ==="

_i2_td=$(mktemp -d)
trap 'rm -rf "$_i2_td"' EXIT

_i2_hist="# History

### Main entry

Main body.
"
_i2_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Main entry | @dotfiles |
"

_i2_archive="# History

### Idempotent archive entry

Archive body.
"
_i2_archive_cls="| N | Subject | Tag |
|---|---------|-----|
| 1 | Idempotent archive entry | @both |
"

setup_split_tree "$_i2_td" "$_i2_hist" "$_i2_cls"
mkdir -p "$_i2_td/docs/history"
printf '%s' "$_i2_archive" > "$_i2_td/docs/history/2026.md"
printf '%s' "$_i2_archive_cls" > "$_i2_td/docs/history-classification-2026.md"

# First run
uv run "$_i2_td/bin/split-history.py" > /dev/null 2>&1

_i2_agents_sum1=$(md5sum "$_i2_td/docs/history/2026-agents.md" 2>/dev/null | cut -d' ' -f1)
_i2_dotfiles_sum1=$(md5sum "$_i2_td/docs/history/2026-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

# Second run
uv run "$_i2_td/bin/split-history.py" > /dev/null 2>&1

_i2_agents_sum2=$(md5sum "$_i2_td/docs/history/2026-agents.md" 2>/dev/null | cut -d' ' -f1)
_i2_dotfiles_sum2=$(md5sum "$_i2_td/docs/history/2026-dotfiles.md" 2>/dev/null | cut -d' ' -f1)

if [ "$_i2_agents_sum1" = "$_i2_agents_sum2" ] && [ "$_i2_dotfiles_sum1" = "$_i2_dotfiles_sum2" ]; then
    pass "I2. second run produces byte-identical archive output (idempotent)"
else
    fail "I2. archive output differs between runs (not idempotent)"
fi

trap - EXIT
rm -rf "$_i2_td"

# ---------------------------------------------------------------------------
# Results
# ---------------------------------------------------------------------------
echo ""
echo "=== Results ==="
TOTAL=$((PASSES + ERRORS + SKIPS))
echo "Passed:  $PASSES"
echo "Failed:  $ERRORS"
echo "Skipped: $SKIPS"
echo "Total:   $TOTAL"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) failed"
    exit 1
fi
