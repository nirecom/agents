#!/bin/bash
# tests/fix-1591-issue-body-append.sh
# Tests: bin/github-issues/issue-body-append.sh
# Tags: github, issues, scan-outbound, security, scope:issue-specific, layer:TL2
#
# Issue #1591 — issue-body-append.sh appends a `### Revision (<UTC ISO8601>)` entry
# inside a single <!-- BEGIN intent-revisions --> ... <!-- END intent-revisions -->
# block (created if absent; appended to if present, without touching prior entries
# or the body outside the block), guards the composed body with label
# issue-body-append:#<N>, then gh issue edit --body-file.
#
# The gh mock is stateful: `issue view` reads a body store, `issue edit --body-file`
# writes it back, so a second invocation sees the first append. RED until
# /write-code creates the script + gh-outbound-guard.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
IBA="$AGENTS_DIR/bin/github-issues/issue-body-append.sh"
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

setup() {
    TMP="$(mktemp -d)"
    export MOCK_LOG_DIR="$TMP"
    export BODY_STORE="$TMP/body-store.txt"
    printf 'ORIGINAL_BODY_MARKER first line of the issue body.\n' > "$BODY_STORE"
    mkdir -p "$TMP/mock-bin" "$TMP/acd/bin"
    cp "$REAL_SCANNER" "$TMP/acd/bin/scan-outbound.sh"
    chmod +x "$TMP/acd/bin/scan-outbound.sh"
    : > "$TMP/acd/.private-info-allowlist"
    : > "$TMP/acd/.private-info-blocklist"
    # Stateful gh mock: view reads store, edit --body-file writes store back.
    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/usr/bin/env bash
echo "gh $*" >> "$MOCK_LOG_DIR/gh-calls.log"
case "$1 $2" in
  "issue view")
    cat "$BODY_STORE"
    exit 0 ;;
  "issue edit")
    # find --body-file <path> and copy it into the store
    prev=""
    for a in "$@"; do
      if [ "$prev" = "--body-file" ]; then cp "$a" "$BODY_STORE"; break; fi
      prev="$a"
    done
    exit 0 ;;
esac
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export AGENTS_CONFIG_DIR="$TMP/acd"
}

teardown() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP" 2>/dev/null || true
    unset MOCK_LOG_DIR BODY_STORE 2>/dev/null || true
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    TMP=""
}

edit_called() { cat "$TMP/gh-calls.log" 2>/dev/null | grep -q 'issue edit'; }

if [ ! -x "$IBA" ] && [ ! -f "$IBA" ]; then
    fail "A-ALL: bin/github-issues/issue-body-append.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi
if [ ! -f "$GUARD_LIB" ]; then
    fail "A-ALL: bin/lib/gh-outbound-guard.sh not yet present (expected RED before /write-code)"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
fi

# A-1: --note appends a revision inside a single marker block, preserving the
# original body text outside the block.
setup
RC=0
run_with_timeout 20 bash "$IBA" --issue 4242 --note "FIRST_NOTE_MARKER content" >/dev/null 2>&1 || RC=$?
BODY="$(cat "$BODY_STORE")"
BEGIN_N=$(printf '%s\n' "$BODY" | grep -c 'BEGIN intent-revisions')
END_N=$(printf '%s\n' "$BODY" | grep -c 'END intent-revisions')
if [ "$RC" -eq 0 ] && edit_called \
    && echo "$BODY" | grep -q "ORIGINAL_BODY_MARKER" \
    && echo "$BODY" | grep -q "FIRST_NOTE_MARKER" \
    && echo "$BODY" | grep -qE '### Revision \(' \
    && [ "$BEGIN_N" -eq 1 ] && [ "$END_N" -eq 1 ]; then
    pass "A-1: --note appends a Revision inside one marker block, original body intact"
else
    fail "A-1: expected single-block append; got rc=$RC begin=$BEGIN_N end=$END_N body='$BODY'"
fi
teardown

# A-2: calling twice preserves BOTH revision entries (append, not replace) and does
# not duplicate the original body; still exactly one marker block.
setup
run_with_timeout 20 bash "$IBA" --issue 4242 --note "FIRST_NOTE_MARKER one"  >/dev/null 2>&1 || true
run_with_timeout 20 bash "$IBA" --issue 4242 --note "SECOND_NOTE_MARKER two" >/dev/null 2>&1 || true
BODY="$(cat "$BODY_STORE")"
BEGIN_N=$(printf '%s\n' "$BODY" | grep -c 'BEGIN intent-revisions')
ORIG_N=$(printf '%s\n' "$BODY" | grep -c 'ORIGINAL_BODY_MARKER')
if echo "$BODY" | grep -q "FIRST_NOTE_MARKER" \
    && echo "$BODY" | grep -q "SECOND_NOTE_MARKER" \
    && [ "$BEGIN_N" -eq 1 ] && [ "$ORIG_N" -eq 1 ]; then
    pass "A-2: two appends keep both revisions, one block, no body duplication"
else
    fail "A-2: expected both notes + single block + single original; got begin=$BEGIN_N orig=$ORIG_N body='$BODY'"
fi
teardown

# A-3: blocked content in --note aborts before gh issue edit, non-zero exit.
setup
RC=0
run_with_timeout 20 bash "$IBA" --issue 4242 --note "leak host 10.0.0.1 note" >/dev/null 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && ! edit_called; then
    pass "A-3: blocked --note -> non-zero exit before gh issue edit"
else
    fail "A-3: expected non-zero no-edit; got rc=$RC edit=$(edit_called && echo y || echo n)"
fi
teardown

# A-4: --issue with non-digit value is rejected (non-zero, no gh edit).
setup
RC=0
run_with_timeout 20 bash "$IBA" --issue 42abc --note "x" >/dev/null 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && ! edit_called; then
    pass "A-4: non-digit --issue rejected"
else
    fail "A-4: expected rejection; got rc=$RC edit=$(edit_called && echo y || echo n)"
fi
teardown

# A-5: --note and --note-file together are rejected (mutually exclusive).
setup
NF="$TMP/note.txt"; printf 'file note\n' > "$NF"
RC=0
run_with_timeout 20 bash "$IBA" --issue 4242 --note "x" --note-file "$NF" >/dev/null 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && ! edit_called; then
    pass "A-5: --note + --note-file rejected (mutually exclusive)"
else
    fail "A-5: expected rejection; got rc=$RC edit=$(edit_called && echo y || echo n)"
fi
teardown

# A-6: neither --note nor --note-file supplied is rejected.
setup
RC=0
run_with_timeout 20 bash "$IBA" --issue 4242 >/dev/null 2>&1 || RC=$?
if [ "$RC" -ne 0 ] && ! edit_called; then
    pass "A-6: neither --note nor --note-file supplied -> rejected"
else
    fail "A-6: expected rejection; got rc=$RC edit=$(edit_called && echo y || echo n)"
fi
teardown

echo ""
echo "Results: $PASS passed, $FAIL failed"
exit $((FAIL > 0 ? 1 : 0))
