
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
