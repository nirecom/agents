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

# ---------------------------------------------------------------------------
# #2808: codex.ps1 structure detectors (wait order, prefix guard, try/catch).
# ---------------------------------------------------------------------------
cat > "$MUT_DIR/good-codex.ps1" << 'GOOD_CODEX_EOF'
if (Get-Command codex -ErrorAction SilentlyContinue) {
    foreach ($_proc in @('claude', 'codex')) {
        & pwsh -NoProfile -File (Join-Path $SCRIPT_CHECKOUT_ROOT "install\lib\wait-cc-exit.ps1") -ProcessName $_proc
        if ($LASTEXITCODE -ne 0) { Write-Warning "$_proc running; skipping update."; exit 0 }
    }
    try {
        $prefix = (& npm prefix -g)
        if (Test-CodexUnderNpmPrefix -NpmPrefix $prefix) {
            npm install -g @openai/codex
            $npmExit = $LASTEXITCODE
            if ($npmExit -ne 0) {
                Write-Warning "npm install failed"
            }
        } else {
            Write-Warning "codex is not under the npm global prefix"
        }
    } catch {
        Write-Warning "codex update skipped"
    }
    exit 0
}
Write-Host "Installing..."
GOOD_CODEX_EOF

# Only claude waited for (codex stage missing).
sed "s|@('claude', 'codex')|@('claude')|" "$MUT_DIR/good-codex.ps1" > "$MUT_DIR/codex-wait-claude-only.ps1"
# Order reversed: codex first.
sed "s|@('claude', 'codex')|@('codex', 'claude')|" "$MUT_DIR/good-codex.ps1" > "$MUT_DIR/codex-wait-reversed.ps1"
# Loop header only mentioned in a comment.
sed "s|^    foreach (\$_proc in @('claude', 'codex')) {|    # @('claude', 'codex')\n    foreach (\$_proc in @('claude')) {|" "$MUT_DIR/good-codex.ps1" > "$MUT_DIR/codex-wait-commented.ps1"
# Prefix guard removed: npm runs unconditionally.
sed 's|if (Test-CodexUnderNpmPrefix -NpmPrefix \$prefix) {|if ($true) {|' "$MUT_DIR/good-codex.ps1" > "$MUT_DIR/codex-no-prefix-check.ps1"
# Guard negated: the update would run when NOT under the prefix.
sed 's|if (Test-CodexUnderNpmPrefix -NpmPrefix \$prefix) {|if (-not (Test-CodexUnderNpmPrefix -NpmPrefix $prefix)) {|' "$MUT_DIR/good-codex.ps1" > "$MUT_DIR/codex-prefix-negated.ps1"
# Guard in a comment only.
sed 's|if (Test-CodexUnderNpmPrefix -NpmPrefix \$prefix) {|if ($true) { # Test-CodexUnderNpmPrefix|' "$MUT_DIR/good-codex.ps1" > "$MUT_DIR/codex-prefix-commented.ps1"
# Update placed in the else side of the guard.
cat > "$MUT_DIR/codex-update-in-else.ps1" << 'CODEX_ELSE_EOF'
if (Get-Command codex -ErrorAction SilentlyContinue) {
    foreach ($_proc in @('claude', 'codex')) {
        & pwsh -NoProfile -File (Join-Path $SCRIPT_CHECKOUT_ROOT "install\lib\wait-cc-exit.ps1") -ProcessName $_proc
        if ($LASTEXITCODE -ne 0) { exit 0 }
    }
    try {
        if (Test-CodexUnderNpmPrefix -NpmPrefix $prefix) {
            Write-Host "ok"
        } else {
            npm install -g @openai/codex
        }
    } catch {
        Write-Warning "skipped"
    }
    exit 0
}
CODEX_ELSE_EOF
# try removed (update section no longer wrapped).
cat > "$MUT_DIR/codex-no-try.ps1" << 'CODEX_NOTRY_EOF'
if (Get-Command codex -ErrorAction SilentlyContinue) {
    $prefix = (& npm prefix -g)
    if (Test-CodexUnderNpmPrefix -NpmPrefix $prefix) {
        npm install -g @openai/codex
        $npmExit = $LASTEXITCODE
        if ($npmExit -ne 0) {
            Write-Warning "npm install failed"
        }
    }
    exit 0
}
try { Write-Host "elsewhere" } catch { Write-Warning "x" }
CODEX_NOTRY_EOF
# try exists but the update sits after its closing brace and catch.
cat > "$MUT_DIR/codex-try-elsewhere.ps1" << 'CODEX_TRYELSE_EOF'
if (Get-Command codex -ErrorAction SilentlyContinue) {
    try {
        $prefix = (& npm prefix -g)
    } catch {
        Write-Warning "prefix failed"
    }
    if (Test-CodexUnderNpmPrefix -NpmPrefix $prefix) {
        npm install -g @openai/codex
        $npmExit = $LASTEXITCODE
        if ($npmExit -ne 0) {
            Write-Warning "npm install failed"
        }
    }
    exit 0
}
CODEX_TRYELSE_EOF
# try without an immediate catch (finally only).
sed 's|^    } catch {$|    } finally {|' "$MUT_DIR/good-codex.ps1" > "$MUT_DIR/codex-try-no-catch.ps1"

# _cprobe <name> <detector> <file> <want>
_cprobe() {
    local name="$1" fn="$2" file="$3" want="$4" got=0
    "$fn" "$file" && got=1
    if [ "$got" = "$want" ]; then
        pass "MUT-codex-$name: $fn returns $got as required"
    else
        fail "MUT-codex-$name: $fn returned $got, expected $want"
    fi
}
_cprobe good-wait            wait_covers_claude_then_codex "$MUT_DIR/good-codex.ps1"             1
_cprobe wait-claude-only     wait_covers_claude_then_codex "$MUT_DIR/codex-wait-claude-only.ps1" 0
_cprobe wait-reversed        wait_covers_claude_then_codex "$MUT_DIR/codex-wait-reversed.ps1"    0
_cprobe wait-commented       wait_covers_claude_then_codex "$MUT_DIR/codex-wait-commented.ps1"   0
_cprobe good-prefix          update_requires_prefix_check  "$MUT_DIR/good-codex.ps1"             1
_cprobe no-prefix-check      update_requires_prefix_check  "$MUT_DIR/codex-no-prefix-check.ps1"  0
_cprobe prefix-negated       update_requires_prefix_check  "$MUT_DIR/codex-prefix-negated.ps1"   0
_cprobe prefix-commented     update_requires_prefix_check  "$MUT_DIR/codex-prefix-commented.ps1" 0
_cprobe update-in-else       update_requires_prefix_check  "$MUT_DIR/codex-update-in-else.ps1"   0
_cprobe good-try             update_section_is_try_wrapped "$MUT_DIR/good-codex.ps1"             1
_cprobe no-try               update_section_is_try_wrapped "$MUT_DIR/codex-no-try.ps1"          0
_cprobe try-elsewhere        update_section_is_try_wrapped "$MUT_DIR/codex-try-elsewhere.ps1"    0
_cprobe try-no-catch         update_section_is_try_wrapped "$MUT_DIR/codex-try-no-catch.ps1"     0

# Table-driven update_line contract: name | cli | input | want.
# input "@file:<name>" reads $MUT_DIR/<name>; any other input is written as a single line.
# want is the expected line number, or "none" when no update must be detected.
while IFS='|' read -r _ul_name _ul_cli _ul_input _ul_want; do
    [[ -z "$_ul_name" || "$_ul_name" =~ ^[[:space:]]*# ]] && continue
    _ul_name="${_ul_name//[[:space:]]/}"
    _ul_cli="${_ul_cli//[[:space:]]/}"
    _ul_want="${_ul_want//[[:space:]]/}"
    _ul_ref="${_ul_input//[[:space:]]/}"
    if [[ "$_ul_ref" == @file:* ]]; then
        _ul_file="$MUT_DIR/${_ul_ref#@file:}"
    else
        _ul_file="$MUT_DIR/ul-row.ps1"
        printf '%s\n' "$_ul_input" > "$_ul_file"
    fi
    _ul_got="$(update_line "$_ul_file" "$_ul_cli")"
    [ -n "$_ul_got" ] || _ul_got="none"
    if [ "$_ul_got" = "$_ul_want" ]; then
        pass "MUT-codex-update-line-$_ul_name: got=$_ul_got"
    else
        fail "MUT-codex-update-line-$_ul_name: got=$_ul_got, expected $_ul_want"
    fi
done <<'UL_TABLE'
npm-form-file      | codex  | @file:good-codex.ps1                                   | 9
claude-in-codex    | claude | @file:good-codex.ps1                                   | none
exec-indented      | codex  |     npm install -g @openai/codex                       | 1
exec-then-comment  | codex  | npm install -g @openai/codex # refresh                 | 1
in-double-quotes   | codex  | Write-Host "npm install -g @openai/codex"              | none
quoted-with-semi   | codex  | Write-Host "x; npm install -g @openai/codex"           | none
trailing-comment   | codex  | foo # npm install -g @openai/codex                     | none
whole-comment      | codex  | # npm install -g @openai/codex                         | none
similar-codex-foo  | codex  | npm install -g @openai/codex-foo                       | none
similar-codexx     | codex  | npm install -g @openai/codexx                          | none
UL_TABLE
