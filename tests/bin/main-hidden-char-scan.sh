#!/usr/bin/env bash
# Tests: bin/scan-outbound.sh
# Tags: scan, filter, outbound, hook, bin, agents-config-dir, fail-closed, manifest, scope:issue-specific
# Test suite for Trojan Source / hidden-char detection in scan-outbound.sh
# Zero-width chars (U+200B/C/D, U+FEFF) → [zero-width]
# Bidi override chars (U+202D/E, U+2066-2069) → [bidi-override]
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/../.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "$@"
    else
        perl -e 'alarm 60; exec @ARGV' -- "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

FAKE_DOTFILES="$TMPBASE/dotfiles"
FAKE_PRIVATE="$TMPBASE/my-private-repo"
mkdir -p "$FAKE_DOTFILES/bin"
mkdir -p "$FAKE_PRIVATE"
cp "$SCANNER_SRC" "$FAKE_DOTFILES/bin/scan-outbound.sh"
chmod +x "$FAKE_DOTFILES/bin/scan-outbound.sh"
SCANNER="$FAKE_DOTFILES/bin/scan-outbound.sh"
: > "$FAKE_DOTFILES/.private-info-allowlist"
# Baseline blocklist for hidden-char normal-case tests: an empty (comment-only)
# blocklist so fail-closed does not trigger when AGENTS_CONFIG_DIR is unset and
# the scanner falls back to SCRIPT_DIR/.. = $FAKE_DOTFILES. The built-in
# zero-width / bidi scan fires independently of the blocklist.
printf '# baseline — no custom blocklist entries for hidden-char scan tests\n' > "$FAKE_DOTFILES/.private-info-blocklist"

scan_output() {
    local input="$1"
    local label="${2:-test.txt}"
    printf '%s\n' "$input" | run_with_timeout env -u AGENTS_CONFIG_DIR "$SCANNER" --stdin "$label" 2>&1 || true
}
expect_label() {
    local desc="$1" input="$2" label="$3"
    local out; out="$(scan_output "$input")"
    if echo "$out" | grep -qF "$label"; then
        pass "$desc"
    else
        fail "$desc — expected '$label'. Got: $(echo "$out" | tr '\n' '|')"
    fi
}
expect_clean() {
    local desc="$1" input="$2"
    if printf '%s\n' "$input" | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
        pass "$desc"
    else
        fail "$desc — false positive on: $input"
    fi
}

echo "=== Normal Cases: zero-width chars ==="
expect_label "U+200B (ZWSP) → [zero-width]"        $'hello\xe2\x80\x8bworld'     "[zero-width]"
expect_label "U+200C (ZWNJ) → [zero-width]"        $'hello\xe2\x80\x8cworld'     "[zero-width]"
expect_label "U+200D (ZWJ)  → [zero-width]"        $'hello\xe2\x80\x8dworld'     "[zero-width]"
expect_label "U+FEFF (BOM)  → [zero-width]"        $'\xef\xbb\xbfhello'          "[zero-width]"

echo ""
echo "=== Normal Cases: bidi override chars ==="
expect_label "U+202D (LRO)  → [bidi-override]"     $'hello\xe2\x80\xadworld'     "[bidi-override]"
expect_label "U+202E (RLO)  → [bidi-override]"     $'hello\xe2\x80\xaeworld'     "[bidi-override]"
expect_label "U+2066 (LRI)  → [bidi-override]"     $'hello\xe2\x81\xa6world'     "[bidi-override]"
expect_label "U+2067 (RLI)  → [bidi-override]"     $'hello\xe2\x81\xa7world'     "[bidi-override]"
expect_label "U+2068 (FSI)  → [bidi-override]"     $'hello\xe2\x81\xa8world'     "[bidi-override]"
expect_label "U+2069 (PDI)  → [bidi-override]"     $'hello\xe2\x81\xa9world'     "[bidi-override]"

echo ""
echo "=== Error Cases (no false positive) ==="
expect_clean "ASCII only — clean"                   "hello world 123"
expect_clean "Japanese text — clean"                "日本語テスト"
expect_clean "Latin extended (é, ü) — clean"       $'caf\xc3\xa9 R\xc3\xbcckgabe'

echo ""
echo "=== Edge Cases ==="
if printf '' | run_with_timeout "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
    pass "empty input — exit 0"
else
    fail "empty input — unexpected non-zero exit"
fi
expect_label "hidden char buried in long line still detected" \
    $'lots of text before \xe2\x80\x8b and lots of text after' "[zero-width]"

echo ""
echo "=== Idempotency Cases ==="
input1=$'code\xe2\x80\xaemalicious'
r1="$(scan_output "$input1")"; r2="$(scan_output "$input1")"
if [ "$r1" = "$r2" ]; then
    pass "scanning same content twice produces identical output"
else
    fail "outputs differ between runs"
fi

echo ""
echo "=== Security Cases (allowlist) ==="
printf '%s\n' $'hello\xe2\x80\x8bworld' > "$FAKE_DOTFILES/.private-info-allowlist"
if printf '%s\n' $'hello\xe2\x80\x8bworld' | run_with_timeout env -u AGENTS_CONFIG_DIR "$SCANNER" --stdin "test.txt" >/dev/null 2>&1; then
    pass "allowlisted zero-width line suppressed"
else
    fail "allowlisted zero-width line still detected"
fi
expect_label "non-allowlisted bidi still detected when zwsp is allowlisted" \
    $'hello\xe2\x80\xaeworld' "[bidi-override]"
: > "$FAKE_DOTFILES/.private-info-allowlist"

echo ""
echo "=== Group A (#1593): AGENTS_CONFIG_DIR anchor + fail-closed + --manifest ==="
# These cases target POST-implementation behavior of bin/scan-outbound.sh:
#   - blocklist resolved via AGENTS_CONFIG_DIR (new anchor), fail-closed with rc=4
#     when the blocklist cannot be resolved (was: silent skip → rc=0)
#   - allowlist absence is non-fatal: stderr warning, processing continues
#   - --manifest mode: RS-delimited, length-prefixed multi-file framing with
#     per-file allowlist labels (a.txt:<pattern> scopes the suppression to a.txt)
# Against CURRENT code these FAIL (fail-before-fix for this security branch):
#   the scanner ignores AGENTS_CONFIG_DIR, treats a missing blocklist as clean,
#   and has no --manifest mode (it tries to scan a file literally named --manifest).

A_RC=0; A_OUT=""; A_ERR=""

# run_anchor <cfg|__unset__> <stdin-content> — invoke scanner in --stdin mode with
# AGENTS_CONFIG_DIR pinned (or unset). Captures A_RC / A_OUT / A_ERR.
run_anchor() {
    local cfg="$1" content="$2"
    local ofile efile
    ofile="$(mktemp)"; efile="$(mktemp)"
    set +e
    (
        if [ "$cfg" = "__unset__" ]; then unset AGENTS_CONFIG_DIR; else export AGENTS_CONFIG_DIR="$cfg"; fi
        printf '%s' "$content" | run_with_timeout "$SCANNER" --stdin "test.txt"
    ) >"$ofile" 2>"$efile"
    A_RC=$?
    set -e
    A_OUT="$(cat "$ofile")"; A_ERR="$(cat "$efile")"
    rm -f "$ofile" "$efile"
}

# run_manifest <cfg> <framed-manifest> — invoke scanner in --manifest mode.
run_manifest() {
    local cfg="$1" manifest="$2"
    local ofile efile
    ofile="$(mktemp)"; efile="$(mktemp)"
    set +e
    (
        export AGENTS_CONFIG_DIR="$cfg"
        printf '%s' "$manifest" | run_with_timeout "$SCANNER" --manifest
    ) >"$ofile" 2>"$efile"
    A_RC=$?
    set -e
    A_OUT="$(cat "$ofile")"; A_ERR="$(cat "$efile")"
    rm -f "$ofile" "$efile"
}

a_expect_rc() {
    local d="$1" w="$2"
    if [ "$A_RC" = "$w" ]; then pass "$d (rc=$w)"
    else fail "$d — expected rc=$w, got rc=$A_RC. out=[$A_OUT] err=[$A_ERR]"; fi
}
# Pure-bash substring tests (quoted needle → literal, so glob metachars like the
# brackets in "[blocklist]" match literally). Avoids grep entirely: under MSYS an
# empty-input `grep -q <<<""` can SIGABRT, and a piped `printf|grep` can SIGPIPE
# printf under pipefail — either would mis-report a genuine match.
a_out_has() {
    local d="$1" n="$2"
    if [[ "$A_OUT" == *"$n"* ]]; then pass "$d"
    else fail "$d — stdout lacks '$n'. out=[$A_OUT]"; fi
}
a_out_lacks() {
    local d="$1" n="$2"
    if [[ "$A_OUT" == *"$n"* ]]; then fail "$d — stdout should NOT contain '$n'. out=[$A_OUT]"
    else pass "$d"; fi
}
a_err_has() {
    local d="$1" n="$2"
    local hay="${A_ERR,,}" nee="${n,,}"
    if [[ "$hay" == *"$nee"* ]]; then pass "$d"
    else fail "$d — stderr lacks '$n'. err=[$A_ERR]"; fi
}

# RS (0x1e) record separator for --manifest framing.
A_RS=$'\x1e'
# a_rec <repo-relative-path> <content> — one length-prefixed record:
#   RS + path + RS + byteLength(decimal) + LF + rawBytes  (no trailing newline added)
a_rec() {
    local p="$1" c="$2" len
    len="$(printf '%s' "$c" | wc -c)"
    len="${len//[[:space:]]/}"
    printf '%s%s%s%s\n%s' "$A_RS" "$p" "$A_RS" "$len" "$c"
}

# ── Fixtures: separate anchor dirs so each case controls its own blocklist. ──
A_CFG_WITH="$TMPBASE/a-cfg-with"; mkdir -p "$A_CFG_WITH"
printf 'forbiddenword[0-9]+\n' > "$A_CFG_WITH/.private-info-blocklist"
: > "$A_CFG_WITH/.private-info-allowlist"

A_CFG_EMPTY="$TMPBASE/a-cfg-empty"; mkdir -p "$A_CFG_EMPTY"   # allowlist only, NO blocklist
: > "$A_CFG_EMPTY/.private-info-allowlist"

A_CFG_ZERO="$TMPBASE/a-cfg-zero"; mkdir -p "$A_CFG_ZERO"      # blocklist present, 0 valid lines
printf '# only a comment\n\n' > "$A_CFG_ZERO/.private-info-blocklist"
: > "$A_CFG_ZERO/.private-info-allowlist"

A_CFG_NOALLOW="$TMPBASE/a-cfg-noallow"; mkdir -p "$A_CFG_NOALLOW"  # blocklist present, NO allowlist
printf 'forbiddenword[0-9]+\n' > "$A_CFG_NOALLOW/.private-info-blocklist"

A_CFG_M="$TMPBASE/a-cfg-manifest"; mkdir -p "$A_CFG_M"
printf 'forbiddenword[0-9]+\n' > "$A_CFG_M/.private-info-blocklist"
printf 'a.txt:forbiddenword5\n' > "$A_CFG_M/.private-info-allowlist"

# A1: blocklist absent (fallback anchor has none) → rc=4 hard fail (was silent rc=0).
#     Temporarily remove the baseline blocklist so the SCRIPT_DIR/.. fallback
#     cannot resolve one → fail-closed.
rm -f "$FAKE_DOTFILES/.private-info-blocklist"
run_anchor "__unset__" "totally clean text"
a_expect_rc "A1: blocklist unresolvable via fallback → rc=4" 4
# Restore baseline blocklist for subsequent tests that use __unset__ or fallback.
printf '# baseline — no custom blocklist entries for hidden-char scan tests\n' > "$FAKE_DOTFILES/.private-info-blocklist"

# A2: blocklist present but 0 valid lines → rc=0 (an empty blocklist is clean).
run_anchor "$A_CFG_ZERO" "totally clean text"
a_expect_rc "A2: blocklist with only comments/blank → rc=0" 0

# A3: allowlist absent → non-fatal stderr warning, processing continues (rc=0 clean).
run_anchor "$A_CFG_NOALLOW" "totally clean text"
a_expect_rc "A3: missing allowlist is non-fatal → rc=0" 0
a_err_has "A3: stderr warns about missing allowlist" "allowlist"

# A3b: allowlist absent + blocklist match → rc=1 (missing allowlist does not suppress match).
run_anchor "$A_CFG_NOALLOW" "see forbiddenword42 here"
a_expect_rc "A3b: missing allowlist + blocklist match → rc=1" 1
a_out_has "A3b: missing allowlist does not suppress blocklist match" "[blocklist]"

# A4: AGENTS_CONFIG_DIR points at a dir with a real blocklist → resolves + scans.
run_anchor "$A_CFG_WITH" "see forbiddenword42 here"
a_expect_rc "A4: anchored blocklist hard match → rc=1" 1
a_out_has "A4: hard match labelled [blocklist]" "[blocklist]"

# A5: AGENTS_CONFIG_DIR set but that dir has no blocklist → rc=4 (fail-closed).
run_anchor "$A_CFG_EMPTY" "totally clean text"
a_expect_rc "A5: anchor set but blocklist missing → rc=4" 4

# A6: AGENTS_CONFIG_DIR unset → falls back to SCRIPT_DIR/.. (backward compat).
#     Give the fallback (FAKE_DOTFILES) a blocklist for this case only.
printf 'forbiddenword[0-9]+\n' > "$FAKE_DOTFILES/.private-info-blocklist"
run_anchor "__unset__" "see forbiddenword7 here"
a_expect_rc "A6: unset anchor → fallback blocklist still scans → rc=1" 1
a_out_has "A6: fallback match labelled [blocklist]" "[blocklist]"
rm -f "$FAKE_DOTFILES/.private-info-blocklist"

# A7: --manifest with 2 files + file-scoped allowlist a.txt:forbiddenword5.
#     a.txt match suppressed (allowlisted for a.txt); b.txt with the same value flagged.
A7_MANIFEST="$(a_rec a.txt "see forbiddenword5 in a")$(a_rec b.txt "see forbiddenword5 in b")"
run_manifest "$A_CFG_M" "$A7_MANIFEST"
a_expect_rc "A7: manifest per-file allowlist → b.txt violates → rc=1" 1
a_out_has "A7: b.txt flagged" "b.txt"
a_out_lacks "A7: a.txt suppressed by file-scoped allowlist" "a.txt:"

# A8: --manifest where the first blob has NO trailing newline and is immediately
#     followed by a second blob → length-prefix framing keeps them separate; both
#     patterns are detected under their own path label (no boundary confusion).
A8_MANIFEST="$(a_rec f1.txt "alpha forbiddenword1")$(a_rec f2.txt "beta forbiddenword2")"
run_manifest "$A_CFG_M" "$A8_MANIFEST"
a_expect_rc "A8: two framed blobs both scanned → rc=1" 1
a_out_has "A8: first blob (no trailing newline) framed → forbiddenword1" "forbiddenword1"
a_out_has "A8: second blob framed → forbiddenword2" "forbiddenword2"

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
