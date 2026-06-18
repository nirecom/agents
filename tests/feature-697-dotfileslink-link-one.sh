#!/usr/bin/env bash
# tests/feature-697-dotfileslink-link-one.sh
# Tests: install/linux/dotfileslink.sh, profile-snippet.sh
# Tags: installer, dotfileslink, _link_one, watchlist, scope:issue-specific
#
# L3 gap (what this test does NOT catch):
# - real Git Bash without SeCreateSymbolicLinkPrivilege (actual failure mode the rollback protects against)
# - real Windows junction collisions (cmd.exe dir /AL detection path)
# - real shell-startup interaction (profile-snippet.sh sourced under a live ~/.bashrc)
# Closest-to-action mitigation: install/uninstall smoke run on native Windows after install.ps1 changes.
#
# Notes on pending-implementation cases:
# - t_rollback_when_ln_fails and t_old_bak_preserved_until_ln_succeeds verify the
#   transactional _link_one rollback semantics planned for WF-CODE-5. They will FAIL
#   until that change lands; failure here is EXPECTED (do not skip).
# - t_watchlist_includes_all_siblings asserts the extended profile-snippet.sh
#   watchlist (skills/rules/agents) planned for WF-CODE-5. Will FAIL until updated.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/install/linux/dotfileslink.sh"
PROFILE_SH="$AGENTS_DIR/profile-snippet.sh"

PASS=0
FAIL=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

SANDBOX="$(mktemp -d 2>/dev/null || mktemp -d -t dlt)"
trap 'rm -rf "$SANDBOX" 2>/dev/null' EXIT

# Build a minimal agents fixture: CLAUDE.md + skills/ + rules/ + agents/
AGENTS_FIXTURE="$SANDBOX/agents-fixture"
mkdir -p "$AGENTS_FIXTURE/install/linux" "$AGENTS_FIXTURE/install" \
         "$AGENTS_FIXTURE/skills" "$AGENTS_FIXTURE/rules" "$AGENTS_FIXTURE/agents" \
         "$AGENTS_FIXTURE/bin" "$AGENTS_FIXTURE/hooks"
printf '# CLAUDE fixture\n' > "$AGENTS_FIXTURE/CLAUDE.md"
# Copy the real script into the fixture so AGENTS_ROOT resolves to the fixture.
cp "$SCRIPT" "$AGENTS_FIXTURE/install/linux/dotfileslink.sh"
# Stub assemble-settings.js so the script doesn't fail after the symlink block.
cat > "$AGENTS_FIXTURE/install/assemble-settings.js" <<'STUB'
// Stub for tests — exits 0 without writing anything.
process.exit(0);
STUB

FIXTURE_SCRIPT="$AGENTS_FIXTURE/install/linux/dotfileslink.sh"

# Fresh per-test HOME helpers
reset_home() {
    rm -rf "$SANDBOX/home"
    mkdir -p "$SANDBOX/home/.claude" "$SANDBOX/home/.local/bin"
    HOME="$SANDBOX/home"
    export HOME
}

invoke_script() {
    # Run the installer with sandbox HOME. Returns the script exit code.
    # PATH stays untouched unless the caller overrides it.
    run_with_timeout 120 env HOME="$HOME" bash "$FIXTURE_SCRIPT" "$@"
}

is_symlink() { [ -L "$1" ]; }

# -------------------------------------------------------------------
# [normal] t_happy_path_creates_symlinks
# -------------------------------------------------------------------
t_happy_path_creates_symlinks() {
    local name="t_happy_path_creates_symlinks"
    reset_home
    if ! invoke_script >"$SANDBOX/happy.out" 2>"$SANDBOX/happy.err"; then
        fail "$name (installer exited non-zero; stderr: $(tr -d '\r' <"$SANDBOX/happy.err" | head -3))"
        return
    fi
    for p in CLAUDE.md skills rules agents; do
        if ! is_symlink "$HOME/.claude/$p"; then
            fail "$name (~/.claude/$p is not a symlink)"
            return
        fi
    done
    pass "$name"
}

# -------------------------------------------------------------------
# [normal] t_relink_when_target_differs
# -------------------------------------------------------------------
t_relink_when_target_differs() {
    local name="t_relink_when_target_differs"
    reset_home
    # Create a symlink pointing to a wrong target.
    local wrong="$SANDBOX/wrong-target"
    printf 'wrong\n' > "$wrong"
    ln -s "$wrong" "$HOME/.claude/CLAUDE.md"
    if ! invoke_script >"$SANDBOX/relink.out" 2>"$SANDBOX/relink.err"; then
        fail "$name (installer exited non-zero)"
        return
    fi
    if ! is_symlink "$HOME/.claude/CLAUDE.md"; then
        fail "$name (~/.claude/CLAUDE.md not a symlink after install)"
        return
    fi
    local target; target="$(readlink "$HOME/.claude/CLAUDE.md")"
    case "$target" in
        *"$AGENTS_FIXTURE/CLAUDE.md"|*"agents-fixture/CLAUDE.md") pass "$name" ;;
        *) fail "$name (target='$target', expected to contain agents-fixture/CLAUDE.md)" ;;
    esac
}

# -------------------------------------------------------------------
# [idempotent] t_idempotent_when_already_correct
# -------------------------------------------------------------------
t_idempotent_when_already_correct() {
    local name="t_idempotent_when_already_correct"
    reset_home
    if ! invoke_script >"$SANDBOX/idem1.out" 2>"$SANDBOX/idem1.err"; then
        fail "$name (first install exited non-zero)"
        return
    fi
    if ! invoke_script >"$SANDBOX/idem2.out" 2>"$SANDBOX/idem2.err"; then
        fail "$name (second install exited non-zero)"
        return
    fi
    for p in CLAUDE.md skills rules agents; do
        if ! is_symlink "$HOME/.claude/$p"; then
            fail "$name (~/.claude/$p is not a symlink after second run)"
            return
        fi
    done
    if ! grep -q "Already linked" "$SANDBOX/idem2.out"; then
        fail "$name (second-run stdout missing 'Already linked')"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# [normal] t_backup_when_regular_file_present
# -------------------------------------------------------------------
t_backup_when_regular_file_present() {
    local name="t_backup_when_regular_file_present"
    reset_home
    local marker="ORIGINAL_CONTENT_$$"
    printf '%s\n' "$marker" > "$HOME/.claude/CLAUDE.md"
    if ! invoke_script >"$SANDBOX/bak.out" 2>"$SANDBOX/bak.err"; then
        fail "$name (installer exited non-zero)"
        return
    fi
    if [ ! -f "$HOME/.claude/CLAUDE.md.bak" ]; then
        fail "$name (~/.claude/CLAUDE.md.bak not created)"
        return
    fi
    if ! grep -q "$marker" "$HOME/.claude/CLAUDE.md.bak"; then
        fail "$name (.bak does not contain original content)"
        return
    fi
    if ! is_symlink "$HOME/.claude/CLAUDE.md"; then
        fail "$name (~/.claude/CLAUDE.md not a symlink after backup)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# [error] t_rollback_when_ln_fails (PENDING — requires WF-CODE-5)
# -------------------------------------------------------------------
t_rollback_when_ln_fails() {
    local name="t_rollback_when_ln_fails (pending implementation)"
    reset_home
    local marker="PRESERVE_ME_$$"
    printf '%s\n' "$marker" > "$HOME/.claude/CLAUDE.md"

    # Stub ln that fails for -s invocations.
    local stub_bin="$SANDBOX/stub-bin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/ln" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    if [ "$arg" = "-s" ]; then
        echo "stub ln: refusing -s" >&2
        exit 1
    fi
done
exec /usr/bin/ln "$@"
STUB
    chmod +x "$stub_bin/ln"

    # Invoke with stub ln prepended to PATH.
    run_with_timeout 120 env HOME="$HOME" PATH="$stub_bin:$PATH" bash "$FIXTURE_SCRIPT" \
        >"$SANDBOX/rollback.out" 2>"$SANDBOX/rollback.err"
    local rc=$?

    # Expected post-rollback state: CLAUDE.md still present (restored from temp backup),
    # script returned non-zero (so install.sh sees the failure).
    if [ ! -e "$HOME/.claude/CLAUDE.md" ]; then
        fail "$name (~/.claude/CLAUDE.md missing — no rollback happened)"
        return
    fi
    if [ -L "$HOME/.claude/CLAUDE.md" ]; then
        fail "$name (~/.claude/CLAUDE.md became a symlink — rollback did not restore)"
        return
    fi
    if [ "$rc" -eq 0 ]; then
        fail "$name (script exit 0 despite ln failure — should signal error)"
        return
    fi
    if ! grep -q "$marker" "$HOME/.claude/CLAUDE.md"; then
        fail "$name (original content not preserved after rollback)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# [edge] t_old_bak_preserved_until_ln_succeeds (PENDING)
# -------------------------------------------------------------------
t_old_bak_preserved_until_ln_succeeds() {
    local name="t_old_bak_preserved_until_ln_succeeds (pending implementation)"
    reset_home
    printf 'new content\n' > "$HOME/.claude/CLAUDE.md"
    printf 'old bak content\n' > "$HOME/.claude/CLAUDE.md.bak"

    local stub_bin="$SANDBOX/stub-bin"
    mkdir -p "$stub_bin"
    cat > "$stub_bin/ln" <<'STUB'
#!/usr/bin/env bash
for arg in "$@"; do
    if [ "$arg" = "-s" ]; then exit 1; fi
done
exec /usr/bin/ln "$@"
STUB
    chmod +x "$stub_bin/ln"

    run_with_timeout 120 env HOME="$HOME" PATH="$stub_bin:$PATH" bash "$FIXTURE_SCRIPT" \
        >"$SANDBOX/oldbak.out" 2>"$SANDBOX/oldbak.err" || true

    if [ ! -f "$HOME/.claude/CLAUDE.md.bak" ]; then
        fail "$name (~/.claude/CLAUDE.md.bak missing)"
        return
    fi
    if ! grep -q "old bak content" "$HOME/.claude/CLAUDE.md.bak"; then
        fail "$name (old .bak was clobbered before ln success)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# [static] t_watchlist_includes_all_siblings (PENDING)
# -------------------------------------------------------------------
t_watchlist_includes_all_siblings() {
    local name="t_watchlist_includes_all_siblings (pending implementation)"
    if [ ! -f "$PROFILE_SH" ]; then
        fail "$name (profile-snippet.sh not found at $PROFILE_SH)"
        return
    fi
    local line
    line="$(grep -nE 'for _f in .*\.claude' "$PROFILE_SH" | head -1)"
    if [ -z "$line" ]; then
        fail "$name (watchlist loop not found in profile-snippet.sh)"
        return
    fi
    local missing=""
    for needle in 'CLAUDE.md' 'skills' 'rules' 'agents'; do
        if ! printf '%s' "$line" | grep -q "$needle"; then
            missing="$missing $needle"
        fi
    done
    if [ -n "$missing" ]; then
        fail "$name (watchlist missing:$missing)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# Run all tests
# -------------------------------------------------------------------
t_happy_path_creates_symlinks
t_relink_when_target_differs
t_idempotent_when_already_correct
t_backup_when_regular_file_present
t_rollback_when_ln_fails
t_old_bak_preserved_until_ln_succeeds
t_watchlist_includes_all_siblings

printf '\n--- Summary ---\n'
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
exit $(( FAIL > 0 ? 1 : 0 ))
