# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.
# --- B5 (PowerShell): mutation probes — detectors must discriminate, not merely be red today ---

# B5g: too-early PS — guard before DOTFILESLINK_LINKS_ONLY must fail _guard_scope_ok_dotfiles.
_mut_early_ps="$TMP_DIR/dotfileslink-too-early.ps1"
cat > "$_mut_early_ps" << 'EARLY_PS_EOF'
& pwsh -NoProfile -File "$PSScriptRoot/../../install/lib/wait-cc-exit.ps1"
if ($LASTEXITCODE -ne 0) { Write-Warning "CC running; skipping."; exit 0 }
if ($env:DOTFILESLINK_LINKS_ONLY -eq "1") { exit 0 }
$links = @(@{ Source = "skills/workflow-init"; Dest = "$AgentsRoot\skills\wf-init" })
foreach ($link in $links) { }
node "$PSScriptRoot/../../install/assemble-settings.js"
EARLY_PS_EOF
_mut_early_ps_scope=0
_guard_scope_ok_dotfiles "$_mut_early_ps" && _mut_early_ps_scope=1
if [ "$_mut_early_ps_scope" = "0" ]; then
    pass "B5g: B4b scope detector rejects a too-early PS guard (before DOTFILESLINK_LINKS_ONLY)"
else
    fail "B5g: B4b scope detector is false-green for a too-early PS guard"
fi

# B5d: PS good — guard with $LASTEXITCODE check must make B4 green.
_mut_good_ps="$TMP_DIR/dotfileslink-good.ps1"
cat > "$_mut_good_ps" << 'GOOD_PS_EOF'
& pwsh -NoProfile -File "$PSScriptRoot/../../install/lib/wait-cc-exit.ps1"
if ($LASTEXITCODE -ne 0) {
    Write-Warning "CC still running; skipping settings write."
    exit 0
}
node "$PSScriptRoot/../../install/assemble-settings.js"
GOOD_PS_EOF
_skip_probe B5d "$_mut_good_ps" 1 "correctly guarded PS caller (exit form)"

# B5e: PS noskip — guard without $LASTEXITCODE check must make B4 red.
_mut_noskip_ps="$TMP_DIR/dotfileslink-noskip.ps1"
cat > "$_mut_noskip_ps" << 'NOSKIP_PS_EOF'
& pwsh -NoProfile -File "$PSScriptRoot/../../install/lib/wait-cc-exit.ps1"
node "$PSScriptRoot/../../install/assemble-settings.js"
NOSKIP_PS_EOF
_skip_probe B5e "$_mut_noskip_ps" 0 "PS guard exit code not checked"

# B5i: PS narrow skip (#2476 dotfileslink.ps1 shape) — assemble inside `-eq 0` → green.
_mut_narrow_ps="$TMP_DIR/dotfileslink-narrow.ps1"
cat > "$_mut_narrow_ps" << 'NARROW_PS_EOF'
& pwsh -NoProfile -File (Join-Path $AgentsRoot "install\lib\wait-cc-exit.ps1")
if ($LASTEXITCODE -eq 0) {
    & node (Join-Path $AgentsRoot "install\assemble-settings.js")
    if ($LASTEXITCODE -ne 0) { throw "assemble-settings.js failed (exit $LASTEXITCODE)" }
} else {
    Write-Warning "Claude Code still running — skipping settings.json write."
}
NARROW_PS_EOF
_skip_probe B5i "$_mut_narrow_ps" 1 "PS narrow skip (assemble inside if (\$LASTEXITCODE -eq 0))"

# B5j: inverted PS narrow form — assemble inside `-ne 0`, no exit/return → red.
_mut_inverted_ps="$TMP_DIR/dotfileslink-inverted.ps1"
sed 's/-eq 0) {$/-ne 0) {/' "$_mut_narrow_ps" > "$_mut_inverted_ps"
_skip_probe B5j "$_mut_inverted_ps" 0 "inverted PS branch (assemble runs only on timeout)"
