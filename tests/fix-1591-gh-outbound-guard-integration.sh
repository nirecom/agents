#!/bin/bash
# tests/fix-1591-gh-outbound-guard-integration.sh
# Tests: bin/lib/gh-outbound-guard.sh
# Tags: scan-outbound, security, gh, guard, integration, scope:issue-specific, layer:TL2
#
# Issue #1591 — end-to-end guard behavior over the real scanner: hard patterns
# block (rc1), warn patterns block fail-closed (rc2), clean input passes (rc0),
# and per-file allowlist entries are honored under the exact label only.
#
# The scanner+lists are isolated inside a fake AGENTS_CONFIG_DIR (a copy of the
# real scan-outbound.sh plus controlled .private-info-allowlist/.blocklist) so the
# test never depends on the developer's private gitignored lists.
#
# RED until /write-code creates bin/lib/gh-outbound-guard.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_LIB="$AGENTS_DIR/bin/lib/gh-outbound-guard.sh"
REAL_SCANNER="$AGENTS_DIR/bin/scan-outbound.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMP=""

# Build fake AGENTS_CONFIG_DIR: real scanner copy + controlled empty allowlist +
# blocklist carrying one warn-tier pattern. $EXTRA_ALLOW lines are appended to the
# allowlist before each case.
setup() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$TMP/acd"
    mkdir -p "$AGENTS_CONFIG_DIR/bin"
    cp "$REAL_SCANNER" "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh"
    chmod +x "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh"
    : > "$AGENTS_CONFIG_DIR/.private-info-allowlist"
    printf 'warn:WIDGET-INTERNAL-CODENAME\n' > "$AGENTS_CONFIG_DIR/.private-info-blocklist"
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    TMP=""
}

# run_guard <label> <content-file> — fresh source + redirection call in this shell.
run_guard() {
    GH_OUTBOUND_GUARD_MESSAGE=""
    # shellcheck disable=SC1090
    source "$GUARD_LIB"
    if gh_outbound_guard "$1" < "$2"; then GUARD_RC=0; else GUARD_RC=$?; fi
}

if [ ! -f "$GUARD_LIB" ]; then
    fail "I-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# I-1: clean content -> return 0
setup
C="$TMP/c.txt"; printf 'This is a perfectly ordinary sentence.\n' > "$C"
run_with_timeout 20 true
run_guard "intent.md" "$C"
if [ "$GUARD_RC" -eq 0 ]; then
    pass "I-1: clean content -> return 0"
else
    fail "I-1: expected rc0; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# I-2: hard built-in pattern (RFC 1918 private IP) -> return 1 (hard block).
# Label 'intent.md' is NOT under tests/* so the repo-shape allowlist does not apply.
setup
C="$TMP/c.txt"; printf 'deploy target host is 10.0.0.1 in the internal net\n' > "$C"
run_guard "intent.md" "$C"
if [ "$GUARD_RC" -eq 1 ] && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qi "hard violation"; then
    pass "I-2: private IP 10.0.0.1 -> return 1 (hard violation)"
else
    fail "I-2: expected rc1 hard; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# I-3: warn-tier blocklist pattern -> return 1 (fail-closed, non-interactive).
setup
C="$TMP/c.txt"; printf 'the release is codenamed WIDGET-INTERNAL-CODENAME internally\n' > "$C"
run_guard "intent.md" "$C"
if [ "$GUARD_RC" -eq 1 ] && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qi "warn-tier"; then
    pass "I-3: warn-tier pattern -> return 1 (fail-closed rc2->block)"
else
    fail "I-3: expected rc1 warn-tier; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# I-4: per-file allowlist — an entry '<label>:<pattern>' allowlists a match ONLY
# under that exact label. Here 10.0.0.1 is allowed under label 'allow-me.md'.
setup
printf 'allow-me.md:10\\.0\\.0\\.1\n' >> "$AGENTS_CONFIG_DIR/.private-info-allowlist"
C="$TMP/c.txt"; printf 'host 10.0.0.1 here\n' > "$C"
run_guard "allow-me.md" "$C"
if [ "$GUARD_RC" -eq 0 ]; then
    pass "I-4: per-file allowlist entry -> match under exact label returns 0"
else
    fail "I-4: expected rc0 (allowlisted); got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# I-5: allowlist scoping regression — the SAME pattern under a DIFFERENT label is
# still blocked (allowlist entry is label-scoped, not global).
setup
printf 'allow-me.md:10\\.0\\.0\\.1\n' >> "$AGENTS_CONFIG_DIR/.private-info-allowlist"
C="$TMP/c.txt"; printf 'host 10.0.0.1 here\n' > "$C"
run_guard "other-file.md" "$C"
if [ "$GUARD_RC" -eq 1 ]; then
    pass "I-5: same pattern under a different label still blocks (scoped allowlist)"
else
    fail "I-5: expected rc1 under non-matching label; got rc=$GUARD_RC"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
