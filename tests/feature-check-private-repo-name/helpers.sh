#!/bin/bash
# tests/feature-check-private-repo-name/helpers.sh
# Tests: bin/check-private-repo-name.js, bin/list-private-repo-names.js
# Tags: private-repo, outbound-scan, security, helpers, fixture, TL2, scope:common
# Shared helpers for feature-check-private-repo-name tests.
# Sourced by sub-files — not a standalone runner.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
CHECK="$AGENTS_DIR/bin/check-private-repo-name.js"
LIST="$AGENTS_DIR/bin/list-private-repo-names.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then echo "PASS: $name"; PASS=$((PASS + 1))
    else echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1)); fi
}
finish() {
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    [ "$FAIL" -eq 0 ] || exit 1
    exit 0
}

# The one fixed literal both name sources end in. Kept here rather than in either
# sub-file: the stdin arm and the cache/live arms share a single finish() in the source,
# so a divergence between what the two sub-files expect would hide a real regression in
# exactly the property that matters (CPR-SSOT).
REJECT_MSG='private repository name detected in candidate; rejecting'

OUT=""; ERR=""; RC=0

# setup_fixture — a throwaway working directory, cleaned on exit. Every sub-file calls
# it before its first case; nothing here touches $HOME or the running user's repo list.
setup_fixture() {
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT
}

# run_check <cache> <candidate...> — drive the checker through the env-cache contract.
# The candidate is passed through "$@" so the zero-argument case is expressible as a
# genuinely absent argv[2] rather than an empty string.
run_check() {
    local cache="$1"; shift
    local errf="$TMP/check-err.txt"
    OUT="$(PRIVATE_REPO_NAMES_CACHE_SET=1 PRIVATE_REPO_NAMES_CACHE="$cache" \
        node "$CHECK" "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}

# run_stdin <list-bytes> <candidate...> — drive the checker through the stdin contract.
# The list is written with `printf '%s'`, NOT '%s\n': the wire content is part of what
# the boundary rows are about (no trailing newline, CRLF, interspersed blanks), so the
# helper must not normalize it. Rows that want the production shape spell the trailing
# newline out themselves.
run_stdin() {
    local list="$1"; shift
    local errf="$TMP/stdin-err.txt"
    OUT="$(printf '%s' "$list" | PRIVATE_REPO_NAMES_STDIN=1 node "$CHECK" "$@" 2>"$errf")"
    RC=$?
    ERR="$(cat "$errf")"
}
