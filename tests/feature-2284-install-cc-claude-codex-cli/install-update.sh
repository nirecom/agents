#!/bin/bash
# tests/feature-2284-install-cc-claude-codex-cli/install-update.sh
# Sub-file: installer update integration tests (Groups C/D/E) and mutation probes.
# Static detectors check that each installer: (1) invokes `cli update`, (2) gates it
# after wait-cc-exit (with skip on exit-1), (3) soft-fails on update failure, (4) scopes
# the guard AFTER the already-installed check (not at script top), (5) reaches the update
# even in the already-installed path.
# Tests: install/linux/claude-code.sh, install/win/claude-code.ps1, install/linux/codex.sh, install/win/codex.ps1
# Tags: installer, wait-cc-exit, pwsh-required, scope:issue-specific
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
# Detector functions — each reads the file it receives on every call.
# ---------------------------------------------------------------------------

# First *executable* wait-cc-exit reference (comments excluded).
wait_ref_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE 'wait-cc-exit\.(sh|ps1)' "$file" \
        | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# First `<cli> update` invocation (comments excluded — HIGH-3).
update_line() {
    local file="$1" cli="$2"
    [ -f "$file" ] || return 0
    grep -nE "(^|[^-[:alnum:]])${cli}[[:space:]]+update([[:space:]]|\$)" "$file" \
        | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# Line of the already-installed detection (`type <cli>` / `Get-Command <cli>`).
already_installed_line() {
    local file="$1" cli="$2" kind="$3"
    [ -f "$file" ] || return 0
    if [ "$kind" = "sh" ]; then
        grep -nE "type[[:space:]]+${cli}([[:space:]]|\$)" "$file" | head -n1 | cut -d: -f1
    else
        grep -nE "Get-Command[[:space:]]+${cli}([[:space:]]|\)|\$)" "$file" | head -n1 | cut -d: -f1
    fi
}

# First `exit 0` after line $2.
early_exit_line_after() {
    local file="$1" after="$2"
    awk -v after="$after" '
        NR > after &&
        ($0 ~ /^[[:space:]]*exit[[:space:]]+0([[:space:]]|$)/ ||
         $0 ~ /[{;][[:space:]]*exit[[:space:]]+0([[:space:]]|\}|$)/) { print NR; exit }
    ' "$file"
}

# Guard line has its exit code bound to a branch (POSIX form).
sh_guard_result_is_bound() {
    local file="$1" wline
    wline="$(wait_ref_line "$file")"
    [ -n "$wline" ] || return 1
    sed -n "${wline}p" "$file" | grep -Eq '(^[[:space:]]*(if|while|until)[[:space:]]|\|\|)'
}

# Guard exit code bound in PowerShell: $LASTEXITCODE check or try/catch within 3 lines.
ps_guard_result_is_bound() {
    local file="$1" wline
    wline="$(wait_ref_line "$file")"
    [ -n "$wline" ] || return 1
    sed -n "$((wline > 3 ? wline - 3 : 1)),$((wline + 6))p" "$file" \
        | grep -Eq '(\$LASTEXITCODE|if[[:space:]]*\(|try[[:space:]]*\{|catch)'
}

# A skip (exit 0 / return) inside the guard's own branch, bounded to 6 lines.
_skip_between() {
    local file="$1" from="$2" before="$3" to
    to=$((from + 6))
    [ "$to" -ge "$before" ] && to=$((before - 1))
    [ "$to" -ge "$from" ] || return 1
    sed -n "${from},${to}p" "$file" \
        | grep -Eq '(exit[[:space:]]+0|(^|[[:space:]]|;|\{)return([[:space:]]|;|\}|$))'
}

# Soft-fail: `cli update … || true|:` pattern.
sh_update_soft_fails() {
    local file="$1" cli="$2"
    [ -f "$file" ] || return 1
    grep -Eq "${cli}[[:space:]]+update.*\|\|[[:space:]]*(true|:)" "$file"
}

# PowerShell soft-fail: failure caught ($LASTEXITCODE / try-catch) + warning, no throw.
ps_update_soft_fails() {
    local file="$1" cli="$2" line block
    line="$(update_line "$file" "$cli")"
    [ -n "$line" ] || return 1
    block="$(sed -n "${line},$((line + 8))p" "$file")"
    printf '%s\n' "$block" | grep -q 'throw' && return 1
    printf '%s\n' "$block" | grep -Eq \
        '(\$LASTEXITCODE|try[[:space:]]*\{|catch|SilentlyContinue|PSNativeCommandUseErrorActionPreference)' \
        || return 1
    printf '%s\n' "$block" | grep -Eq '(Write-Warning|SilentlyContinue)'
}

# Guard referenced before update (ordering).
update_is_gated() {
    local file="$1" cli="$2" wline uline
    wline="$(wait_ref_line "$file")"
    uline="$(update_line "$file" "$cli")"
    [ -n "$wline" ] && [ -n "$uline" ] && [ "$wline" -lt "$uline" ]
}

# Guard exit code actually consumed so a timeout skips the update.
update_is_skip_gated() {
    local file="$1" cli="$2" kind="$3" wline uline
    wline="$(wait_ref_line "$file")"
    uline="$(update_line "$file" "$cli")"
    [ -n "$wline" ] && [ -n "$uline" ] && [ "$wline" -lt "$uline" ] || return 1
    if [ "$kind" = "sh" ]; then
        sh_guard_result_is_bound "$file" || return 1
    else
        ps_guard_result_is_bound "$file" || return 1
    fi
    _skip_between "$file" "$wline" "$uline"
}

# Update reachable from already-installed path (not dead code after an early exit).
update_is_reachable_when_installed() {
    local file="$1" cli="$2" kind="$3" uline tline eline
    uline="$(update_line "$file" "$cli")"
    [ -n "$uline" ] || return 1
    tline="$(already_installed_line "$file" "$cli" "$kind")"
    [ -n "$tline" ] || return 0
    [ "$uline" -lt "$tline" ] && return 0
    eline="$(early_exit_line_after "$file" "$tline")"
    [ -n "$eline" ] || return 0
    [ "$uline" -lt "$eline" ]
}

# Guard must be scoped AFTER the already-installed check, not before it (HIGH-1).
# Placing the guard before the install check would skip new installs, not just updates.
update_guard_is_scoped() {
    local file="$1" cli="$2" kind="$3" wline tline
    wline="$(wait_ref_line "$file")"
    tline="$(already_installed_line "$file" "$cli" "$kind")"
    [ -n "$wline" ] && [ -n "$tline" ] && [ "$wline" -gt "$tline" ]
}

check_update_group() {
    local label="$1" file="$2" cli="$3" kind="$4"

    if [ -n "$(update_line "$file" "$cli")" ]; then
        pass "$label-1: $(basename "$file") invokes \`$cli update\`"
    else
        fail "$label-1: $(basename "$file") has no \`$cli update\` invocation"
    fi

    if update_is_gated "$file" "$cli"; then
        pass "$label-2: \`$cli update\` is gated by wait-cc-exit (reference precedes it)"
    else
        fail "$label-2: \`$cli update\` has no preceding wait-cc-exit reference"
    fi

    if [ "$kind" = "sh" ]; then
        if sh_update_soft_fails "$file" "$cli"; then
            pass "$label-3: \`$cli update\` soft-fails (|| true / || :)"
        else
            fail "$label-3: \`$cli update\` failure is not soft-failed"
        fi
    else
        if ps_update_soft_fails "$file" "$cli"; then
            pass "$label-3: \`$cli update\` soft-fails (failure caught, warning, no throw)"
        else
            fail "$label-3: \`$cli update\` failure is not soft-failed"
        fi
    fi

    if update_is_skip_gated "$file" "$cli" "$kind"; then
        pass "$label-4: guard timeout skips \`$cli update\` (exit code consumed, skip path present)"
    else
        fail "$label-4: guard timeout does not skip \`$cli update\` (exit code ignored or no skip path)"
    fi

    if update_is_reachable_when_installed "$file" "$cli" "$kind"; then
        pass "$label-5: \`$cli update\` is reachable when $cli is already installed"
    else
        fail "$label-5: \`$cli update\` is dead code after the already-installed early exit"
    fi

    if update_guard_is_scoped "$file" "$cli" "$kind"; then
        pass "$label-6: wait-cc-exit guard is scoped after the install check (not at script top)"
    else
        fail "$label-6: wait-cc-exit guard precedes the install check — would skip new installs"
    fi
}

# --- Group C: claude-code installers ---
check_update_group "C" "$CC_SH" "claude" "sh"
check_update_group "C4" "$CC_PS" "claude" "ps"

# --- Group D: codex installers ---
check_update_group "D" "$CODEX_SH" "codex" "sh"
check_update_group "D4" "$CODEX_PS" "codex" "ps"

# --- CPR-ORTH: guard is symmetric across both platforms ---
for _pair in "claude:$CC_SH:$CC_PS" "codex:$CODEX_SH:$CODEX_PS"; do
    _cli="${_pair%%:*}"
    _rest="${_pair#*:}"
    _sh="${_rest%%:*}"
    _ps="${_rest#*:}"
    _sh_ok=0; _ps_ok=0
    update_is_skip_gated "$_sh" "$_cli" "sh" && _sh_ok=1
    update_is_skip_gated "$_ps" "$_cli" "ps" && _ps_ok=1
    if [ "$_sh_ok" = "1" ] && [ "$_ps_ok" = "1" ]; then
        pass "ORTH: $_cli update is skip-guarded on both platforms"
    else
        fail "ORTH: one-sided $_cli update guard (posix=$_sh_ok, win=$_ps_ok; both must be 1)"
    fi
done

# ---------------------------------------------------------------------------
# Mutation probes — detectors must discriminate, not merely be red today.
# ---------------------------------------------------------------------------

MUT_DIR="$TMP_DIR/mut"
mkdir -p "$MUT_DIR"

# Reference implementation: guard scoped after install check, skip path present.
cat > "$MUT_DIR/good.sh" << 'GOOD_SH_EOF'
#!/bin/bash
set -euo pipefail
if type claude >/dev/null 2>&1; then
    if ! bash "$AGENTS_ROOT/install/lib/wait-cc-exit.sh"; then
        echo "CC running; skipping update." >&2; exit 0
    fi
    claude update || true
    exit 0
fi
echo "Installing Claude Code..."
GOOD_SH_EOF

cat > "$MUT_DIR/good.ps1" << 'GOOD_PS_EOF'
if (Get-Command claude -ErrorAction SilentlyContinue) {
    & pwsh -NoProfile -File (Join-Path $AgentsRoot "install\lib\wait-cc-exit.ps1")
    if ($LASTEXITCODE -ne 0) { Write-Warning "CC running; skipping update."; exit 0 }
    claude update
    if ($LASTEXITCODE -ne 0) { Write-Warning "claude update failed; retry manually." }
    exit 0
}
Write-Host "Installing..."
GOOD_PS_EOF

# Guard exit code discarded (|| true) — HIGH-1 ungated shape.
cat > "$MUT_DIR/ungated.sh" << 'UNGATED_EOF'
#!/bin/bash
set -euo pipefail
if type claude >/dev/null 2>&1; then
    bash "$AGENTS_ROOT/install/lib/wait-cc-exit.sh" || true
    claude update || true
    exit 0
fi
UNGATED_EOF

# Guard reference in a comment only.
sed 's|^    if ! bash|    # if ! bash|' "$MUT_DIR/good.sh" > "$MUT_DIR/commented.sh"

# Skip path removed (guard call valid but no exit 0 inside the branch).
grep -v 'exit 0' "$MUT_DIR/good.sh" > "$MUT_DIR/noskip.sh"

# Guard placed BEFORE the already-installed check (too-early — HIGH-1).
cat > "$MUT_DIR/too-early.sh" << 'TOO_EARLY_EOF'
#!/bin/bash
set -euo pipefail
if ! bash "$AGENTS_ROOT/install/lib/wait-cc-exit.sh"; then
    echo "CC running; skipping update." >&2; exit 0
fi
if type claude >/dev/null 2>&1; then
    claude update || true
    exit 0
fi
echo "Installing..."
TOO_EARLY_EOF

# update line commented out.
cat > "$MUT_DIR/commented-update.sh" << 'COMMENTED_UPDATE_EOF'
#!/bin/bash
if type claude >/dev/null 2>&1; then
    # claude update || true
    exit 0
fi
COMMENTED_UPDATE_EOF

_probe() {
    local name="$1" file="$2" cli="$3" kind="$4" want="$5" got=0
    update_is_skip_gated "$file" "$cli" "$kind" && got=1
    if [ "$got" = "$want" ]; then
        pass "MUT-$name: skip-gate detector returns $got as required"
    else
        fail "MUT-$name: skip-gate detector returned $got, expected $want"
    fi
}

_probe "good-sh"     "$MUT_DIR/good.sh"      "claude" "sh" 1
_probe "good-ps"     "$MUT_DIR/good.ps1"     "claude" "ps" 1
_probe "ungated"     "$MUT_DIR/ungated.sh"   "claude" "sh" 0
_probe "commented"   "$MUT_DIR/commented.sh" "claude" "sh" 0
_probe "noskip"      "$MUT_DIR/noskip.sh"    "claude" "sh" 0

# Scope probe: too-early guard must fail update_guard_is_scoped.
_scope_good=0; _scope_early=0
update_guard_is_scoped "$MUT_DIR/good.sh" "claude" "sh" && _scope_good=1
update_guard_is_scoped "$MUT_DIR/too-early.sh" "claude" "sh" && _scope_early=1
if [ "$_scope_good" = "1" ] && [ "$_scope_early" = "0" ]; then
    pass "MUT-scope: scope detector accepts in-branch guard and rejects too-early guard"
else
    fail "MUT-scope: scope detector (good=$_scope_good expected 1, early=$_scope_early expected 0)"
fi

# Commented-update probe: update_line must not match a commented line.
_cu_line="$(update_line "$MUT_DIR/commented-update.sh" "claude")"
if [ -z "$_cu_line" ]; then
    pass "MUT-commented-update: commented update line not detected as invocation"
else
    fail "MUT-commented-update: commented update line falsely detected at line=$_cu_line"
fi

# Reachability probes.
cat > "$MUT_DIR/reach-live.sh" << 'REACH_LIVE_EOF'
#!/bin/bash
if type claude >/dev/null 2>&1; then
    claude update || true
    exit 0
fi
REACH_LIVE_EOF
cat > "$MUT_DIR/reach-dead.sh" << 'REACH_DEAD_EOF'
#!/bin/bash
if type claude >/dev/null 2>&1; then
    echo "already installed"
    exit 0
fi
claude update || true
REACH_DEAD_EOF

_reach_live=0; _reach_dead=0
update_is_reachable_when_installed "$MUT_DIR/reach-live.sh" "claude" "sh" && _reach_live=1
update_is_reachable_when_installed "$MUT_DIR/reach-dead.sh" "claude" "sh" && _reach_dead=1
if [ "$_reach_live" = "1" ] && [ "$_reach_dead" = "0" ]; then
    pass "MUT-reach: reachability detector separates in-branch from post-exit update"
else
    fail "MUT-reach: reachability detector (live=$_reach_live expected 1, dead=$_reach_dead expected 0)"
fi

# ---------------------------------------------------------------------------
# Group E: exit-code contract — guard timeout must not abort the caller.
# ---------------------------------------------------------------------------

cat > "$TMP_DIR/fake-guard.sh" << 'FAKE_GUARD_EOF'
#!/bin/bash
exit 1
FAKE_GUARD_EOF
chmod +x "$TMP_DIR/fake-guard.sh"

cat > "$TMP_DIR/caller.sh" << 'CALLER_EOF'
#!/bin/bash
set -euo pipefail
if ! bash "$1"; then
    echo "skipped"
    exit 0
fi
echo "updated"
CALLER_EOF

_e1_rc=0
_e1_out="$(bash "$TMP_DIR/caller.sh" "$TMP_DIR/fake-guard.sh" 2>&1)" || _e1_rc=$?
if [ "$_e1_rc" = "0" ] && [ "$_e1_out" = "skipped" ]; then
    pass "E1: under set -e a guard timeout skips the update and the caller exits 0"
else
    fail "E1: guard timeout broke the caller contract (rc=$_e1_rc, out=$_e1_out)"
fi

if ! command -v pwsh > /dev/null 2>&1; then
    echo "SKIP: E2/E2b require pwsh (not installed)"
else
    # E2: with PSNativeCommandUseErrorActionPreference=$false (pre-7.4 default),
    # $LASTEXITCODE-check soft-fail shape exits 0.
    cat > "$TMP_DIR/caller.ps1" << 'CALLER_PS_EOF'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
& /usr/bin/false
if ($LASTEXITCODE -ne 0) {
    Write-Warning "update failed; continuing"
}
Write-Output "continued"
exit 0
CALLER_PS_EOF
    _e2_rc=0
    _e2_out="$(pwsh -NoProfile -File "$TMP_DIR/caller.ps1" 2>&1)" || _e2_rc=$?
    if [ "$_e2_rc" = "0" ] && printf '%s' "$_e2_out" | grep -q "continued"; then
        pass "E2: PSNativeCommandUseErrorActionPreference=false — LASTEXITCODE soft-fail exits 0"
    else
        fail "E2: LASTEXITCODE soft-fail shape aborts (rc=$_e2_rc, out=$_e2_out)"
    fi

    # E2b: with PSNativeCommandUseErrorActionPreference=$true (pwsh 7.4+ default),
    # the installer must use try/catch so a failed native command is still handled gracefully.
    cat > "$TMP_DIR/caller-trycatch.ps1" << 'CALLER_TC_EOF'
Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $true
try {
    & /usr/bin/false
} catch {
    Write-Warning "update failed; continuing"
}
Write-Output "continued"
exit 0
CALLER_TC_EOF
    _e2b_rc=0
    _e2b_out="$(pwsh -NoProfile -File "$TMP_DIR/caller-trycatch.ps1" 2>&1)" || _e2b_rc=$?
    if [ "$_e2b_rc" = "0" ] && printf '%s' "$_e2b_out" | grep -q "continued"; then
        pass "E2b: PSNativeCommandUseErrorActionPreference=true — try/catch soft-fail exits 0"
    else
        fail "E2b: try/catch soft-fail shape aborts under true (rc=$_e2b_rc, out=$_e2b_out)"
    fi
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
