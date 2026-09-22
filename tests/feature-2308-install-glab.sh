#!/usr/bin/env bash
# Tests: install.sh, install/linux/glab.sh
# Tags: install, glab-install, gitlab, auth-idempotent, non-interactive, scope:issue-specific, TL2
#
# Tests glab sub-script added in issue #2308.
# Verifies glab.sh direct behaviour and that install.sh always calls both gh.sh and glab.sh.
#
# TL3 gap: install.ps1/win/glab.ps1 (needs pwsh), real pkg managers, real glab auth login (TTY-gated; T4 covers non-interactive).
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer at WORKFLOW_USER_VERIFIED.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

INSTALL_SH="$AGENTS_DIR/install.sh"
GLAB_SH="$AGENTS_DIR/install/linux/glab.sh"

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Guard: skip on Windows shell — install.sh is unsupported there.
# ---------------------------------------------------------------------------
_uname_s="$(uname -s 2>/dev/null || true)"
if [[ "$_uname_s" == MINGW* || "$_uname_s" == MSYS* || "$_uname_s" == CYGWIN* ]]; then
    echo "SKIP: Windows shell environment detected -- install.sh is not supported here (use install.ps1)"
    echo ""
    echo "Results: 0 passed, 0 failed"
    exit 0
fi
unset _uname_s

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || true)
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMP=$(mktemp -d "${_BASH_WIN_TMPDIR}/install2308.XXXXXXXX")
else
    TMP=$(mktemp -d)
fi
trap 'rm -rf "$TMP"' EXIT

GLAB_SH_OK=0
[ -f "$GLAB_SH" ] && GLAB_SH_OK=1

# ---------------------------------------------------------------------------
# Section 1: install/linux/glab.sh direct tests
# ---------------------------------------------------------------------------

# T1: glab already installed → exit 0, no package manager called
T1_BIN="$TMP/t1-bin"
mkdir -p "$T1_BIN"
T1_PKG_MARKER="$TMP/t1-pkg-called"
printf '#!/usr/bin/env bash\necho "glab version 1.0.0 (2024-01-01)"\nexit 0\n' > "$T1_BIN/glab"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/apt-get"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/brew"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T1_BIN/sudo"
chmod +x "$T1_BIN/glab" "$T1_BIN/apt-get" "$T1_BIN/brew" "$T1_BIN/sudo"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T1_BIN:$PATH" HOME="$TMP/home-t1" bash "$GLAB_SH" \
        >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T1_PKG_MARKER" ]; then
        pass "T1: glab.sh — glab already installed -> exit 0, no package manager called"
    else
        fail "T1: rc=$RC pkg_called=$([ -f "$T1_PKG_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T1: install/linux/glab.sh not yet created"
fi

# T2: not installed, package manager fails, glab still absent → exit 0 (non-fatal), warning printed
T2_BIN="$TMP/t2-bin"
mkdir -p "$T2_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T2_BIN/apt-get"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T2_BIN/brew"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T2_BIN/sudo"
chmod +x "$T2_BIN/apt-get" "$T2_BIN/brew" "$T2_BIN/sudo"

if [ "$GLAB_SH_OK" = "1" ]; then
    STDOUT_FILE="$TMP/t2-stdout.log"
    STDERR_FILE="$TMP/t2-stderr.log"
    run_with_timeout 15 env -i PATH="$T2_BIN:$PATH" HOME="$TMP/home-t2" bash "$GLAB_SH" \
        >"$STDOUT_FILE" 2>"$STDERR_FILE" </dev/null
    RC=$?
    COMBINED="$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null)"
    if [ "$RC" -eq 0 ] && echo "$COMBINED" | grep -qi "manual\|could not\|warning\|failed\|install"; then
        pass "T2: glab.sh — package manager fails, glab not found -> exit 0, fallback message printed"
    else
        fail "T2: rc=$RC output=$(printf '%s' "$COMBINED" | head -3)"
    fi
else
    fail "T2: install/linux/glab.sh not yet created"
fi

# T3: glab installed, already authenticated → auth login skipped, exit 0
T3_BIN="$TMP/t3-bin"
mkdir -p "$T3_BIN"
T3_LOGIN_MARKER="$TMP/t3-login-called"
cat > "$T3_BIN/glab" << GLAB_T3_EOF
#!/usr/bin/env bash
case "\$*" in
  --version*)    echo "glab version 1.0.0" ;;
  auth\ status*) exit 0 ;;
  auth\ login*)  touch "$T3_LOGIN_MARKER"; exit 0 ;;
  *) exit 0 ;;
esac
GLAB_T3_EOF
chmod +x "$T3_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T3_BIN:$PATH" HOME="$TMP/home-t3" bash "$GLAB_SH" \
        >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T3_LOGIN_MARKER" ]; then
        pass "T3: glab.sh — already authenticated -> auth login skipped, exit 0"
    else
        fail "T3: rc=$RC login_called=$([ -f "$T3_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T3: install/linux/glab.sh not yet created"
fi

# T4: glab installed, not authenticated, non-TTY stdin → auth login skipped, exit 0
T4_BIN="$TMP/t4-bin"
mkdir -p "$T4_BIN"
T4_LOGIN_MARKER="$TMP/t4-login-called"
cat > "$T4_BIN/glab" << GLAB_T4_EOF
#!/usr/bin/env bash
case "\$*" in
  --version*)    echo "glab version 1.0.0" ;;
  auth\ status*) exit 1 ;;
  auth\ login*)  touch "$T4_LOGIN_MARKER"; exit 0 ;;
  *) exit 0 ;;
esac
GLAB_T4_EOF
chmod +x "$T4_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T4_BIN:$PATH" HOME="$TMP/home-t4" bash "$GLAB_SH" \
        >/dev/null 2>/dev/null </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T4_LOGIN_MARKER" ]; then
        pass "T4: glab.sh — non-TTY stdin -> auth login skipped, exit 0"
    else
        fail "T4: rc=$RC login_called=$([ -f "$T4_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T4: install/linux/glab.sh not yet created"
fi

# ---------------------------------------------------------------------------
# Section 2: install.sh always installs both gh and glab
# ---------------------------------------------------------------------------

INSTALL_SH_OK=0
[ -f "$INSTALL_SH" ] && INSTALL_SH_OK=1

build_fake_root() {
    local n="$1"
    local FAKE_ROOT="$TMP/fake-$n"
    mkdir -p "$FAKE_ROOT/install/linux" "$FAKE_ROOT/mock-bin" "$FAKE_ROOT/fake-nvm"

    for _stub in dotfileslink.sh claude-code.sh session-sync-init.sh vscode-settings.sh \
                 global-gitignore.sh codex.sh jq.sh shellcheck.sh pwsh.sh codegraph.sh rtk.sh; do
        printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/install/linux/$_stub"
        chmod +x "$FAKE_ROOT/install/linux/$_stub"
    done
    unset _stub

    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TMP/${n}-gh-marker" \
        > "$FAKE_ROOT/install/linux/gh.sh"
    printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$TMP/${n}-glab-marker" \
        > "$FAKE_ROOT/install/linux/glab.sh"
    chmod +x "$FAKE_ROOT/install/linux/gh.sh" "$FAKE_ROOT/install/linux/glab.sh"

    printf '# fake nvm\n' > "$FAKE_ROOT/fake-nvm/nvm.sh"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/mock-bin/npm"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/mock-bin/claude"
    chmod +x "$FAKE_ROOT/mock-bin/npm" "$FAKE_ROOT/mock-bin/claude"

    printf '# agents profile snippet\n' > "$FAKE_ROOT/profile-snippet.sh"
    cp "$INSTALL_SH" "$FAKE_ROOT/install.sh"
}

run_install() {
    local fake_root="$1"
    local fake_home="$TMP/home-run-$$"
    mkdir -p "$fake_home"
    touch "$fake_home/.bashrc"
    run_with_timeout 30 env -i \
        PATH="$fake_root/mock-bin:$PATH" \
        HOME="$fake_home" \
        NVM_DIR="$fake_root/fake-nvm" \
        SHELL="/bin/bash" \
        TERM="dumb" \
        bash "$fake_root/install.sh" \
        >/dev/null 2>/dev/null
}

# T5: install.sh always calls both gh.sh and glab.sh
if [ "$INSTALL_SH_OK" = "1" ]; then
    build_fake_root "t5"
    run_install "$TMP/fake-t5"
    RC=$?
    GH_CALLED=$([ -f "$TMP/t5-gh-marker" ] && echo yes || echo no)
    GLAB_CALLED=$([ -f "$TMP/t5-glab-marker" ] && echo yes || echo no)
    if [ "$RC" -eq 0 ] && [ "$GH_CALLED" = "yes" ] && [ "$GLAB_CALLED" = "yes" ]; then
        pass "T5: install.sh -> both gh.sh and glab.sh always called"
    else
        fail "T5: rc=$RC gh=$GH_CALLED glab=$GLAB_CALLED"
    fi
else
    fail "T5: install.sh not found"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
