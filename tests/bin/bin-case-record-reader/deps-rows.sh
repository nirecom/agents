# tests/bin/bin-case-record-reader/deps-rows.sh
# Tests: bin/lib/case-record-reader.sh
# Tags: TL2, bin, case-markers, test-language-registry, table-driven, scope:issue-specific
# crr_read (#2502 S1-3b): the deps op's rows are validated before they fill the deps column.
# One bad row (missing, duplicate or out-of-range index, a third column, CR, a csv split by LF,
# an empty element, a non-numeric index, no rows) turns the whole file into
# FILE uncertain "" case-embed with no CASE lines. The deps op is a stub in a fixture checkout.
# Sourced by the dispatcher.

echo ""
echo "=== crr_read: deps op row validation ==="

DR_CO="$TMPBASE/co-deps-rows"
fx_checkout "$DR_CO"
# The stub replaces the bash caseEmbedRules part: deps prints $DR_ROWS verbatim, exits $DR_RC.
printf '%s\n' \
  'bash_case_embed() {' \
  '  [ "$1" = deps ] || return 2' \
  '  if [ -n "${DR_CALLED:-}" ]; then : >"$DR_CALLED"; fi' \
  '  cat "$DR_ROWS"' \
  '  return "${DR_RC:-0}"' \
  '}' >"$DR_CO/bin/lib/test-language-parts/bash-case-embed.sh"

DR_B="case""_begin"  # split so the fixture lines below are not read as markers
DR_E="case""_end"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: bin/a.sh' \
  "$DR_B \"c0\" \"bin/a.sh\"" 'echo 0' "$DR_E" \
  "$DR_B \"c1\" \"bin/a.sh\"" 'echo 1' "$DR_E" \
  "$DR_B \"c2\" \"bin/a.sh\"" 'echo 2' "$DR_E" >"$FXD/deps-three.sh"
export DR_ROWS="$TMPBASE/deps-rows.out" DR_RC=0 DR_CALLED=""

# dr_run <rows-printf-format> [<rc>] — crr_read deps-three.sh with the stub printing the rows.
dr_run() {
  # shellcheck disable=SC2059 # the format is the row text under test
  printf "$1" >"$DR_ROWS"
  DR_RC="${2:-0}"
  crr "$DR_CO" "$FXD/deps-three.sh"
}

# dr_case_count <crr-output> — the number of CASE lines.
dr_case_count() { printf '%s\n' "$1" | grep -c '^CASE'; }

case_begin "deps-rows-valid-fill-the-column" "bin/lib/case-record-reader.sh"
dr_run '0\ta\n1\t\n2\tb,c\n'
assert_eq "valid: rc=$CRR_RC FILE=$(file_line "$CRR_OUT")" "valid: rc=0 FILE=conforming||"
got="$(printf '%s\n' "$CRR_OUT" | awk -F'\t' '$1 == "CASE" { printf "%s=[%s] ", $2, $6 }')"
assert_eq "valid deps: $got" "valid deps: c0=[a] c1=[] c2=[b,c] "
case_end

case_begin "deps-rows-invalid-make-the-file-uncertain" "bin/lib/case-record-reader.sh"
# label|printf format of the deps op's stdout (rc 0)
while IFS='|' read -r label fmt; do
  [ -n "$label" ] || continue
  dr_run "$fmt"
  assert_eq "$label: rc=$CRR_RC FILE=$(file_line "$CRR_OUT") CASE=$(dr_case_count "$CRR_OUT")" \
    "$label: rc=0 FILE=uncertain||case-embed CASE=0"
done <<'ROWS'
index 1 missing|0\ta\n2\tb\n
index 1 duplicated|0\ta\n1\tb\n1\tc\n2\t\n
index 3 out of range|0\ta\n1\tb\n2\tc\n3\td\n
third column|0\ta\tx\n1\t\n2\t\n
CR in a value|0\ta\n1\tb\r\n2\t\n
csv split by LF|0\ta\n1\tb\nc\n2\t\n
empty csv element|0\ta,,b\n1\t\n2\t\n
non-numeric index|x\ta\n1\t\n2\t\n
no rows at all|
ROWS
case_end

case_begin "deps-op-failure-is-uncertain-or-unavailable" "bin/lib/case-record-reader.sh"
# A failing deps op is never read as "no deps": rc 1 is case-embed, rc 69 names the runtime.
dr_run '0\ta\n1\t\n2\t\n' 1
assert_eq "rc 1: rc=$CRR_RC FILE=$(file_line "$CRR_OUT") CASE=$(dr_case_count "$CRR_OUT")" \
  "rc 1: rc=0 FILE=uncertain||case-embed CASE=0"
req="$(bash -c '. "$1/bin/lib/test-language-registry.sh"; tlr_load || exit 96; tlr_field bash launch.requires' _ "$DR_CO" 2>/dev/null)"
dr_run '' 69
assert_eq "rc 69: rc=$CRR_RC FILE=$(file_line "$CRR_OUT") CASE=$(dr_case_count "$CRR_OUT")" \
  "rc 69: rc=0 FILE=unavailable||$req CASE=0"
case_end

case_begin "deps-op-not-called-without-cases" "bin/lib/case-record-reader.sh"
# A file with no case markers never reaches the deps op (unchanged behavior).
export DR_CALLED="$TMPBASE/deps-called"
rm -f "$DR_CALLED"
printf '0\ta\n' >"$DR_ROWS"
DR_RC=0
crr "$DR_CO" "$FXD/none.sh"
assert_eq "none.sh: rc=$CRR_RC FILE=$(file_line "$CRR_OUT") called=$([ -e "$DR_CALLED" ] && echo yes || echo no)" \
  "none.sh: rc=0 FILE=none|| called=no"
export DR_CALLED=""
case_end
