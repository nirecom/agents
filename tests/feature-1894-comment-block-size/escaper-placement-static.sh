#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/escaper-placement-static.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, injection, control-bytes, escaping, static-guard, enumeration, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 10 — the call sites no dynamic case can reach.
#
# injection-hardening.sh drives the WARN path, because that is the path a normal
# run takes. The scanner interpolates the SAME untrusted value into three ERROR
# lines ("staged blob unreadable", "baseline blob unreadable", "file
# unreadable"), and those fire only when a blob genuinely cannot be read — a
# state that is environment-fragile to stage and not portably forceable. An
# escaping fix applied to the WARN call sites alone would therefore pass every
# dynamic case in this suite while leaving F1 half-open. So the remaining sites
# get a STATIC guard on the source text instead; the idiom is borrowed from
# failopen-placement-static.sh in the sibling suite.
#
# Deliberately agnostic to the escaper's eventual NAME: the WARN sites define
# what "escaped" looks like, and every other site — the ERROR lines and the
# `extensions:` header, F5's own site — must match whatever form that turns out
# to be. The enumeration is by SHAPE, so a call site added later is covered the
# day it lands, and an enumeration that finds nothing fails loudly instead of
# quietly asserting nothing.
#
# Mutation-checked before landing: a WARN-only fix trips both the bare-
# interpolation assertion and the symmetry assertion; a complete fix is green
# whether it wraps in a call (`$(esc "$dst")`) or pre-escapes into a local
# (`$dst_e`); renaming the variables away empties the enumeration and fails.
#
# Sourced by the dispatcher; every helper and constant is defined there.

# The untrusted values, matched two ways on purpose: the LOOSE form selects
# lines (it must also catch a fix that renames `$dst` to a pre-escaped
# `$dst_e`), the STRICT form detects a BARE interpolation (`\>` makes `$dst_e`
# not a use of `$dst`, so a pre-escaped local is accepted).
I5_LOOSE='\$\{?(dst|src|f|_EXTS)'
I5_BARE_RE='\$(dst|src|f|_EXTS)\>|\$\{(dst|src|f|_EXTS)\}'

i5_norm() { printf '%s' "$1" | sed -E 's/\$\{?(dst|src|f|_EXTS)\}?/$@VAR@/g'; }
i5_nosub() { printf '%s' "$1" | sed -E 's/\$\([^)]*\)/@ESCAPED@/g'; }

echo ""
echo "=== I5: static guard — ERROR lines and the header escape too (F1/F5) ==="

I5_WARN_SIGS=""
I5_ERR_SIGS=""
I5_HDR_SIG=""
I5_BARE_AT=""
I5_N=0

# Report-emitting lines: an add_line/printf whose argument opens with the
# report's own `WARN: ` / `ERROR: ` marker, plus the summary line that prints
# `extensions: `. Comment lines are excluded so prose cannot pad the count.
I5_HITS="$(grep -nE '(add_line|printf).*"(WARN|ERROR): |printf.*extensions: ' "$SCRIPT" \
    | grep -vE '^[0-9]+:[[:space:]]*#' || true)"

while IFS= read -r hit; do
    [ -z "$hit" ] && continue
    lno="${hit%%:*}"
    line="${hit#*:}"
    # `ERROR: (staged index) — git diff --cached failed (rc=$rc)` carries only a
    # numeric git exit code, so it is not selected — and would be, automatically,
    # the moment someone interpolates a path into it.
    printf '%s' "$line" | grep -qE "$I5_LOOSE" || continue
    I5_N=$((I5_N + 1))
    if i5_nosub "$line" | grep -qE "$I5_BARE_RE"; then
        I5_BARE_AT="$I5_BARE_AT $lno"
    fi
    case "$line" in
        *'"WARN: '*)
            rest="${line#*\"WARN: }"
            I5_WARN_SIGS="$I5_WARN_SIGS$(i5_norm "${rest%% —*}")"$'\n' ;;
        *'"ERROR: '*)
            rest="${line#*\"ERROR: }"
            I5_ERR_SIGS="$I5_ERR_SIGS$(i5_norm "${rest%% —*}")"$'\n' ;;
        *'extensions: '*)
            rest="${line#*extensions: }"
            I5_HDR_SIG="$(i5_norm "${rest%%;*}")" ;;
    esac
done <<< "$I5_HITS"

# Non-vacuity: this whole case is an enumeration, and an enumeration that
# selects nothing asserts nothing. A rename that empties any group must break
# the test rather than quietly vacate it.
if [ "$I5_N" -gt 0 ]; then
    pass "I5/enumeration-is-not-empty ($I5_N report line(s) carry an untrusted value)"
else
    fail "I5/enumeration-is-not-empty" \
         "no report-emitting line in $SCRIPT references dst/src/f/_EXTS — the selector is stale, not the source clean."
fi
assert_absent "I5/warn-group-is-not-empty" "EMPTY" "${I5_WARN_SIGS:-EMPTY}"
assert_absent "I5/error-group-is-not-empty" "EMPTY" "${I5_ERR_SIGS:-EMPTY}"
assert_absent "I5/header-site-was-found" "EMPTY" "${I5_HDR_SIG:-EMPTY}"

# (1) fail-before-fix: no site may interpolate the value bare.
if [ -z "$I5_BARE_AT" ]; then
    pass "I5/no-site-interpolates-an-untrusted-value-bare"
else
    fail "I5/no-site-interpolates-an-untrusted-value-bare" \
         "bare \$dst/\$src/\$f/\$_EXTS at line(s):$I5_BARE_AT of $SCRIPT"
fi

# (2) symmetry (CPR-ORTH): whatever wrapper the WARN sites settle on, every
# other site uses the SAME one. This is what a WARN-only fix trips on.
i5_sig_known() { printf '%s\n' "$I5_WARN_SIGS" | grep -qxF -- "$1"; }
I5_ODD=""
while IFS= read -r sig; do
    [ -z "$sig" ] && continue
    i5_sig_known "$sig" || I5_ODD="$I5_ODD [$sig]"
done <<< "$I5_ERR_SIGS"
if [ -z "$I5_ODD" ]; then
    pass "I5/error-sites-use-the-same-wrapper-as-warn-sites"
else
    fail "I5/error-sites-use-the-same-wrapper-as-warn-sites" \
         "ERROR-site form(s)$I5_ODD not among the WARN-site form(s): $(printf '%s' "$I5_WARN_SIGS" | tr '\n' ' ')"
fi
if i5_sig_known "${I5_HDR_SIG:-EMPTY}"; then
    pass "I5/header-uses-the-same-wrapper-as-warn-sites"
else
    fail "I5/header-uses-the-same-wrapper-as-warn-sites" \
         "extensions: form [${I5_HDR_SIG:-EMPTY}] not among the WARN-site form(s): $(printf '%s' "$I5_WARN_SIGS" | tr '\n' ' ')"
fi
