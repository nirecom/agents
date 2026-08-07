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
# TL3 gap (what this test does NOT catch):
# - Whether the symlink is actually created on a real Windows host (Developer Mode /
#   admin privileges, MSYS winsymlinks) and on a real POSIX host.
# - Whether Claude Code's skill scanner resolves /wf-init to the same SKILL.md
#   without erroring or double-counting the skill in the slash-command list.
# Accepted tradeoff: real-machine verification of the symlink approach was explicitly
# deferred by user decision for this session (see outline.md).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

echo "---"
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
