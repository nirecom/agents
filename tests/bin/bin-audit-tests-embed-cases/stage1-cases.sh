# Tests: bin/lib/test-embed-cases/stage-plan.sh
# Tags: TL2, scope:common, audit-tests, embed-cases, stage-protocol, stage-1
# Sourced by tests/bin/bin-audit-tests-embed-cases.sh — stage 1 (plan): workdir
# location, worklist.tsv columns and initial values, items/<idx>/ layout, the
# EMBED-GATE-STE4 gate block, and the header fix applied to the copy only.

S1_REPO="$(ec_make_repo)"
ec_add_test "$S1_REPO" tests/bin/t-fixable.sh "bin/alpha.sh (annotation)"
ec_add_test "$S1_REPO" tests/bin/t-clean.sh "bin/bravo.sh"
ec_commit "$S1_REPO" init
S1_FIXABLE_BEFORE="$(git -C "$S1_REPO" hash-object tests/bin/t-fixable.sh)"
S1_CLEAN_BEFORE="$(git -C "$S1_REPO" hash-object tests/bin/t-clean.sh)"
ec_stage1 "$S1_REPO" "$AUDIT" --band-size 5
S1_OUT="$OUT"
S1_DIAG="rc=$RC err=${ERR:0:200}"
S1_PLANS_ROOT="$WORKFLOW_PLANS_DIR/sweep-tests-embed/"

case_begin "stage1-workdir-location" "bin/lib/test-embed-cases/stage-plan.sh"
check_eq "S1-1 stage 1 exits 0 ($S1_DIAG)" "0" "$RC"
if [[ -n "$EC_WORKDIR" && "$EC_WORKDIR" == "$S1_PLANS_ROOT"* && -d "$EC_WORKDIR" ]]; then
  pass "S1-1 EMBED_WORKDIR is a directory under <plans>/sweep-tests-embed/"
else
  fail "S1-1 EMBED_WORKDIR is a directory under <plans>/sweep-tests-embed/" "workdir='$EC_WORKDIR' root='$S1_PLANS_ROOT' $S1_DIAG"
fi
case_end

case_begin "stage1-worklist-columns" "bin/lib/test-embed-cases/stage-plan.sh"
if [[ -f "$EC_WORKDIR/worklist.tsv" ]]; then pass "S1-2 worklist.tsv exists"; else fail "S1-2 worklist.tsv exists" "workdir='$EC_WORKDIR'"; fi
_s1_rows="$(awk -F'\t' '$2 ~ /^tests\// { print }' "$EC_WORKDIR/worklist.tsv" 2>/dev/null)"
check_eq "S1-2 one item row per band member" "2" "$(printf '%s\n' "$_s1_rows" | grep -c .)"
check_eq "S1-2 every item row has 9 columns" "" "$(printf '%s\n' "$_s1_rows" | awk -F'\t' 'NF != 9 { print }')"
for _rel in tests/bin/t-fixable.sh tests/bin/t-clean.sh; do
  check_eq "S1-3 $_rel starts pending" "pending" "$(ec_wl_field "$_rel" 8)"
  check_eq "S1-3 $_rel starts with 0 attempts" "0" "$(ec_wl_field "$_rel" 9)"
  check_eq "S1-3 $_rel rules_doc is the bash embed rules" "skills/sweep-tests/embed-rules/bash.md" "$(ec_wl_field "$_rel" 5)"
done
check_eq "S1-4 orig_hash is the original's git hash-object" "$S1_FIXABLE_BEFORE" "$(ec_wl_field tests/bin/t-fixable.sh 7)"
check_eq "S1-4 orig_hash of the clean file" "$S1_CLEAN_BEFORE" "$(ec_wl_field tests/bin/t-clean.sh 7)"
check_eq "S1-5 header_status is applied for a fixable header" "applied" "$(ec_wl_field tests/bin/t-fixable.sh 6)"
check_eq "S1-5 header_status is clean for a correct header" "clean" "$(ec_wl_field tests/bin/t-clean.sh 6)"
case_end

case_begin "stage1-items-layout" "bin/lib/test-embed-cases/stage-plan.sh"
for _rel in tests/bin/t-fixable.sh tests/bin/t-clean.sh; do
  _idx="$(ec_wl_field "$_rel" 1)"
  _item="$EC_WORKDIR/items/$_idx"
  _base="$(basename "$_rel")"
  if [[ -n "$_idx" && -f "$_item/input/$_base" ]]; then pass "S1-6 $_rel input copy at items/<idx>/input/<basename>"; else fail "S1-6 $_rel input copy at items/<idx>/input/<basename>" "idx='$_idx'"; fi
  if [[ -n "$_idx" && -d "$_item/output" && -z "$(ls -A "$_item/output" 2>/dev/null)" ]]; then pass "S1-6 $_rel output/ exists and is empty"; else fail "S1-6 $_rel output/ exists and is empty" "idx='$_idx'"; fi
  if [[ -n "$_idx" && -d "$_item/backup" && -z "$(ls -A "$_item/backup" 2>/dev/null)" ]]; then pass "S1-6 $_rel backup/ exists and is empty"; else fail "S1-6 $_rel backup/ exists and is empty" "idx='$_idx'"; fi
  check_eq "S1-6 $_rel input column points at the copy" "$_item/input/$_base" "$(ec_abs "$(ec_wl_field "$_rel" 3)")"
done
case_end

case_begin "stage1-header-fixed-on-copy-only" "bin/lib/test-embed-cases/stage-plan.sh"
_idx="$(ec_wl_field tests/bin/t-fixable.sh 1)"
_copy="$EC_WORKDIR/items/$_idx/input/t-fixable.sh"
check_eq "S1-7 the input copy carries the fixed header" "# Tests: bin/alpha.sh" "$(grep -m1 '^# Tests:' "$_copy" 2>/dev/null)"
check_eq "S1-7 the original file is untouched by stage 1" "$S1_FIXABLE_BEFORE" "$(git -C "$S1_REPO" hash-object tests/bin/t-fixable.sh)"
check_eq "S1-7 stage 1 leaves the repo clean" "" "$(git -C "$S1_REPO" status --porcelain)"
_cidx="$(ec_wl_field tests/bin/t-clean.sh 1)"
if [[ -n "$_cidx" ]] && cmp -s "$S1_REPO/tests/bin/t-clean.sh" "$EC_WORKDIR/items/$_cidx/input/t-clean.sh"; then
  pass "S1-7 a clean header's copy is byte-identical to the original"
else
  fail "S1-7 a clean header's copy is byte-identical to the original" "idx='$_cidx'"
fi
case_end

case_begin "stage1-gate-block" "bin/lib/test-embed-cases/stage-plan.sh"
_gate="$(printf '%s\n' "$S1_OUT" | sed -n '/^<<<EMBED-GATE-STE4/,/^>>>/p')"
if [[ -n "$_gate" ]]; then pass "S1-8 stdout carries a <<<EMBED-GATE-STE4 ... >>> block"; else fail "S1-8 stdout carries a <<<EMBED-GATE-STE4 ... >>> block" "out=${S1_OUT:0:300}"; fi
_items="$(printf '%s\n' "$_gate" | awk -F'\t' '$1 == "ITEM"')"
check_eq "S1-8 one ITEM row per worklist item" "2" "$(printf '%s\n' "$_items" | grep -c .)"
check_eq "S1-8 every ITEM row has 6 fields" "" "$(printf '%s\n' "$_items" | awk -F'\t' 'NF != 6 { print }')"
_fidx="$(ec_wl_field tests/bin/t-fixable.sh 1)"
_frow="$(printf '%s\n' "$_items" | awk -F'\t' -v i="$_fidx" '$2 == i')"
check_eq "S1-8 ITEM input matches the worklist input" "$(ec_abs "$(ec_wl_field tests/bin/t-fixable.sh 3)")" "$(ec_abs "$(printf '%s' "$_frow" | cut -f3)")"
check_eq "S1-8 ITEM rules_doc matches the worklist rules_doc" "skills/sweep-tests/embed-rules/bash.md" "$(printf '%s' "$_frow" | cut -f5)"
check_eq "S1-8 ITEM report is items/<idx>/report.txt" "$EC_WORKDIR/items/$_fidx/report.txt" "$(ec_abs "$(printf '%s' "$_frow" | cut -f6)")"
case_end

case_begin "stage1-fix-headers-flag-accepted" "bin/lib/test-embed-cases/stage-plan.sh"
ec_stage1 "$S1_REPO" "$AUDIT" --band-size 5 --fix-headers
if [[ "$RC" -eq 0 && -n "$EC_WORKDIR" ]]; then pass "S1-9 --embed-cases --fix-headers plans a workdir"; else fail "S1-9 --embed-cases --fix-headers plans a workdir" "rc=$RC err=${ERR:0:200}"; fi
check_eq "S1-9 --fix-headers with --embed-cases still leaves the original untouched" "$S1_FIXABLE_BEFORE" "$(git -C "$S1_REPO" hash-object tests/bin/t-fixable.sh)"
case_end

grp_done stage1-cases.sh
