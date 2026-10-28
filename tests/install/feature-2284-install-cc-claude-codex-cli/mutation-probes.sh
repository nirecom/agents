# Sourced by tests/install/feature-2284-install-cc-claude-codex-cli.sh inside a case span
# (needs the detectors from install-update.sh).
# Mutation probes — detectors must discriminate, not merely be red today.

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
    & pwsh -NoProfile -File (Join-Path $SCRIPT_CHECKOUT_ROOT "install\lib\wait-cc-exit.ps1")
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

# #2476: the guard's own skip-branch `exit 0` must not mark the update dead, while an
# unconditional `exit 0` after the guard still must.
cat > "$MUT_DIR/reach-ps-multi.ps1" << 'REACH_PS_MULTI_EOF'
if (Get-Command claude -ErrorAction SilentlyContinue) {
    & pwsh -NoProfile -File (Join-Path $SCRIPT_CHECKOUT_ROOT "install\lib\wait-cc-exit.ps1")
    if ($LASTEXITCODE -ne 0) {
        Write-Warning "CC running; skipping update."
        exit 0
    }
    claude update
    exit 0
}
REACH_PS_MULTI_EOF
sed '6a\    exit 0' "$MUT_DIR/good.sh" > "$MUT_DIR/reach-uncond.sh"
sed '3a\    exit 0' "$MUT_DIR/good.ps1" > "$MUT_DIR/reach-uncond.ps1"

_reach_probe() {
    local name="$1" file="$2" kind="$3" want="$4" got=0
    update_is_reachable_when_installed "$file" "claude" "$kind" && got=1
    if [ "$got" = "$want" ]; then
        pass "MUT-reach-$name: reachability detector returns $got as required"
    else
        fail "MUT-reach-$name: reachability detector returned $got, expected $want"
    fi
}
_reach_probe guarded-sh           "$MUT_DIR/good.sh"            sh 1
_reach_probe guarded-ps           "$MUT_DIR/good.ps1"           ps 1
_reach_probe guarded-ps-multiline "$MUT_DIR/reach-ps-multi.ps1" ps 1
_reach_probe uncond-after-sh      "$MUT_DIR/reach-uncond.sh"    sh 0
_reach_probe uncond-after-ps      "$MUT_DIR/reach-uncond.ps1"   ps 0
