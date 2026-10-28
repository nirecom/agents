# bin/check-self-impl.sh --head <HEAD copy>: only a (kind, detail) key HEAD lacks is reported, for
# every language with a self-impl op (#2502 S3). Sourced by tests/bin/feature-2502-check-self-impl.sh;
# the bodies are in bodies-head.sh. A language whose runtime is not installed answers the
# SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE WARN, so its HIGH rows expect that WARN instead.
# shellcheck shell=bash

echo ""
echo "=== cli: bin/check-self-impl.sh --head ==="

REPO_HEAD="$TMPBASE/repo-head"
mkrepo "$REPO_HEAD"
HEAD_COPIES="$TMPBASE/head-copies"
mkdir -p "$HEAD_COPIES"
HEAD_LANGS=(bash pytest pester js)

# head_lang <id> — HL_B body prefix, HL_REL the test path, HL_RT the runtime (empty: always there),
# HL_FAIL / HL_REDEF the detail of the added counter / redefinition and HL_ADD_LINE their line,
# HL_CTR / HL_CTR_LINE the detail and line of the -ctr counter, HL_LEX 1 when the op is lexical
# (it reads a syntax error through instead of failing).
head_lang() {
  case "$1" in
    bash) HL_B=sh; HL_REL=tests/bin/head.sh; HL_RT=""; HL_FAIL="FAIL=0"; HL_REDEF=harness_isolate
      HL_ADD_LINE=6; HL_CTR="PASS=0"; HL_CTR_LINE=5; HL_LEX=1 ;;
    pytest) HL_B=py; HL_REL=tests/bin/test_head.py; HL_RT=uv; HL_FAIL="failed=0"; HL_REDEF=isolate
      HL_ADD_LINE=10; HL_CTR="passed=0"; HL_CTR_LINE=9; HL_LEX=0 ;;
    pester) HL_B=ps1; HL_REL=tests/bin/head.Tests.ps1; HL_RT=pwsh; HL_FAIL="Failed=0"
      HL_REDEF=Enter-HarnessIsolation; HL_ADD_LINE=7; HL_CTR="Passed=0"; HL_CTR_LINE=6; HL_LEX=0 ;;
    js) HL_B=js; HL_REL=tests/bin/head.js; HL_RT=""; HL_FAIL="FAIL=0"; HL_REDEF=isolate
      HL_ADD_LINE=5; HL_CTR="PASS=0"; HL_CTR_LINE=4; HL_LEX=1 ;;
  esac
  HL_HAS_RT=1
  if [ -n "$HL_RT" ] && ! command -v "$HL_RT" >/dev/null 2>&1; then HL_HAS_RT=0; fi
}

# hl_high <line> <kind> <detail> — the HIGH line the CLI prints for HL_REL.
hl_high() {
  printf '%s' "HIGH: $HL_REL line $1: self-implemented harness ($2 $3) code=SELF_IMPLEMENTED_HARNESS"
}

# head_si <head-body|-> <work-body> — the CLI on HL_REL holding <work-body>, with --head on a copy of
# <head-body> ("-": no --head).
head_si() {
  put "$REPO_HEAD" "$HL_REL" "$2"
  if [ "$1" = "-" ]; then
    si "$REPO_HEAD" "$HL_REL"
  else
    cp "$BODIES/$1" "$HEAD_COPIES/${HL_REL##*/}"
    si "$REPO_HEAD" --head "$HEAD_COPIES/${HL_REL##*/}" "$HL_REL"
  fi
}

# head_row <label> <head-body|-> <work-body> <want> — <want> is the whole stdout of a HIGH verdict
# (rc 1), or empty for no HIGH (rc 0, no output). Without the runtime a HIGH verdict is the WARN.
head_row() {
  head_si "$2" "$3"
  if [ "$HL_HAS_RT" -ne 1 ]; then
    expect_rc "$1 (no $HL_RT)" 0 "$SI_RC" "$SI_OUT $SI_ERR"
    lacks "$1 (no $HL_RT)" "$SI_OUT" "code=SELF_IMPLEMENTED_HARNESS"
    [ -z "$4" ] || has "$1 (no $HL_RT)" "$SI_OUT" "WARN: $HL_REL: harness self-implementation not checked ($HL_RT is not installed) code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"
    return 0
  fi
  if [ -z "$4" ]; then
    expect_rc "$1" 0 "$SI_RC" "$SI_OUT $SI_ERR"
    assert_eq "$1: stdout=[$SI_OUT]" "$1: stdout=[]"
  else
    expect_rc "$1" 1 "$SI_RC" "$SI_OUT $SI_ERR"
    assert_eq "$1: stdout=[$SI_OUT]" "$1: stdout=[$4]"
  fi
}

case_begin "si-head-no-self-impl-either-passes" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  head_row "$_lang clean -> clean edited" "$HL_B-h-clean" "$HL_B-h-clean2" ""
done
case_end

case_begin "si-head-kept-counter-other-edit-passes" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  head_row "$_lang HEAD counter kept, another line edited" "$HL_B-h-ctr" "$HL_B-h-ctr2" ""
done
case_end

case_begin "si-head-kept-counter-line-shift-passes" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  head_row "$_lang HEAD counter moved down by a new function" "$HL_B-h-ctr" "$HL_B-h-shift" ""
done
case_end

case_begin "si-head-added-counter-blocks" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  head_row "$_lang second counter added" "$HL_B-h-ctr" "$HL_B-h-fail" "$(hl_high "$HL_ADD_LINE" counter-init "$HL_FAIL")"
done
case_end

case_begin "si-head-added-redef-blocks" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  head_row "$_lang helper redefinition added" "$HL_B-h-ctr" "$HL_B-h-redef" "$(hl_high "$HL_ADD_LINE" harness-redef "$HL_REDEF")"
done
case_end

case_begin "si-head-removed-self-impl-passes" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  head_row "$_lang HEAD counter removed" "$HL_B-h-ctr" "$HL_B-h-clean" ""
done
case_end

# A HEAD copy the op cannot analyse (pytest, pester) counts as an empty set, so even the counter it
# holds is reported. The bash and js ops are lexical and read a syntax error through: there a
# syntax-error HEAD without the counter reports it, and one with the counter keeps it.
case_begin "si-head-unparsable-head-blocks" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  _want="$(hl_high "$HL_CTR_LINE" counter-init "$HL_CTR")"
  if [ "$HL_LEX" -eq 1 ]; then
    head_row "$_lang syntax-error HEAD without the counter" "$HL_B-h-synclean" "$HL_B-h-ctr" "$_want"
    head_row "$_lang syntax-error HEAD with the counter" "$HL_B-h-synctr" "$HL_B-h-ctr" ""
  else
    head_row "$_lang unparsable HEAD with the counter" "$HL_B-h-synctr" "$HL_B-h-ctr" "$_want"
    [ "$HL_HAS_RT" -ne 1 ] || lacks "$_lang unparsable HEAD: no temp path" "$SI_OUT" "$HEAD_COPIES"
  fi
done
case_end

case_begin "si-head-absent-reports-all" "bin/check-self-impl.sh"
for _lang in "${HEAD_LANGS[@]}"; do
  head_lang "$_lang"
  head_row "$_lang no --head" - "$HL_B-h-ctr" "$(hl_high "$HL_CTR_LINE" counter-init "$HL_CTR")"
done
case_end

# The bash golden sample (tests/bin/bin-case-record-reader/fixtures.sh self-impl): three detections,
# all of them HEAD's own when HEAD holds the same content.
case_begin "si-head-bash-golden-sample-unchanged-passes" "bin/check-self-impl.sh"
_fxd="$TMPBASE/crr-fixtures"
mkdir -p "$_fxd"
( FXD="$_fxd"; . "$SCRIPT_CHECKOUT_ROOT/tests/bin/bin-case-record-reader/fixtures.sh" ) >/dev/null 2>&1
if [ ! -f "$_fxd/self-impl.sh" ]; then
  fail "bash golden sample" "fixtures.sh wrote no self-impl.sh"
else
  head_lang bash
  cp "$_fxd/self-impl.sh" "$BODIES/sh-golden"
  { cat "$_fxd/self-impl.sh"; echo 'echo unrelated'; } > "$BODIES/sh-golden-edited"
  head_si - sh-golden
  expect_rc "golden sample without --head" 1 "$SI_RC" "$SI_OUT $SI_ERR"
  _n="$(printf '%s\n' "$SI_OUT" | grep -c 'code=SELF_IMPLEMENTED_HARNESS')"
  assert_eq "golden sample detections=$_n" "golden sample detections=3"
  head_row "golden sample, HEAD identical" sh-golden sh-golden ""
  head_row "golden sample, HEAD identical but an unrelated line added" sh-golden sh-golden-edited ""
fi
case_end

# head_no_rt <label> <lang> — the --head HIGH row with the runtime taken off PATH: the WARN only.
head_no_rt() {
  head_lang "$2"
  SI_PATH="$(no_runtime_path "$HL_RT")"
  if [ -z "$SI_PATH" ]; then
    skip "$1: could not build a PATH without $HL_RT"
  else
    head_si "$HL_B-h-ctr" "$HL_B-h-fail"
    expect_rc "$1" 0 "$SI_RC" "$SI_OUT $SI_ERR"
    assert_eq "$SI_OUT" "WARN: $HL_REL: harness self-implementation not checked ($HL_RT is not installed) code=SELF_IMPL_CHECK_RUNTIME_UNAVAILABLE"
  fi
  SI_PATH=""
}

case_begin "si-head-pester-runtime-unavailable-warns" "bin/check-self-impl.sh"
head_no_rt "pester --head without pwsh" pester
case_end

case_begin "si-head-pytest-runtime-unavailable-warns" "bin/check-self-impl.sh"
head_no_rt "pytest --head without uv" pytest
case_end

case_begin "si-head-missing-copy-exit-2" "bin/check-self-impl.sh"
head_lang bash
put "$REPO_HEAD" "$HL_REL" sh-h-ctr
si "$REPO_HEAD" --head "$HEAD_COPIES/no-such-copy.sh" "$HL_REL"
expect_rc "--head copy missing" 2 "$SI_RC" "$SI_OUT $SI_ERR"
lacks "--head copy missing" "$SI_OUT" "code=SELF_IMPLEMENTED_HARNESS"
case_end

# Each HEAD detection cancels at most one working detection with the same (kind, detail) key.
# hl_count_row <label> <head-body> <work-body> <want-highs> — bash only: the subtraction is in the CLI.
hl_count_row() {
  head_lang bash
  head_si "$2" "$3"
  local n
  n="$(printf '%s\n' "$SI_OUT" | grep -c 'code=SELF_IMPLEMENTED_HARNESS')"
  assert_eq "$1: HIGH lines=$n" "$1: HIGH lines=$4"
  if [ "$4" -eq 0 ]; then expect_rc "$1" 0 "$SI_RC" "$SI_OUT $SI_ERR"; else expect_rc "$1" 1 "$SI_RC" "$SI_OUT $SI_ERR"; fi
}

case_begin "si-head-duplicate-counter-blocks" "bin/check-self-impl.sh"
hl_count_row "HEAD 1 PASS=0, working 2" sh-h-ctr sh-h-dup 1
has "HEAD 1 PASS=0, working 2: names the counter" "$SI_OUT" "self-implemented harness (counter-init PASS=0)"
case_end

case_begin "si-head-same-count-passes" "bin/check-self-impl.sh"
hl_count_row "HEAD 2 PASS=0, working 2 with another line edited" sh-h-dup sh-h-dup2 0
hl_count_row "HEAD 2 PASS=0, working 1" sh-h-dup sh-h-ctr2 0
case_end

case_begin "si-head-count-filters-by-key" "bin/check-self-impl.sh"
head_lang bash
head_row "HEAD PASS=0, working PASS=0 and FAIL=0" sh-h-ctr sh-h-fail "$(hl_high 6 counter-init FAIL=0)"
head_row "HEAD PASS=0 twice, working PASS=0 twice and FAIL=0" sh-h-dup sh-h-dupfail "$(hl_high 7 counter-init FAIL=0)"
case_end

echo ""
echo "=== cli: bin/check-self-impl.sh --manifest ==="

MF_DIR="$TMPBASE/manifest"
mkdir -p "$MF_DIR"

# mf_copy <slot> <rel> <body> — prints the path of a copy of <body> under <slot>, named after <rel>.
mf_copy() {
  local p="$MF_DIR/$1/$2"
  mkdir -p "$(dirname "$p")"
  cp "$BODIES/$3" "$p"
  printf '%s' "$p"
}

_mf_ok="$(mf_copy w tests/bin/mf-ok.sh sh-h-clean)"
printf 'tests/bin/mf-ok.sh\t%s\t\n' "$_mf_ok" > "$MF_DIR/ok.manifest"
printf 'tests/bin/mf-ok.sh\t\t\n' > "$MF_DIR/nocopy.manifest"
printf 'tests/bin/mf-ok.sh\t%s\t\n' "$MF_DIR/w/no-such.sh" > "$MF_DIR/nofile.manifest"
printf 'tests/bin/mf-ok.sh\t%s\t%s\n' "$_mf_ok" "$MF_DIR/h/no-such.sh" > "$MF_DIR/nohead.manifest"

# Every row exits 2 with its diagnostic on stderr and prints no verdict line. @MFDIR is MF_DIR.
case_begin "si-manifest-usage-and-missing-exit-2" "bin/check-self-impl.sh"
while IFS='|' read -r _name _args _want; do
  [[ -z "$_name" || "$_name" =~ ^[[:space:]]*# ]] && continue
  _name="${_name//[[:space:]]/}"
  _want="${_want#"${_want%%[![:space:]]*}"}"
  _want="${_want//@MFDIR/$MF_DIR}"
  read -r -a _argv <<<"$_args"
  _argv=("${_argv[@]//@MFDIR/$MF_DIR}")
  si "$REPO_HEAD" "${_argv[@]}"
  expect_rc "$_name" 2 "$SI_RC" "$SI_OUT $SI_ERR"
  has "$_name" "$SI_ERR" "$_want"
  assert_eq "$_name: stdout=[$SI_OUT]" "$_name: stdout=[]"
done <<'TABLE'
manifest-missing   | --manifest @MFDIR/absent.manifest                                   | file not found: @MFDIR/absent.manifest
manifest-no-value  | --manifest                                                        | --manifest needs a value
copy-field-empty   | --manifest @MFDIR/nocopy.manifest                                   | malformed manifest line: tests/bin/mf-ok.sh
copy-missing       | --manifest @MFDIR/nofile.manifest                                   | file not found: @MFDIR/w/no-such.sh
head-copy-missing  | --manifest @MFDIR/nohead.manifest                                   | file not found: @MFDIR/h/no-such.sh
with-rel           | --manifest @MFDIR/ok.manifest --rel tests/bin/mf-ok.sh              | --manifest takes no --rel, --head or file
rel-before         | --rel tests/bin/mf-ok.sh --manifest @MFDIR/ok.manifest              | --manifest takes no --rel, --head or file
with-head          | --manifest @MFDIR/ok.manifest --head @MFDIR/w/tests/bin/mf-ok.sh      | --manifest takes no --rel, --head or file
with-file          | --manifest @MFDIR/ok.manifest @MFDIR/w/tests/bin/mf-ok.sh             | --manifest takes no --rel, --head or file
TABLE
si "$REPO_HEAD" --manifest "$MF_DIR/ok.manifest"
expect_rc "the same clean manifest alone" 0 "$SI_RC" "$SI_OUT $SI_ERR"
case_end

# One manifest run prints exactly what the equivalent single-file runs print, in manifest order.
# The new file after a --head entry keeps its counter, which HEAD keys leaked from that entry would hide.
case_begin "si-manifest-matches-single-file-runs" "bin/check-self-impl.sh"
_mf_want=""
_mf_want_rc=0
: > "$MF_DIR/batch.manifest"
while IFS='|' read -r _rel _work _hb; do
  [[ -z "$_rel" || "$_rel" =~ ^[[:space:]]*# ]] && continue
  _rel="${_rel//[[:space:]]/}"; _work="${_work//[[:space:]]/}"; _hb="${_hb//[[:space:]]/}"
  _w="$(mf_copy w "$_rel" "$_work")"
  _h=""
  [ "$_hb" = "-" ] || _h="$(mf_copy h "$_rel" "$_hb")"
  printf '%s\t%s\t%s\n' "$_rel" "$_w" "$_h" >> "$MF_DIR/batch.manifest"
  si "$REPO_HEAD" --rel "$_rel" ${_h:+--head "$_h"} "$_w"
  [ -z "$SI_OUT" ] || _mf_want+="$SI_OUT"$'\n'
  [ "$SI_RC" -le "$_mf_want_rc" ] || _mf_want_rc="$SI_RC"
done <<'TABLE'
tests/bin/mf-added.sh | sh-h-fail   | sh-h-ctr
tests/bin/mf-new.sh   | sh-h-ctr    | -
tests/bin/mf-clean.sh | sh-h-clean  | -
tests/bin/mf-debt.sh  | sh-h-ctr2   | sh-h-ctr
tests/bin/mf-same.sh  | sh-h-ctr    | sh-h-ctr
tests/bin/mf-added.js | js-h-fail   | js-h-ctr
TABLE
_mf_want="${_mf_want%$'\n'}"
expect_rc "single-file runs" 1 "$_mf_want_rc" "$_mf_want"
has "single-file runs" "$_mf_want" "HIGH: tests/bin/mf-added.sh line 6: self-implemented harness (counter-init FAIL=0)"
has "single-file runs" "$_mf_want" "HIGH: tests/bin/mf-new.sh line 5: self-implemented harness (counter-init PASS=0)"
has "single-file runs" "$_mf_want" "HIGH: tests/bin/mf-added.js line 5: self-implemented harness (counter-init FAIL=0)"
lacks "single-file runs" "$_mf_want" "mf-debt.sh"
si "$REPO_HEAD" --manifest "$MF_DIR/batch.manifest"
expect_rc "manifest run" "$_mf_want_rc" "$SI_RC" "$SI_OUT $SI_ERR"
assert_eq "manifest stdout=[$SI_OUT]" "manifest stdout=[$_mf_want]"
case_end

# HEAD counts stay per entry, in either order: the duplicate entry (HEAD 1, working 2) blocks, and
# neither the same-count entry (2, 2) nor the spare HEAD count of mf-dupless.sh (2, 1) cancels it.
case_begin "si-manifest-head-counts-per-entry" "bin/check-self-impl.sh"
: > "$MF_DIR/dup-first.manifest"
while read -r _rel _work _hb; do
  printf '%s\t%s\t%s\n' "$_rel" "$(mf_copy w "$_rel" "$_work")" "$(mf_copy h "$_rel" "$_hb")" >> "$MF_DIR/dup-first.manifest"
done <<'TABLE'
tests/bin/mf-dup.sh      sh-h-dup   sh-h-ctr
tests/bin/mf-dupsame.sh  sh-h-dup2  sh-h-dup
tests/bin/mf-dupless.sh  sh-h-ctr2  sh-h-dup
TABLE
tac "$MF_DIR/dup-first.manifest" > "$MF_DIR/dup-last.manifest"
for _mf_order in dup-first dup-last; do
  si "$REPO_HEAD" --manifest "$MF_DIR/$_mf_order.manifest"
  expect_rc "$_mf_order manifest" 1 "$SI_RC" "$SI_OUT $SI_ERR"
  _n="$(printf '%s\n' "$SI_OUT" | grep -c 'code=SELF_IMPLEMENTED_HARNESS')"
  assert_eq "$_mf_order manifest: HIGH lines=$_n" "$_mf_order manifest: HIGH lines=1"
  has "$_mf_order manifest" "$SI_OUT" "HIGH: tests/bin/mf-dup.sh line"
  lacks "$_mf_order manifest" "$SI_OUT" "mf-dupsame.sh"
  lacks "$_mf_order manifest" "$SI_OUT" "mf-dupless.sh"
done
case_end
