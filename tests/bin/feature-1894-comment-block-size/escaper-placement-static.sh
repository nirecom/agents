#!/usr/bin/env bash
# tests/bin/feature-1894-comment-block-size/escaper-placement-static.sh
# Tests: hooks/lib/comment-block-review/review.js, hooks/lib/comment-block-review/report.js
# Tags: comment-block-size, injection, control-bytes, escaping, static-guard, enumeration, scope:issue-specific, scope:feature-1894, layer:TL2, test-lang-exception:text-only
#
# Part 10 — static guard for sites no dynamic case reaches: ERROR lines fire only on
# an unreadable blob. Every review.js report template literal (WARN/ERROR/BLOCK and the
# `extensions: ` header) interpolating dst/src/f/extensionsRaw must use the WARN site's
# escaper, exported by report.js. Enumerated by SHAPE; an empty enumeration fails.
# Sourced by the dispatcher; every helper and constant is defined there.

I5_REVIEW_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/comment-block-review/review.js"
I5_REPORT_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/comment-block-review/report.js"
I5_BT='`'

# The untrusted values: git paths (dst/src/f) and the configured extension list.
I5_ID='(dst|src|f|(cfg\.)?extensionsRaw)'
# LOOSE is a prefix match on purpose: it must also select a pre-escaped local (dstE).
I5_LOOSE="(^|[^A-Za-z0-9_\$.])$I5_ID"
# An escaped interpolation normalizes to exactly one call around the value.
I5_WRAPPED_RE='^[A-Za-z_$][A-Za-z0-9_$.]*\(@VAR@\)$'
I5_DECL_RE='^[[:space:]]*const[[:space:]]+([A-Za-z_$][A-Za-z0-9_$]*)[[:space:]]*=[[:space:]]*([A-Za-z_$][A-Za-z0-9_$.]*)\((dst|src|f|(cfg\.)?extensionsRaw)\)[[:space:]]*;'

# Pre-escaped locals (`const dstE = esc(dst);`) stand for the call they were built from.
declare -A I5_LOCAL_SIG=()
while IFS= read -r i5_decl; do
    [[ "$i5_decl" =~ $I5_DECL_RE ]] || continue
    I5_LOCAL_SIG["${BASH_REMATCH[1]}"]="${BASH_REMATCH[2]}(@VAR@)"
done < <(grep -E '^[[:space:]]*const ' "$I5_REVIEW_JS" 2>/dev/null || true)

i5_norm() { printf '%s' "$1" | sed -E "s/(^|[^A-Za-z0-9_\$.])$I5_ID([^A-Za-z0-9_\$]|\$)/\\1@VAR@\\4/g"; }
i5_sig() {
    if [[ -n "${I5_LOCAL_SIG[$1]+x}" ]]; then printf '%s' "${I5_LOCAL_SIG[$1]}"; else i5_norm "$1"; fi
}
# i5_exprs <text> — the untrusted-carrying `${...}` bodies in <text>, one per line.
i5_exprs() {
    local ex
    printf '%s\n' "$1" | grep -oE '\$\{[^}]*\}' | while IFS= read -r ex; do
        ex="${ex#\$\{}"
        ex="${ex%\}}"
        printf '%s' "$ex" | grep -qE "$I5_LOOSE" && printf '%s\n' "$ex"
    done
}
# i5_seg_sigs <text after the marker> <terminator> — signatures of that segment only.
i5_seg_sigs() {
    local ex
    while IFS= read -r ex; do
        [[ -n "$ex" ]] && printf '%s\n' "$(i5_sig "$ex")"
    done <<< "$(i5_exprs "${1%%"$2"*}")"
}

echo ""
echo "=== I5: static guard — ERROR/BLOCK lines and the header escape too (F1/F5) ==="

I5_WARN_SIGS=""
I5_BLOCK_SIGS=""
I5_ERR_SIGS=""
I5_HDR_SIG=""
I5_BARE_AT=""
I5_N=0

# Report-emitting template literals; comment lines are excluded so prose cannot pad the count.
I5_HITS="$(grep -nE "${I5_BT}(WARN|ERROR|BLOCK): |extensions: \\$\\{" "$I5_REVIEW_JS" 2>/dev/null \
    | grep -vE '^[0-9]+:[[:space:]]*(//|\*)' || true)"

while IFS= read -r hit; do
    [[ -z "$hit" ]] && continue
    lno="${hit%%:*}"
    line="${hit#*:}"
    # `ERROR: (staged index) — ... (rc=${list.status})` carries only a number, so it is
    # not selected — and would be, automatically, once a path is interpolated into it.
    exprs="$(i5_exprs "$line")"
    [[ -z "$exprs" ]] && continue
    I5_N=$((I5_N + 1))
    while IFS= read -r ex; do
        [[ "$(i5_sig "$ex")" =~ $I5_WRAPPED_RE ]] || I5_BARE_AT="$I5_BARE_AT $lno:\${$ex}"
    done <<< "$exprs"
    case "$line" in
        *"${I5_BT}WARN: "*) I5_WARN_SIGS="$I5_WARN_SIGS$(i5_seg_sigs "${line#*"${I5_BT}"WARN: }" ' —')"$'\n' ;;
        *"${I5_BT}BLOCK: "*) I5_BLOCK_SIGS="$I5_BLOCK_SIGS$(i5_seg_sigs "${line#*"${I5_BT}"BLOCK: }" ' —')"$'\n' ;;
        *"${I5_BT}ERROR: "*) I5_ERR_SIGS="$I5_ERR_SIGS$(i5_seg_sigs "${line#*"${I5_BT}"ERROR: }" ' —')"$'\n' ;;
        *'extensions: ${'*) I5_HDR_SIG="$(i5_seg_sigs "${line#*extensions: }" ';')" ;;
    esac
done <<< "$I5_HITS"

# Non-vacuity: an enumeration that selects nothing asserts nothing, so a rename
# that empties any group must break the test rather than quietly vacate it.
if [[ "$I5_N" -gt 0 ]]; then
    pass "I5/enumeration-is-not-empty ($I5_N report line(s) carry an untrusted value)"
else
    fail "I5/enumeration-is-not-empty" \
         "no report template literal in $I5_REVIEW_JS references dst/src/f/extensionsRaw — the selector is stale, not the source clean."
fi
assert_absent "I5/warn-group-is-not-empty" "EMPTY" "${I5_WARN_SIGS:-EMPTY}"
assert_absent "I5/block-group-is-not-empty" "EMPTY" "${I5_BLOCK_SIGS:-EMPTY}"
assert_absent "I5/error-group-is-not-empty" "EMPTY" "${I5_ERR_SIGS:-EMPTY}"
assert_absent "I5/header-site-was-found" "EMPTY" "${I5_HDR_SIG:-EMPTY}"

# (1) fail-before-fix: no site may interpolate the value bare (or through an unknown local).
if [[ -z "$I5_BARE_AT" ]]; then
    pass "I5/no-site-interpolates-an-untrusted-value-bare"
else
    fail "I5/no-site-interpolates-an-untrusted-value-bare" \
         "unescaped interpolation at line(s):$I5_BARE_AT of $I5_REVIEW_JS"
fi

# (2) the WARN sites' escaper is the one report.js defines and exports.
I5_ESC_BAD=""
I5_ESC_SEEN=0
while IFS= read -r sig; do
    [[ -z "$sig" ]] && continue
    I5_ESC_SEEN=1
    callee="${sig%(@VAR@)}"
    grep -qE "^const \\{[^}]*\\b${callee}\\b[^}]*\\} = require\\(\"\\./report\"\\)" "$I5_REVIEW_JS" \
        && grep -qE "^function ${callee}\\(" "$I5_REPORT_JS" \
        && grep -qE "^module\\.exports = \\{[^}]*\\b${callee}\\b" "$I5_REPORT_JS" \
        || I5_ESC_BAD="$I5_ESC_BAD [$sig]"
done <<< "$I5_WARN_SIGS"
if [[ "$I5_ESC_SEEN" -eq 1 && -z "$I5_ESC_BAD" ]]; then
    pass "I5/warn-escaper-is-the-one-report-js-exports"
else
    fail "I5/warn-escaper-is-the-one-report-js-exports" \
         "WARN-site form(s)${I5_ESC_BAD:- [none]} not an escaper review.js imports from ./report and report.js defines"
fi

# (3) symmetry (CPR-ORTH): every other site uses the SAME wrapper as the WARN sites.
i5_sig_known() { printf '%s\n' "$I5_WARN_SIGS" | grep -qxF -- "$1"; }
i5_assert_same_wrapper() {
    local name="$1" sigs="$2" sig odd=""
    while IFS= read -r sig; do
        [[ -z "$sig" ]] && continue
        i5_sig_known "$sig" || odd="$odd [$sig]"
    done <<< "$sigs"
    [[ -z "$sigs" ]] && odd=" [EMPTY]"
    if [[ -z "$odd" ]]; then
        pass "$name"
    else
        fail "$name" "form(s)$odd not among the WARN-site form(s): $(printf '%s' "$I5_WARN_SIGS" | tr '\n' ' ')"
    fi
}
i5_assert_same_wrapper "I5/error-sites-use-the-same-wrapper-as-warn-sites" "$I5_ERR_SIGS"
i5_assert_same_wrapper "I5/block-sites-use-the-same-wrapper-as-warn-sites" "$I5_BLOCK_SIGS"
i5_assert_same_wrapper "I5/header-uses-the-same-wrapper-as-warn-sites" "$I5_HDR_SIG"
