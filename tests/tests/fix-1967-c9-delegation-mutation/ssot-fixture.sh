# Part of tests/fix-1967-c9-delegation-mutation.sh (sourced, not standalone).
# Tests: tests/install-path-exposed-commands.sh, tests/feature-confirm-flags-static.sh
# Tags: mutation-test, meta-test, ssot-fixture, delegation, scope:issue-specific, pwsh-not-required, TL2

# M6 -- MUTATE THE SSOT DATA, NOT THE TEST SOURCE (review round 3, codex C2).

# WHAT THE EARLIER GROUPS DO NOT DO. M1-M5 mutate the owner test's SOURCE and watch the
# section-9 greps (and the owner's own row budget) react. Not one of them changes the fact
# under test -- the CONTENT of install/path-exposed-commands.txt. So "get-config-var was
# dropped from the list" had no direct case: the closest was T8b, which feeds synthesised
# list TEXT to the predicate rather than exercising the file-reading path.

# WHAT M6 ADDS. Three fixture copies of the list -- entry removed, list empty, list file
# absent -- each driven through the owner's REAL T8/T8b/T8c path, with exact pass/fail
# totals pinned. Every one must go RED. A fourth row copies the real list byte-for-byte
# and must stay green, so a fixture wiring bug cannot make the three reds vacuous.

# THE ROUTE TAKEN, AND WHY. tests/install-path-exposed-commands.sh hardcodes
# SSOT="$AGENTS_DIR/$SSOT_REL" and exposes no env or argument seam for it. Adding one
# would be a source change to the owner test purely to make it testable, so the route is
# the one M5 already established: build_focused() lifts the owner's own function bodies
# verbatim out of the copy (CPR-SSOT -- no predicate is transcribed here) and emits a
# single `SSOT=` assignment ahead of them. M6 passes the fixture path to that assignment.

# THE REAL LIST IS NEVER WRITTEN. Every variant is produced in $TMP, and M6d fingerprints
# install/path-exposed-commands.txt before and after this group to prove it.

M6_DIR="$TMP/m6"
mkdir -p "$M6_DIR"
M6_REAL_SSOT="$AGENTS_DIR/install/path-exposed-commands.txt"
M6_ROWS=0
M6_ROWS_EXPECTED=4   # rows in M6_CASES; a dropped row is a silent loss of a RED proof

m6_sum() { # <file> -- content fingerprint, independent of md5/sha tool availability
  if [ -f "$1" ]; then
    wc -c < "$1" | tr -d ' '
    printf ':'
    cksum < "$1" 2>/dev/null | awk '{print $1}'
  else
    printf 'ABSENT'
  fi
}

M6_SSOT_BEFORE="$(m6_sum "$M6_REAL_SSOT")"

# Fixture list builder. `missing-list` is produced by NOT creating the file, so the
# owner's own `[ -f "$SSOT" ] || return 0` reader is what discovers the absence -- a
# hand-written empty string would bypass exactly the branch the case is about.
m6_build_list() { # <variant> <dst>
  case "$1" in
    identical)     cp "$M6_REAL_SSOT" "$2" ;;
    entry-removed) grep -vx -- 'get-config-var' "$M6_REAL_SSOT" > "$2" || true ;;
    empty-list)    : > "$2" ;;
    missing-list)  rm -f "$2" ;;
    *) echo "HARNESS ERROR: unknown M6 list variant '$1'" >&2; exit 2 ;;
  esac
}

# Preconditions. If the real list stopped holding get-config-var, `entry-removed` would be
# a no-op and would report the same totals as `identical` -- green for the wrong reason.
m6_preconditions() {
  local n
  if [ ! -f "$M6_REAL_SSOT" ]; then
    fail "M6a: install/path-exposed-commands.txt exists (every fixture below is built FROM it)"
    return 1
  fi
  pass "M6a: install/path-exposed-commands.txt exists"
  n="$(grep -cx -- 'get-config-var' "$M6_REAL_SSOT" || true)"
  check "M6b: the real list holds get-config-var exactly once, so removing it is a real mutation" "1" "$n"
  [ "$n" = "1" ]
}

# Columns: case-id | list-variant | want-PASS | want-FAIL | want-rc.
# EXACT totals, measured rather than guessed. What each row is really saying:

#   identical     6/0 -- the control. T8 (2 rows) + T8b (3 rows) + T8c (1 row), all green.
#   entry-removed 4/2 -- T8's two rows go red (present wants 1, sees 0; duplicate wants 2,
#                        sees 1). T8b's three rows still pass -- they ASSERT absence -- and
#                        T8c still counts 5 executed rows. Only T8 owns "it is on the list".
#   empty-list    4/2 -- the same shape reached another way: the file EXISTS, so both loops
#                        still run; the entries are simply gone.
#   missing-list  0/3 -- SSOT_PRESENT is 0, so T8 and T8b take their early `fail`+return
#                        paths and never enter their loops; T8c then sees 0 executed rows
#                        against a budget of 5 and fails too.
M6_CASES='
identical|identical|6|0|0
entry-removed|entry-removed|4|2|2
empty-list|empty-list|4|2|2
missing-list|missing-list|0|3|3
'

m6_focused_against_fixture_ssot() {
  local id variant wp wf want_rc copy focused out rc got list
  while IFS='|' read -r id variant wp wf want_rc; do
    [ -n "$id" ] || continue
    M6_ROWS=$((M6_ROWS + 1))
    copy="$M6_DIR/$id-owner.sh"
    focused="$M6_DIR/$id-focused.sh"
    out="$M6_DIR/$id.out"
    list="$M6_DIR/$id-path-exposed-commands.txt"
    mutate none "$copy"          # the owner test SOURCE is unmutated here; only its data is
    m6_build_list "$variant" "$list"
    build_focused "$copy" "$focused" "$list"
    bash "$focused" > "$out" 2>&1
    rc=$?
    got="$(grep -E '^FOCUSED-TOTAL: ' "$out" | tail -1)"
    # No FOCUSED-TOTAL line means the focused script died before its own summary -- a
    # harness bug, not a verdict. Echo its output so the next reader sees the cause
    # instead of an empty `got`.
    [ -n "$got" ] || sed 's/^/  M6-DEBUG: /' "$out"
    check "M6[$id]: the owner's real T8/T8b/T8c path against a '$variant' fixture list" \
      "FOCUSED-TOTAL: $wp passed, $wf failed" "$got"
    check "M6rc[$id]: its exit code" "$want_rc" "$rc"
  done <<EOF
$M6_CASES
EOF
}

m6_row_budget() {
  check "M6c: every M6 case row executed (0 would mean an empty or unreachable table reporting green)" \
    "$M6_ROWS_EXPECTED" "$M6_ROWS"
}

# ---- M7: the honest boundary -- what section 9 can and cannot see -------------

# RECORDED EXPECTATION, NOT AN OMISSION. Section 9 of feature-confirm-flags-static.sh is a
# DELEGATION check: its eight predicates grep the owner test's SOURCE, and none of them
# opens install/path-exposed-commands.txt. Every mutation M6 just proved RED is therefore
# INVISIBLE to section 9 -- measured below rather than asserted from reading the code.

# HOW IT IS MEASURED. A throwaway repo root in $TMP holds only tests/ (the subject and an
# unmutated owner copy) and install/path-exposed-commands.txt in the given variant. The
# subject derives REPO_ROOT from its own $0, so the copy roots at the fixture. Only the
# C9-* verdict lines are read: the fixture has no skills/ or .env.example, so other
# sections fail and the subject's exit code is meaningless here and is not asserted.
m7_section9_blindness() {
  local variant root out n
  for variant in identical entry-removed empty-list missing-list; do
    root="$M6_DIR/root-$variant"
    mkdir -p "$root/tests" "$root/install"
    cp "$SUBJECT" "$root/tests/feature-confirm-flags-static.sh"
    mutate none "$root/tests/install-path-exposed-commands.sh"
    m6_build_list "$variant" "$root/install/path-exposed-commands.txt"
    out="$M6_DIR/root-$variant.out"
    bash "$root/tests/feature-confirm-flags-static.sh" > "$out" 2>&1
    n="$(grep -cE '^PASS: \[C9-[a-h]\]' "$out" || true)"
    check "M7[$variant]: all eight section-9 predicates still PASS -- they grep the owner's source and never read the list file" \
      "8" "$n"
    n="$(grep -cE '^(FAIL|XFAIL): \[C9-[a-h]\]' "$out" || true)"
    check "M7neg[$variant]: no section-9 predicate went red on a list mutation (recorded boundary, not a hole)" \
      "0" "$n"
  done
}

m6_ssot_untouched() {
  check "M6d: install/path-exposed-commands.txt is byte-for-byte what it was before this group ran" \
    "$M6_SSOT_BEFORE" "$(m6_sum "$M6_REAL_SSOT")"
}

m6_main() {
  if m6_preconditions; then
    m6_focused_against_fixture_ssot
    m6_row_budget
    m7_section9_blindness
  fi
  m6_ssot_untouched
}

m6_main
