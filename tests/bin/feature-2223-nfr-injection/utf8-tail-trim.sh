#!/usr/bin/env bash
# tests/feature-2223-nfr-injection/utf8-tail-trim.sh
# Tests: bin/lib/codex-core.sh
# Tags: scope:issue-specific, TL2, codex, nfr, utf8, pwsh-not-required
# Case file for tests/feature-2223-nfr-injection.sh — sourced from it, never run
# standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# Split off rather than added to cli-guards-and-caps.sh because that file sits
# within a few lines of the 500-line HARD limit of rules/coding/file-split.md.
NFR_UTF8_TAIL_TRIM_CASES_LOADED=1

# ---------------------------------------------------------------------------
# Part E4 — _codex_core_utf8_trim_incomplete_tail on its own. The cap cases in
# cli-guards-and-caps.sh drive one 3-byte character through a real .env, the
# path that matters, but reach only the byte offsets that fixture happens to
# have. Sequence lengths 2 and 4, an orphaned continuation byte with no lead at
# all, and the empty input are branches no affordable fixture reaches.
# ---------------------------------------------------------------------------
CFG_TRIM="$(make_cfg utf8trim "CODE_LANG=english")"

# utf8_trim_hex <printf-escape> — feed the bytes that escape denotes through the
# trim and print the surviving bytes as lowercase hex. Hex rather than the raw
# text because a failure message about invalid UTF-8 must itself be readable.
utf8_trim_hex() {
    printf "$1" | AGENTS_CONFIG_DIR="$CFG_TRIM" run_with_timeout 20 bash -c '
      source "$1/bin/lib/codex-core.sh" >/dev/null 2>&1 || exit 3
      declare -F _codex_core_utf8_trim_incomplete_tail >/dev/null || exit 4
      _codex_core_utf8_trim_incomplete_tail
    ' _ "$AGENTS_DIR" 2>/dev/null | od -An -tx1 | tr -d ' \n'
}

# The function must exist before any claim about its behaviour is evidence:
# a missing function returns empty, which several rows below would accept.
if grep -q '_codex_core_utf8_trim_incomplete_tail' "$AGENTS_DIR/bin/lib/codex-core.sh" 2>/dev/null; then
    pass "T2223E4-trim-function-defined"
else
    fail "T2223E4-trim-function-defined — _codex_core_utf8_trim_incomplete_tail absent"
fi

# Complete input of every sequence length is left exactly as it arrived. These
# are the rows that stop the trim from being a blanket "drop the last bytes".
assert_eq "T2223E4-ascii-untouched" "4142" "$(utf8_trim_hex 'AB')"
assert_eq "T2223E4-complete-2byte-untouched" "c3a9" "$(utf8_trim_hex '\xc3\xa9')"
assert_eq "T2223E4-complete-3byte-untouched" "e38182" "$(utf8_trim_hex '\xe3\x81\x82')"
assert_eq "T2223E4-complete-4byte-untouched" "f09f9880" "$(utf8_trim_hex '\xf0\x9f\x98\x80')"

# A lead byte whose continuations were cut away: the whole character goes, at
# every distance from the boundary the sequence length allows.
assert_eq "T2223E4-2byte-lead-alone-dropped" "" "$(utf8_trim_hex '\xc3')"
assert_eq "T2223E4-3byte-lead-alone-dropped" "" "$(utf8_trim_hex '\xe3')"
assert_eq "T2223E4-3byte-missing-one-dropped" "" "$(utf8_trim_hex '\xe3\x81')"
assert_eq "T2223E4-4byte-lead-alone-dropped" "" "$(utf8_trim_hex '\xf0')"
assert_eq "T2223E4-4byte-missing-two-dropped" "" "$(utf8_trim_hex '\xf0\x9f')"
assert_eq "T2223E4-4byte-missing-one-dropped" "" "$(utf8_trim_hex '\xf0\x9f\x98')"

# The preceding text is never collateral: only the dangling character leaves.
assert_eq "T2223E4-keeps-prefix-past-3byte-fragment" "616263" "$(utf8_trim_hex 'abc\xe3\x81')"
assert_eq "T2223E4-keeps-prefix-past-4byte-fragment" "5a" "$(utf8_trim_hex 'Z\xf0\x9f\x98')"
assert_eq "T2223E4-keeps-complete-char-after-prefix" "61e38182" "$(utf8_trim_hex 'a\xe3\x81\x82')"

# A continuation byte with no lead byte in front of it is not a fragment of
# anything the trim can complete, so it is dropped on its own terms.
assert_eq "T2223E4-orphan-continuation-dropped" "41" "$(utf8_trim_hex 'A\x81')"
assert_eq "T2223E4-orphan-continuations-dropped" "41" "$(utf8_trim_hex 'A\x81\x82')"

# Empty input is the boundary case the byte-length arithmetic has to survive:
# an unguarded "last byte" read on nothing is where such a function crashes.
assert_eq "T2223E4-empty-input-stays-empty" "" "$(utf8_trim_hex '')"
