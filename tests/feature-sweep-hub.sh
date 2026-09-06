#!/bin/bash
# tests/feature-sweep-hub.sh
# Tests: skills/sweep-worktrees/SKILL.md, skills/sweep/SKILL.md, skills/sweep-branches/SKILL.md, skills/sweep-issues/SKILL.md, skills/sweep-shell-snapshots/SKILL.md
# Tags: sweep, worktree, branch, issues, shell-snapshots, maintenance, frontmatter, tests, scope:common, TL1
#
# Structural tests for the /sweep hub skill and the /sweep-worktrees dispatch
# target. These check only file presence + frontmatter shape — no source-code
# behavior dependency, so they should turn GREEN as soon as the SKILL.md
# files exist.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP_HUB="$AGENTS_DIR/skills/sweep/SKILL.md"
SWEEP_WT="$AGENTS_DIR/skills/sweep-worktrees/SKILL.md"
SWEEP_BR="$AGENTS_DIR/skills/sweep-branches/SKILL.md"
SWEEP_IS="$AGENTS_DIR/skills/sweep-issues/SKILL.md"
SWEEP_SS="$AGENTS_DIR/skills/sweep-shell-snapshots/SKILL.md"

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

# Everything AFTER the closing `---` — the procedure the model actually reads.
# A delegation named only in the frontmatter `description:` is documentation,
# not an instruction, so wiring assertions must look here and not at the whole file.
body_of() {
    local f="$1"
    [ -f "$f" ] || { printf ''; return; }
    awk '/^---[[:space:]]*$/ { count++; next } count >= 2 { print }' "$f"
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
# T6 — skills/sweep-branches/SKILL.md exists and is non-empty
# ─────────────────────────────────────────────────────────────────────────────

T6_sweep_branches_exists_nonempty() {
    if [ ! -f "$SWEEP_BR" ]; then
        fail "T6 sweep_branches_exists_nonempty: $SWEEP_BR does not exist"
        return
    fi
    if [ ! -s "$SWEEP_BR" ]; then
        fail "T6 sweep_branches_exists_nonempty: $SWEEP_BR is empty"
        return
    fi
    pass "T6 sweep_branches_exists_nonempty"
}

# ─────────────────────────────────────────────────────────────────────────────
# T7 — skills/sweep/SKILL.md body references 'sweep-branches'
# ─────────────────────────────────────────────────────────────────────────────

T7_sweep_hub_references_sweep_branches() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T7 sweep_hub_references_sweep_branches: $SWEEP_HUB does not exist"
        return
    fi
    if grep -qF 'sweep-branches' "$SWEEP_HUB" 2>/dev/null; then
        pass "T7 sweep_hub_references_sweep_branches"
    else
        fail "T7 sweep_hub_references_sweep_branches: 'sweep-branches' not referenced in $SWEEP_HUB"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T8 — skills/sweep/SKILL.md body references 'sweep-plans'
# ─────────────────────────────────────────────────────────────────────────────

T8_sweep_hub_references_sweep_plans() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T8 sweep_hub_references_sweep_plans: $SWEEP_HUB does not exist"
        return
    fi
    if grep -qF 'sweep-plans' "$SWEEP_HUB" 2>/dev/null; then
        pass "T8 sweep_hub_references_sweep_plans"
    else
        fail "T8 sweep_hub_references_sweep_plans: 'sweep-plans' not referenced in $SWEEP_HUB"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T9 — skills/sweep-issues/SKILL.md exists, is non-empty, and is user-invocable
# ─────────────────────────────────────────────────────────────────────────────

T9_sweep_issues_exists_user_invocable() {
    if [ ! -f "$SWEEP_IS" ]; then
        fail "T9 sweep_issues_exists_user_invocable: $SWEEP_IS does not exist"
        return
    fi
    if [ ! -s "$SWEEP_IS" ]; then
        fail "T9 sweep_issues_exists_user_invocable: $SWEEP_IS is empty"
        return
    fi
    local fm
    fm="$(frontmatter_of "$SWEEP_IS")"
    if [ -z "$fm" ]; then
        fail "T9 sweep_issues_exists_user_invocable: no frontmatter found"
        return
    fi
    case "$fm" in
        *"user-invocable: true"*|*"user-invocable:true"*)
            pass "T9 sweep_issues_exists_user_invocable" ;;
        *)
            fail "T9 sweep_issues_exists_user_invocable: 'user-invocable: true' not in frontmatter: $fm" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T10 — skills/sweep/SKILL.md registers 'sweep-issues' as a dispatch target
#       (both in the frontmatter description list and in the SW-N procedure)
# ─────────────────────────────────────────────────────────────────────────────

T10_sweep_hub_registers_sweep_issues() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T10 sweep_hub_registers_sweep_issues: $SWEEP_HUB does not exist"
        return
    fi
    local fm
    fm="$(frontmatter_of "$SWEEP_HUB")"
    case "$fm" in
        *"sweep-issues"*) ;;
        *)
            fail "T10 sweep_hub_registers_sweep_issues: 'sweep-issues' not in hub frontmatter description"
            return ;;
    esac
    if grep -qE '^SW-[0-9]+[a-z]*\..*/sweep-issues' "$SWEEP_HUB" 2>/dev/null; then
        pass "T10 sweep_hub_registers_sweep_issues"
    else
        fail "T10 sweep_hub_registers_sweep_issues: no SW-N step invokes /sweep-issues in $SWEEP_HUB"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T11 — SW step numbering is coherent after the sweep-issues insertion:
#       primary steps (SW-N. with no letter suffix) are unique and form the
#       contiguous run 0..N — no duplicate and no skipped number. SW-0 is a
#       legitimate leading step (the hub's WORKTREE_OFF bracket), not a gap.
#       Lettered
#       sub-steps (SW-2b/SW-2c) are sub-ordinates of their primary and are
#       only required to reference an existing primary.
# ─────────────────────────────────────────────────────────────────────────────

T11_sweep_hub_sw_numbering_coherent() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T11 sweep_hub_sw_numbering_coherent: $SWEEP_HUB does not exist"
        return
    fi
    local primaries sub_nums n expected=0 prev=""
    primaries="$(grep -oE '^SW-[0-9]+\.' "$SWEEP_HUB" 2>/dev/null | sed 's/^SW-//; s/\.$//' | sort -n)"
    if [ -z "$primaries" ]; then
        fail "T11 sweep_hub_sw_numbering_coherent: no SW-N. steps found in $SWEEP_HUB"
        return
    fi
    for n in $primaries; do
        if [ "$n" = "$prev" ]; then
            fail "T11 sweep_hub_sw_numbering_coherent: duplicate step SW-$n"
            return
        fi
        if [ "$n" -ne "$expected" ]; then
            fail "T11 sweep_hub_sw_numbering_coherent: expected SW-$expected, found SW-$n (gap or out-of-order)"
            return
        fi
        prev="$n"
        expected=$((expected + 1))
    done
    # Every lettered sub-step must hang off a declared primary number.
    sub_nums="$(grep -oE '^SW-[0-9]+[a-z]+\.' "$SWEEP_HUB" 2>/dev/null | sed 's/^SW-//; s/[a-z]*\.$//' | sort -nu)"
    for n in $sub_nums; do
        if ! echo "$primaries" | grep -qx "$n"; then
            fail "T11 sweep_hub_sw_numbering_coherent: sub-step SW-${n}x has no primary SW-$n"
            return
        fi
    done
    pass "T11 sweep_hub_sw_numbering_coherent (primaries: $(echo "$primaries" | tr '\n' ' '))"
}

# ─────────────────────────────────────────────────────────────────────────────
# T12 — skills/sweep-shell-snapshots/SKILL.md exists, is non-empty, and is
#       user-invocable (same contract every other sweep sub-skill carries).
# ─────────────────────────────────────────────────────────────────────────────

T12_sweep_shell_snapshots_exists_user_invocable() {
    if [ ! -f "$SWEEP_SS" ]; then
        fail "T12 sweep_shell_snapshots_exists_user_invocable: $SWEEP_SS does not exist"
        return
    fi
    if [ ! -s "$SWEEP_SS" ]; then
        fail "T12 sweep_shell_snapshots_exists_user_invocable: $SWEEP_SS is empty"
        return
    fi
    local fm
    fm="$(frontmatter_of "$SWEEP_SS")"
    if [ -z "$fm" ]; then
        fail "T12 sweep_shell_snapshots_exists_user_invocable: no frontmatter found"
        return
    fi
    case "$fm" in
        *"user-invocable: true"*|*"user-invocable:true"*)
            pass "T12 sweep_shell_snapshots_exists_user_invocable" ;;
        *)
            fail "T12 sweep_shell_snapshots_exists_user_invocable: 'user-invocable: true' not in frontmatter: $fm" ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# T12b — the sub-skill's own body must delegate to bin/sweep-shell-snapshots.sh.
#        T12 only proves a user-invocable SKILL.md exists; a file that says
#        nothing about the script is a /sweep-shell-snapshots that sweeps
#        nothing, and T13 (hub → sub-skill) stays green throughout. This closes
#        the last hop of the chain, mirroring how sweep-plans/SKILL.md names
#        `bin/sweep-plans.sh` in its Usage section.
# ─────────────────────────────────────────────────────────────────────────────

T12b_sweep_shell_snapshots_delegates_to_script() {
    if [ ! -f "$SWEEP_SS" ]; then
        fail "T12b sweep_shell_snapshots_delegates_to_script: $SWEEP_SS does not exist"
        return
    fi
    local body
    body="$(body_of "$SWEEP_SS")"
    if [ -z "$body" ]; then
        fail "T12b sweep_shell_snapshots_delegates_to_script: $SWEEP_SS has no body below its frontmatter"
        return
    fi
    if printf '%s\n' "$body" | grep -qF 'bin/sweep-shell-snapshots.sh'; then
        pass "T12b sweep_shell_snapshots_delegates_to_script"
    else
        fail "T12b sweep_shell_snapshots_delegates_to_script: body never names 'bin/sweep-shell-snapshots.sh' — the skill delegates to nothing"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T13 — skills/sweep/SKILL.md registers 'sweep-shell-snapshots' as a dispatch
#       target (both in the frontmatter description list and in the SW-N
#       procedure), exactly as T10 pins it for sweep-issues. A sub-skill the hub
#       never invokes is dead code: /sweep would silently stop clearing the
#       corrupted snapshots issue #2160 is about.
# ─────────────────────────────────────────────────────────────────────────────

T13_sweep_hub_registers_sweep_shell_snapshots() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T13 sweep_hub_registers_sweep_shell_snapshots: $SWEEP_HUB does not exist"
        return
    fi
    local fm
    fm="$(frontmatter_of "$SWEEP_HUB")"
    case "$fm" in
        *"sweep-shell-snapshots"*) ;;
        *)
            fail "T13 sweep_hub_registers_sweep_shell_snapshots: 'sweep-shell-snapshots' not in hub frontmatter description"
            return ;;
    esac
    if grep -qE '^SW-[0-9]+[a-z]*\..*/sweep-shell-snapshots' "$SWEEP_HUB" 2>/dev/null; then
        pass "T13 sweep_hub_registers_sweep_shell_snapshots"
    else
        fail "T13 sweep_hub_registers_sweep_shell_snapshots: no SW-N step invokes /sweep-shell-snapshots in $SWEEP_HUB"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T14 — the WORKTREE_ON bracket step names the step it actually follows.
#       Inserting the new dispatch step renumbers the tail, and the bracket
#       step's prose carries a hard-coded 'after SW-N' back-reference that
#       T11's numbering check cannot see. Pin it to the last dispatch step —
#       /sweep-shell-snapshots — so a stale reference is caught.
# ─────────────────────────────────────────────────────────────────────────────

T14_sweep_hub_worktree_on_references_last_dispatch() {
    if [ ! -f "$SWEEP_HUB" ]; then
        fail "T14 sweep_hub_worktree_on_references_last_dispatch: $SWEEP_HUB does not exist"
        return
    fi
    local snap_step on_ref
    snap_step="$(grep -oE '^SW-[0-9]+\..*/sweep-shell-snapshots' "$SWEEP_HUB" 2>/dev/null | head -1 | sed 's/^SW-//; s/\..*$//')"
    if [ -z "$snap_step" ]; then
        fail "T14 sweep_hub_worktree_on_references_last_dispatch: no primary SW-N step invokes /sweep-shell-snapshots"
        return
    fi
    on_ref="$(grep -E '^SW-[0-9]+[a-z]*\..*WORKFLOW_ENFORCE_WORKTREE_ON' "$SWEEP_HUB" 2>/dev/null | grep -oE 'after SW-[0-9]+' | head -1 | sed 's/^after SW-//')"
    if [ -z "$on_ref" ]; then
        fail "T14 sweep_hub_worktree_on_references_last_dispatch: WORKFLOW_ENFORCE_WORKTREE_ON step has no 'after SW-N' back-reference"
        return
    fi
    if [ "$on_ref" = "$snap_step" ]; then
        pass "T14 sweep_hub_worktree_on_references_last_dispatch (SW-$snap_step)"
    else
        fail "T14 sweep_hub_worktree_on_references_last_dispatch: bracket says 'after SW-$on_ref' but the last dispatch step is SW-$snap_step (stale reference after renumbering)"
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
T6_sweep_branches_exists_nonempty
T7_sweep_hub_references_sweep_branches
T8_sweep_hub_references_sweep_plans
T9_sweep_issues_exists_user_invocable
T10_sweep_hub_registers_sweep_issues
T11_sweep_hub_sw_numbering_coherent
T12_sweep_shell_snapshots_exists_user_invocable
T12b_sweep_shell_snapshots_delegates_to_script
T13_sweep_hub_registers_sweep_shell_snapshots
T14_sweep_hub_worktree_on_references_last_dispatch

# T15-T17 (exact skill-host frontmatter, the forked dispatch family, flag
# forwarding) and T18/T19 (real `claude -p` invocation, TL3-gated) live in a
# sibling part file — rules/coding/file-split.md Pattern A. It self-invokes its
# cases at source time and uses the pass/fail helpers defined above.
# shellcheck source=tests/feature-sweep-hub/skill-host-integration.sh
. "$AGENTS_DIR/tests/feature-sweep-hub/skill-host-integration.sh"

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
