#!/bin/bash
# Tests: bin/scan-outbound.sh
# Tags: scan, outbound, blocklist, allowlist, regression, scope:issue-specific
# Regression tests for #1520 — loader loops in bin/scan-outbound.sh drop the
# last line of blocklist/allowlist files that lack a trailing newline.
#
# Fail-before-fix: cases 1 and 2 are expected to FAIL until the loader loops
# in bin/scan-outbound.sh (lines 41 and 54) are fixed with `|| [ -n "$line" ]`.
# Cases 3 and 4 are baseline controls that verify normal behavior is unchanged.
#
# L3 gap (what this test does NOT catch):
# - Real Claude Code session loading hooks that invoke scan-outbound.sh
# - Interaction with actual .private-info-blocklist / .private-info-allowlist
#   in the repo root (which may have trailing newlines on all platforms)
# - Windows CRLF vs LF edge cases in the actual files

set -u

SCRIPT_DIR_TEST="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REAL_SCRIPT="$SCRIPT_DIR_TEST/../bin/scan-outbound.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

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
    # Start with empty lists; caller overwrites as needed
    printf '' > "$sb/.private-info-blocklist"
    printf '' > "$sb/.private-info-allowlist"
    echo "$sb"
}

run_scan() {
    local sandbox="$1" content="$2"
    printf '%s' "$content" | "$sandbox/bin/scan-outbound.sh" --stdin test-label >/dev/null 2>&1
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

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
