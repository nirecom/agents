#!/bin/bash
# Tests: bin/scan-outbound.sh
# Tags: scan, outbound, blocklist, allowlist, regression, scope:issue-specific
# Regression (#1520): loader loops in scan-outbound.sh drop the last line of
# blocklist/allowlist files lacking a trailing newline.
# Cases 1-2: FAIL before fix (add `|| [ -n "$line" ]` on loader loops in scan-outbound.sh).
# Cases 3-4: baseline controls verifying normal behavior is unchanged.
# L3 gap: real session hooks, actual list files, Windows CRLF — not covered here.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT="$SCRIPT_DIR_TEST/../../bin/scan-outbound.sh"

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

if [ ! -f "$REAL_SCRIPT" ]; then
    echo "SKIP: bin/scan-outbound.sh not found at $REAL_SCRIPT"
    exit 0
fi

# Create a sandbox with:
#   $sandbox/bin/scan-outbound.sh -> symlink to real script
#   $sandbox/.private-info-blocklist  (caller writes content)
#   $sandbox/.private-info-allowlist  (caller writes content)
# Because scan-outbound.sh resolves SCRIPT_DIR from $0, placing a symlink in
# $sandbox/bin/ makes SCRIPT_DIR=$sandbox/bin and the list paths resolve to
# $sandbox/bin/../.private-info-{blocklist,allowlist} = $sandbox/.
make_sandbox() {
    local sb
    sb="$(mktemp -d)"
    mkdir -p "$sb/bin"
    ln -s "$REAL_SCRIPT" "$sb/bin/scan-outbound.sh"
    # #2589: carry the main-worktree helper so a scanner that sources it still runs here.
    if [ -f "$SCRIPT_DIR_TEST/../../bin/lib/main-worktree.sh" ]; then
        mkdir -p "$sb/bin/lib"
        cp "$SCRIPT_DIR_TEST/../../bin/lib/main-worktree.sh" "$sb/bin/lib/main-worktree.sh"
    fi
    # Start with empty lists; caller overwrites as needed
    printf '' > "$sb/.private-info-blocklist"
    printf '' > "$sb/.private-info-allowlist"
    echo "$sb"
}

run_scan() {
    local sandbox="$1" content="$2"
    printf '%s' "$content" | env -u AGENTS_MAIN_ROOT "$sandbox/bin/scan-outbound.sh" --stdin test-label >/dev/null 2>&1
    echo $?
}

cleanup_dirs=()
trap 'rm -rf "${cleanup_dirs[@]}"' EXIT

# -----------------------------------------------------------------------
# Case 1: blocklist-no-trailing-newline-hard-block  [EXPECTED TO FAIL before fix]
# Blocklist written WITHOUT trailing newline — the bug causes the last
# (only) line to be dropped so the pattern is never loaded.
# Expected exit: 1 (hard block).  Currently exits: 0 (bug: pattern dropped).
# -----------------------------------------------------------------------
SB1="$(make_sandbox)"
cleanup_dirs+=("$SB1")
printf '%s' 'UNIQUE_SECRET_XYZ789' > "$SB1/.private-info-blocklist"
printf '' > "$SB1/.private-info-allowlist"
RC1="$(run_scan "$SB1" "This content contains UNIQUE_SECRET_XYZ789 in it")"
if [ "$RC1" -eq 1 ]; then
    pass "case1 blocklist-no-trailing-newline-hard-block: exit $RC1 (blocked)"
else
    fail "case1 blocklist-no-trailing-newline-hard-block: expected exit 1 (block), got $RC1 — bug #1520: last blocklist line dropped when no trailing newline"
fi

# -----------------------------------------------------------------------
# Case 2: allowlist-no-trailing-newline-allows  [EXPECTED TO FAIL before fix]
# Blocklist has pattern (with trailing newline) + allowlist has the same
# pattern WITHOUT trailing newline — the bug drops the allowlist last line
# so the exception is never loaded, causing a spurious hard block.
# Expected exit: 0 (allowed).  Currently exits: 1 (bug: allowlist last line dropped).
# -----------------------------------------------------------------------
SB2="$(make_sandbox)"
cleanup_dirs+=("$SB2")
printf '%s\n' 'UNIQUE_SECRET_XYZ789' > "$SB2/.private-info-blocklist"
printf '%s' 'UNIQUE_SECRET_XYZ789' > "$SB2/.private-info-allowlist"
RC2="$(run_scan "$SB2" "This content contains UNIQUE_SECRET_XYZ789 in it")"
if [ "$RC2" -eq 0 ]; then
    pass "case2 allowlist-no-trailing-newline-allows: exit $RC2 (allowed)"
else
    fail "case2 allowlist-no-trailing-newline-allows: expected exit 0 (allowed), got $RC2 — bug #1520: last allowlist line dropped when no trailing newline"
fi

# -----------------------------------------------------------------------
# Case 3: blocklist-with-trailing-newline-control  [EXPECTED TO PASS — baseline]
# Normal blocklist WITH trailing newline — baseline to verify unchanged behavior.
# Expected exit: 1 (hard block).
# -----------------------------------------------------------------------
SB3="$(make_sandbox)"
cleanup_dirs+=("$SB3")
printf '%s\n' 'UNIQUE_CONTROL_ABC123' > "$SB3/.private-info-blocklist"
printf '' > "$SB3/.private-info-allowlist"
RC3="$(run_scan "$SB3" "This content contains UNIQUE_CONTROL_ABC123 in it")"
if [ "$RC3" -eq 1 ]; then
    pass "case3 blocklist-with-trailing-newline-control: exit $RC3 (blocked)"
else
    fail "case3 blocklist-with-trailing-newline-control: expected exit 1 (block), got $RC3 — unexpected baseline failure"
fi

# -----------------------------------------------------------------------
# Case 4: allowlist-with-trailing-newline-control  [EXPECTED TO PASS — baseline]
# Blocklist has pattern (with newline) + allowlist has same pattern (with newline).
# Expected exit: 0 (allowed).
# -----------------------------------------------------------------------
SB4="$(make_sandbox)"
cleanup_dirs+=("$SB4")
printf '%s\n' 'UNIQUE_CONTROL_ABC123' > "$SB4/.private-info-blocklist"
printf '%s\n' 'UNIQUE_CONTROL_ABC123' > "$SB4/.private-info-allowlist"
RC4="$(run_scan "$SB4" "This content contains UNIQUE_CONTROL_ABC123 in it")"
if [ "$RC4" -eq 0 ]; then
    pass "case4 allowlist-with-trailing-newline-control: exit $RC4 (allowed)"
else
    fail "case4 allowlist-with-trailing-newline-control: expected exit 0 (allowed), got $RC4 — unexpected baseline failure"
fi

# -----------------------------------------------------------------------
# Case 5: env-pointer-does-not-move-scan-basis  [#2589 S4-2 — FAILS before fix]
# The scanner reads the lists of its own checkout. Pointing AGENTS_MAIN_ROOT at
# a decoy dir whose blocklist is near-empty must not swap in the decoy lists.
# Expected exit: 1 (blocked by the sandbox blocklist).
# -----------------------------------------------------------------------
SB5="$(make_sandbox)"
DECOY5="$(mktemp -d)"
cleanup_dirs+=("$SB5" "$DECOY5")
printf '%s\n' 'UNIQUE_PINNED_QRS456' > "$SB5/.private-info-blocklist"
printf '' > "$SB5/.private-info-allowlist"
printf '%s\n' 'NEVER_MATCHES_DECOY_000' > "$DECOY5/.private-info-blocklist"
printf '' > "$DECOY5/.private-info-allowlist"
RC5="$(printf '%s' "This content contains UNIQUE_PINNED_QRS456 in it" | env AGENTS_MAIN_ROOT="$DECOY5" "$SB5/bin/scan-outbound.sh" --stdin test-label >/dev/null 2>&1; echo $?)"
if [ "$RC5" -eq 1 ]; then
    pass "case5 env-pointer-does-not-move-scan-basis: exit $RC5 (blocked by own checkout list)"
else
    fail "case5 env-pointer-does-not-move-scan-basis: expected exit 1 (block), got $RC5 — AGENTS_MAIN_ROOT redirected the blocklist to a decoy"
fi

# -----------------------------------------------------------------------
# Case 6/7: env-pointer-does-not-block-own-allow  [#2589 S4-2 allow-side pair — FAILS before fix]
# Mirror of case 5. The input is allowed by the sandbox's own lists (6: blocklisted
# but allowlisted; 7: not blocklisted at all), while the decoy blocklist names it with
# no allowlist entry. The decoy must have no effect. Expected exit: 0 (allowed).
# -----------------------------------------------------------------------
DECOY6="$(mktemp -d)"
cleanup_dirs+=("$DECOY6")
printf '%s\n' 'UNIQUE_ALLOWED_TUV789' > "$DECOY6/.private-info-blocklist"
printf '' > "$DECOY6/.private-info-allowlist"
for pair in "6 allowlisted-in-own-list" "7 absent-from-own-blocklist"; do
    n="${pair%% *}"; label="${pair#* }"
    SB="$(make_sandbox)"
    cleanup_dirs+=("$SB")
    if [ "$n" = 6 ]; then
        printf '%s\n' 'UNIQUE_ALLOWED_TUV789' > "$SB/.private-info-blocklist"
        printf '%s\n' 'UNIQUE_ALLOWED_TUV789' > "$SB/.private-info-allowlist"
    else
        printf '%s\n' 'UNRELATED_OWN_PATTERN_111' > "$SB/.private-info-blocklist"
    fi
    RC="$(printf '%s' "This content contains UNIQUE_ALLOWED_TUV789 in it" | env AGENTS_MAIN_ROOT="$DECOY6" "$SB/bin/scan-outbound.sh" --stdin test-label >/dev/null 2>&1; echo $?)"
    if [ "$RC" -eq 0 ]; then
        pass "case$n env-pointer-does-not-block-own-allow ($label): exit $RC (allowed by own checkout lists)"
    else
        fail "case$n env-pointer-does-not-block-own-allow ($label): expected exit 0 (allowed), got $RC — AGENTS_MAIN_ROOT swapped in the decoy blocklist"
    fi
done
# Vacuity guard: the decoy blocklist really blocks this input when it is the scan basis.
SBV="$(make_sandbox)"
cleanup_dirs+=("$SBV")
cp "$DECOY6/.private-info-blocklist" "$SBV/.private-info-blocklist"
RCV="$(run_scan "$SBV" "This content contains UNIQUE_ALLOWED_TUV789 in it")"
if [ "$RCV" -eq 1 ]; then
    pass "case6-7 vacuity: the decoy blocklist blocks the input when used as the own list"
else
    fail "case6-7 vacuity: expected exit 1 with the decoy list as own list, got $RCV — the pair proves nothing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
