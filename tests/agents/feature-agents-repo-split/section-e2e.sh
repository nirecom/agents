
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
