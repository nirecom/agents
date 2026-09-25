#!/bin/bash
# tests/feature-1743-wf-init-symlink-static.sh
# Tests: install/win/dotfileslink.ps1, install/linux/dotfileslink.sh, .gitignore
# Tags: installer, symlink, wf-init, gitignore, dotfileslink, scope:issue-specific
#
# Issue #1743: installer-created directory symlink alias /wf-init -> /workflow-init.
# Both installers must create skills/wf-init as a symlink to skills/workflow-init
# (CPR-ORTH symmetry), and the generated path must stay untracked (.gitignore).
#
# Layer: TL2 (static/grep over the real installer sources; no installer execution).
set -u

# TL3 gap (what this test does NOT catch):
# - Whether the symlink is actually created on a real Windows host (Developer Mode /
#   admin privileges, MSYS winsymlinks) and on a real POSIX host.
# - Whether Claude Code's skill scanner resolves /wf-init to the same SKILL.md
#   without erroring or double-counting the skill in the slash-command list.
# Accepted tradeoff: real-machine verification of the symlink approach was explicitly
# deferred by user decision for this session (see outline.md).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
PS_FILE="$AGENTS_DIR/install/win/dotfileslink.ps1"
SH_FILE="$AGENTS_DIR/install/linux/dotfileslink.sh"
GITIGNORE_FILE="$AGENTS_DIR/.gitignore"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT

# --- content-derived detectors (each reads the file passed to it, every call) ---

# Windows: a $links entry whose Source is skills\workflow-init and Dest is skills\wf-init.
has_win_entry() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*skills[\\/]wf-init' "$file"
}

# Windows: the same entry, with Dest anchored under the repo root ($AgentsRoot).
# The whole point of this alias is that it is repo-internal — every other entry in the
# same $links table targets $ClaudeDir, so an accidental $ClaudeDir Dest here would look
# plausible and still be wrong (CPR-ORTH orthogonality: this member differs by design).
has_win_dest_under_agents_root() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*Dest[[:space:]]*=[[:space:]]*"\$AgentsRoot[\\/]skills[\\/]wf-init"' "$file"
}

# Windows: the wrong-root regression — Dest pointing under $ClaudeDir instead.
has_win_dest_under_claude_dir() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*Dest[[:space:]]*=[[:space:]]*"\$ClaudeDir[\\/]' "$file"
}

# Windows: the wf-init entry must declare IsDir = $true (directory symlink, not a file).
has_win_isdir_true() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"[^#]*IsDir[[:space:]]*=[[:space:]]*\$true' "$file"
}

# POSIX: a _link_one call with skills/workflow-init as source and skills/wf-init as dest.
has_sh_entry() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -Eq '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$file"
}

# .gitignore: a line that is exactly `skills/wf-init` (not a substring of a longer pattern).
has_gitignore_line() {
    local file="$1"
    [ -f "$file" ] || return 1
    grep -qx 'skills/wf-init' "$file"
}

# Line number (1-based) of the wf-init _link_one call; empty when absent.
sh_wf_init_line() {
    local file="$1"
    grep -nE '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$file" \
        | head -n1 | cut -d: -f1
}

# Line number of the `fi` that closes the `if [ -d ~/.claude/.git ]` guard; empty on mismatch.
sh_guard_close_line() {
    local file="$1"
    awk '
        started == 0 {
            if ($0 ~ /^[[:space:]]*if[[:space:]].*\.claude\/\.git/) { started = 1; depth = 1 }
            next
        }
        {
            if ($0 ~ /^[[:space:]]*if[[:space:]]/) depth++
            if ($0 ~ /^[[:space:]]*fi([[:space:]]|$)/) {
                depth--
                if (depth == 0) { print NR; exit }
            }
        }
    ' "$file"
}

# --- L1: Windows installer entry present (normal case) ---
if has_win_entry "$PS_FILE"; then
    pass "L1: dotfileslink.ps1 has a \$links entry skills\\workflow-init -> skills\\wf-init"
else
    fail "L1: dotfileslink.ps1 is missing the skills\\workflow-init -> skills\\wf-init entry"
fi

# --- L1b: Windows Dest is anchored under $AgentsRoot, not under $ClaudeDir ---
if ! has_win_dest_under_agents_root "$PS_FILE"; then
    fail "L1b: wf-init entry Dest is not anchored to \$AgentsRoot\\skills\\wf-init"
elif has_win_dest_under_claude_dir "$PS_FILE"; then
    fail "L1b: wf-init entry Dest points under \$ClaudeDir (must stay repo-internal)"
else
    pass "L1b: wf-init entry Dest is \$AgentsRoot\\skills\\wf-init (repo-internal, not \$ClaudeDir)"
fi

# --- L1c: IsDir flag — this alias is a directory symlink, not a file symlink ---
if has_win_isdir_true "$PS_FILE"; then
    pass "L1c: wf-init entry declares IsDir = \$true"
else
    fail "L1c: wf-init entry does not declare IsDir = \$true"
fi

# --- L2: POSIX installer entry present (normal case) ---
if has_sh_entry "$SH_FILE"; then
    pass "L2: dotfileslink.sh has a _link_one call skills/workflow-init -> skills/wf-init"
else
    fail "L2: dotfileslink.sh is missing the _link_one skills/workflow-init -> skills/wf-init call"
fi

# --- L3: placement — the wf-init link is OUTSIDE the ~/.claude/.git guard block ---
_wf_line="$(sh_wf_init_line "$SH_FILE")"
_guard_fi_line="$(sh_guard_close_line "$SH_FILE")"
if [ -z "$_wf_line" ]; then
    fail "L3: cannot locate the wf-init _link_one call in dotfileslink.sh"
elif [ -z "$_guard_fi_line" ]; then
    fail "L3: cannot locate the closing fi of the 'if [ -d ~/.claude/.git ]' guard"
elif [ "$_wf_line" -gt "$_guard_fi_line" ]; then
    pass "L3: wf-init _link_one (line $_wf_line) is after the guard's closing fi (line $_guard_fi_line)"
else
    fail "L3: wf-init _link_one (line $_wf_line) is inside the ~/.claude/.git guard (fi at line $_guard_fi_line)"
fi

# --- L4: CPR-ORTH symmetry — both platforms must carry the entry ---
_win_found=0; _sh_found=0
has_win_entry "$PS_FILE" && _win_found=1
has_sh_entry "$SH_FILE" && _sh_found=1
if [ "$_win_found" = "1" ] && [ "$_sh_found" = "1" ]; then
    pass "L4: both installers declare the wf-init link (win=$_win_found, posix=$_sh_found)"
else
    fail "L4: one-sided wf-init link — win=$_win_found, posix=$_sh_found (both must be 1)"
fi

# --- L4b: mutation probe — a one-sided removal must be detected, not silently green ---
_mut_win="$TMP_DIR/dotfileslink-no-win-entry.ps1"
grep -vE 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"' "$PS_FILE" > "$_mut_win"
_mut_sh="$TMP_DIR/dotfileslink-no-sh-entry.sh"
grep -vE '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$SH_FILE" > "$_mut_sh"

_mut_win_found=0; _mut_sh_found=0
has_win_entry "$_mut_win" && _mut_win_found=1
has_sh_entry "$_mut_sh" && _mut_sh_found=1
if [ "$_mut_win_found" = "0" ] && [ "$_mut_sh_found" = "0" ]; then
    pass "L4b: detectors report absent on mutated copies (win=$_mut_win_found, posix=$_mut_sh_found)"
else
    fail "L4b: detectors still report present after removal — false-green risk (win=$_mut_win_found, posix=$_mut_sh_found)"
fi

# --- L4c: mutation probe — a wrong-root Dest must be detected, not silently green ---
_mut_root="$TMP_DIR/dotfileslink-wrong-root.ps1"
sed 's|\$AgentsRoot\\skills\\wf-init|$ClaudeDir\\skills\\wf-init|' "$PS_FILE" > "$_mut_root"
_mut_anchor=0; _mut_wrong=0
has_win_dest_under_agents_root "$_mut_root" && _mut_anchor=1
has_win_dest_under_claude_dir "$_mut_root" && _mut_wrong=1
if [ "$_mut_anchor" = "0" ] && [ "$_mut_wrong" = "1" ]; then
    pass "L4c: anchor detector rejects a \$ClaudeDir-rooted Dest (anchored=$_mut_anchor, wrong=$_mut_wrong)"
else
    fail "L4c: anchor detector is false-green on a \$ClaudeDir-rooted Dest (anchored=$_mut_anchor, wrong=$_mut_wrong)"
fi

# --- L5: .gitignore carries the exact line ---
if has_gitignore_line "$GITIGNORE_FILE"; then
    pass "L5: .gitignore contains an exact 'skills/wf-init' line"
else
    fail "L5: .gitignore has no exact 'skills/wf-init' line"
fi

# --- L5b: mutation probe — removing the .gitignore line must be detected (symmetric to L4b) ---
_mut_gi="$TMP_DIR/gitignore-no-wf-init"
grep -vx 'skills/wf-init' "$GITIGNORE_FILE" > "$_mut_gi"
_mut_gi_found=0
has_gitignore_line "$_mut_gi" && _mut_gi_found=1
if [ "$_mut_gi_found" = "0" ]; then
    pass "L5b: .gitignore detector reports absent on the mutated copy (found=$_mut_gi_found)"
else
    fail "L5b: .gitignore detector still reports present after removal — false-green risk"
fi

# --- L6: idempotency — the entry is declared exactly once per installer ---
# Re-run safety itself lives in the installers' already-linked short-circuits
# (ps1 loop: "Already linked" + continue; sh _link_one: readlink comparison + return 0),
# which are covered by tests/feature-697-dotfileslink-link-one.*. What is specific to this
# entry — and what those tests cannot see — is that it was added once and not duplicated:
# a duplicate declaration would make the second pass relink an already-correct symlink.
_win_count="$(grep -cE 'Source[[:space:]]*=[[:space:]]*"skills[\\/]workflow-init"' "$PS_FILE")"
_sh_count="$(grep -cE '_link_one[[:space:]]+.*skills/workflow-init.*skills/wf-init' "$SH_FILE")"
if [ "$_win_count" = "1" ] && [ "$_sh_count" = "1" ]; then
    pass "L6: wf-init link declared exactly once per installer (win=$_win_count, posix=$_sh_count)"
else
    fail "L6: duplicate/missing wf-init declaration (win=$_win_count, posix=$_sh_count; expected 1 each)"
fi

# --- CC process guard (issue #2284) ---
# Both dotfileslink installers must wait for a live Claude Code process to exit before
# rewriting settings.json, and skip the assemble-settings.js call when the wait times
# out. Detector shape: the wait-cc-exit reference precedes the assemble-settings call,
# with a skip (exit 0 / return) between the two.

# Line number of the first *executable* wait-cc-exit reference; empty when absent.
# A commented-out reference is documentation, never a guard.
_wait_ref_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE 'wait-cc-exit\.(sh|ps1)' "$file" \
        | grep -vE '^[0-9]+:[[:space:]]*#' | head -n1 | cut -d: -f1
}

# Line number of the assemble-settings.js invocation; empty when absent.
_assemble_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -nE 'assemble-settings\.js' "$file" | head -n1 | cut -d: -f1
}

# The guard must run before the write.
_guard_precedes_assemble() {
    local file="$1" w a
    w="$(_wait_ref_line "$file")"
    a="$(_assemble_line "$file")"
    [ -n "$w" ] && [ -n "$a" ] && [ "$w" -lt "$a" ]
}

# On timeout the write must be skipped: a skip path must appear in the guard's immediate
# neighbourhood (bounded to 6 lines) and the guard's exit code must be consumed by a branch.
# Scanning the whole range from guard to assemble is a false-green trap because
# dotfileslink.sh already contains unrelated `exit 0` and `return` lines in that span.
#
# Two patterns are accepted:
#   POSIX: `if ! bash .../wait-cc-exit.sh; then … exit 0; fi`
#           `bash .../wait-cc-exit.sh || { …; exit 0; }`
#   PS:     `& pwsh … wait-cc-exit.ps1` then `if ($LASTEXITCODE -ne 0) { …; exit 0 }`
#
_guard_skips_assemble() {
    local file="$1" w a to _bound=false _guard_line
    w="$(_wait_ref_line "$file")"
    a="$(_assemble_line "$file")"
    [ -n "$w" ] && [ -n "$a" ] && [ "$w" -lt "$a" ] || return 1

    _guard_line="$(sed -n "${w}p" "$file")"

    # Pattern 2 — positive-if (narrow skip): `if bash .../wait-cc-exit; then assemble; fi`
    # Assemble is inside the then-block; no exit 0 needed. hooksPath/doc-append still run.
    # Accept when guard line is a positive `if` (no `!`) with the wait-cc-exit call.
    if printf '%s' "$_guard_line" | grep -Eq '^[[:space:]]*if[[:space:]]' \
    && ! printf '%s' "$_guard_line" | grep -q '!' \
    && [ "$((a - w))" -le 6 ]; then
        return 0
    fi

    # Pattern 1 — exit-on-timeout: guard bound + exit 0 within 6 lines.
    # Guard exit code must be bound — POSIX (if/||) OR PowerShell ($LASTEXITCODE within 3 lines).
    printf '%s' "$_guard_line" | grep -Eq '(^[[:space:]]*(if|while|until)[[:space:]]|\|\|)' && _bound=true
    if ! $_bound; then
        sed -n "${w},$((w + 3))p" "$file" | grep -Eq '(\$LASTEXITCODE|if[[:space:]]*\()' || return 1
    fi
    to=$((w + 6))
    [ "$to" -ge "$a" ] && to=$((a - 1))
    [ "$to" -ge "$w" ] || return 1
    sed -n "${w},${to}p" "$file" \
        | grep -Eq '(exit[[:space:]]+0|(^|[[:space:]]|;|\{)return([[:space:]]|;|\}|$))'
}

# Line of the DOTFILESLINK_LINKS_ONLY early-exit — the scope anchor for the guard.
# The guard must appear AFTER this line so a timeout skips only the settings write,
# not symlink creation or links-only mode.
_dotfiles_links_only_line() {
    local file="$1"
    [ -f "$file" ] || return 0
    grep -n 'DOTFILESLINK_LINKS_ONLY' "$file" \
        | grep -vE '^[0-9]+:[[:space:]]*#' | tail -n1 | cut -d: -f1
}

# Guard must appear AFTER the DOTFILESLINK_LINKS_ONLY exit.
_guard_scope_ok_dotfiles() {
    local file="$1" w sl
    w="$(_wait_ref_line "$file")"
    sl="$(_dotfiles_links_only_line "$file")"
    [ -n "$w" ] && [ -n "$sl" ] && [ "$w" -gt "$sl" ]
}

# --- B1: POSIX installer calls the guard before assemble-settings.js ---
if _guard_precedes_assemble "$SH_FILE"; then
    pass "B1: dotfileslink.sh calls wait-cc-exit.sh before node assemble-settings.js"
else
    fail "B1: dotfileslink.sh has no wait-cc-exit.sh call preceding assemble-settings.js"
fi

# --- B2: POSIX installer skips the write when the guard times out ---
if _guard_skips_assemble "$SH_FILE"; then
    pass "B2: dotfileslink.sh skips assemble-settings.js on a wait-cc-exit timeout"
else
    fail "B2: dotfileslink.sh has no skip path between wait-cc-exit.sh and assemble-settings.js"
fi

# --- B2b: POSIX guard is scoped after DOTFILESLINK_LINKS_ONLY (not at script top) ---
if _guard_scope_ok_dotfiles "$SH_FILE"; then
    pass "B2b: dotfileslink.sh guard is placed after the DOTFILESLINK_LINKS_ONLY exit"
else
    fail "B2b: dotfileslink.sh guard precedes DOTFILESLINK_LINKS_ONLY exit — would block links-only mode"
fi

# --- B3: Windows installer calls the guard before assemble-settings.js ---
if _guard_precedes_assemble "$PS_FILE"; then
    pass "B3: dotfileslink.ps1 calls wait-cc-exit.ps1 before assemble-settings.js"
else
    fail "B3: dotfileslink.ps1 has no wait-cc-exit.ps1 call preceding assemble-settings.js"
fi

# --- B4: Windows installer skips the write when the guard times out ---
if _guard_skips_assemble "$PS_FILE"; then
    pass "B4: dotfileslink.ps1 skips assemble-settings.js on a wait-cc-exit timeout"
else
    fail "B4: dotfileslink.ps1 has no skip path between wait-cc-exit.ps1 and assemble-settings.js"
fi

# --- B4b: PS guard is scoped after DOTFILESLINK_LINKS_ONLY (not at script top) ---
if _guard_scope_ok_dotfiles "$PS_FILE"; then
    pass "B4b: dotfileslink.ps1 guard is placed after the DOTFILESLINK_LINKS_ONLY exit"
else
    fail "B4b: dotfileslink.ps1 guard precedes DOTFILESLINK_LINKS_ONLY exit — would block links-only mode"
fi

# --- B5: mutation probes — detectors must discriminate, not merely be red today ---

# B5a: removing the guard reference must make B1 red.
_mut_guard="$TMP_DIR/dotfileslink-no-guard.sh"
grep -vE 'wait-cc-exit\.(sh|ps1)' "$SH_FILE" > "$_mut_guard"
_mut_guard_found=0
_guard_precedes_assemble "$_mut_guard" && _mut_guard_found=1
if [ "$_mut_guard_found" = "0" ]; then
    pass "B5a: B1 detector reports absent after guard removal"
else
    fail "B5a: B1 detector is false-green after guard removal"
fi

# B5b: a synthetic caller where the skip path is absent must make B2 red.
# This catches the HIGH-2 false-green: a file that calls the guard but ignores the exit code.
_mut_noskip="$TMP_DIR/dotfileslink-noskip.sh"
cat > "$_mut_noskip" << 'NOSKIP_EOF'
#!/bin/bash
set -euo pipefail
bash "$AGENTS_ROOT/install/lib/wait-cc-exit.sh" || true
node "$AGENTS_ROOT/install/assemble-settings.js"
NOSKIP_EOF
_mut_noskip_skips=0
_guard_skips_assemble "$_mut_noskip" && _mut_noskip_skips=1
if [ "$_mut_noskip_skips" = "0" ]; then
    pass "B5b: B2 detector reports no skip when guard exit code is discarded (|| true)"
else
    fail "B5b: B2 detector is false-green when guard exit code is discarded"
fi

# B5c: a synthetic caller where the guard is correct must make B2 green.
_mut_good="$TMP_DIR/dotfileslink-good.sh"
cat > "$_mut_good" << 'GOOD_EOF'
#!/bin/bash
set -euo pipefail
if ! bash "$AGENTS_ROOT/install/lib/wait-cc-exit.sh"; then
    echo "CC still running; skipping settings write." >&2
    exit 0
fi
node "$AGENTS_ROOT/install/assemble-settings.js"
GOOD_EOF
_mut_good_skips=0
_guard_skips_assemble "$_mut_good" && _mut_good_skips=1
if [ "$_mut_good_skips" = "1" ]; then
    pass "B5c: B2 detector reports skip present on a correctly guarded caller"
else
    fail "B5c: B2 detector gives false-red on a correctly guarded caller"
fi

# B5h: narrow-skip SH — positive-if pattern (assemble in then-block, hooksPath outside) → B2 green.
_mut_narrow_sh="$TMP_DIR/dotfileslink-narrow.sh"
cat > "$_mut_narrow_sh" << 'NARROW_SH_EOF'
#!/bin/bash
set -euo pipefail
[ "${DOTFILESLINK_LINKS_ONLY:-0}" = "1" ] && exit 0
if bash "$AGENTS_ROOT/install/lib/wait-cc-exit.sh"; then
    node "$AGENTS_ROOT/install/assemble-settings.js"
fi
git config --file "$HOME/.gitconfig" core.hooksPath "$AGENTS_ROOT/hooks"
NARROW_SH_EOF
_mut_narrow_sh_skips=0
_guard_skips_assemble "$_mut_narrow_sh" && _mut_narrow_sh_skips=1
if [ "$_mut_narrow_sh_skips" = "1" ]; then
    pass "B5h: B2 detector accepts narrow-skip (positive-if with assemble in then-block)"
else
    fail "B5h: B2 detector false-negative on narrow-skip pattern (positive-if)"
fi

# B5f: too-early SH — guard before DOTFILESLINK_LINKS_ONLY must fail _guard_scope_ok_dotfiles.
_mut_early_sh="$TMP_DIR/dotfileslink-too-early.sh"
cat > "$_mut_early_sh" << 'EARLY_SH_EOF'
#!/bin/bash
set -euo pipefail
if ! bash "$AGENTS_ROOT/install/lib/wait-cc-exit.sh"; then
    echo "CC still running; skipping settings write." >&2
    exit 0
fi
[ "${DOTFILESLINK_LINKS_ONLY:-0}" = "1" ] && exit 0
_link_one "$AGENTS_ROOT/CLAUDE.md" "$HOME/.claude/CLAUDE.md"
node "$AGENTS_ROOT/install/assemble-settings.js"
EARLY_SH_EOF
_mut_early_sh_scope=0
_guard_scope_ok_dotfiles "$_mut_early_sh" && _mut_early_sh_scope=1
if [ "$_mut_early_sh_scope" = "0" ]; then
    pass "B5f: B2b scope detector rejects a too-early SH guard (before DOTFILESLINK_LINKS_ONLY)"
else
    fail "B5f: B2b scope detector is false-green for a too-early SH guard"
fi

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
_mut_good_ps_skips=0
_guard_skips_assemble "$_mut_good_ps" && _mut_good_ps_skips=1
if [ "$_mut_good_ps_skips" = "1" ]; then
    pass "B5d: B4 detector reports skip present on a correctly guarded PS caller"
else
    fail "B5d: B4 detector gives false-red on a correctly guarded PS caller"
fi

# B5e: PS noskip — guard without $LASTEXITCODE check must make B4 red.
_mut_noskip_ps="$TMP_DIR/dotfileslink-noskip.ps1"
cat > "$_mut_noskip_ps" << 'NOSKIP_PS_EOF'
& pwsh -NoProfile -File "$PSScriptRoot/../../install/lib/wait-cc-exit.ps1"
node "$PSScriptRoot/../../install/assemble-settings.js"
NOSKIP_PS_EOF
_mut_noskip_ps_skips=0
_guard_skips_assemble "$_mut_noskip_ps" && _mut_noskip_ps_skips=1
if [ "$_mut_noskip_ps_skips" = "0" ]; then
    pass "B5e: B4 detector reports no skip when PS guard exit code is not checked"
else
    fail "B5e: B4 detector is false-green when PS guard exit code is not checked"
fi

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
