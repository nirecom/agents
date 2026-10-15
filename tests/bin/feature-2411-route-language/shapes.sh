# --with-language column 10: the new file name shape of each language, in both query forms,
# and its order in a query of several languages (#2411). Sourced by
# tests/bin/feature-2411-route-language.sh, which builds SHAPE_Q, SHAPE_LANG and the fixtures.
# Each language is held to its literal shape string, and to the properties a shape has:
# one element, a name the language's own patterns match, distinct from the others.
# shellcheck shell=bash

echo ""
echo "=== shapes: new file name shape per language ==="

# literal_shape <language id> — the shape string fixed for that language; empty for an id
# this table does not know, which the case reports as a failure.
literal_shape() {
  case "$1" in
    bash) printf '%s' '<name>.sh' ;;
    pester) printf '%s' '<name>.Tests.ps1' ;;
    pytest) printf '%s' 'test_<name>.py' ;;
    js) printf '%s' '<name>.js' ;;
  esac
}
REGISTRY="$SCRIPT_CHECKOUT_ROOT/hooks/lib/test-language-registry.json"

Q_WITH=1
run_q --sources "${SHAPE_Q[@]}"; SH_SRC="$Q_OUT"; SH_SRC_RC="$Q_RC"
run_q --test-file "${SHAPE_TF[@]}"; SH_TF="$Q_OUT"; SH_TF_RC="$Q_RC"
Q_WITH=0

SHAPE_PATS_JS="$TMPBASE/shape-pats.js"
cat > "$SHAPE_PATS_JS" <<'SHAPEPATSJS'
const t = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
for (const e of t.entries) for (const p of e.patterns) console.log(e.id + "|" + p);
SHAPEPATSJS
SHAPE_PATS="$(node "$(np "$SHAPE_PATS_JS")" "$(np "$REGISTRY")" 2>/dev/null | tr -d '\r')"

# shape_ok <shape> — a usable single shape: not empty, not the no-language dash, one element.
shape_ok() {
  case "$1" in
    ""|"-"|*,*|*$'\t'*) return 1 ;;
  esac
  return 0
}

# shape_fits <language id> <shape> — the shape, read as a file name, matches a name pattern
# of that language's registry entry.
shape_fits() {
  local id pat
  while IFS='|' read -r id pat; do
    [ "$id" = "$1" ] || continue
    # shellcheck disable=SC2254
    case "$2" in $pat) return 0 ;; esac
  done <<< "$SHAPE_PATS"
  return 1
}

# single_shape <language id> — the shape the --sources run gave that language alone.
single_shape() {
  local i
  for i in "${!SHAPE_LANG[@]}"; do
    if [ "${SHAPE_LANG[$i]}" = "$1" ]; then
      col "$(row "$SH_SRC" "$i")" 10
      return 0
    fi
  done
}

# joined_shapes <language set> — the single shapes of the set, in its order, comma-joined;
# empty when one of them is not usable.
joined_shapes() {
  local out="" id s
  local IFS=,
  for id in $1; do
    s="$(single_shape "$id")"
    shape_ok "$s" || return 0
    out="${out:+$out,}$s"
  done
  printf '%s' "$out"
}

case_begin "new-file-name-shape-of-each-language" "bin/find-tests-for-source.sh"
assert_eq "--sources rc=$SH_SRC_RC rows=$(printf '%s\n' "$SH_SRC" | grep -c .)" "--sources rc=0 rows=${#SHAPE_Q[@]}"
assert_eq "--test-file rc=$SH_TF_RC rows=$(printf '%s\n' "$SH_TF" | grep -c .)" "--test-file rc=0 rows=${#SHAPE_TF[@]}"
_seen=""
_lits=""
for _i in "${!SHAPE_LANG[@]}"; do
  _lang="${SHAPE_LANG[$_i]}"
  case "$_lang" in *,*) continue ;; esac
  _src="$(row "$SH_SRC" "$_i")"
  _tf="$(row "$SH_TF" "$_i")"
  _s="$(col "$_src" 10)"
  _t="$(col "$_tf" 10)"
  assert_eq "--sources ${SHAPE_Q[$_i]} language=$(col "$_src" 9)" "--sources ${SHAPE_Q[$_i]} language=$_lang"
  assert_eq "--test-file ${SHAPE_TF[$_i]} language=$(col "$_tf" 9)" "--test-file ${SHAPE_TF[$_i]} language=$_lang"
  if shape_ok "$_s"; then
    pass "$_lang --sources: one shape [$_s]"
  else
    fail "$_lang --sources shape" "not a single shape: [$_s]"
  fi
  assert_eq "$_lang --test-file shape=$_t" "$_lang --test-file shape=$_s"
  if shape_ok "$_s" && shape_fits "$_lang" "$_s"; then
    pass "$_lang: [$_s] matches a name pattern of the $_lang registry entry"
  else
    fail "$_lang shape vs registry" "[$_s] matches no name pattern of the $_lang entry"
  fi
  _lit="$(literal_shape "$_lang")"
  if [ -z "$_lit" ]; then
    fail "$_lang literal shape" "no literal shape is fixed for [$_lang]"
  else
    assert_eq "$_lang --sources shape=$_s" "$_lang --sources shape=$_lit"
    assert_eq "$_lang --test-file shape=$_t" "$_lang --test-file shape=$_lit"
    _lits="${_lits:+$_lits }$_lang"
  fi
  case ",$_seen," in
    *",$_s,"*) fail "$_lang shape is its own" "[$_s] is also the shape of another language ($_seen)" ;;
    *) pass "$_lang: shape differs from the languages before it" ;;
  esac
  _seen="${_seen:+$_seen,}$_s"
done
assert_eq "languages held to a literal: $(printf '%s\n' $_lits | LC_ALL=C sort | tr '\n' ' ')" "languages held to a literal: bash js pester pytest "
case_end

case_begin "new-file-name-shape-follows-the-language-order" "bin/find-tests-for-source.sh"
_mixed=0
for _i in "${!SHAPE_LANG[@]}"; do
  _lang="${SHAPE_LANG[$_i]}"
  case "$_lang" in *,*) ;; *) continue ;; esac
  _mixed=$((_mixed + 1))
  _want="$(joined_shapes "$_lang")"
  _src="$(row "$SH_SRC" "$_i")"
  _tf="$(row "$SH_TF" "$_i")"
  assert_eq "--sources ${SHAPE_Q[$_i]} languages=$(col "$_src" 9)" "--sources ${SHAPE_Q[$_i]} languages=$_lang"
  assert_eq "--test-file ${SHAPE_TF[$_i]} languages=$(col "$_tf" 9)" "--test-file ${SHAPE_TF[$_i]} languages=$_lang"
  if [ -z "$_want" ]; then
    fail "${SHAPE_Q[$_i]} shapes" "no single shape for one of [$_lang] to compare with"
    continue
  fi
  assert_eq "--sources ${SHAPE_Q[$_i]} shapes=$(col "$_src" 10)" "--sources ${SHAPE_Q[$_i]} shapes=$_want"
  assert_eq "--test-file ${SHAPE_TF[$_i]} shapes=$(col "$_tf" 10)" "--test-file ${SHAPE_TF[$_i]} shapes=$_want"
done
if [ "$_mixed" -ge 4 ]; then
  pass "queries of several languages checked ($_mixed)"
else
  fail "queries of several languages" "only $_mixed in SHAPE_LANG"
fi
case_end
