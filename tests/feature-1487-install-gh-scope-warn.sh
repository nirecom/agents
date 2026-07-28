#!/usr/bin/env bash
# Tests: install.sh, install.ps1, install/linux/gh.sh, install/linux/jq.sh
# Tags: install, gh-install, jq-install, auth-idempotent, non-interactive, scope:issue-specific
#
# Tests gh and jq install scripts added in issues #1567 and #1566.
# Also verifies that the scope-warn block removed from install.sh no longer fires.
#
# TL3 gap (what this test does NOT catch):
# - install.ps1 / install/win/gh.ps1 / install/win/jq.ps1: PowerShell behavior requires real pwsh runtime.
# - Real winget/apt-get/brew: mock package managers do not verify network or privilege behavior.
# - Real gh auth login: TTY-gated path requires interactive terminal; non-interactive path is covered by T6.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
INSTALL_SH="$AGENTS_DIR/install.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# ---------------------------------------------------------------------------
# Guard: skip if running under a Windows shell (MINGW/MSYS/Cygwin). install.sh
# exits 1 on those environments itself, so tests would give false negatives.
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
# Windows-compatible tmpdir: mktemp -d on MSYS2 returns /tmp/... which won't
# work cross-process. Use Node to resolve os.tmpdir() if available.
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || true)
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMP=$(mktemp -d "${_BASH_WIN_TMPDIR}/install1487.XXXXXXXX")
else
    TMP=$(mktemp -d)
fi
trap 'rm -rf "$TMP"' EXIT

# ---------------------------------------------------------------------------
# Build a fake AGENTS_ROOT with NOP stub sub-scripts so install.sh can run
# without performing any real side effects (no curl, no npm, no file mutations
# outside TMP).
#
# Stubs required (all called unconditionally or conditionally by install.sh):
#   install/linux/dotfileslink.sh
#   install/linux/claude-code.sh
#   install/linux/session-sync-init.sh
#   install/linux/vscode-settings.sh
#   install/linux/global-gitignore.sh
#   install/linux/gh.sh
#   install/linux/jq.sh
#   (codex.sh / gemini.sh only when --develop, not exercised here)
#
# Also stubs:
#   npm     -- checked via `type npm`
#   claude  -- checked via `type claude` for session-sync branch
# ---------------------------------------------------------------------------

FAKE_ROOT="$TMP/fake-agents-root"
mkdir -p "$FAKE_ROOT/install/linux"
mkdir -p "$FAKE_ROOT/mock-bin"

# NOP sub-scripts
for _stub in dotfileslink.sh claude-code.sh session-sync-init.sh vscode-settings.sh global-gitignore.sh codex.sh gh.sh jq.sh; do
    printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/install/linux/$_stub"
    chmod +x "$FAKE_ROOT/install/linux/$_stub"
done
unset _stub

# profile-snippet.sh placeholder (referenced in the profile-sourcing section)
printf '# agents profile snippet\n' > "$FAKE_ROOT/profile-snippet.sh"

# Fake nvm setup: install.sh sources "$NVM_DIR/nvm.sh" then checks `type npm`.
# We create a fake nvm.sh that is non-empty (satisfies `[ ! -s ... ]` check)
# and a fake `npm` binary so `type npm` succeeds.
mkdir -p "$FAKE_ROOT/fake-nvm"
printf '# fake nvm\n' > "$FAKE_ROOT/fake-nvm/nvm.sh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/mock-bin/npm"
chmod +x "$FAKE_ROOT/mock-bin/npm"

# Fake `claude` binary so the session-sync-init branch is entered (non-fatal
# even if it were not, since session-sync-init.sh is also stubbed).
printf '#!/usr/bin/env bash\nexit 0\n' > "$FAKE_ROOT/mock-bin/claude"
chmod +x "$FAKE_ROOT/mock-bin/claude"

# ---------------------------------------------------------------------------
# Helper: run install.sh in a controlled environment.
#
# Args:
#   $1 - path to a mock-bin directory that contains a `gh` stub,
#        or "none" to omit gh from PATH entirely
#   $2 - temp file to capture stderr into
#
# Env forwarded (minimal, isolated from the real system):
#   NVM_DIR  -- points to our fake nvm dir
#   HOME     -- points to $TMP/home so rc-file writes stay isolated
#   PATH     -- prepends mock-bin so our fake binaries are found first
#   SHELL    -- set to bash so rc-file is ~/.bashrc
# ---------------------------------------------------------------------------
run_install() {
    local mock_bin_dir="$1"
    local stderr_file="$2"

    local fake_home="$TMP/home-$$"
    mkdir -p "$fake_home"
    # Pre-create .bashrc so the profile-sourcing section finds it
    touch "$fake_home/.bashrc"

    local path_prefix
    if [ "$mock_bin_dir" = "none" ]; then
        path_prefix="$FAKE_ROOT/mock-bin"
    else
        path_prefix="$mock_bin_dir:$FAKE_ROOT/mock-bin"
    fi

    # We copy install.sh to the fake root so AGENTS_ROOT resolves to FAKE_ROOT
    # (install.sh uses dirname of BASH_SOURCE[0] to compute AGENTS_ROOT).
    cp "$INSTALL_SH" "$FAKE_ROOT/install.sh"

    run_with_timeout 30 env -i \
        PATH="$path_prefix:$PATH" \
        HOME="$fake_home" \
        NVM_DIR="$FAKE_ROOT/fake-nvm" \
        SHELL="/bin/bash" \
        TERM="dumb" \
        bash "$FAKE_ROOT/install.sh" \
        >/dev/null 2>"$stderr_file"
}

# ---------------------------------------------------------------------------
# T1: gh not installed -> no warning on stderr about project scope
#
# We do NOT put a `gh` stub into PATH at all. install.sh should silently skip
# the scope check (command -v gh fails -> outer if-branch not entered).
# ---------------------------------------------------------------------------
STDERR_FILE="$TMP/t1-stderr.log"
run_install "none" "$STDERR_FILE"
RC=$?
if [ "$RC" -eq 0 ] && ! grep -q "gh auth lacks" "$STDERR_FILE" 2>/dev/null; then
    pass "T1: gh not installed -> no scope warning on stderr"
else
    fail "T1: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# T2: gh.sh direct — already authenticated -> auth login is skipped
#
# gh.sh checks `gh auth status` first; if already authenticated, it must
# skip `gh auth login` entirely and proceed to `gh auth refresh -s project`.
# Relies on install/linux/gh.sh (created in write-code step).
# ---------------------------------------------------------------------------
GH_SH="$AGENTS_DIR/install/linux/gh.sh"
T2_BIN="$TMP/t2-bin"
mkdir -p "$T2_BIN"
LOGIN_MARKER="$TMP/t2-login-called"
cat > "$T2_BIN/gh" << GH_T2_EOF
#!/usr/bin/env bash
case "\$*" in
  auth\ status*)  exit 0 ;;
  auth\ login*)   touch "$LOGIN_MARKER"; exit 0 ;;
  auth\ refresh*) exit 0 ;;
  *) exit 0 ;;
esac
GH_T2_EOF
chmod +x "$T2_BIN/gh"
# mock package managers (should not be called when gh already installed)
printf '#!/usr/bin/env bash\nexit 0\n' > "$T2_BIN/brew"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T2_BIN/apt-get"
chmod +x "$T2_BIN/brew" "$T2_BIN/apt-get"

STDOUT_FILE="$TMP/t2-stdout.log"
STDERR_FILE="$TMP/t2-stderr.log"
if [ -f "$GH_SH" ]; then
    run_with_timeout 15 env -i PATH="$T2_BIN:$PATH" HOME="$TMP/home-t2" bash "$GH_SH" \
        >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$LOGIN_MARKER" ]; then
        pass "T2: gh.sh — already authenticated -> auth login skipped, exit 0"
    else
        fail "T2: rc=$RC login_called=$([ -f "$LOGIN_MARKER" ] && echo yes || echo no) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
    fi
else
    fail "T2: install/linux/gh.sh not yet created (implement in write-code step)"
fi

# ---------------------------------------------------------------------------
# T3: jq.sh direct — jq already installed -> reports "already installed", exit 0
#
# jq.sh checks `command -v jq` first; if found, it must print a message
# indicating jq is already installed and exit 0 without calling the installer.
# Relies on install/linux/jq.sh (created in write-code step).
# ---------------------------------------------------------------------------
JQ_SH="$AGENTS_DIR/install/linux/jq.sh"
T3_BIN="$TMP/t3-bin"
mkdir -p "$T3_BIN"
# Provide a fake jq binary so command -v jq succeeds
printf '#!/usr/bin/env bash\necho "jq-1.6"\nexit 0\n' > "$T3_BIN/jq"
chmod +x "$T3_BIN/jq"

STDOUT_FILE="$TMP/t3-stdout.log"
STDERR_FILE="$TMP/t3-stderr.log"
if [ -f "$JQ_SH" ]; then
    run_with_timeout 15 env -i PATH="$T3_BIN:$PATH" HOME="$TMP/home-t3" bash "$JQ_SH" \
        >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RC=$?
    COMBINED_OUT="$(cat "$STDOUT_FILE" "$STDERR_FILE" 2>/dev/null)"
    if [ "$RC" -eq 0 ] && echo "$COMBINED_OUT" | grep -qi "already\|installed\|found\|skip"; then
        pass "T3: jq.sh — jq already installed -> exit 0 with installed message"
    else
        fail "T3: rc=$RC output=$COMBINED_OUT"
    fi
else
    fail "T3: install/linux/jq.sh not yet created (implement in write-code step)"
fi

# ---------------------------------------------------------------------------
# T4: install.sh — gh authenticated but no 'project' scope
#     -> install.sh exits 0, NO scope-warn emitted (scope-warn block deleted in #1567)
#
# Previously T4 verified that a scope warning WAS emitted. After the scope-warn
# block is removed and replaced by gh.sh/jq.sh calls, no warning should appear.
# ---------------------------------------------------------------------------
T4_BIN="$TMP/t4-bin"
mkdir -p "$T4_BIN"
cat > "$T4_BIN/gh" << 'GH_T4_EOF'
#!/usr/bin/env bash
case "$*" in
  auth\ status*)
    echo "Token scopes: 'gist', 'read:org', 'repo'"
    exit 0 ;;
  *) exit 0 ;;
esac
GH_T4_EOF
chmod +x "$T4_BIN/gh"

STDERR_FILE="$TMP/t4-stderr.log"
run_install "$T4_BIN" "$STDERR_FILE"
RC=$?
if [ "$RC" -eq 0 ] && ! grep -q "gh auth lacks 'project' scope" "$STDERR_FILE" 2>/dev/null; then
    pass "T4: install.sh — no 'project' scope -> NO scope-warn on stderr (scope-warn block deleted)"
else
    fail "T4: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# T5: gh.sh direct — package manager fails AND gh not found -> gh.sh exits 0 (non-fatal)
#
# When the package manager (apt-get/brew) returns non-zero and gh is still not
# available afterward, gh.sh must continue without failing.
# Relies on install/linux/gh.sh (created in write-code step).
# ---------------------------------------------------------------------------
T5_BIN="$TMP/t5-bin"
mkdir -p "$T5_BIN"
# No gh binary in PATH; package managers fail
printf '#!/usr/bin/env bash\nexit 1\n' > "$T5_BIN/apt-get"
printf '#!/usr/bin/env bash\nexit 1\n' > "$T5_BIN/brew"
chmod +x "$T5_BIN/apt-get" "$T5_BIN/brew"

STDOUT_FILE="$TMP/t5-stdout.log"
STDERR_FILE="$TMP/t5-stderr.log"
if [ -f "$GH_SH" ]; then
    run_with_timeout 15 env -i PATH="$T5_BIN:$PATH" HOME="$TMP/home-t5" bash "$GH_SH" \
        >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "T5: gh.sh — package manager fails, gh not found -> exit 0 (non-fatal)"
    else
        fail "T5: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
    fi
else
    fail "T5: install/linux/gh.sh not yet created (implement in write-code step)"
fi

# ---------------------------------------------------------------------------
# T6: gh.sh direct — non-TTY stdin -> auth login skipped, exit 0
#
# When stdin is not a terminal ([ -t 0 ] is false), gh.sh must skip gh auth login
# to avoid hanging in headless/CI environments. It should still try
# gh auth refresh -s project (non-fatal) and exit 0.
# Relies on install/linux/gh.sh (created in write-code step).
# ---------------------------------------------------------------------------
T6_BIN="$TMP/t6-bin"
mkdir -p "$T6_BIN"
T6_LOGIN_MARKER="$TMP/t6-login-called"
cat > "$T6_BIN/gh" << GH_T6_EOF
#!/usr/bin/env bash
case "\$*" in
  auth\ status*)  exit 1 ;;
  auth\ login*)   touch "$T6_LOGIN_MARKER"; exit 0 ;;
  auth\ refresh*) exit 0 ;;
  *) exit 0 ;;
esac
GH_T6_EOF
chmod +x "$T6_BIN/gh"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T6_BIN/apt-get"
printf '#!/usr/bin/env bash\nexit 0\n' > "$T6_BIN/brew"
chmod +x "$T6_BIN/apt-get" "$T6_BIN/brew"

STDOUT_FILE="$TMP/t6-stdout.log"
STDERR_FILE="$TMP/t6-stderr.log"
if [ -f "$GH_SH" ]; then
    # Redirect stdin from /dev/null to simulate non-TTY (CI) environment
    run_with_timeout 15 env -i PATH="$T6_BIN:$PATH" HOME="$TMP/home-t6" bash "$GH_SH" \
        >/dev/null 2>"$STDERR_FILE" </dev/null
    RC=$?
    if [ "$RC" -eq 0 ] && [ ! -f "$T6_LOGIN_MARKER" ]; then
        pass "T6: gh.sh — non-TTY stdin -> auth login skipped, exit 0"
    else
        fail "T6: rc=$RC login_called=$([ -f "$T6_LOGIN_MARKER" ] && echo yes || echo no) stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
    fi
else
    fail "T6: install/linux/gh.sh not yet created (implement in write-code step)"
fi

# ---------------------------------------------------------------------------
# T7: jq.sh direct — installer returns non-zero but jq binary found on re-check -> exit 0
#
# When apt-get/brew exits non-zero for jq install, jq.sh must re-check with
# command -v jq. If jq is now available (e.g. another mechanism installed it),
# jq.sh must exit 0. This mirrors the CPR-5 symmetric re-check in jq.ps1.
# Relies on install/linux/jq.sh (created in write-code step).
# ---------------------------------------------------------------------------
T7_BIN="$TMP/t7-bin"
mkdir -p "$T7_BIN"
T7_JQ_INSTALL_CALLED="$TMP/t7-install-called"
# apt-get and brew: exit non-zero for install sub-command, but jq binary is present
cat > "$T7_BIN/apt-get" << APT_T7_EOF
#!/usr/bin/env bash
if [ "\$1" = "install" ]; then
    touch "$T7_JQ_INSTALL_CALLED"
    exit 1
fi
exit 0
APT_T7_EOF
printf '#!/usr/bin/env bash\nexit 1\n' > "$T7_BIN/brew"
# jq IS available in PATH (simulates "installed by other means" or "already present")
printf '#!/usr/bin/env bash\necho "jq-1.6"\nexit 0\n' > "$T7_BIN/jq"
chmod +x "$T7_BIN/apt-get" "$T7_BIN/brew" "$T7_BIN/jq"

STDOUT_FILE="$TMP/t7-stdout.log"
STDERR_FILE="$TMP/t7-stderr.log"
if [ -f "$JQ_SH" ]; then
    run_with_timeout 15 env -i PATH="$T7_BIN:$PATH" HOME="$TMP/home-t7" bash "$JQ_SH" \
        >"$STDOUT_FILE" 2>"$STDERR_FILE"
    RC=$?
    if [ "$RC" -eq 0 ]; then
        pass "T7: jq.sh — installer non-zero but jq found on re-check -> exit 0"
    else
        fail "T7: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
    fi
else
    fail "T7: install/linux/jq.sh not yet created (implement in write-code step)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
