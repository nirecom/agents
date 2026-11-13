#!/usr/bin/env bash
# tests/tests/feature-2956-case-details.sh
# Tests: tests/lib/harness-detail.sh, tests/lib/harness.sh
# Tags: scope:issue-specific, run-all, result-dir, fail-details, tl2
# #2956 S3/S5: the bash harness writes one fail-details.tsv record (<seq>\t<case>\t<text>) per
# fail() call, folds $2 by the contract rule (checked against tests/fixtures/fail-detail-fold.tsv),
# records a fail outside any case as seq 0 / case "-", and harness-detail.sh offers the list and
# count markers harness_list_detail / harness_count_detail.
set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/fail-detail-fold.sh"

T="$(make_tmp)"
readonly T
trap 'rm -rf "$T"' EXIT
fold_load

# The child is the file run-all would launch: it owns the result dir, so its harness records.
cat >"$T/child.sh" <<'EOF'
#!/usr/bin/env bash
set -u
. "$1"
. "$2"
fold_load
fail "outside-before" "before any case"
for i in "${!FOLD_INPUTS[@]}"; do
  case_begin "fold-row-$i-end" "tests/lib/harness-detail.sh"
  fail "fold" "${FOLD_INPUTS[$i]}"
  case_end
done
case_begin "two-fails" "tests/lib/harness-detail.sh"
fail "first" "detail one"
fail "second" "detail two"
case_end
case_begin "pass-only" "tests/lib/harness-detail.sh"
pass "fine"
case_end
case_begin "no-detail" "tests/lib/harness-detail.sh"
fail "bare"
case_end
fail "outside-after" "after the cases"
exit 0
EOF

# run_child <resdir> <owner> — launch the child with a result dir owned by <owner>.
run_child() {
  mkdir -p "$1"
  env RUN_ALL_RESULT_DIR="$1" RUN_ALL_RESULT_OWNER="$2" bash "$T/child.sh" \
    "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh" "$SCRIPT_CHECKOUT_ROOT/tests/lib/fail-detail-fold.sh" >"$1.out" 2>&1 </dev/null
}

run_child "$T/r-own" "$T/child.sh"
DT="$T/r-own/fail-details.tsv"
CT="$T/r-own/cases.tsv"

# fd_lines <case> — the fail-details.tsv records of that case, verbatim.
fd_lines() {
  [ -f "$DT" ] && awk -F'\t' -v c="$1" '$2==c' "$DT"
}

case_begin "fold-fixture-rows-match" "tests/lib/harness-detail.sh"
fold_check_records "$DT" "fold-row-" "-end"
case_end

case_begin "one-record-per-fail-call" "tests/lib/harness-detail.sh"
got="$(fd_lines two-fails)"
seq_two="$( [ -f "$CT" ] && awk -F'\t' '$3=="two-fails"{print $1; exit}' "$CT")"
want="$(printf '%s\t%s\t%s\n%s\t%s\t%s' "$seq_two" two-fails "detail one" "$seq_two" two-fails "detail two")"
if [ -n "$seq_two" ] && [ "$got" = "$want" ]; then
  pass "two fail() calls in one case -> two records with the case's seq"
else
  fail "two fail() calls in one case -> two records" "seq=$seq_two got=$(printf '%q' "$got")"
fi
case_end

case_begin "record-seq-matches-cases-tsv" "tests/lib/harness-detail.sh"
bad="$( [ -f "$DT" ] && [ -f "$CT" ] && awk -F'\t' 'NR==FNR{s[$3]=$1; next} $2!="-" && s[$2]!=$1{print $2}' "$CT" "$DT")"
if [ -f "$DT" ] && [ -z "$bad" ]; then pass "every in-case record carries its case's seq"; else fail "record seq differs from cases.tsv" "${bad:-no fail-details.tsv}"; fi
case_end

case_begin "fail-outside-case-is-seq-0-dash" "tests/lib/harness-detail.sh"
got="$(fd_lines -)"
want="$(printf '0\t-\tbefore any case\n0\t-\tafter the cases')"
if [ "$got" = "$want" ]; then pass "fails before and after the cases -> seq 0, case -"; else fail "outside-case records" "got=$(printf '%q' "$got")"; fi
case_end

case_begin "pass-only-case-writes-no-record" "tests/lib/harness-detail.sh"
if [ -f "$DT" ] && [ -z "$(fd_lines pass-only)" ]; then pass "no record for a passing case"; else fail "pass-only case" "file=$([ -f "$DT" ] && echo yes || echo no) lines=$(fd_lines pass-only)"; fi
case_end

case_begin "fail-stdout-unchanged" "tests/lib/harness.sh"
out="$(cat "$T/r-own.out")"
if [[ "$out" == *"FAIL: first — detail one"* && "$out" == *"FAIL: bare"* ]]; then pass "fail() still prints FAIL: <name> — <detail>"; else fail "fail() stdout changed" "$out"; fi
case_end

case_begin "no-record-without-owned-result-dir" "tests/lib/harness.sh"
run_child "$T/r-foreign" "$T/not-the-child.sh"
if [ ! -e "$T/r-foreign/fail-details.tsv" ] && [ ! -e "$T/r-foreign/cases.tsv" ]; then
  pass "a result dir owned by another file gets no records"
else
  fail "foreign result dir written"
fi
case_end

case_begin "detail-helpers-defined" "tests/lib/harness-detail.sh"
if declare -F harness_list_detail >/dev/null && declare -F harness_count_detail >/dev/null; then
  pass "harness.sh loads harness_list_detail and harness_count_detail"
else
  fail "detail helpers not defined after sourcing tests/lib/harness.sh"
fi
case_end

case_begin "count-detail-shape" "tests/lib/harness-detail.sh"
assert_eq "$(harness_count_detail 3 2>&1)" "[count=3]"
assert_eq "$(harness_count_detail 0 2>&1)" "[count=0]"
case_end

case_begin "list-detail-shape" "tests/lib/harness-detail.sh"
assert_eq "$(harness_list_detail 2 alpha beta 2>&1)" "[list total=2: alpha | beta]"
assert_eq "$(harness_list_detail 1 only 2>&1)" "[list total=1: only]"
# Fewer items than the total keeps the shape; the comparer reads it as a cut list.
assert_eq "$(harness_list_detail 5 a b 2>&1)" "[list total=5: a | b]"
case_end

case_begin "list-detail-escapes-items" "tests/lib/harness-detail.sh"
assert_eq "$(harness_list_detail 2 'p\q|r]s' 'x y' 2>&1)" '[list total=2: p\\q\|r\]s | x y]'
case_end

echo "Results: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
[ "$FAIL" -eq 0 ]
