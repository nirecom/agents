# The deps op contract (#2502 S1): registration, rules-doc, the deps column crr_read fills per
# case, the reader child's untouched output, rc 2 for an unknown op and rc 69 without the
# runtime. Sourced by tests/bin/feature-2502-case-embed-order.sh.
# shellcheck shell=bash

echo ""
echo "=== deps op contract ==="

DEPS_CO="$TMPBASE/co-deps"
embed_checkout "$DEPS_CO"

# reader_raw <id> <abs> — the test case reader child process's own stdout, run directly.
reader_raw() {
  local r
  case "$1" in
    pester) r="$(np "$DEPS_CO/$PARTS/pester-case-reader.ps1")"; run_with_timeout 120 pwsh -NoProfile -NonInteractive -File "$r" "$(np "$2")" ;;
    pytest) r="$(np "$DEPS_CO/$PARTS/pytest-case-reader.py")"; run_with_timeout 120 uv run --no-project python "$r" "$(np "$2")" ;;
    js) r="$(np "$DEPS_CO/$PARTS/js-case-reader.js")"; run_with_timeout 120 node "$r" "$(np "$2")" ;;
  esac
}

# check_contract <id> — registration, rules-doc, the deps column, the deps op's own answer,
# the reader child's untouched output, and rc 2 for an unknown op.
check_contract() {
  local id="$1" got out lines c0 c1 c2 raw bad
  need_rt "$id" || return 0
  got="$(bash -c '. "$1/bin/lib/test-language-registry.sh"; tlr_load || exit 96; tlr_field "$2" caseEmbedRules.file; tlr_field "$2" caseEmbedRules.function' _ "$DEPS_CO" "$id" 2>/dev/null | tr '\n' ' ')"
  assert_eq "$id caseEmbedRules: $got" "$id caseEmbedRules: $PARTS/$id-case-embed.sh ${id}_case_embed "
  if [ -f "$SCRIPT_CHECKOUT_ROOT/$PARTS/$L_ANALYZER" ]; then pass "$id: analyzer $L_ANALYZER present"; else fail "$id: analyzer $L_ANALYZER present" "missing"; fi
  out="$(batch "$DEPS_CO" "$DEPS_CO/$L_REL" - "$id" "rules-doc FILE" "deps FILE" "no-such-op FILE")"
  assert_eq "$id rules-doc rc=$(sect_rc "$out" "rules-doc FILE") out=$(sect "$out" "rules-doc FILE")" "$id rules-doc rc=0 out=skills/sweep-tests/embed-rules/$id.md"
  lines="$(sect "$out" crr)"
  assert_eq "$id crr_read rc=$(sect_rc "$out" crr) FILE=$(file_line "$lines")" "$id crr_read rc=0 FILE=conforming||"
  c0="$(deps_of "$lines" 0)" c1="$(deps_of "$lines" 1)" c2="$(deps_of "$lines" 2)"
  for got in "$c0" "$c1" "$c2"; do
    if [ "$got" = "?" ] || [ "$got" = "<none>" ]; then fail "$id: deps column filled" "got [$got]; stderr: $(head -c 300 "$TMPBASE/b.0.err")"; else pass "$id: deps column filled"; fi
  done
  expect_deps "$id case 0" "$c0" "$L_A" "$L_B $L_V $L_U"
  expect_deps "$id case 1" "$c1" "$L_A $L_B $L_V" "$L_U"
  # Case 2 uses none of the sample's own definitions (js may still list module-level requires).
  expect_deps "$id case 2" "$c2" "" "$L_A $L_B $L_V $L_U"
  # The deps op itself answers idx<TAB>csv per case; the ORDER lines stay inside the part.
  assert_eq "$id deps op rc=$(sect_rc "$out" "deps FILE")" "$id deps op rc=0"
  assert_eq "$id deps op indexes: $(sect "$out" "deps FILE" | cut -f1 | tr '\n' ' ')" "$id deps op indexes: 0 1 2 "
  assert_eq "$id unknown op rc=$(sect_rc "$out" "no-such-op FILE")" "$id unknown op rc=2"
  # The test case reader child process's output is unchanged: CASE lines keep an empty deps
  # column (the window fills it, not the child).
  raw="$(reader_raw "$id" "$DEPS_CO/$L_REL")"
  bad="$(printf '%s\n' "$raw" | awk -F'\t' '$1 == "CASE" && (NF != 7 || $6 != "") { print NR }' | tr '\n' ' ')"
  assert_eq "$id reader child CASE lines with deps [$bad] count=$(printf '%s\n' "$raw" | grep -c '^CASE')" "$id reader child CASE lines with deps [] count=3"
}

# check_runtime_missing <id> — the ops run with the runtime off PATH: rc 69, never rc 0.
check_runtime_missing() {
  local id="$1" o out
  need_rt "$id" || return 0
  out="$(batch "$DEPS_CO" "$DEPS_CO/$L_REL" "$(path_without "$L_RT")" "$id" "deps FILE" "leftover-defs FILE" "self-impl FILE" "skip-reason FILE")"
  for o in "deps FILE" "leftover-defs FILE" "self-impl FILE" "skip-reason FILE"; do
    assert_eq "$id $o without $L_RT: rc=$(sect_rc "$out" "$o")" "$id $o without $L_RT: rc=69"
  done
}

case_begin "pester-deps-contract" "bin/lib/test-language-parts/pester-case-embed.sh"
check_contract pester
case_end

case_begin "pytest-deps-contract" "bin/lib/test-language-parts/pytest-case-embed.sh"
check_contract pytest
case_end

case_begin "js-deps-contract" "bin/lib/test-language-parts/js-case-embed.sh"
check_contract js
case_end

case_begin "pester-runtime-missing" "bin/lib/test-language-parts/pester-case-embed.sh"
check_runtime_missing pester
case_end

case_begin "pytest-runtime-missing" "bin/lib/test-language-parts/pytest-case-embed.sh"
check_runtime_missing pytest
case_end

case_begin "js-runtime-missing" "bin/lib/test-language-parts/js-case-embed.sh"
check_runtime_missing js
case_end
