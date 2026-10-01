# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.
# --- B5 (POSIX): mutation probes — detectors must discriminate, not merely be red today ---

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
_skip_probe B5c "$_mut_good" 1 "correctly guarded POSIX caller (exit form)"

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
_skip_probe B5h "$_mut_narrow_sh" 1 "POSIX narrow skip (positive-if with assemble in then-block)"

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
