# --with-language: column 9 (the language set of the query) and column 10 (the new file
# name shape per language) (#2411). Sourced by tests/bin/feature-2411-route-language.sh.
# shellcheck shell=bash

echo ""
echo "=== columns: --with-language ==="

# count_csv <text> — number of comma-separated elements.
count_csv() {
  local IFS=,
  # shellcheck disable=SC2086
  set -- $1
  printf '%s' "$#"
}

# lang_columns <label> <row> <language set>
lang_columns() {
  local r="$2" c9 c10
  if [ -z "$r" ]; then
    fail "$1" "no row from the --with-language run"
    return 0
  fi
  c9="$(col "$r" 9)"
  c10="$(col "$r" 10)"
  assert_eq "$1 fields=$(printf '%s\n' "$r" | awk -F'\t' '{print NF}')" "$1 fields=10"
  assert_eq "$1 languages=$c9" "$1 languages=$3"
  if [ "$3" = unsupported ]; then
    assert_eq "$1 shapes=$c10" "$1 shapes=-"
  else
    assert_eq "$1 shape count=$(count_csv "$c10")" "$1 shape count=$(count_csv "$3")"
    case ",$c10," in
      *",,"*|*",-,"*) fail "$1 shapes" "an empty shape in [$c10]" ;;
      *) pass "$1: every language has a shape" ;;
    esac
  fi
}

case_begin "language-of-each-source" "bin/lib/test-route-destination/language.sh"
assert_eq "--sources rc=$F_SRC_RC" "--sources rc=0"
assert_eq "--test-file rc=$F_TF_RC" "--test-file rc=0"
for _i in "${!MAP_SRC[@]}"; do
  _what="${MAP_SRC[$_i]}${MAP_NOTE[$_i]}"
  _r="$(row "$F_SRC" $((MAP_AT_SRC + _i)))"
  assert_eq "--sources $_what -> $(col "$_r" 9)" "--sources $_what -> ${MAP_LANG[$_i]}"
  _r="$(row "$F_TF" $((MAP_AT_TF + _i)))"
  assert_eq "--test-file for $_what -> $(col "$_r" 9)" "--test-file for $_what -> ${MAP_LANG[$_i]}"
done
case_end

case_begin "with-language-adds-columns-nine-and-ten" "bin/find-tests-for-source.sh"
for _i in "${!SRC_Q[@]}"; do
  lang_columns "--sources ${SRC_Q[$_i]}" "$(row "$F_SRC" "$_i")" "${SRC_LANG[$_i]}"
done
for _i in "${!TF_Q[@]}"; do
  lang_columns "--test-file ${TF_Q[$_i]}" "$(row "$F_TF" "$_i")" "${TF_LANG[$_i]}"
done
case_end

case_begin "columns-one-to-eight-ignore-the-flag" "bin/find-tests-for-source.sh"
assert_eq "--sources rc=$F_SRC_RC" "--sources rc=0"
assert_eq "--test-file rc=$F_TF_RC" "--test-file rc=0"
if [ -n "$F_SRC" ] && [ "$(printf '%s\n' "$F_SRC" | cut -f 1-8)" = "$N_SRC" ]; then
  pass "--sources: columns 1-8 equal the run without the flag"
else
  fail "--sources columns 1-8" "differ from the run without the flag"
fi
if [ -n "$F_TF" ] && [ "$(printf '%s\n' "$F_TF" | cut -f 1-8)" = "$N_TF" ]; then
  pass "--test-file: columns 1-8 equal the run without the flag"
else
  fail "--test-file columns 1-8" "differ from the run without the flag"
fi
case_end
