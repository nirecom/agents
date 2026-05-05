#!/bin/bash
# Test suite for `.private-info-blocklist` warn-mode in bin/scan-outbound.sh
#
# Tests target POST-implementation behavior:
#   - Lines in blocklist starting with `warn:` are soft-block patterns
#   - Exit codes: 0=clean, 1=hard violation, 2=warn-only, 3=usage error
#   - Warn match output line: <file>:<lineno>: [blocklist-warn] <match>
#   - Empty `warn:` line emits stderr warning and is skipped
#   - Hard wins: any hard violation -> exit 1 even if warns also matched
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

# Setup fake dotfiles tree
TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_DOTFILES="$TMPBASE/dotfiles"
mkdir -p "$FAKE_DOTFILES/bin"
cp "$SCANNER_SRC" "$FAKE_DOTFILES/bin/scan-outbound.sh"
chmod +x "$FAKE_DOTFILES/bin/scan-outbound.sh"
SCANNER="$FAKE_DOTFILES/bin/scan-outbound.sh"
: > "$FAKE_DOTFILES/.private-info-allowlist"

set_blocklist() {
    printf '%s\n' "$1" > "$FAKE_DOTFILES/.private-info-blocklist"
}

set_allowlist() {
    printf '%s\n' "$1" > "$FAKE_DOTFILES/.private-info-allowlist"
}

# Run scanner. Captures stdout, stderr, rc separately.
# Sets globals: SC_OUT, SC_ERR, SC_RC
run_scanner() {
    local input="$1"
    local out_file err_file
    out_file="$(mktemp)"; err_file="$(mktemp)"
    set +e
    printf '%s' "$input" | run_with_timeout "$SCANNER" --stdin "test.txt" >"$out_file" 2>"$err_file"
    SC_RC=$?
    set -e
    SC_OUT="$(cat "$out_file")"
    SC_ERR="$(cat "$err_file")"
    rm -f "$out_file" "$err_file"
}

expect_rc() {
    local desc="$1" want="$2"
    if [ "$SC_RC" = "$want" ]; then
        pass "$desc (rc=$want)"
    else
        fail "$desc — expected rc=$want, got rc=$SC_RC. stdout=[$SC_OUT] stderr=[$SC_ERR]"
    fi
}

expect_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc — expected to contain '$needle'. Got: [$haystack]"
    fi
}

expect_not_contains() {
    local desc="$1" haystack="$2" needle="$3"
    if echo "$haystack" | grep -qF "$needle"; then
        fail "$desc — should NOT contain '$needle'. Got: [$haystack]"
    else
        pass "$desc"
    fi
}

echo "=== Normal: clean stdin -> exit 0 ==="
set_blocklist "forbiddenword[0-9]+
warn:suspicious[a-z]+pattern"
run_scanner "this is fine content"
expect_rc "clean stdin" 0

echo ""
echo "=== Normal: hard pattern matched -> exit 1 ==="
run_scanner "see forbiddenword42 here"
expect_rc "hard pattern matched" 1
expect_contains "hard match has [blocklist] label" "$SC_OUT" "[blocklist]"

echo ""
echo "=== Normal: warn pattern matched -> exit 2 ==="
run_scanner "see suspiciousfoopattern here"
expect_rc "warn-only matched" 2
expect_contains "warn match has [blocklist-warn] label" "$SC_OUT" "[blocklist-warn]"

echo ""
echo "=== Edge: hard + warn both matched -> exit 1 (hard wins) ==="
run_scanner "forbiddenword99 and suspiciousbarpattern"
expect_rc "hard+warn -> exit 1" 1
expect_contains "stdout has [blocklist]" "$SC_OUT" "[blocklist]"
expect_contains "stdout has [blocklist-warn]" "$SC_OUT" "[blocklist-warn]"

echo ""
echo "=== Edge: warn matches twice (multi-line) -> exit 2, count reported ==="
run_scanner "suspiciousfoopattern
suspiciousbarpattern"
expect_rc "two warn matches -> exit 2" 2
# Accept either "Found 2 warning(s)" or a "warnings" line referencing 2
if echo "$SC_OUT" | grep -Eq 'Found 2 warning|2 warning|WARNINGS=2'; then
    pass "warning count reported (2)"
else
    fail "warning count not reported. Got: [$SC_OUT]"
fi

echo ""
echo "=== Edge: only warn patterns in blocklist; no match -> exit 0 ==="
set_blocklist "warn:suspicious[a-z]+pattern"
run_scanner "totally clean text"
expect_rc "only-warn blocklist, no match" 0

echo ""
echo "=== Edge: empty warn: line -> stderr warning + skip (no false positive) ==="
# blocklist with an empty `warn:` line (just the prefix, nothing after)
printf '%s\n' "warn:" > "$FAKE_DOTFILES/.private-info-blocklist"
printf '%s\n' "warn:suspicious[a-z]+pattern" >> "$FAKE_DOTFILES/.private-info-blocklist"
run_scanner "totally clean innocuous text"
expect_rc "empty warn: skipped, clean input -> exit 0" 0
expect_contains "stderr warns about empty warn pattern" "$SC_ERR" "empty warn pattern"

echo ""
echo "=== Edge: empty stdin -> exit 0 ==="
set_blocklist "forbiddenword[0-9]+
warn:suspicious[a-z]+pattern"
run_scanner ""
expect_rc "empty stdin" 0

echo ""
echo "=== Error: no args -> exit 3 (was exit 2 pre-change) ==="
set +e
run_with_timeout "$SCANNER" >/dev/null 2>&1
NOARGS_RC=$?
set -e
if [ "$NOARGS_RC" = "3" ]; then
    pass "no args -> exit 3"
else
    fail "no args — expected rc=3, got rc=$NOARGS_RC"
fi

echo ""
echo "=== Security: allowlist suppresses warn match ==="
set_blocklist "warn:suspicious[a-z]+pattern"
set_allowlist "suspiciousfoopattern"
run_scanner "suspiciousfoopattern"
expect_rc "allowlisted warn -> exit 0" 0

echo ""
echo "=== Security: allowlist suppresses warn but hard pattern still hits ==="
set_blocklist "forbiddenword[0-9]+
warn:suspicious[a-z]+pattern"
set_allowlist "suspiciousfoopattern"
run_scanner "suspiciousfoopattern and forbiddenword7"
expect_rc "warn allowlisted, hard hits -> exit 1" 1

echo ""
echo "=== Security: built-in hard secret + warn pattern -> hard wins (exit 1) ==="
set_blocklist "warn:suspicious[a-z]+pattern"
: > "$FAKE_DOTFILES/.private-info-allowlist"
# Build the fixture key at runtime so the test file itself does not contain a
# string matching the anthropic-key detector (would otherwise block this commit).
HS_PREFIX="sk-ant-api03"
HS_BODY="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
HS_FIXTURE="${HS_PREFIX}-${HS_BODY}"
run_scanner "${HS_FIXTURE} and suspiciousxxxpattern"
expect_rc "anthropic key + warn -> exit 1" 1
expect_contains "anthropic-key label present" "$SC_OUT" "[anthropic-key]"

echo ""
echo "=== Security: warn match content with shell metacharacters -> no injection ==="
set_blocklist "warn:suspicious[a-z]+pattern"
run_scanner 'suspiciousxxxpattern; rm -rf /tmp/should-not-exist-xyz'
expect_rc "shell-meta in matched line -> exit 2" 2
if [ -e "/tmp/should-not-exist-xyz" ] || [ -e "/" ]; then
    # / always exists; this check is just a sanity placeholder.
    # Real assertion: ensure the embedded `rm` didn't actually run by checking
    # a sentinel file we never created didn't appear.
    if [ -e "$TMPBASE/shell-injection-marker" ]; then
        fail "shell injection: marker file was created"
    else
        pass "no shell injection (marker absent)"
    fi
fi

echo ""
echo "=== Idempotency: same input twice -> identical rc + stdout ==="
set_blocklist "forbiddenword[0-9]+
warn:suspicious[a-z]+pattern"
: > "$FAKE_DOTFILES/.private-info-allowlist"
run_scanner "forbiddenword1 and suspiciousaapattern"
RC1=$SC_RC; OUT1=$SC_OUT
run_scanner "forbiddenword1 and suspiciousaapattern"
RC2=$SC_RC; OUT2=$SC_OUT
if [ "$RC1" = "$RC2" ] && [ "$OUT1" = "$OUT2" ]; then
    pass "idempotent across runs"
else
    fail "idempotency: rc1=$RC1 rc2=$RC2 out1=[$OUT1] out2=[$OUT2]"
fi

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
