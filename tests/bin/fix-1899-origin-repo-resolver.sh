#!/bin/bash
# tests/fix-1899-origin-repo-resolver.sh
# Tests: bin/github-issues/lib/origin-repo.sh, bin/github-issues/lib/board-card.sh, bin/github-issues/lib/resolve-project.sh, skills/issue-close-finalize/scripts/pre-flight.sh, hooks/lib/parse-remote-url.js, bin/is-github-dotcom-remote
# Tags: origin-resolution, github-issues, board-card, pre-flight, parity, cpr-orth, table-driven, security, path-traversal, authority-anchoring, TL2, scope:issue-specific
#
# Dispatch + aggregate entrypoint for the fix-1899-origin-repo-resolver split
# suite. All cases live in tests/fix-1899-origin-repo-resolver/ per
# rules/coding/file-split.md (the flat file reached 478 lines against a 500-line
# HARD limit, and the authority group would have crossed it). Each split group
# also runs standalone.
#
# Issue #1899 — `gh repo view` asks the GitHub API "what repo is this checkout?",
# and when a fork has BOTH `origin` and `upstream` it can answer with the
# upstream repository. Every downstream write (board cards, issue close, project
# resolution) then targets the WRONG repository. The fix introduces one bash
# resolver, bin/github-issues/lib/origin-repo.sh::resolve_origin_owner_repo,
# that reads `git remote get-url origin` only, and repoints the bash callers at
# it.
#
# Contract under test:
#   resolve_origin_owner_repo [<dir>]   (<dir> defaults to ".")
#     rc 0 -> prints "owner/repo" resolved from the ORIGIN remote
#     rc 1 -> no origin remote (or not a git repo)
#     rc 2 -> origin exists but is not github.com (includes hosts that cannot be
#             classified as github.com — "not confirmed github.com" is rc 2, the
#             same fail-closed direction bin/is-github-dotcom-remote already uses)
#     rc 3 -> origin is github.com but owner/repo is not extractable
#
# Split groups (original group letters in parentheses):
#   resolve-origin.sh       (A, B)    rc/stdout table + origin-vs-upstream pin
#   resolver-contract.sh    (C)       default dir, idempotency, no sed/gh
#   owner-repo-charset.sh   (F, G, H) F1 owner/repo charset + traversal boundary
#   callers.sh              (D, E)    board-card.sh + pre-flight.sh seams
#   authority.sh            (NEW)     F-B userinfo anchoring — CPR-ORTH mirror of
#                                     tests/fix-1899-parse-remote-url/authority.sh
#   parity.sh               (P)       one URL table run through BOTH resolvers
#                                     (bash + JS) so neither can drift alone
#   mutation-probe.sh       (M)       charset-gate mutation probe — proves the
#                                     bash charset cases are load-bearing
#
# Owner/repo charset contract pinned here is the exact mirror of the JS one in
# tests/fix-1899-parse-remote-url.sh (CPR-ORTH — both resolvers must agree):
#   owner — leading [A-Za-z0-9], remaining [A-Za-z0-9-], length 1..39
#   repo  — [A-Za-z0-9._-]{1,100}, never exactly "." or ".."
#
# TL2 (real git fixtures, real bash, stubbed `gh`). TL3 gap: no real GitHub API
# and no real multi-remote clone. Mitigated at WORKFLOW_USER_VERIFIED preflight
# (bin/check-verification-gate.sh) since the change is skill-orchestration class.

set -uo pipefail

# Outer timeout so a wedged git/bash cannot stall the suite (rules/test.md).
# ~56 git fixtures across the split groups; raised from 540 with the mutation
# probe's 12 additional fixtures (each replayed against 5 mutants).
if command -v timeout >/dev/null 2>&1 && [ -z "${_FIX1899_ORIGIN_INNER:-}" ]; then
    _FIX1899_ORIGIN_INNER=1 timeout 660 bash "$0" "$@"
    exit $?
fi

SPLIT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fix-1899-origin-repo-resolver"

SPLIT_GROUPS=(
    "resolve-origin.sh"
    "owner-repo-charset.sh"
    "authority.sh"
    "parity.sh"
    "resolver-contract.sh"
    "callers.sh"
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
