#!/usr/bin/env bash
# Tests: install.sh, install.ps1
# Tags: install, gh-scope, scope:issue-specific
#
# Tests the 3-stage soft gh auth project-scope check in install.sh (issue #1487).
# The check emits a notice on stderr when gh is installed, authenticated, but
# lacks the 'project' scope. It is a soft warning -- exit code remains 0.
#
# L3 gap (what this test does NOT catch):
# - install.ps1 PowerShell scope-check: colour/stream behavior requires real pwsh runtime.
# - Covered by manual smoke test only; tracked in issue #1487.
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
for _stub in dotfileslink.sh claude-code.sh session-sync-init.sh vscode-settings.sh global-gitignore.sh codex.sh gemini.sh; do
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
# T2: gh installed but not authenticated (gh auth status exits non-zero)
#     -> no warning on stderr
# ---------------------------------------------------------------------------
T2_BIN="$TMP/t2-bin"
mkdir -p "$T2_BIN"
cat > "$T2_BIN/gh" << 'GH_T2_EOF'
#!/usr/bin/env bash
case "$*" in
  auth\ status*) exit 1 ;;
  *) exit 0 ;;
esac
GH_T2_EOF
chmod +x "$T2_BIN/gh"

STDERR_FILE="$TMP/t2-stderr.log"
run_install "$T2_BIN" "$STDERR_FILE"
RC=$?
if [ "$RC" -eq 0 ] && ! grep -q "gh auth lacks" "$STDERR_FILE" 2>/dev/null; then
    pass "T2: gh installed but not authenticated -> no scope warning on stderr"
else
    fail "T2: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# T3: gh installed, authenticated, 'project' scope present -> no warning on stderr
# ---------------------------------------------------------------------------
T3_BIN="$TMP/t3-bin"
mkdir -p "$T3_BIN"
cat > "$T3_BIN/gh" << 'GH_T3_EOF'
#!/usr/bin/env bash
case "$*" in
  auth\ status*)
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"
    exit 0 ;;
  *) exit 0 ;;
esac
GH_T3_EOF
chmod +x "$T3_BIN/gh"

STDERR_FILE="$TMP/t3-stderr.log"
run_install "$T3_BIN" "$STDERR_FILE"
RC=$?
if [ "$RC" -eq 0 ] && ! grep -q "gh auth lacks" "$STDERR_FILE" 2>/dev/null; then
    pass "T3: gh installed, authenticated, 'project' scope present -> no scope warning on stderr"
else
    fail "T3: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
# T4: gh installed, authenticated, 'project' scope absent
#     -> warning on stderr containing "gh auth lacks 'project' scope"
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
if [ "$RC" -eq 0 ] && grep -q "gh auth lacks 'project' scope" "$STDERR_FILE" 2>/dev/null; then
    pass "T4: gh installed, authenticated, no 'project' scope -> warning on stderr"
else
    fail "T4: rc=$RC stderr=$(cat "$STDERR_FILE" 2>/dev/null)"
fi

# ---------------------------------------------------------------------------
echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
