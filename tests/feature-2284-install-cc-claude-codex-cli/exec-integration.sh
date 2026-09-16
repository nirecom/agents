#!/bin/bash
# tests/feature-2284-install-cc-claude-codex-cli/exec-integration.sh
# Sub-file: TL2 execution-layer tests for real installer scripts with PATH stubs.
# Tests: install/linux/claude-code.sh, install/linux/codex.sh, install/win/claude-code.ps1, install/win/codex.ps1
# Tags: installer, wait-cc-exit, pwsh-required, scope:issue-specific
# TL2 — real script execution with mocked process/update stubs.
# TL3 gap: real fnm/node/npm/network operations; see wait-helper.sh TL3 gap.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CC_SH="$AGENTS_DIR/install/linux/claude-code.sh"
CC_PS="$AGENTS_DIR/install/win/claude-code.ps1"
CODEX_SH="$AGENTS_DIR/install/linux/codex.sh"
CODEX_PS="$AGENTS_DIR/install/win/codex.ps1"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# ---------------------------------------------------------------------------
# Stub factory
# ---------------------------------------------------------------------------
# Build a mock AGENTS_ROOT that mirrors the real layout.  The installer is
# COPIED into $mock_root/install/linux (or /win) so that dirname-based paths
# (e.g. $(dirname "$0")/../../lib/wait-cc-exit.sh) resolve to mocks.
# AGENTS_ROOT is also set to $mock_root so variable-based paths work too.
# NVM_DIR is unset to prevent bash installers from sourcing real nvm.
# Call log: $TMP_DIR/call-log-<label>.txt — each invocation appends "$@".
# ---------------------------------------------------------------------------

_setup_sh_stubs() {
    local label="$1" cli="$2" cli_exit="${3:-0}" wait_exit="${4:-0}" installer="$5"
    local stub_bin="$TMP_DIR/stubs-$label"
    local mock_root="$TMP_DIR/agents-root-$label"
    local sub_dir="install/linux"
    rm -rf "$stub_bin" "$mock_root"
    mkdir -p "$stub_bin" "$mock_root/$sub_dir" "$mock_root/install/lib"

    # Copy real installer so dirname-relative paths resolve into mock_root.
    local mock_installer="$mock_root/$sub_dir/$(basename "$installer")"
    cp "$installer" "$mock_installer"

    # Mock CLI (claude or codex): records calls, exits as requested.
    local call_log="$TMP_DIR/call-log-$label.txt"
    printf '#!/bin/bash\necho "$@" >> "%s"\nexit %s\n' "$call_log" "$cli_exit" \
        > "$stub_bin/$cli"
    chmod +x "$stub_bin/$cli"

    # Mock pgrep: always "absent" (the wait-cc-exit.sh uses pgrep).
    printf '#!/bin/bash\nexit 1\n' > "$stub_bin/pgrep"
    chmod +x "$stub_bin/pgrep"

    # Mock node: no-op (we don't want to run assemble-settings.js for real).
    printf '#!/bin/bash\nexit 0\n' > "$stub_bin/node"
    chmod +x "$stub_bin/node"

    # Mock wait-cc-exit.sh at both AGENTS_ROOT-relative and dirname-relative paths.
    printf '#!/bin/bash\nexit %s\n' "$wait_exit" \
        > "$mock_root/install/lib/wait-cc-exit.sh"
    chmod +x "$mock_root/install/lib/wait-cc-exit.sh"

    printf '%s %s %s %s' "$stub_bin" "$mock_root" "$call_log" "$mock_installer"
}

# Run bash installer with stubs; isolate from host NVM_DIR/HOME to prevent network calls.
_run_installer_sh() {
    local stub_bin="$1" mock_root="$2" installer="$3"
    local rc=0
    local mock_home="$TMP_DIR/home-$$"
    mkdir -p "$mock_home"
    env -i PATH="$stub_bin:/usr/bin:/bin" \
        HOME="$mock_home" \
        AGENTS_ROOT="$mock_root" \
        bash "$installer" > "$TMP_DIR/installer-stdout" 2> "$TMP_DIR/installer-stderr" || rc=$?
    echo "$rc"
}

# ---------------------------------------------------------------------------
# Group F: bash installer execution (claude-code.sh / codex.sh)
# ---------------------------------------------------------------------------

_run_exec_group_sh() {
    local label="$1" file="$2" cli="$3"
    if [ ! -f "$file" ]; then
        fail "$label-a: $(basename "$file") does not exist (write_code pending)"
        fail "$label-b: $(basename "$file") does not exist"
        fail "$label-c: $(basename "$file") does not exist"
        return
    fi

    # Fa: guard passes (pgrep absent, wait exits 0) → `cli update` IS invoked.
    read -r _bin_a _root_a _log_a _inst_a < <(_setup_sh_stubs "${label}a" "$cli" 0 0 "$file")
    _rc_a="$(_run_installer_sh "$_bin_a" "$_root_a" "$_inst_a")"
    if [ -f "$_log_a" ] && grep -q "^update" "$_log_a" 2>/dev/null; then
        pass "$label-a: $(basename "$file") — guard passes → \`$cli update\` invoked"
    else
        fail "$label-a: $(basename "$file") — guard passes but \`$cli update\` was not called (rc=$_rc_a)"
    fi

    # Fb: guard times out (wait exits 1) → `cli update` is NOT invoked, installer exits 0.
    read -r _bin_b _root_b _log_b _inst_b < <(_setup_sh_stubs "${label}b" "$cli" 0 1 "$file")
    _rc_b="$(_run_installer_sh "$_bin_b" "$_root_b" "$_inst_b")"
    _upd_b=0
    [ -f "$_log_b" ] && grep -q "^update" "$_log_b" 2>/dev/null && _upd_b=1
    if [ "$_upd_b" = "0" ] && [ "$_rc_b" = "0" ]; then
        pass "$label-b: $(basename "$file") — guard timeout → update skipped, installer exits 0"
    else
        fail "$label-b: $(basename "$file") — timeout case wrong (update_called=$_upd_b, rc=$_rc_b)"
    fi

    # Fc: guard passes, update fails (exit 1) → installer still exits 0 (soft-fail).
    read -r _bin_c _root_c _log_c _inst_c < <(_setup_sh_stubs "${label}c" "$cli" 1 0 "$file")
    _rc_c="$(_run_installer_sh "$_bin_c" "$_root_c" "$_inst_c")"
    if [ "$_rc_c" = "0" ]; then
        pass "$label-c: $(basename "$file") — update failure is soft-failed (installer exits 0)"
    else
        fail "$label-c: $(basename "$file") — update failure aborted installer (rc=$_rc_c)"
    fi
}

_run_exec_group_sh "F1" "$CC_SH" "claude"
_run_exec_group_sh "F2" "$CODEX_SH" "codex"

# ---------------------------------------------------------------------------
# Group F (PS): PowerShell installer execution (claude-code.ps1 / codex.ps1)
# ---------------------------------------------------------------------------

if ! command -v pwsh > /dev/null 2>&1; then
    echo "SKIP: F3/F4 require pwsh (not installed)"
else
    _setup_ps_stubs() {
        local label="$1" cli="$2" cli_exit="${3:-0}" wait_exit="${4:-0}"
        local stub_bin="$TMP_DIR/stubs-ps-$label"
        local mock_root="$TMP_DIR/agents-root-ps-$label"
        rm -rf "$stub_bin" "$mock_root"
        mkdir -p "$stub_bin" "$mock_root/install/lib"
        local call_log="$TMP_DIR/call-log-ps-$label.txt"

        printf '#!/bin/bash\necho "$@" >> "%s"\nexit %s\n' "$call_log" "$cli_exit" \
            > "$stub_bin/$cli"
        chmod +x "$stub_bin/$cli"

        cat > "$mock_root/install/lib/wait-cc-exit.ps1" << WAIT_PS_EOF
exit $wait_exit
WAIT_PS_EOF

        printf '%s %s %s' "$stub_bin" "$mock_root" "$call_log"
    }

    _run_installer_ps() {
        local stub_bin="$1" mock_root="$2" installer="$3"
        local rc=0
        env PATH="$stub_bin:$PATH" \
            AGENTS_ROOT="$mock_root" \
            pwsh -NoProfile -File "$installer" \
            > "$TMP_DIR/ps-installer-stdout" 2> "$TMP_DIR/ps-installer-stderr" || rc=$?
        echo "$rc"
    }

    _run_exec_group_ps() {
        local label="$1" file="$2" cli="$3"
        if [ ! -f "$file" ]; then
            fail "$label-a: $(basename "$file") does not exist (write_code pending)"
            fail "$label-b: $(basename "$file") does not exist"
            fail "$label-c: $(basename "$file") does not exist"
            return
        fi

        read -r _bin_a _root_a _log_a < <(_setup_ps_stubs "${label}a" "$cli" 0 0)
        _rc_a="$(_run_installer_ps "$_bin_a" "$_root_a" "$file")"
        if [ -f "$_log_a" ] && grep -q "^update" "$_log_a" 2>/dev/null; then
            pass "$label-a: $(basename "$file") — guard passes → \`$cli update\` invoked"
        else
            fail "$label-a: $(basename "$file") — guard passes but update not called (rc=$_rc_a)"
        fi

        read -r _bin_b _root_b _log_b < <(_setup_ps_stubs "${label}b" "$cli" 0 1)
        _rc_b="$(_run_installer_ps "$_bin_b" "$_root_b" "$file")"
        _upd_b=0
        [ -f "$_log_b" ] && grep -q "^update" "$_log_b" 2>/dev/null && _upd_b=1
        if [ "$_upd_b" = "0" ] && [ "$_rc_b" = "0" ]; then
            pass "$label-b: $(basename "$file") — guard timeout → update skipped, exits 0"
        else
            fail "$label-b: $(basename "$file") — timeout case wrong (upd=$_upd_b, rc=$_rc_b)"
        fi

        read -r _bin_c _root_c _log_c < <(_setup_ps_stubs "${label}c" "$cli" 1 0)
        _rc_c="$(_run_installer_ps "$_bin_c" "$_root_c" "$file")"
        if [ "$_rc_c" = "0" ]; then
            pass "$label-c: $(basename "$file") — update failure soft-failed (exits 0)"
        else
            fail "$label-c: $(basename "$file") — update failure aborted PS installer (rc=$_rc_c)"
        fi
    }

    _run_exec_group_ps "F3" "$CC_PS" "claude"
    _run_exec_group_ps "F4" "$CODEX_PS" "codex"
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
