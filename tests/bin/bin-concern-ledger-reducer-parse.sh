#!/usr/bin/env bash
# tests/bin/bin-concern-ledger-reducer-parse.sh
# Tests: bin/lib/concern-ledger/parse.sh
# Tags: concern-ledger, reducer, parse, pattern-discovery, scope:common, pwsh-not-required, threat-boundary, issue-2020
# Runs the parse group (pattern-discovery, path-shapes-and-framing) of bin-concern-ledger-reducer.sh (#2723 split).
export WORKFLOW_STATE_DIR="${TMPDIR:-/tmp}/clg-wrapper-state-$$" WORKFLOW_PLANS_DIR="${TMPDIR:-/tmp}/clg-wrapper-plans-$$"
# shellcheck source=../lib/harness.sh
. "$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)/tests/lib/harness.sh"
set -uo pipefail

# #2020 I4 cases run here, in this file's own shell, before the dispatcher: the dispatcher resets
# PASS/FAIL and ends in exit, so it runs last in a subshell and its status joins this file's result.
# The library is sourced per call inside a subshell, so this shell never pre-loads the library
# names the dispatcher's namespace guard snapshots.
NCM_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
NCM_LIB="$NCM_ROOT/bin/lib/concern-ledger.sh"
NCM_TMP="$(make_tmp)"
readonly NCM_TMP
trap 'rm -rf "$NCM_TMP"' EXIT
unset CLAUDE_CODE_SESSION_ID

ncm_trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ncm_check <name> <want> <got>
ncm_check() {
    if [[ "$2" == "$3" ]]; then
        pass "$1"
    else
        fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"
    fi
}

# ncm_parse <raw> <producer> <norm> → the first line cl_parse_anchored prints (its label)
ncm_parse() {
    [[ -f "$NCM_LIB" ]] || return 127
    ( set +u; . "$NCM_LIB" >/dev/null 2>&1 || exit 127; cl_parse_anchored "$@" 2>/dev/null ) | head -n1
}

# ncm_report <file> <delta-line>... → reviewer report carrying a Concern Delta section
ncm_report() {
    local f="$1" l
    shift
    {
        printf '## Codex Review: PERFORMED\n\n'
        printf '## Concern Delta\n'
        for l in "$@"; do printf '%s\n' "$l"; done
        printf '\n'
    } > "$f"
}

# ncm_anchored <sev> <ref> <path> <anchor> <category> <text> → one reviewer delta line
ncm_anchored() { printf '[%s] %s | %s#%s | %s | %s\n' "$1" "$2" "$3" "$4" "$5" "$6"; }

NCM_PROD="security-scanner"
NCM_OK="$(ncm_anchored HIGH - bin/x.sh run_cmd security 'axis:A5/B2 shell injection through an unquoted argument')"
NCM_OK_DOCS="$(ncm_anchored LOW - docs/a.md intro docs 'axis:A0/B0 the intro names a removed flag')"
NCM_MARK_A2='[NOT-CONCERN] axis:A2/B1 | bin/x.sh#run_cmd | a remote attacker could tamper with the network share'
NCM_MARK_A0='[NOT-CONCERN] axis:A0/B3 | bin/y.sh#- | a hypothetical injection with no reachable input path'
# #2020 (the #2929 premise): a marker line with an unknown trailing column is still a marker.
NCM_MARK_X='[NOT-CONCERN] axis:A2/B1 | bin/x.sh#run_cmd | a remote attacker on the LAN | v1 | future-col'
NCM_BAD='this line is concern-like but has no severity token'
NCM_EMBED='note: [NOT-CONCERN] axis:A2/B1 | bin/x.sh#f | not at line start'

# #2020 I4: cl_parse_anchored drops a '[NOT-CONCERN] axis:<A>/<B> | <path>#<anchor|-> | <text>'
# marker line from its candidates — never an #unparsed record, never a PARTIAL label — while a
# concern line still parses as before and a malformed non-marker line is still PARTIAL.
case_begin "reducer-not-concern-marker" "bin/lib/concern-ledger/parse.sh"
# Tokens: OK / DOCS = well-formed concern lines, M2 / M0 = marker lines, NONE = '(none)',
# BAD = malformed, EMBED = a marker token that does not open the line.
# Columns: name | tokens | label | #unparsed records | concern rows
while IFS='|' read -r name tokens want_lbl want_unp want_rows; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(ncm_trim "$name")"; tokens="$(ncm_trim "$tokens")"
    want_lbl="$(ncm_trim "$want_lbl")"; want_unp="$(ncm_trim "$want_unp")"; want_rows="$(ncm_trim "$want_rows")"
    W="$(mktemp -d "$NCM_TMP/ncm-XXXXXX")"
    NCM_LINES=()
    for tok in $tokens; do
        case "$tok" in
            OK)    NCM_LINES+=("$NCM_OK") ;;
            DOCS)  NCM_LINES+=("$NCM_OK_DOCS") ;;
            M2)    NCM_LINES+=("$NCM_MARK_A2") ;;
            M0)    NCM_LINES+=("$NCM_MARK_A0") ;;
            MX)    NCM_LINES+=("$NCM_MARK_X") ;;
            NONE)  NCM_LINES+=("(none)") ;;
            BAD)   NCM_LINES+=("$NCM_BAD") ;;
            EMBED) NCM_LINES+=("$NCM_EMBED") ;;
            *) fail "2020-marker: unknown token '$tok' in row $name" ;;
        esac
    done
    ncm_report "$W/raw.txt" "${NCM_LINES[@]}"
    got="$(ncm_parse "$W/raw.txt" "$NCM_PROD" "$W/norm.txt")"
    ncm_check "2020-marker $name: parse label" "$want_lbl" "$(ncm_trim "${got:-}")"
    ncm_check "2020-marker $name: #unparsed records" "$want_unp" "$(grep -c '^#unparsed|' "$W/norm.txt" 2>/dev/null)"
    ncm_check "2020-marker $name: concern rows" "$want_rows" "$(grep -vc '^#' "$W/norm.txt" 2>/dev/null)"
    ncm_check "2020-marker $name: no marker text reaches the delta" "0" "$(grep -c -F '[NOT-CONCERN]' "$W/norm.txt" 2>/dev/null)"
done <<'TABLE'
concern-only-baseline          | OK           | COMPLETE | 0 | 1
concern-then-marker            | OK M2        | COMPLETE | 0 | 1
marker-then-two-concerns       | M0 OK DOCS   | COMPLETE | 0 | 2
markers-only                   | M2 M0        | COMPLETE | 0 | 0
marker-and-explicit-none       | NONE M2      | COMPLETE | 0 | 0
malformed-still-partial        | OK M2 BAD    | PARTIAL  | 1 | 1
marker-unknown-trailing-column | OK MX        | COMPLETE | 0 | 1
TABLE
case_end

# A marker token that does not open the line is not a marker: it stays an #unparsed record.
case_begin "reducer-not-concern-marker-embedded" "bin/lib/concern-ledger/parse.sh"
W="$(mktemp -d "$NCM_TMP/ncm-XXXXXX")"
ncm_report "$W/raw.txt" "$NCM_OK" "$NCM_EMBED"
got="$(ncm_parse "$W/raw.txt" "$NCM_PROD" "$W/norm.txt")"
ncm_check "2020-marker embedded-token: still PARTIAL" "PARTIAL" "$(ncm_trim "${got:-}")"
if grep -qF -- "#unparsed|$NCM_EMBED" "$W/norm.txt" 2>/dev/null; then
    pass "2020-marker embedded-token: kept verbatim as #unparsed"
else
    fail "2020-marker embedded-token: kept verbatim as #unparsed" "norm: $(cat "$W/norm.txt" 2>/dev/null)"
fi
case_end

# A line that opens with the marker token but breaks the I4 shape is not a marker either: it must
# stay a verbatim #unparsed record and keep the label PARTIAL, so a reviewer line such as
# '[NOT-CONCERN] shell injection in run_cmd' can never vanish silently.
case_begin "reducer-not-concern-marker-malformed" "bin/lib/concern-ledger/parse.sh"
# Columns: name @ malformed marker line ('@' because the line itself carries '|').
while IFS='@' read -r name bad; do
    [[ -z "${name// }" ]] && continue
    name="$(ncm_trim "$name")"; bad="$(ncm_trim "$bad")"
    W="$(mktemp -d "$NCM_TMP/ncm-XXXXXX")"
    ncm_report "$W/raw.txt" "$NCM_OK" "$bad"
    got="$(ncm_parse "$W/raw.txt" "$NCM_PROD" "$W/norm.txt")"
    ncm_check "2020-marker malformed $name: still PARTIAL" "PARTIAL" "$(ncm_trim "${got:-}")"
    ncm_check "2020-marker malformed $name: one #unparsed record" "1" "$(grep -c '^#unparsed|' "$W/norm.txt" 2>/dev/null)"
    ncm_check "2020-marker malformed $name: the concern line still parses" "1" "$(grep -vc '^#' "$W/norm.txt" 2>/dev/null)"
    if grep -qF -- "#unparsed|$bad" "$W/norm.txt" 2>/dev/null; then
        pass "2020-marker malformed $name: kept verbatim as #unparsed"
    else
        fail "2020-marker malformed $name: kept verbatim as #unparsed" "norm: $(cat "$W/norm.txt" 2>/dev/null)"
    fi
done <<'TABLE'
no-axis           @ [NOT-CONCERN] shell injection in run_cmd
out-of-range-axis @ [NOT-CONCERN] axis:A9/B1 | bin/x.sh#f | out-of-range axis
no-anchor-hash    @ [NOT-CONCERN] axis:A2/B1 | bin/x.sh | no anchor hash
TABLE
case_end

NCM_PASS=$PASS
NCM_FAIL=$FAIL

CLG_GROUP=parse
( . "$(dirname "${BASH_SOURCE[0]}")/bin-concern-ledger-reducer.sh" )
NCM_DISPATCH_RC=$?

echo ""
echo "=== #2020 marker cases: $NCM_PASS passed, $NCM_FAIL failed; parse-group dispatcher rc=$NCM_DISPATCH_RC ==="
[[ "$NCM_FAIL" -eq 0 && "$NCM_DISPATCH_RC" -eq 0 ]]
