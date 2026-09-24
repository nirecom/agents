#!/bin/bash
# tests/feature-check-private-repo-name.sh
# Tests: bin/check-private-repo-name.js, bin/list-private-repo-names.js
# Tags: private-repo, outbound-scan, security, classifier, worktree, TL2, scope:common
#
# Why: a /worktree-start slug becomes a public branch name, and scan-outbound's
# static lists never see the user's private repo names. check-private-repo-name.js
# is that gate; list-private-repo-names.js feeds it.
# Classifier, so both verdicts are covered (skills/_shared/test-design.md):
# private name caught, lookalike not caught (over-blocking degrades every name).

# Hermetic: cases drive the checker via its documented name sources (stdin, or
# PRIVATE_REPO_NAMES_CACHE_SET/_CACHE) or a stub is-private-repo.js. No `gh`,
# no network, no real private repo name anywhere in this suite.

# Dispatcher — sub-files under feature-check-private-repo-name/ (split per
# rules/coding/file-split.md Pattern A):
#   helpers.sh        — fixture, run_check/run_stdin drivers, assertions
#   cache-and-live.sh — P1-P7: env cache, live path + fail-open, word
#                       boundaries, diagnostics, lister -> checker round trip
#   stdin-mode.sh     — S1-S6 [F3]: PRIVATE_REPO_NAMES_STDIN=1 (highest
#                       precedence) — matching, wire format, authoritative
#                       empty, precedence both directions, env-mode parity

# TL3 gap: the live `gh repo list --visibility private` path (auth, rate limit,
# nameWithOwner shape), and /worktree-start actually feeding the checker (covered
# one layer up by tests/feature-worktree-start-non-interactive/env-nonexposure.sh).
# Mitigated at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

TESTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SUB_DIR="$TESTS_DIR/feature-check-private-repo-name"
TOTAL_PASS=0
TOTAL_FAIL=0

d_fail() { echo "FAIL: $1"; TOTAL_FAIL=$((TOTAL_FAIL + 1)); }

dispatch_status() { if [ "$TOTAL_FAIL" -eq 0 ]; then echo 0; else echo 1; fi; }

# run_sub <sub-file> <min-expected-PASS>
# PASS/FAIL counting alone goes false-green when a sub-file crashes before
# printing, so two guards: the sub-file's exit status folds into TOTAL_FAIL, and
# a per-file minimum PASS count catches a truncated run that still exits 0.
# Minimums track the current baseline — raise on new cases; only lower while
# naming the retired cases.
# Same mechanism as tests/feature-worktree-start-non-interactive.sh, whose
# selftest_dispatcher() owns the crash/shrink/healthy probes.
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
