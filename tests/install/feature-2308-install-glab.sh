#!/usr/bin/env bash
# Tests: install.sh, install/linux/glab.sh, install/win/glab.ps1
# Tags: install, glab-install, gitlab, auth-idempotent, non-interactive, scope:issue-specific, TL2, pwsh-required
#
# Tests glab sub-script added in issue #2308, updated for GITLAB flag + non-interactive auth.
# Verifies glab.sh flag gate, install/upgrade, auth behavior, and that install.sh always calls glab.sh.
#
# TL3 gap: real pkg managers, real glab auth login (TTY-gated), real winget install and keyring auth.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: installer at WORKFLOW_USER_VERIFIED.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$AGENTS_DIR/tests/lib/harness.sh"

INSTALL_SH="$AGENTS_DIR/install.sh"
GLAB_SH="$AGENTS_DIR/install/linux/glab.sh"

# ---------------------------------------------------------------------------
# Detect Windows bash: install.sh / glab.sh (Sections 1–4) skip there;
# install/win/glab.ps1 (Section 5) is tested via pwsh regardless of platform.
# ---------------------------------------------------------------------------
_uname_s="$(uname -s 2>/dev/null || true)"
_on_windows_bash=0
if [[ "$_uname_s" == MINGW* || "$_uname_s" == MSYS* || "$_uname_s" == CYGWIN* ]]; then
    _on_windows_bash=1
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
# Sections 1–4: Linux-only (install.sh / install/linux/glab.sh)
# ---------------------------------------------------------------------------
if [ "$_on_windows_bash" = "0" ]; then

# ---------------------------------------------------------------------------
# Section 1: GITLAB flag gate
# ---------------------------------------------------------------------------

case_begin "T1" "install/linux/glab.sh"
# T1: GITLAB not set → exit 0, no package manager called (flag gate)
T1_BIN="$TMP/t1-bin"
mkdir -p "$T1_BIN"
T1_PKG_MARKER="$TMP/t1-pkg-called"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/apt-get"
printf '#!/usr/bin/env bash\ntouch "%s"\nexit 0\n' "$T1_PKG_MARKER" > "$T1_BIN/brew"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T1_BIN/sudo"
chmod +x "$T1_BIN/apt-get" "$T1_BIN/brew" "$T1_BIN/sudo"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T1_BIN:$PATH" HOME="$TMP/home-t1" \
        bash "$GLAB_SH" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T1_PKG_MARKER" ]; then
        pass "T1: glab.sh — GITLAB not set -> exit 0, no package manager called (flag gate)"
    else
        fail "T1: rc=$RC pkg_called=$([ -f "$T1_PKG_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T1: install/linux/glab.sh not found"
fi
case_end

# ---------------------------------------------------------------------------
# Section 2: install/upgrade and fallback behavior (GITLAB=on)
# ---------------------------------------------------------------------------

case_begin "T2" "install/linux/glab.sh"
# T2: GITLAB=on, not installed, package manager fails → exit 0, warning printed
T2_BIN="$TMP/t2-bin"
mkdir -p "$T2_BIN"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T2_BIN/apt-get"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T2_BIN/brew"
printf '#!/usr/bin/env bash\nexec "$@"\n' > "$T2_BIN/sudo"
chmod +x "$T2_BIN/apt-get" "$T2_BIN/brew" "$T2_BIN/sudo"

if [ "$GLAB_SH_OK" = "1" ]; then
    STDOUT_FILE="$TMP/t2-stdout.log"
    STDERR_FILE="$TMP/t2-stderr.log"
    run_with_timeout 15 env -i PATH="$T2_BIN:$PATH" HOME="$TMP/home-t2" GITLAB=on \
        bash "$GLAB_SH" >"$STDOUT_FILE" 2>"$STDERR_FILE" </dev/null
    RC=$?
    COMBINED="$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null)"
    if [ "$RC" -eq 0 ] && echo "$COMBINED" | grep -qi "manual\|could not\|warning\|failed\|install"; then
        pass "T2: glab.sh — GITLAB=on, pkg manager fails -> exit 0, fallback message printed"
    else
        fail "T2: rc=$RC output=$(printf '%s' "$COMBINED" | head -3)"
    fi
else
    fail "T2: install/linux/glab.sh not found"
fi
case_end

# ---------------------------------------------------------------------------
# Section 3: auth behavior (GITLAB=on, glab installed)
# ---------------------------------------------------------------------------

case_begin "T3" "install/linux/glab.sh"
# T3: GITLAB=on, already authenticated (auth status 0) → auth login never called
T3_BIN="$TMP/t3-bin"
mkdir -p "$T3_BIN"
T3_LOGIN_MARKER="$TMP/t3-login-called"
cat > "$T3_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$*" in
  --version*)    echo "glab version 1.0.0" ;;
  auth\ status*) exit 0 ;;
  auth\ login*)  touch "LOGIN_MARKER_PLACEHOLDER"; exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|LOGIN_MARKER_PLACEHOLDER|$T3_LOGIN_MARKER|" "$T3_BIN/glab"
chmod +x "$T3_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T3_BIN:$PATH" HOME="$TMP/home-t3" GITLAB=on \
        bash "$GLAB_SH" >/dev/null 2>/dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T3_LOGIN_MARKER" ]; then
        pass "T3: glab.sh — GITLAB=on, already authenticated -> auth login skipped, exit 0"
    else
        fail "T3: rc=$RC login_called=$([ -f "$T3_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T3: install/linux/glab.sh not found"
fi
case_end

case_begin "T4" "install/linux/glab.sh"
# T4: GITLAB=on, no HOSTNAME/TOKEN, not authenticated → auth login NOT called (no creds)
T4_BIN="$TMP/t4-bin"
mkdir -p "$T4_BIN"
T4_LOGIN_MARKER="$TMP/t4-login-called"
cat > "$T4_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$*" in
  --version*)    echo "glab version 1.0.0" ;;
  auth\ status*) exit 1 ;;
  auth\ login*)  touch "LOGIN_MARKER_PLACEHOLDER"; exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|LOGIN_MARKER_PLACEHOLDER|$T4_LOGIN_MARKER|" "$T4_BIN/glab"
chmod +x "$T4_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T4_BIN:$PATH" HOME="$TMP/home-t4" GITLAB=on \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T4_LOGIN_MARKER" ]; then
        pass "T4: glab.sh — GITLAB=on, no creds configured -> auth login never called"
    else
        fail "T4: rc=$RC login_called=$([ -f "$T4_LOGIN_MARKER" ] && echo yes || echo no)"
    fi
else
    fail "T4: install/linux/glab.sh not found"
fi
case_end

case_begin "T5" "install/linux/glab.sh"
# T5: GITLAB=on + HOSTNAME + TOKEN → glab auth login called with --hostname and --token flags
T5_BIN="$TMP/t5-bin"
mkdir -p "$T5_BIN"
T5_AUTH_ARGS="$TMP/t5-auth-args.txt"
cat > "$T5_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$1" in
  --version)  echo "glab version 1.0.0"; exit 0 ;;
  auth)
    if [ "${2:-}" = "login" ]; then
      echo "$@" >> "AUTH_ARGS_PLACEHOLDER"
    fi
    exit 0 ;;
  config) exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|AUTH_ARGS_PLACEHOLDER|$T5_AUTH_ARGS|" "$T5_BIN/glab"
chmod +x "$T5_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T5_BIN:$PATH" HOME="$TMP/home-t5" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    AUTH_ARGS="$(cat "$T5_AUTH_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$AUTH_ARGS" | grep -q -- "--hostname" && \
       echo "$AUTH_ARGS" | grep -q "example.com" && \
       echo "$AUTH_ARGS" | grep -q -- "--token"; then
        pass "T5: glab.sh — GITLAB_HOSTNAME+TOKEN -> auth login called with --hostname and --token"
    else
        fail "T5: rc=$RC auth_args='$AUTH_ARGS'"
    fi
else
    fail "T5: install/linux/glab.sh not found"
fi
case_end

case_begin "T6" "install/linux/glab.sh"
# T6: GITLAB=on + HOSTNAME + TOKEN + SUBFOLDER → glab config set subfolder called
T6_BIN="$TMP/t6-bin"
mkdir -p "$T6_BIN"
T6_CONFIG_ARGS="$TMP/t6-config-args.txt"
cat > "$T6_BIN/glab" << 'GLAB_STUB'
#!/usr/bin/env bash
case "$1" in
  --version)  echo "glab version 1.0.0"; exit 0 ;;
  auth)       exit 0 ;;
  config)
    if [ "${2:-}" = "set" ]; then
      echo "$@" >> "CONFIG_ARGS_PLACEHOLDER"
    fi
    exit 0 ;;
  *) exit 0 ;;
esac
GLAB_STUB
sed -i "s|CONFIG_ARGS_PLACEHOLDER|$T6_CONFIG_ARGS|" "$T6_BIN/glab"
chmod +x "$T6_BIN/glab"

if [ "$GLAB_SH_OK" = "1" ]; then
    run_with_timeout 15 env -i PATH="$T6_BIN:$PATH" HOME="$TMP/home-t6" \
        GITLAB=on GITLAB_HOSTNAME=example.com GITLAB_TOKEN=glpat-test GITLAB_SUBFOLDER=group1/gitlab \
        bash "$GLAB_SH" >/dev/null 2>/dev/null </dev/null
    RC=$?
    CONFIG_ARGS="$(cat "$T6_CONFIG_ARGS" 2>/dev/null || echo "")"
    if [ "$RC" -eq 0 ] && echo "$CONFIG_ARGS" | grep -q "subfolder" && \
       echo "$CONFIG_ARGS" | grep -q "group1/gitlab"; then
        pass "T6: glab.sh — GITLAB_SUBFOLDER -> glab config set subfolder called"
    else
        fail "T6: rc=$RC config_args='$CONFIG_ARGS'"
    fi
else
    fail "T6: install/linux/glab.sh not found"
fi
case_end

# ---------------------------------------------------------------------------
# Section 4: install.sh always calls glab.sh (flag gate is inside glab.sh)
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

case_begin "T7" "install.sh"
# T7: install.sh always calls glab.sh (GITLAB gate lives inside glab.sh, not install.sh)
if [ "$INSTALL_SH_OK" = "1" ]; then
    build_fake_root "t7"
    run_install "$TMP/fake-t7"
    RC=$?
    GH_CALLED=$([ -f "$TMP/t7-gh-marker" ] && echo yes || echo no)
    GLAB_CALLED=$([ -f "$TMP/t7-glab-marker" ] && echo yes || echo no)
    if [ "$RC" -eq 0 ] && [ "$GH_CALLED" = "yes" ] && [ "$GLAB_CALLED" = "yes" ]; then
        pass "T7: install.sh -> both gh.sh and glab.sh always called"
    else
        fail "T7: rc=$RC gh=$GH_CALLED glab=$GLAB_CALLED"
    fi
else
    fail "T7: install.sh not found"
fi
case_end

fi  # end Linux-only sections (Sections 1–4)

# ---------------------------------------------------------------------------
# Section 5: Windows/pwsh — glab.ps1 flag gate and non-interactive auth
# ---------------------------------------------------------------------------

win_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -w "$1"; else printf '%s' "$1"; fi; }
ps_path()  { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

_GLAB_PS1="$AGENTS_DIR/install/win/glab.ps1"
_RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
_PS_TIMEOUT=30

run_glab_ps1() {
    local dir="$1"
    P_RC=0
    P_OUT="$(bash "$_RWT" "$_PS_TIMEOUT" \
        "$_ps_bin" -NoProfile -NonInteractive -File "$(win_path "$dir/driver.ps1")" 2>&1)" || P_RC=$?
}

_ps_bin=""
for _c in pwsh powershell powershell.exe; do
    if command -v "$_c" >/dev/null 2>&1; then _ps_bin="$_c"; break; fi
done

if [ -z "$_ps_bin" ]; then
    echo "SKIP-ENV: no pwsh/powershell on PATH — install/win/glab.ps1 tests skipped"
elif [ ! -f "$_GLAB_PS1" ]; then
    fail "P-all: install/win/glab.ps1 not found at $_GLAB_PS1"
else

_GLAB_PS1_WIN="$(ps_path "$_GLAB_PS1")"

case_begin "P1" "install/win/glab.ps1"
# P1: GITLAB=off → exit 0, winget NOT called (flag gate)
P1="$TMP/p1"
mkdir -p "$P1"
P1_WINGET_WIN="$(win_path "$P1/winget-called.txt")"
printf '@echo off\necho %%* >> "%s"\nexit /b 0\n' "$P1_WINGET_WIN" > "$P1/winget.cmd"
cat > "$P1/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P1");' + \$env:PATH
\$env:GITLAB = 'off'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P1"
if [ "$P_RC" -eq 0 ] && [ ! -f "$P1/winget-called.txt" ]; then
    pass "P1: glab.ps1 — GITLAB=off -> exit 0, winget not called (flag gate)"
else
    fail "P1: rc=$P_RC winget_called=$([ -f "$P1/winget-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "P2" "install/win/glab.ps1"
# P2: GITLAB=on, glab in PATH, HOSTNAME+TOKEN → auth login called with --hostname and --token
P2="$TMP/p2"
mkdir -p "$P2"
P2_AUTH_WIN="$(win_path "$P2/auth-args.txt")"
printf '@echo off\nexit /b 1\n' > "$P2/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nif "%%1"=="config" (exit /b 0)\nexit /b 0\n' \
    "$P2_AUTH_WIN" > "$P2/glab.cmd"
cat > "$P2/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P2");' + \$env:PATH
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'example.com'
\$env:GITLAB_TOKEN = 'glpat-test'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P2"
P2_AUTH="$(cat "$P2/auth-args.txt" 2>/dev/null || echo "")"
if [ "$P_RC" -eq 0 ] && \
   printf '%s' "$P2_AUTH" | grep -qi -- "--hostname" && \
   printf '%s' "$P2_AUTH" | grep -qi "example.com" && \
   printf '%s' "$P2_AUTH" | grep -qi -- "--token"; then
    pass "P2: glab.ps1 — GITLAB_HOSTNAME+TOKEN -> auth login called with --hostname and --token"
else
    fail "P2: rc=$P_RC auth_args='$P2_AUTH' out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "P3" "install/win/glab.ps1"
# P3: GITLAB=on, glab in PATH, HOSTNAME+TOKEN+SUBFOLDER → glab config set subfolder called
P3="$TMP/p3"
mkdir -p "$P3"
P3_AUTH_WIN="$(win_path "$P3/auth-args.txt")"
P3_CONFIG_WIN="$(win_path "$P3/config-args.txt")"
printf '@echo off\nexit /b 1\n' > "$P3/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nif "%%1"=="config" (\n  if "%%2"=="set" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$P3_AUTH_WIN" "$P3_CONFIG_WIN" > "$P3/glab.cmd"
cat > "$P3/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P3");' + \$env:PATH
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = 'example.com'
\$env:GITLAB_TOKEN = 'glpat-test'
\$env:GITLAB_SUBFOLDER = 'group1/gitlab'
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P3"
P3_CONFIG="$(cat "$P3/config-args.txt" 2>/dev/null || echo "")"
if [ "$P_RC" -eq 0 ] && \
   printf '%s' "$P3_CONFIG" | grep -qi "subfolder" && \
   printf '%s' "$P3_CONFIG" | grep -qi "group1/gitlab"; then
    pass "P3: glab.ps1 — GITLAB_SUBFOLDER -> glab config set subfolder called"
else
    fail "P3: rc=$P_RC config_args='$P3_CONFIG' out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

case_begin "P4" "install/win/glab.ps1"
# P4: GITLAB=on, glab in PATH, no creds → auth login NOT called
P4="$TMP/p4"
mkdir -p "$P4"
P4_LOGIN_WIN="$(win_path "$P4/login-called.txt")"
printf '@echo off\nexit /b 1\n' > "$P4/winget.cmd"
printf '@echo off\nif "%%1"=="--version" (echo glab version 1.0.0 & exit /b 0)\nif "%%1"=="auth" (\n  if "%%2"=="status" (exit /b 1)\n  if "%%2"=="login" (echo %%* >> "%s" & exit /b 0)\n)\nexit /b 0\n' \
    "$P4_LOGIN_WIN" > "$P4/glab.cmd"
cat > "$P4/driver.ps1" << PS1EOF
\$env:PATH = '$(win_path "$P4");' + \$env:PATH
\$env:GITLAB = 'on'
\$env:GITLAB_HOSTNAME = ''
\$env:GITLAB_TOKEN = ''
& '$_GLAB_PS1_WIN'
PS1EOF
run_glab_ps1 "$P4"
if [ "$P_RC" -eq 0 ] && [ ! -f "$P4/login-called.txt" ]; then
    pass "P4: glab.ps1 — GITLAB=on, no creds -> auth login never called"
else
    fail "P4: rc=$P_RC login_called=$([ -f "$P4/login-called.txt" ] && echo yes || echo no) out=$(printf '%s' "$P_OUT" | head -2)"
fi
case_end

fi  # end pwsh skip gate

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
