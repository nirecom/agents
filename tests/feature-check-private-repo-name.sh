#!/bin/bash
# tests/feature-check-private-repo-name.sh
# Tests: bin/check-private-repo-name.js, bin/list-private-repo-names.js
# Tags: private-repo, outbound-scan, security, classifier, worktree, TL2, scope:common
#
# Why this exists: a task-name slug derived by /worktree-start becomes a public
# branch name, and bin/scan-outbound.sh's static allowlist/blocklist never sees the
# user's private repo names. bin/check-private-repo-name.js is the gate that closes
# that hole, and bin/list-private-repo-names.js is the one-shot producer that feeds
# it. Neither had any coverage.
#
# The gate is a classifier, so both verdicts are covered (skills/_shared/test-design.md
# "Classifier / guard cases"): a private name that must be caught, and — equally — a
# lookalike that must NOT be, since over-blocking silently degrades every derived name
# to a non-descriptive fallback.
#
# Hermetic by construction: every case drives the checker through one of its documented
# name-source contracts (stdin, or PRIVATE_REPO_NAMES_CACHE_SET/PRIVATE_REPO_NAMES_CACHE),
# or through a stand-in AGENTS-config directory whose hooks/lib/is-private-repo.js is a
# stub. No case reaches `gh`, the network, or the running user's real repo list — and no
# real private repo name appears anywhere in this suite.
#
# Dispatcher — sub-files under feature-check-private-repo-name/:
#   helpers.sh        — shared fixture, run_check/run_stdin drivers, assertion helpers,
#                       and the one rejection-message literal both arms must produce
#   cache-and-live.sh — P1-P7: the env-cache contract, the live listPrivateRepoNames()
#                       path and its fail-open behaviour, the matcher's word boundaries,
#                       diagnostic discipline, and the lister -> checker round trip
#   stdin-mode.sh     — S1-S6 [F3]: PRIVATE_REPO_NAMES_STDIN=1, the third and
#                       highest-precedence name source — matching and wire-format
#                       boundaries, authoritative-empty semantics, precedence over the
#                       env cache in BOTH directions, env-mode parity, and the same
#                       non-identifying diagnostic
#
# Split (rules/coding/file-split.md, Pattern A): the single file reached the 500-line
# HARD limit once the stdin source was covered. The two name sources are separate
# concerns with separate drivers; the precedence BETWEEN them is asserted in
# stdin-mode.sh, where both can be armed at once.
#
# TL3 gap (what this test does NOT catch):
# - the live path against a real `gh repo list --visibility private`: whether the
#   installed gh is authenticated, within rate limits, and returns nameWithOwner in
#   the shape hooks/lib/is-private-repo.js parses.
# - /worktree-start actually delivering the list to the checker before it derives a
#   name (that seam is covered one layer up, in
#   tests/feature-worktree-start-non-interactive/ — env-nonexposure.sh owns the
#   caller-side half of the stdin migration, including that the list never enters a
#   child process's environment).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$TESTS_DIR/feature-check-private-repo-name"
TOTAL_PASS=0
TOTAL_FAIL=0

d_fail() { echo "FAIL: $1"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }

dispatch_status() { if [ "$TOTAL_FAIL" -eq 0 ]; then echo 0; else echo 1; fi; }

# run_sub <sub-file> <min-expected-PASS>
#
# Counting PASS/FAIL lines alone reports a false green when a sub-file never gets to
# print them: an unbound variable under `set -u`, a renamed/missing file, a syntax
# error, or a typo in the dispatch list all yield zero FAIL lines and a silent skip of
# everything downstream of the crash. Two guards close that:
#   1. the sub-file's own exit status is folded into TOTAL_FAIL;
#   2. a per-file minimum PASS count catches a run truncated mid-file, where the
#      interpreter still exits 0 (e.g. an early `exit 0`) but coverage shrank.
# The minimums are set at the current baseline: raise one whenever a sub-file gains
# cases, and never lower one without saying which cases were retired.
#
# Identical in mechanism to tests/feature-worktree-start-non-interactive.sh, whose
# selftest_dispatcher() drives the crashing / shrunken / healthy probes against this
# same implementation. Not re-run here: it exercises the guard logic, which is shared
# text, not this suite's sub-files.
run_sub() {
    local sub="$1" min="$2"
    local name; name="$(basename "$sub")"
    local out rc
    # `bash "$sub"; rc=$?` in two statements: capture the status before anything else
    # can clobber $?.
    out="$(bash "$sub" 2>&1)"
    rc=$?
    printf '%s\n' "$out"
    local p f
    p=$(printf '%s\n' "$out" | grep -c '^PASS:' || true)
    f=$(printf '%s\n' "$out" | grep -c '^FAIL:' || true)
    TOTAL_PASS=$((TOTAL_PASS + p))
    TOTAL_FAIL=$((TOTAL_FAIL + f))

    # Only when the sub-file reported no failure of its own — a legitimately failing
    # sub-file also exits non-zero and is already counted above.
    if [ "$rc" -ne 0 ] && [ "$f" -eq 0 ]; then
        d_fail "dispatcher/$name: sub-file exited $rc without emitting a single FAIL line (crashed or never ran)"
    fi
    if [ "$p" -lt "$min" ]; then
        d_fail "dispatcher/$name: emitted $p PASS lines, below the expected minimum of $min (coverage shrank or the run was truncated)"
    fi
}

#          sub-file                min PASS (current baseline)
run_sub "$SUB_DIR/cache-and-live.sh"   54
run_sub "$SUB_DIR/stdin-mode.sh"       30

echo ""
echo "Results: $TOTAL_PASS passed, $TOTAL_FAIL failed"
exit "$(dispatch_status)"
