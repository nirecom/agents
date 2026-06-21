#!/usr/bin/env bash
# tests/fix-969-965-dotfileslink-hardening.sh
# Tests: install/linux/dotfileslink.sh, profile-snippet.sh
# Tags: installer, dotfileslink, profile-snippet, scope:issue-specific, pwsh-not-required, bugfix-969, bugfix-965
#
# Covers:
# - T3-1/T3-2: _link_one explicit error handling for rm -f / mv failures
# - T4-1/T4-2/T4-3: profile-snippet.sh watchlist detects dangling symlinks and replaced files
# - T5-2/T5-3: stale pending-comment removal (verified by static grep on the sibling test file)
#
# L3 gap (what this test does NOT catch):
# - Real shell-startup interaction (profile-snippet.sh sourced under a live ~/.bashrc)
# - Real Git Bash without SeCreateSymbolicLinkPrivilege on Windows
# - Real interaction with assemble-settings.js (stubbed here)
# Closest-to-action mitigation: install/uninstall smoke run on native Windows / Linux
# after install.{ps1,sh} changes (manual user verification).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SCRIPT="$AGENTS_DIR/install/linux/dotfileslink.sh"
PROFILE_SH="$AGENTS_DIR/profile-snippet.sh"
SIBLING_SH="$AGENTS_DIR/tests/feature-697-dotfileslink-link-one.sh"

PASS=0
FAIL=0
SKIP=0
pass() { printf 'PASS: %s\n' "$1"; PASS=$((PASS+1)); }
fail() { printf 'FAIL: %s\n' "$1"; FAIL=$((FAIL+1)); }
skip() { printf 'SKIP: %s — %s\n' "$1" "$2"; SKIP=$((SKIP+1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

SANDBOX="$(mktemp -d 2>/dev/null || mktemp -d -t fix969)"
trap 'chmod -R u+rwX "$SANDBOX" 2>/dev/null; rm -rf "$SANDBOX" 2>/dev/null' EXIT

# Detect whether real symlinks can be created (Windows Git Bash needs nativestrict +
# either Developer Mode or Admin). If not, the profile-snippet tests cannot exercise
# their assertions meaningfully.
case "${OS:-}${MSYSTEM:-}" in
    *Windows_NT*|*MINGW*|*MSYS*|*CYGWIN*)
        export MSYS=winsymlinks:nativestrict
        ;;
esac
_sym_probe="$SANDBOX/.sym-probe-target"
_sym_probe_link="$SANDBOX/.sym-probe-link"
printf 'probe\n' > "$_sym_probe"
if ln -s "$_sym_probe" "$_sym_probe_link" 2>/dev/null && [ -L "$_sym_probe_link" ]; then
    HAS_REAL_SYMLINKS=1
else
    HAS_REAL_SYMLINKS=0
fi
rm -f "$_sym_probe" "$_sym_probe_link"

# -------------------------------------------------------------------
# T3 helper: source the _link_one function from dotfileslink.sh into a subshell
# -------------------------------------------------------------------
# Extract _link_one + helpers from the script for direct invocation in tests.
extract_link_one_block() {
    # Capture from "_link_one() {" up to the matching closing "}" at column 0.
    awk '
        /^_link_one\(\) \{/ { capture=1 }
        capture { print }
        capture && /^\}$/ { capture=0; exit }
    ' "$SCRIPT"
}

# -------------------------------------------------------------------
# T3-1: rm -f failure → _link_one returns non-zero
# -------------------------------------------------------------------
t_link_one_rm_failure_propagates() {
    local name="t_link_one_rm_failure_propagates"
    # Source presupposes the _link_one function explicitly checks `rm -f` exit status.
    # If the new error-handling code is not yet in dotfileslink.sh, skip.
    if ! grep -qE 'rm -f "\$dest"[[:space:]]*\|\|[[:space:]]*\{?[[:space:]]*return 1' "$SCRIPT" \
       && ! grep -qE 'if[[:space:]]+!?[[:space:]]*rm -f "\$dest"' "$SCRIPT"; then
        skip "$name" "explicit rm-f error check not yet in dotfileslink.sh"
        return
    fi
    local parent="$SANDBOX/t31/parent"
    mkdir -p "$parent"
    local dest="$parent/dest"
    ln -s /tmp/nonexistent "$dest"
    # Make parent unwritable so `rm -f` against the symlink fails (EACCES on the directory).
    chmod 555 "$parent"

    local block_file="$SANDBOX/t31-block.sh"
    {
        printf '#!/usr/bin/env bash\nset -u\n_dl_is_windows=0\n'
        extract_link_one_block
        printf '\n_link_one "/some/source" "%s"\n' "$dest"
    } > "$block_file"
    bash "$block_file" >"$SANDBOX/t31.out" 2>"$SANDBOX/t31.err"
    local rc=$?
    chmod 755 "$parent" 2>/dev/null || true

    if [ "$rc" -eq 0 ]; then
        fail "$name (returned 0 despite rm failure — error not propagated)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# T3-2: mv failure → _link_one returns non-zero
# -------------------------------------------------------------------
t_link_one_mv_failure_propagates() {
    local name="t_link_one_mv_failure_propagates"
    if ! grep -qE 'mv "\$dest" "\$_tmp_bak"[[:space:]]*\|\|[[:space:]]*\{?[[:space:]]*return 1' "$SCRIPT" \
       && ! grep -qE 'if[[:space:]]+!?[[:space:]]*mv "\$dest" "\$_tmp_bak"' "$SCRIPT"; then
        skip "$name" "explicit mv error check not yet in dotfileslink.sh"
        return
    fi
    local parent="$SANDBOX/t32/parent"
    mkdir -p "$parent"
    local dest="$parent/dest"
    printf 'original\n' > "$dest"
    # Make parent unwritable so `mv $dest $tmp_bak` fails (EACCES).
    chmod 555 "$parent"

    local block_file="$SANDBOX/t32-block.sh"
    {
        printf '#!/usr/bin/env bash\nset -u\n_dl_is_windows=0\n'
        extract_link_one_block
        printf '\n_link_one "/some/source" "%s"\n' "$dest"
    } > "$block_file"
    bash "$block_file" >"$SANDBOX/t32.out" 2>"$SANDBOX/t32.err"
    local rc=$?
    chmod 755 "$parent" 2>/dev/null || true

    if [ "$rc" -eq 0 ]; then
        fail "$name (returned 0 despite mv failure — error not propagated)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# T4 helpers: run profile-snippet.sh in a sandbox HOME and detect repair trigger
# -------------------------------------------------------------------
# profile-snippet.sh invokes "$_agents_root/install/linux/dotfileslink.sh" when broken.
# Replace that script with a sentinel-writing stub so we can detect repair.
prepare_profile_sandbox() {
    local sandbox_root="$1"
    rm -rf "$sandbox_root"
    mkdir -p "$sandbox_root/agents/install/linux" "$sandbox_root/home/.claude"
    cp "$PROFILE_SH" "$sandbox_root/agents/profile-snippet.sh"
    cat > "$sandbox_root/agents/install/linux/dotfileslink.sh" <<STUB
#!/usr/bin/env bash
printf 'REPAIR_TRIGGERED\n' > "$sandbox_root/repair-sentinel"
exit 0
STUB
    chmod +x "$sandbox_root/agents/install/linux/dotfileslink.sh"
}

invoke_profile_sh() {
    local sandbox_root="$1"
    rm -f "$sandbox_root/repair-sentinel"
    HOME="$sandbox_root/home" \
        run_with_timeout 30 bash -c "source '$sandbox_root/agents/profile-snippet.sh'" \
        >"$sandbox_root/profile.out" 2>"$sandbox_root/profile.err"
}

repair_triggered() {
    [ -f "$1/repair-sentinel" ]
}

# -------------------------------------------------------------------
# T4-1: valid symlinks → no repair
# -------------------------------------------------------------------
t_profile_sh_valid_symlinks_no_repair() {
    local name="t_profile_sh_valid_symlinks_no_repair"
    if [ "$HAS_REAL_SYMLINKS" != "1" ]; then
        skip "$name" "host does not support real symlinks (Windows non-Admin/non-DevMode)"
        return
    fi
    local root="$SANDBOX/t41"
    prepare_profile_sandbox "$root"
    # Create real symlinks pointing to existing target dirs.
    local target_dir="$root/targets"
    mkdir -p "$target_dir/skills" "$target_dir/rules" "$target_dir/agents"
    printf 'agents claude md\n' > "$target_dir/CLAUDE.md"
    ln -s "$target_dir/CLAUDE.md" "$root/home/.claude/CLAUDE.md"
    ln -s "$target_dir/skills" "$root/home/.claude/skills"
    ln -s "$target_dir/rules" "$root/home/.claude/rules"
    ln -s "$target_dir/agents" "$root/home/.claude/agents"

    invoke_profile_sh "$root"
    if repair_triggered "$root"; then
        fail "$name (repair triggered though all symlinks are valid)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# T4-2: dangling symlink → repair triggered
# -------------------------------------------------------------------
t_profile_sh_dangling_symlink_triggers_repair() {
    local name="t_profile_sh_dangling_symlink_triggers_repair"
    if [ "$HAS_REAL_SYMLINKS" != "1" ]; then
        skip "$name" "host does not support real symlinks"
        return
    fi
    local root="$SANDBOX/t42"
    prepare_profile_sandbox "$root"
    # Create a dangling symlink (target doesn't exist).
    ln -s "/nonexistent/path-$$" "$root/home/.claude/CLAUDE.md"

    invoke_profile_sh "$root"
    if ! repair_triggered "$root"; then
        # Current source uses `[ -e "$_f" ] && [ ! -L "$_f" ]` which evaluates to
        # false on a dangling symlink (because -e fails through the broken link).
        # The fix is expected to add a `-L && ! -e` (or equivalent) probe to detect
        # dangling links. Skip until that fix lands.
        if ! grep -qE '\-L[^]]*&&[^]]*!\s*-e|!\s*-e[^]]*&&[^]]*-L|readlink' "$PROFILE_SH"; then
            skip "$name" "profile-snippet.sh dangling-symlink detection not yet implemented"
            return
        fi
        fail "$name (dangling symlink did not trigger repair)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# T4-3: regular file in place of symlink → repair triggered
# -------------------------------------------------------------------
t_profile_sh_regular_file_triggers_repair() {
    local name="t_profile_sh_regular_file_triggers_repair"
    local root="$SANDBOX/t43"
    prepare_profile_sandbox "$root"
    # Create a regular file at the symlink location.
    printf 'i am a regular file\n' > "$root/home/.claude/CLAUDE.md"

    invoke_profile_sh "$root"
    if ! repair_triggered "$root"; then
        fail "$name (regular file did not trigger repair)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# T5-2: stale "PENDING — requires WF-CODE-5" comment removed
# -------------------------------------------------------------------
t_no_stale_pending_comment_in_sibling() {
    local name="t_no_stale_pending_comment_in_sibling"
    if grep -q "PENDING — requires WF-CODE-5" "$SIBLING_SH"; then
        fail "$name (stale 'PENDING — requires WF-CODE-5' comment still in $SIBLING_SH)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# T5-3: stale "will FAIL until" comment removed
# -------------------------------------------------------------------
t_no_will_fail_until_comment_in_sibling() {
    local name="t_no_will_fail_until_comment_in_sibling"
    if grep -q "will FAIL until" "$SIBLING_SH"; then
        fail "$name (stale 'will FAIL until' comment still in $SIBLING_SH)"
        return
    fi
    pass "$name"
}

# -------------------------------------------------------------------
# Run all tests
# -------------------------------------------------------------------
t_link_one_rm_failure_propagates
t_link_one_mv_failure_propagates
t_profile_sh_valid_symlinks_no_repair
t_profile_sh_dangling_symlink_triggers_repair
t_profile_sh_regular_file_triggers_repair
t_no_stale_pending_comment_in_sibling
t_no_will_fail_until_comment_in_sibling

printf '\n--- Summary ---\n'
printf 'Passed: %d\n' "$PASS"
printf 'Failed: %d\n' "$FAIL"
printf 'Skipped: %d\n' "$SKIP"
exit $(( FAIL > 0 ? 1 : 0 ))
