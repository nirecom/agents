#!/bin/bash
# tests/fix-1591-gh-outbound-guard.sh
# Tests: bin/lib/gh-outbound-guard.sh
# Tags: scan-outbound, security, gh, guard, scope:issue-specific, layer:TL1
#
# Issue #1591 — shared fail-closed outbound-scan guard for scripts that call gh
# with free-text. gh_outbound_guard <label> reads content from STDIN, scans via
# $AGENTS_CONFIG_DIR/bin/scan-outbound.sh --stdin <label>, and RETURNS (not exits):
#   scanner rc 0 -> return 0 (clean)
#   scanner rc 1 -> return 1, GH_OUTBOUND_GUARD_MESSAGE contains "hard violation"
#   scanner rc 2 -> return 1, message "warn-tier" + "treated as block" (fail-closed)
#   scanner rc 3 -> return 1, message "usage error"
#   scanner unresolvable -> return 1 (fail-closed)
# CRITICAL: caller MUST use input redirection (guard < file); piping runs it in a
# subshell so GH_OUTBOUND_GUARD_MESSAGE never reaches the parent shell.
#
# TL1: fake scan-outbound.sh returns a scripted rc so rc->return mapping is tested
# in isolation. This test is RED until /write-code creates gh-outbound-guard.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GUARD_LIB="$AGENTS_DIR/bin/lib/gh-outbound-guard.sh"

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

# Build a fake AGENTS_CONFIG_DIR whose bin/scan-outbound.sh drains stdin and exits
# with the scripted rc from $MOCK_SCAN_RC. When $NO_SCANNER=1, no scanner is placed
# (exercises the unresolvable fail-closed path).
setup() {
    TMP="$(mktemp -d)"
    export AGENTS_CONFIG_DIR="$TMP/acd"
    mkdir -p "$AGENTS_CONFIG_DIR/bin"
    if [ "${NO_SCANNER:-0}" != "1" ]; then
        cat > "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh" <<'MOCK'
#!/usr/bin/env bash
# Drain stdin fully (avoid SIGPIPE on large input), then emit a fake match line
# and exit with the scripted rc.
cat >/dev/null
echo "${2:-stdin}:1: [mock] SCRIPTED-MATCH"
exit "${MOCK_SCAN_RC:-0}"
MOCK
        chmod +x "$AGENTS_CONFIG_DIR/bin/scan-outbound.sh"
    fi
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    unset MOCK_SCAN_RC NO_SCANNER 2>/dev/null || true
    TMP=""
}

# call_guard <label> <content-file> — sources the lib fresh and invokes via input
# redirection in THIS shell so GH_OUTBOUND_GUARD_MESSAGE propagation is observable.
# Sets globals GUARD_RC and (from the lib) GH_OUTBOUND_GUARD_MESSAGE.
call_guard() {
    GH_OUTBOUND_GUARD_MESSAGE=""
    # shellcheck disable=SC1090
    source "$GUARD_LIB"
    if gh_outbound_guard "$1" < "$2"; then
        GUARD_RC=0
    else
        GUARD_RC=$?
    fi
}

if [ ! -f "$GUARD_LIB" ]; then
    fail "G-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# G-1: scanner rc 0 -> return 0, message empty
setup
export MOCK_SCAN_RC=0
CONTENT="$TMP/c.txt"; printf 'clean text\n' > "$CONTENT"
run_with_timeout 15 true  # keep timeout wrapper referenced for lint parity
call_guard "label-a" "$CONTENT"
if [ "$GUARD_RC" -eq 0 ] && [ -z "${GH_OUTBOUND_GUARD_MESSAGE:-}" ]; then
    pass "G-1: scanner rc0 -> return 0, empty message"
else
    fail "G-1: expected rc0 empty-msg; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# G-2: scanner rc 1 (hard) -> return 1, message names "hard violation"
setup
export MOCK_SCAN_RC=1
CONTENT="$TMP/c.txt"; printf 'bad\n' > "$CONTENT"
call_guard "label-b" "$CONTENT"
if [ "$GUARD_RC" -eq 1 ] && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qi "hard violation"; then
    pass "G-2: scanner rc1 -> return 1, message contains 'hard violation'"
else
    fail "G-2: expected rc1 + 'hard violation'; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# G-3: scanner rc 2 (warn) -> return 1 (fail-closed), message names warn-tier + block
setup
export MOCK_SCAN_RC=2
CONTENT="$TMP/c.txt"; printf 'warnish\n' > "$CONTENT"
call_guard "label-c" "$CONTENT"
if [ "$GUARD_RC" -eq 1 ] \
    && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qi "warn-tier" \
    && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qi "treated as block"; then
    pass "G-3: scanner rc2 -> return 1 (fail-closed), 'warn-tier' + 'treated as block'"
else
    fail "G-3: expected rc1 + warn-tier/treated-as-block; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# G-4: scanner rc 3 (usage error) -> return 1, message names usage error
setup
export MOCK_SCAN_RC=3
CONTENT="$TMP/c.txt"; printf 'x\n' > "$CONTENT"
call_guard "label-d" "$CONTENT"
if [ "$GUARD_RC" -eq 1 ] && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qi "usage error"; then
    pass "G-4: scanner rc3 -> return 1, message contains 'usage error'"
else
    fail "G-4: expected rc1 + 'usage error'; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# G-5: scanner unresolvable -> return 1 (fail-closed), non-empty message
NO_SCANNER=1 setup
CONTENT="$TMP/c.txt"; printf 'x\n' > "$CONTENT"
call_guard "label-e" "$CONTENT"
if [ "$GUARD_RC" -eq 1 ] && [ -n "${GH_OUTBOUND_GUARD_MESSAGE:-}" ]; then
    pass "G-5: scanner unresolvable -> return 1 (fail-closed) + non-empty message"
else
    fail "G-5: expected rc1 + non-empty message; got rc=$GUARD_RC msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# G-6: message triple contract — on block, message references the labeled file/
# allowlist remedy AND states bypassing another way is prohibited.
setup
export MOCK_SCAN_RC=1
CONTENT="$TMP/c.txt"; printf 'bad\n' > "$CONTENT"
call_guard "the-label" "$CONTENT"
if [ "$GUARD_RC" -eq 1 ] \
    && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qi "allowlist" \
    && echo "${GH_OUTBOUND_GUARD_MESSAGE:-}" | grep -qiE "bypass|prohibit"; then
    pass "G-6: block message references allowlist remedy + prohibits bypass"
else
    fail "G-6: expected allowlist + bypass/prohibit language; got msg='${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# G-7: PROPAGATION regression — redirection sets GH_OUTBOUND_GUARD_MESSAGE in the
# CALLING shell (guard is NOT a local; runs in the current shell).
setup
export MOCK_SCAN_RC=1
CONTENT="$TMP/c.txt"; printf 'bad\n' > "$CONTENT"
call_guard "prop" "$CONTENT"
if [ -n "${GH_OUTBOUND_GUARD_MESSAGE:-}" ]; then
    pass "G-7: redirection call -> GH_OUTBOUND_GUARD_MESSAGE visible in caller"
else
    fail "G-7: expected non-empty GH_OUTBOUND_GUARD_MESSAGE after redirection call; got empty"
fi
teardown

# G-8: FOOTGUN regression — piping runs the guard in a subshell, so the variable
# must NOT propagate to the caller (documents why callers must use redirection).
setup
export MOCK_SCAN_RC=1
GH_OUTBOUND_GUARD_MESSAGE=""
# shellcheck disable=SC1090
source "$GUARD_LIB"
printf 'bad\n' | gh_outbound_guard "piped" || true
if [ -z "${GH_OUTBOUND_GUARD_MESSAGE:-}" ]; then
    pass "G-8: pipe call -> GH_OUTBOUND_GUARD_MESSAGE does NOT propagate (subshell footgun)"
else
    fail "G-8: expected empty GH_OUTBOUND_GUARD_MESSAGE after pipe call; got '${GH_OUTBOUND_GUARD_MESSAGE:-}'"
fi
teardown

# G-9: large stdin (200KB, well beyond ARG_MAX) is streamed via --stdin cleanly.
setup
export MOCK_SCAN_RC=0
CONTENT="$TMP/big.txt"
run_with_timeout 15 bash -c 'head -c 204800 /dev/zero | tr "\0" "A" > "$1"' _ "$CONTENT"
call_guard "big-label" "$CONTENT"
if [ "$GUARD_RC" -eq 0 ]; then
    pass "G-9: 200KB stdin via --stdin -> return 0 (no ARG_MAX overflow)"
else
    fail "G-9: expected rc0 on 200KB input; got rc=$GUARD_RC"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
