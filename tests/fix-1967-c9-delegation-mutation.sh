#!/usr/bin/env bash
# tests/fix-1967-c9-delegation-mutation.sh
# Tests: tests/feature-confirm-flags-static.sh, tests/install-path-exposed-commands.sh
# Tags: mutation-test, meta-test, static, delegation, xfail-ledger, scope:issue-specific, pwsh-not-required, TL2

# THE THING UNDER TEST is section 9 of tests/feature-confirm-flags-static.sh -- the checks
# C9-a..C9-h that stand in for the `get-config-var` PATH-exposure contract instead
# of re-asserting it. Section 9 does not run the owner test (348-460 s); it greps it for
# the delegate's definition, its presence on the run list, its body, its negative control's
# run-list line and DEFINITION, and for a still-executable assertion inside the body. Those
# greps are the ONLY thing standing between a silently deleted T8 and a green tree, which
# is precisely the failure mode #1967 was.

# AND the owner test's own executed-row budget (t8c_row_budget). Section 9 is made of
# GREPS, and a grep cannot see a table-driven test whose table went empty or whose loop
# became unreachable: every string it matches is still on the page while zero assertions
# run. The M5 group below is the answer -- it EXECUTES the owner's T8/T8b/T8c predicates,
# extracted from the mutated copy, without paying for the 348-460 s the whole owner test
# costs (that cost is its top-level DERIVED scan, not these three functions).

# WHY A SEPARATE FILE. In a healthy tree all six checks pass on every run, so an
# assertion that only ever sees green cannot tell a live grep from one that matches a
# comment, from one that would keep passing over a dead T8 body. Here each of the four is
# driven RED on purpose by mutating a COPY of the owner test.

# NO PREDICATE IS TRANSCRIBED HERE (CPR-SSOT). The C9 greps stay defined in
# feature-confirm-flags-static.sh and only there; this file re-runs that same file with
# OWNER_TEST_OVERRIDE pointed at the mutated copy and reads its verdict lines. A change to
# a C9 predicate therefore cannot drift away from what is asserted below.

# NOTHING IN THE REPOSITORY IS MUTATED, and the owner test is never EXECUTED -- only
# copied and grepped. Runtime is one round of the static subject (~7 s), because the nine
# mutated runs are launched concurrently and only then read back -- see run_cases().

# TL3 gap (what this test does NOT catch):
# - Whether the commands the list names actually reach PATH after a real installer run:
#   every route here reads text or runs extracted functions, never an installer.
# - Whether the owner test PASSES end to end on a real host -- its 348-460 s top-level
#   DERIVED scan is deliberately never executed here, only T8/T8b/T8c are.
# - Whether awk/grep/comm behave identically on a host with a different toolchain
#   (BSD userland, busybox); every mutator above is written against GNU behaviour.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: installer.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$AGENTS_DIR/tests/feature-confirm-flags-static.sh"
OWNER="$AGENTS_DIR/tests/install-path-exposed-commands.sh"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}

finish() {
  echo ""
  echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
  exit "$FAIL"
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fix-1967-c9-mutation.XXXXXX")" || {
  echo "FATAL: mktemp -d failed" >&2
  exit 2
}
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$SUBJECT" ]; then
  fail "M0: the subject tests/feature-confirm-flags-static.sh exists"
  finish
fi
if [ ! -f "$OWNER" ]; then
  fail "M0: the owner test tests/install-path-exposed-commands.sh exists"
  finish
fi

# The seam itself. If feature-confirm-flags-static.sh stopped honouring
# OWNER_TEST_OVERRIDE, every mutation below would silently be applied to a copy nobody
# reads and all four checks would report PASS for the wrong reason.
if grep -q 'OWNER_TEST_OVERRIDE' "$SUBJECT"; then
  pass "M0a: the subject still exposes the OWNER_TEST_OVERRIDE seam this harness drives"
else
  fail "M0a: the subject no longer reads OWNER_TEST_OVERRIDE -- every case below would be vacuous"
  finish
fi

# ---- mutators ---------------------------------------------------------------
# Each writes a full copy of the owner test to <dst>. awk rather than sed with an
# interpolated pattern: the bodies contain `|`, `$` and backslashes.

drop_runlist_line() { # <src> <dst> <bare-name>
  awk -v n="$3" '$0 == n { next } { print }' "$1" > "$2"
}

rename_in_t8_body() { # <src> <dst> -- the delegate stops naming get-config-var
  awk '
    /^t8_get_config_var_pinned\(\)/ { inside = 1 }
    inside { gsub(/get-config-var/, "some-other-command") }
    inside && /^\}/ { inside = 0 }
    { print }
  ' "$1" > "$2"
}

hollow_t8_body() { # <src> <dst> -- definition and closing brace survive, body does not
  awk '
    /^t8_get_config_var_pinned\(\)/ && !inside { print; print "  # body removed by the C9 mutation harness"; inside = 1; next }
    inside && /^\}/ { print; inside = 0; next }
    inside { next }
    { print }
  ' "$1" > "$2"
}

# drop_definition — the whole `<name>() { ... }` block goes, the run-list line stays.
# The owner test runs under `set -uo pipefail` with no `-e`, so the surviving call is a
# `command not found` that neither aborts the run nor increments its FAIL counter: the
# owner test still exits 0 while the function it named no longer exists. That is the
# shape a run-list grep alone cannot see (review round 5, C3/C5).
drop_definition() { # <src> <dst> <function-name>
  awk -v fn="$3" '
    $0 ~ ("^" fn "\\(\\)") { inside = 1; next }
    inside && /^\}/ { inside = 0; next }
    inside { next }
    { print }
  ' "$1" > "$2"
}

# rename_definition — the definition line is renamed; the run-list line is untouched, so
# the call still names the old function. Same dormancy as above, reached a second way.
rename_definition() { # <src> <dst> <old> <new>
  awk -v old="$3" -v new="$4" '
    !done && $0 ~ ("^" old "\\(\\)") { sub("^" old, new); done = 1 }
    { print }
  ' "$1" > "$2"
}

# comment_out_t8_check — the delegate keeps its definition, its run-list line and every
# string a grep looks for, but its only executable assertion becomes a comment. T8 then
# runs zero real checks while a string-matching predicate sees nothing wrong (round 5, C4).
# The `check` call is a two-line continuation, so the trailing-backslash state is carried.
comment_out_t8_check() { # <src> <dst>
  awk '
    /^t8_get_config_var_pinned\(\)/ { inside = 1 }
    inside && cont { print "#" $0; cont = ($0 ~ /\\$/); next }
    inside && /^[[:space:]]*check[[:space:]]/ { print "#" $0; cont = ($0 ~ /\\$/); next }
    inside && /^\}/ { inside = 0 }
    { print }
  ' "$1" > "$2"
}

# empty_t8_table / unreachable_t8_loop — the two false-green shapes no grep can see.
# Both leave every string C9-a..C9-h matches exactly where it was; what they remove is the
# EXECUTION. The first empties T8's heredoc case table, the second puts an early `return 0`
# in front of the loop. Either way T8 runs zero assertions and, in a file that only counts
# failures, still reports green (review round 6, codex C2).
empty_t8_table() { # <src> <dst>
  awk '
    /^t8_get_config_var_pinned\(\)/ { inside = 1 }
    inside && /<<.T8_CASES.$/ { print; intable = 1; next }
    intable && /^T8_CASES$/ { print; intable = 0; next }
    intable { next }
    inside && /^\}/ { inside = 0 }
    { print }
  ' "$1" > "$2"
}

unreachable_t8_loop() { # <src> <dst>
  awk '
    /^t8_get_config_var_pinned\(\)/ { inside = 1 }
    inside && !done && /^[[:space:]]*while[[:space:]]+IFS=/ {
      print "  return 0  # unreachable-loop mutation"; done = 1
    }
    inside && /^\}/ { inside = 0 }
    { print }
  ' "$1" > "$2"
}

mutate() { # <variant> <dst>
  case "$1" in
    none)          cp "$OWNER" "$2" ;;
    unhook-t8)     drop_runlist_line "$OWNER" "$2" "t8_get_config_var_pinned" ;;
    unhook-t8b)    drop_runlist_line "$OWNER" "$2" "t8b_pin_negative_control" ;;
    rename-target) rename_in_t8_body "$OWNER" "$2" ;;
    hollow-body)   hollow_t8_body "$OWNER" "$2" ;;
    drop-t8b-def)  drop_definition "$OWNER" "$2" "t8b_pin_negative_control" ;;
    drop-t8-def)   drop_definition "$OWNER" "$2" "t8_get_config_var_pinned" ;;
    rename-t8-def) rename_definition "$OWNER" "$2" "t8_get_config_var_pinned" "t8_renamed_definition" ;;
    comment-out-check) comment_out_t8_check "$OWNER" "$2" ;;
    drop-budget-def)   drop_definition "$OWNER" "$2" "t8c_row_budget" ;;
    unhook-budget)     drop_runlist_line "$OWNER" "$2" "t8c_row_budget" ;;
    empty-case-table)  empty_t8_table "$OWNER" "$2" ;;
    unreachable-loop)  unreachable_t8_loop "$OWNER" "$2" ;;
    *) echo "HARNESS ERROR: unknown mutation '$1'" >&2; exit 2 ;;
  esac
}

# ---- the case table ---------------------------------------------------------
# Columns: case-id | mutation | C9-a | C9-b | C9-c | C9-d | C9-e | C9-f | C9-g | C9-h
# (each PASS or FAIL)

# What each row is really asking:
#   baseline      an unmutated copy keeps all six green -- so a row that goes red below
#                 did so because of the mutation, not because C9 always fails on a copy
#   unhook-t8     the delegate is defined but no longer invoked (dormant) -> C9-b only
#   unhook-t8b    the non-vacuity control is dormant -> C9-d only
#   rename-target the delegate no longer names get-config-var -> C9-c only
#   hollow-body   the delegate is a comment with no assertions left -> C9-c and C9-f

# The four rows below were added by review round 5. Their expected columns are wider
# because deleting or renaming a DEFINITION also empties the body the C9-c/C9-f greps
# read -- collateral, and recorded here rather than hidden:
#   drop-t8b-def      the control's definition is gone, its call survives -> C9-e only
#   comment-out-check T8's only assertion is commented out, strings intact -> C9-f only
#   drop-t8-def       T8's definition is gone, its call survives -> C9-a, plus c/f
#   rename-t8-def     T8's definition is renamed, its call survives -> C9-a, plus c/f
# C9-a's reject path had no row at all before these two, so it was unverified.

# Round 6 (codex C2) added four more rows, in two deliberately different shapes:
#   drop-budget-def   the executed-row budget's definition is gone -> C9-g only
#   unhook-budget     the budget is defined but dormant -> C9-h only
#   empty-case-table  T8's table is empty -> ALL EIGHT STILL PASS, on purpose
#   unreachable-loop  an early `return` in front of T8's loop -> same, all eight PASS
# The last two are not a hole in the table: they are the recorded proof that section 9's
# greps CANNOT see a loop that executes nothing. What rejects those two is the M5 group,
# which runs the owner's own budget against the same mutated copies.
C9_CASES='
baseline|none|PASS|PASS|PASS|PASS|PASS|PASS|PASS|PASS
unhook-t8|unhook-t8|PASS|FAIL|PASS|PASS|PASS|PASS|PASS|PASS
unhook-t8b|unhook-t8b|PASS|PASS|PASS|FAIL|PASS|PASS|PASS|PASS
rename-target|rename-target|PASS|PASS|FAIL|PASS|PASS|PASS|PASS|PASS
hollow-body|hollow-body|PASS|PASS|FAIL|PASS|PASS|FAIL|PASS|PASS
drop-t8b-def|drop-t8b-def|PASS|PASS|PASS|PASS|FAIL|PASS|PASS|PASS
comment-out-check|comment-out-check|PASS|PASS|PASS|PASS|PASS|FAIL|PASS|PASS
drop-t8-def|drop-t8-def|FAIL|PASS|FAIL|PASS|PASS|FAIL|PASS|PASS
rename-t8-def|rename-t8-def|FAIL|PASS|FAIL|PASS|PASS|FAIL|PASS|PASS
drop-budget-def|drop-budget-def|PASS|PASS|PASS|PASS|PASS|PASS|FAIL|PASS
unhook-budget|unhook-budget|PASS|PASS|PASS|PASS|PASS|PASS|PASS|FAIL
empty-case-table|empty-case-table|PASS|PASS|PASS|PASS|PASS|PASS|PASS|PASS
unreachable-loop|unreachable-loop|PASS|PASS|PASS|PASS|PASS|PASS|PASS|PASS
'

# assert_verdict <case> <check-id> <want-verdict> <output-file>
# Exactly one line for the id, and it carries the wanted verdict. Counting both the wanted
# and the unwanted prefix catches a check that dropped out of the run entirely (0 lines of
# either), which a bare "FAIL: is absent" assertion would call green.
assert_verdict() {
  local case_id="$1" cid="$2" want="$3" out="$4" other got_want got_other
  if [ "$want" = "PASS" ]; then other="FAIL"; else other="PASS"; fi
  got_want="$(grep -cE "^$want: \[$cid\]" "$out" || true)"
  got_other="$(grep -cE "^$other: \[$cid\]" "$out" || true)"
  check "M2[$case_id/$cid]: exactly one $want line" "1" "$got_want"
  check "M2[$case_id/$cid]: no $other line" "0" "$got_other"
}

# Two passes, because the table grew from 5 rows to 9 and the subject costs ~6.5 s a
# run on this host: serially that is ~90 s, inside the 120 s default of rules/test.md
# only by luck. Pass 1 mutates and launches every subject run concurrently; pass 2
# reads the finished output files. Nothing is shared between the concurrent runs --
# each has its own mutated copy and its own output file, and the subject only ever
# READS the repository -- so the split changes the wall clock and nothing else.
# The counters stay in this shell: pass 2 runs after `wait`, never in a subshell.
SKIPPED_IDS=""

launch_cases() {
  local id variant rest copy out
  while IFS='|' read -r id variant rest; do
    [ -n "$id" ] || continue
    copy="$TMP/$id-owner.sh"
    out="$TMP/$id.out"
    mutate "$variant" "$copy"

    # Non-vacuity of the mutation itself: an awk program that matched nothing would leave
    # a byte-identical copy, and every assertion below would be re-measuring the baseline.
    if [ "$variant" = "none" ]; then
      if cmp -s "$OWNER" "$copy"; then
        pass "M1[$id]: the unmutated copy is byte-identical to the owner test"
      else
        fail "M1[$id]: the unmutated copy already differs from the owner test"
      fi
    elif cmp -s "$OWNER" "$copy"; then
      fail "M1[$id]: the '$variant' mutation changed nothing, so every assertion below would be measuring the baseline"
      SKIPPED_IDS="$SKIPPED_IDS $id"
      continue
    else
      pass "M1[$id]: the '$variant' mutation actually altered the copy"
    fi

    ( OWNER_TEST_OVERRIDE="$copy" bash "$SUBJECT" > "$out" 2>&1; echo $? > "$out.rc" ) &
  done <<EOF
$C9_CASES
EOF
  wait
}

assert_cases() {
  local id variant wa wb wc wd we wf wg wh out rc want_rc
  while IFS='|' read -r id variant wa wb wc wd we wf wg wh; do
    [ -n "$id" ] || continue
    case " $SKIPPED_IDS " in *" $id "*) continue ;; esac
    out="$TMP/$id.out"
    # A launched run that produced no exit-code file never finished; reading its output
    # as though it had would judge a truncated file.
    if [ ! -f "$out.rc" ]; then
      fail "M2[$id]: the subject run never completed (no exit status recorded), so its verdict lines cannot be judged"
      continue
    fi
    rc="$(cat "$out.rc")"

    assert_verdict "$id" "C9-a" "$wa" "$out"
    assert_verdict "$id" "C9-b" "$wb" "$out"
    assert_verdict "$id" "C9-c" "$wc" "$out"
    assert_verdict "$id" "C9-d" "$wd" "$out"
    assert_verdict "$id" "C9-e" "$we" "$out"
    assert_verdict "$id" "C9-f" "$wf" "$out"
    assert_verdict "$id" "C9-g" "$wg" "$out"
    assert_verdict "$id" "C9-h" "$wh" "$out"

    # C9 ids are not in EXPECTED_FAILURES, so any C9 FAIL must colour the exit code. This
    # is what makes the section a gate rather than a printed opinion.
    case "$wa$wb$wc$wd$we$wf$wg$wh" in
      PASSPASSPASSPASSPASSPASSPASSPASS) want_rc=0 ;;
      *) want_rc=1 ;;
    esac
    check "M3[$id]: the subject's exit code" "$want_rc" "$rc"
  done <<EOF
$C9_CASES
EOF
}

run_cases() {
  launch_cases
  assert_cases
}

# The mutations above target the delegate by name. If the owner test renamed T8 or its
# control, `mutate` would still produce a file (an unchanged one for the awk variants) and
# M1 would catch it -- but say so directly, because the message "the mutation changed
# nothing" is a much worse hint than "the delegate you are mutating is gone".
m4_fixture_preconditions() {
  local n
  n="$(grep -cE '^t8_get_config_var_pinned\(\)' "$OWNER" || true)"
  check "M4a: the owner test defines t8_get_config_var_pinned() exactly once" "1" "$n"
  n="$(grep -cE '^t8_get_config_var_pinned[[:space:]]*$' "$OWNER" || true)"
  check "M4b: t8_get_config_var_pinned appears on the run list exactly once" "1" "$n"
  n="$(grep -cE '^t8b_pin_negative_control[[:space:]]*$' "$OWNER" || true)"
  check "M4c: t8b_pin_negative_control appears on the run list exactly once" "1" "$n"
  # The two definition-targeting mutations added in round 5 need the definitions to be
  # there, and comment-out-check needs an uncommented `check` line inside T8's body.
  n="$(grep -cE '^t8b_pin_negative_control\(\)' "$OWNER" || true)"
  check "M4d: the owner test defines t8b_pin_negative_control() exactly once" "1" "$n"
  n="$(sed -n '/^t8_get_config_var_pinned()/,/^}/p' "$OWNER" | grep -cE '^[[:space:]]*check[[:space:]]' || true)"
  check "M4e: t8_get_config_var_pinned's body holds exactly one executable check call" "1" "$n"
  # The owner test having no `set -e` is WHY a deleted definition is silent, and it is
  # the premise the drop-*-def rows rest on. If it ever gained -e, those rows would be
  # describing a failure mode that no longer exists.
  n="$(grep -cE '^set -[a-z]*e' "$OWNER" || true)"
  check "M4f: the owner test still runs without set -e (a missing function stays a silent 'command not found')" "0" "$n"
  # The round-6 rows need the executed-row budget to exist, to be on the run list, and to
  # have its counter initialised at file scope -- the focused runner below re-uses all three.
  n="$(grep -cE '^t8c_row_budget\(\)' "$OWNER" || true)"
  check "M4g: the owner test defines t8c_row_budget() exactly once" "1" "$n"
  n="$(grep -cE '^t8c_row_budget[[:space:]]*$' "$OWNER" || true)"
  check "M4h: t8c_row_budget appears on the run list exactly once" "1" "$n"
  n="$(grep -cE '^T8_ROWS=' "$OWNER" || true)"
  check "M4i: the owner test initialises T8_ROWS at file scope exactly once" "1" "$n"
  n="$(grep -cE '^[[:space:]]+T8_ROWS=\$\(\(T8_ROWS \+ 1\)\)' "$OWNER" || true)"
  check "M4j: exactly two loop bodies (T8 and T8b) increment the executed-row counter" "2" "$n"
}

# ---- M5: focused execution of the owner's own coverage-integrity guard -------
# Section 9 is greps, and the two shapes that matter most to #1967 -- an empty case table
# and a loop the code never reaches -- leave every grepped string intact. This group is the
# other half: it EXECUTES t8_get_config_var_pinned, t8b_pin_negative_control and
# t8c_row_budget, lifted verbatim out of the mutated copy, against the REAL (never written)
# install/path-exposed-commands.txt. No predicate is transcribed here either -- every
# function body comes out of the copy (CPR-SSOT).

# extract_fn — one `<name>() { ... }` definition, single-line or `^}`-terminated.
extract_fn() { # <file> <name>
  awk -v fn="$2" '
    !on && $0 ~ ("^" fn "\\(\\)") {
      print
      if ($0 ~ /\}[[:space:]]*$/) { next }
      on = 1; next
    }
    on { print; if ($0 ~ /^\}/) on = 0 }
  ' "$1"
}

# The focused runner: the copy's own harness (pass/fail/check), the copy's own list reader,
# the copy's own counter declarations, then the three functions and their run list. What is
# supplied from outside is only the fixture wiring -- the SSOT path and SSOT_PRESENT -- which
# the copy normally derives from $AGENTS_DIR.
#
# <ssot-path> defaults to the REAL install/path-exposed-commands.txt (which is only ever
# READ). The M6 group in the sibling module passes a throwaway fixture list instead --
# that argument is the whole reason a mutation of the SSOT *data* is expressible here.
build_focused() { # <owner-copy> <dst> [ssot-path]
  local src="$1"
  local ssot="${3:-$AGENTS_DIR/install/path-exposed-commands.txt}"
  {
    echo 'set -uo pipefail'
    echo 'PASS=0; FAIL=0; SKIP=0'
    extract_fn "$src" pass
    extract_fn "$src" fail
    extract_fn "$src" check
    # SSOT_REL is lifted from the copy rather than transcribed (CPR-SSOT). It appears only
    # in the owner's own failure messages, and those messages are reached exactly on the
    # "the list file does not exist" branch -- which M6 is the first group to exercise.
    grep -E '^SSOT_REL=' "$src" || true
    printf 'SSOT=%q\n' "$ssot"
    extract_fn "$src" ssot_entries
    echo 'ENTRIES="$(ssot_entries)"'
    echo 'SSOT_PRESENT=0; [ -f "$SSOT" ] && SSOT_PRESENT=1'
    grep -E '^T8_ROWS=' "$src" || true
    grep -E '^T8_ROWS_EXPECTED=' "$src" || true
    extract_fn "$src" pinned_in_list
    extract_fn "$src" t8_list_variant
    extract_fn "$src" t8_get_config_var_pinned
    extract_fn "$src" t8b_pin_negative_control
    extract_fn "$src" t8c_row_budget
    echo 't8_get_config_var_pinned'
    echo 't8b_pin_negative_control'
    echo 't8c_row_budget'
    echo 'echo "FOCUSED-TOTAL: $PASS passed, $FAIL failed"'
    echo 'exit "$FAIL"'
  } > "$2"
}

# Columns: case-id | mutation | want-PASS | want-FAIL | want-rc.
# Exact PASS counts, not "at least one failure": the empty-table and unreachable rows are
# distinguished from a healthy run by the ROWS THAT DID NOT RUN (6 -> 3), and only an exact
# count can see that. drop-budget-def is recorded here for the opposite reason -- executing
# a budget that no longer exists is a silent no-op, so this group cannot catch it and C9-g
# is what does. Nothing here can pass while the guard is absent.
M5_CASES='
baseline|none|6|0|0
empty-case-table|empty-case-table|3|1|1
unreachable-loop|unreachable-loop|3|1|1
drop-budget-def|drop-budget-def|5|0|0
'

m5_focused_execution() {
  local id variant wp wf want_rc out copy focused rc got
  while IFS='|' read -r id variant wp wf want_rc; do
    [ -n "$id" ] || continue
    copy="$TMP/m5-$id-owner.sh"
    focused="$TMP/m5-$id-focused.sh"
    out="$TMP/m5-$id.out"
    mutate "$variant" "$copy"
    build_focused "$copy" "$focused"
    bash "$focused" > "$out" 2>&1
    rc=$?
    got="$(grep -E '^FOCUSED-TOTAL: ' "$out" | tail -1)"
    check "M5[$id]: the focused run of T8/T8b/T8c reports its own totals" \
      "FOCUSED-TOTAL: $wp passed, $wf failed" "$got"
    check "M5rc[$id]: the focused run's exit code" "$want_rc" "$rc"
  done <<EOF
$M5_CASES
EOF
}

m4_fixture_preconditions
run_cases
m5_focused_execution

# M6/M7 mutate the SSOT DATA rather than the test source (rules/coding/file-split.md:
# a sibling module, because this file is already past the 300-line WARN threshold).
. "$AGENTS_DIR/tests/fix-1967-c9-delegation-mutation/ssot-fixture.sh"

finish
