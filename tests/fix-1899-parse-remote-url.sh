#!/bin/bash
# tests/fix-1899-parse-remote-url.sh
# Tests: hooks/lib/parse-remote-url.js, hooks/lib/is-private-repo.js
# Tags: parse-remote-url, origin-resolution, table-driven, parser, regex, security, path-traversal, secret-redaction, TL1, scope:issue-specific
#
# Dispatch + aggregate entrypoint for the fix-1899-parse-remote-url split suite.
# All cases live in tests/fix-1899-parse-remote-url/ per rules/coding/file-split.md
# (the flat file reached 499 lines against a 500-line HARD limit). Each split
# group also runs standalone.
#
# Issue #1899 — repository identity was resolved through `gh repo view`, which
# consults ALL remotes and can answer with `upstream` when both `origin` and
# `upstream` exist. The fix moves URL parsing into one pure module,
# hooks/lib/parse-remote-url.js, so every JS caller derives owner/repo from the
# ORIGIN URL alone with one shared, testable contract.
#
# Split groups (original group letters in parentheses):
#   parse-origin.sh        (A)     parseOriginOwnerRepo verdict table
#   host-and-repo-id.sh    (B, C)  extractHost / extractRepoId
#   module-contract.sh     (D, E)  purity + is-private-repo backward compat
#   owner-repo-charset.sh  (F,G,J) F1 owner/repo charset + traversal boundary
#   redaction.sh           (H, I)  F2/F3 credential redaction
#   authority.sh           (NEW)   F-B userinfo anchoring — CPR-ORTH mirror of
#                                  tests/fix-1899-origin-repo-resolver/authority.sh
#   mutation-probe.sh      (M)     OWNER_RE/REPO_RE mutation probe — proves the
#                                  charset cases above are load-bearing
#
# Owner/repo contract pinned here (bin/github-issues/lib/origin-repo.sh must agree
# — CPR-ORTH): owner = GitHub login charset, leading [A-Za-z0-9] then
# [A-Za-z0-9-], length 1..39, no dots/underscores; repo = [A-Za-z0-9._-]{1,100}
# and never exactly "." or "..".
#
# TL3 gap (what this TL1 suite does NOT catch):
#   - Whether any caller actually passes the ORIGIN url (vs. some other remote)
#     into parseOriginOwnerRepo — that seam is covered by
#     tests/fix-1899-origin-repo-resolver.sh and the driver/route-decision cases.
#   - Real `git remote get-url origin` output shapes on a live checkout.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.

set -uo pipefail

# Outer timeout so a wedged node cannot stall the suite (rules/test.md).
if command -v timeout >/dev/null 2>&1 && [ -z "${_FIX1899_PRU_INNER:-}" ]; then
    _FIX1899_PRU_INNER=1 timeout 240 bash "$0" "$@"
    exit $?
fi

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-1899-parse-remote-url"

SPLIT_GROUPS=(
    "parse-origin.sh"
    "host-and-repo-id.sh"
    "module-contract.sh"
    "owner-repo-charset.sh"
    "redaction.sh"
    "authority.sh"
    "mutation-probe.sh"
)

TOTAL_PASS=0
TOTAL_FAIL=0

for group in "${SPLIT_GROUPS[@]}"; do
    script="$SPLIT_DIR/$group"
    if [ ! -f "$script" ]; then
        echo "FAIL: split group missing: $script"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
        continue
    fi

    echo ""
    echo "═══ $group ═══"
    out_file="$(mktemp)"
    bash "$script" 2>&1 | tee "$out_file"
    rc=${PIPESTATUS[0]}

    results_line="$(grep -E '^Results: [0-9]+ passed, [0-9]+ failed' "$out_file" | tail -1)"
    if [ -n "$results_line" ]; then
        g_pass="$(printf '%s' "$results_line" | sed -E 's/^Results: ([0-9]+) passed.*/\1/')"
        g_fail="$(printf '%s' "$results_line" | sed -E 's/.* ([0-9]+) failed.*/\1/')"
        TOTAL_PASS=$((TOTAL_PASS + g_pass))
        TOTAL_FAIL=$((TOTAL_FAIL + g_fail))
    else
        echo "WARN: $group emitted no Results line (exit=$rc); counting as 1 failure"
        TOTAL_FAIL=$((TOTAL_FAIL + 1))
    fi
    rm -f "$out_file"
done

echo ""
echo "═════════════════════════════════════════"
echo "Aggregate Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
echo "Total: PASS=$TOTAL_PASS FAIL=$TOTAL_FAIL"
[ "$TOTAL_FAIL" -eq 0 ] && exit 0 || exit 1
