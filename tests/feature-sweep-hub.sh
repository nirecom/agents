#!/bin/bash
# tests/feature-sweep-hub.sh
#
# Structural tests for the /sweep hub skill and the /sweep-worktrees dispatch
# target. These check only file presence + frontmatter shape — no source-code
# behavior dependency, so they should turn GREEN as soon as the SKILL.md
# files exist.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP_HUB="$AGENTS_DIR/skills/sweep/SKILL.md"
SWEEP_WT="$AGENTS_DIR/skills/sweep-worktrees/SKILL.md"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Extract YAML frontmatter (between the first two `---` lines) as plain text.
# Returns empty string if no frontmatter found.
frontmatter_of() {
    local f="$1"
    [ -f "$f" ] || { printf ''; return; }
    awk '
        /^---[[:space:]]*$/ {
            count++
            if (count == 1) { inblock = 1; next }
            if (count == 2) { inblock = 0; exit }
        }
        inblock { print }
    ' "$f"
}

# ─────────────────────────────────────────────────────────────────────────────
# T1 — skills/sweep/SKILL.md exists and is non-empty
# ─────────────────────────────────────────────────────────────────────────────

T1_sweep_hub_exists_nonempty() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T1 sweep_hub_exists_nonempty: $SWEEP_HUB does not exist"
        return
    fi
    if [ ! -s "$SWEEP_HUB" ]; then
        fail "T1 sweep_hub_exists_nonempty: $SWEEP_HUB is empty"
        return
    fi
    pass "T1 sweep_hub_exists_nonempty"
}

# ─────────────────────────────────────────────────────────────────────────────
# T2 — skills/sweep/SKILL.md frontmatter contains user-invocable: true
# ─────────────────────────────────────────────────────────────────────────────

T2_sweep_hub_user_invocable() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T2 sweep_hub_user_invocable: $SWEEP_HUB does not exist"
        return
    fi
    local fm
    fm="$(frontmatter_of "$SWEEP_HUB")"
    if [ -z "$fm" ]; then
        fail "T2 sweep_hub_user_invocable: no frontmatter found"
        return
    fi
    case "$fm" in
        *"user-invocable: true"*|*"user-invocable:true"*)
            pass "T2 sweep_hub_user_invocable" ;;
        *)
            fail "T2 sweep_hub_user_invocable: 'user-invocable: true' not in frontmatter: $fm" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T3 — skills/sweep-worktrees/SKILL.md exists and is non-empty
# ─────────────────────────────────────────────────────────────────────────────

T3_sweep_worktrees_exists_nonempty() {
    if [ ! -f "$SWEEP_WT" ]; then
        fail "T3 sweep_worktrees_exists_nonempty: $SWEEP_WT does not exist"
        return
    fi
    if [ ! -s "$SWEEP_WT" ]; then
        fail "T3 sweep_worktrees_exists_nonempty: $SWEEP_WT is empty"
        return
    fi
    pass "T3 sweep_worktrees_exists_nonempty"
}

# ─────────────────────────────────────────────────────────────────────────────
# T4 — skills/sweep-worktrees/SKILL.md frontmatter contains user-invocable: true
# ─────────────────────────────────────────────────────────────────────────────

T4_sweep_worktrees_user_invocable() {
    if [ ! -f "$SWEEP_WT" ]; then
        fail "T4 sweep_worktrees_user_invocable: $SWEEP_WT does not exist"
        return
    fi
    local fm
    fm="$(frontmatter_of "$SWEEP_WT")"
    if [ -z "$fm" ]; then
        fail "T4 sweep_worktrees_user_invocable: no frontmatter found"
        return
    fi
    case "$fm" in
        *"user-invocable: true"*|*"user-invocable:true"*)
            pass "T4 sweep_worktrees_user_invocable" ;;
        *)
            fail "T4 sweep_worktrees_user_invocable: 'user-invocable: true' not in frontmatter: $fm" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T5 — skills/sweep/SKILL.md body references sweep-worktrees (dispatch line)
# ─────────────────────────────────────────────────────────────────────────────

T5_sweep_hub_references_sweep_worktrees() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T5 sweep_hub_references_sweep_worktrees: $SWEEP_HUB does not exist"
        return
    fi
    if grep -qF 'sweep-worktrees' "$SWEEP_HUB" 2>/dev/null; then
        pass "T5 sweep_hub_references_sweep_worktrees"
    else
        fail "T5 sweep_hub_references_sweep_worktrees: 'sweep-worktrees' not referenced in $SWEEP_HUB"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

T1_sweep_hub_exists_nonempty
T2_sweep_hub_user_invocable
T3_sweep_worktrees_exists_nonempty
T4_sweep_worktrees_user_invocable
T5_sweep_hub_references_sweep_worktrees

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
