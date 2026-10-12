# shellcheck shell=bash
# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.
# --- X1-X3: the installer's own pre-fetch block, executed against a stand-in uv ---
# Reads PREFETCH_FILE and PREFETCH_EXEC_KIND (sh|ps). The block is cut out of the real installer
# and run under that installer's own strictness settings, so only the pre-fetch runs: no link,
# launcher, or settings write of the installer is reached.

_px_name="${PREFETCH_FILE##*/}"
_px_dir="$TMP_DIR/px-$PREFETCH_EXEC_KIND"
mkdir -p "$_px_dir/fail" "$_px_dir/ok" "$_px_dir/none"
# The block runs from its marker comment to the first blank line after it.
_px_block="$(awk '/^# --- pytest pre-fetch/ {on=1} on && /^[[:space:]]*$/ {exit} on' "$PREFETCH_FILE")"

# _px_run <fail|ok|none>: sets PX_RC and PX_OUT (stdout and stderr together).
_px_run() {
    local mode="$1" script
    if [ "$PREFETCH_EXEC_KIND" = "sh" ]; then
        script="$_px_dir/$mode.sh"
        printf '%s\n' 'set -euo pipefail' "C_YELLOW='' C_RESET=''" "$_px_block" 'echo AFTER-PREFETCH' > "$script"
        if [ "$mode" = "none" ]; then
            PX_OUT="$(PATH="$_px_dir/none" "$BASH" "$script" 2>&1)"; PX_RC=$?
        else
            PX_OUT="$(PATH="$_px_dir/$mode:$PATH" "$BASH" "$script" 2>&1)"; PX_RC=$?
        fi
        return 0
    fi
    local bin path_line
    bin="$(cygpath -w "$_px_dir/$mode" 2>/dev/null || printf '%s' "$_px_dir/$mode")"
    if [ "$mode" = "none" ]; then path_line="\$env:PATH = '$bin'"; else path_line="\$env:PATH = '$bin;' + \$env:PATH"; fi
    script="$_px_dir/$mode.ps1"
    printf '%s\n' 'Set-StrictMode -Version Latest' '$ErrorActionPreference = "Stop"' "$path_line" \
        "$_px_block" 'Write-Output "AFTER-PREFETCH"' > "$script"
    PX_OUT="$("$_PX_PS" -NoProfile -ExecutionPolicy Bypass -File "$script" 2>&1)"; PX_RC=$?
}

# Stand-in uv: records its arguments, then exits with the status its directory is named for.
if [ "$PREFETCH_EXEC_KIND" = "sh" ]; then
    printf '%s\n' '#!/bin/sh' "echo \"\$*\" > \"$_px_dir/fail/args\"" 'exit 1' > "$_px_dir/fail/uv"
    printf '%s\n' '#!/bin/sh' "echo \"\$*\" > \"$_px_dir/ok/args\"" 'exit 0' > "$_px_dir/ok/uv"
    chmod +x "$_px_dir/fail/uv" "$_px_dir/ok/uv"
    _PX_PS=""
else
    printf '@echo off\r\necho %%* > "%%~dp0args"\r\nexit /b 1\r\n' > "$_px_dir/fail/uv.cmd"
    printf '@echo off\r\necho %%* > "%%~dp0args"\r\nexit /b 0\r\n' > "$_px_dir/ok/uv.cmd"
    _PX_PS="$(command -v pwsh 2>/dev/null || command -v powershell 2>/dev/null || true)"
fi

if [ -z "$_px_block" ]; then
    fail "X0: $_px_name has no '# --- pytest pre-fetch' block to execute"
elif [ "$PREFETCH_EXEC_KIND" = "ps" ] && [ -z "$_PX_PS" ]; then
    skip "X1-X3: $_px_name — no PowerShell on this host to execute the block"
else
    _px_run fail
    if [ "$PX_RC" -eq 0 ] && [[ "$PX_OUT" == *AFTER-PREFETCH* ]] && [[ "$PX_OUT" == *WARNING*"pre-fetch"* ]]; then
        pass "X1: $_px_name — uv exiting 1 prints a warning and the installer carries on (rc 0)"
    else
        fail "X1: $_px_name — a failing uv stopped the installer or printed no warning (rc=$PX_RC out=$PX_OUT)"
    fi
    if grep -q -- '--no-project --with pytest python -c' "$_px_dir/fail/args" 2>/dev/null; then
        pass "X1b: $_px_name — the stand-in uv received the pytest pre-fetch arguments"
    else
        fail "X1b: $_px_name — uv was not called with the pre-fetch arguments (args=$(cat "$_px_dir/fail/args" 2>/dev/null))"
    fi

    _px_run none
    if [ "$PX_RC" -eq 0 ] && [[ "$PX_OUT" == *AFTER-PREFETCH* ]] && [[ "$PX_OUT" == *WARNING* ]]; then
        pass "X2: $_px_name — uv absent from PATH prints a warning and the installer carries on (rc 0)"
    else
        fail "X2: $_px_name — a missing uv stopped the installer or printed no warning (rc=$PX_RC out=$PX_OUT)"
    fi

    _px_run ok
    if [ "$PX_RC" -eq 0 ] && [[ "$PX_OUT" == *AFTER-PREFETCH* ]] && [[ "$PX_OUT" != *WARNING* ]]; then
        pass "X3: $_px_name — uv exiting 0 prints no warning"
    else
        fail "X3: $_px_name — a successful pre-fetch warned or stopped the installer (rc=$PX_RC out=$PX_OUT)"
    fi
fi
