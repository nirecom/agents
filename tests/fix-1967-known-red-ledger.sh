#!/usr/bin/env bash
# tests/fix-1967-known-red-ledger.sh
# Tests: tests/feature-confirm-flags-static.sh
# Tags: xfail-ledger, classifier, static, meta-test, scope:issue-specific, pwsh-not-required, TL2

# THE THING UNDER TEST is not a skill or a bin/ command: it is the known-RED CLASSIFIER
# that #1967 put into tests/feature-confirm-flags-static.sh. That file used to be red on
# every run for reasons nobody was repairing, so its exit code carried no information. The
# classifier restores the signal by sorting each check into one of five verdicts -- XFAIL,
# FAIL, XPASS, STALE-LEDGER, invalid-id -- and colouring the exit code for four of them.

# WHY A SEPARATE FILE. A normal run of the subject exercises exactly two of those verdicts
# (PASS and XFAIL); the other three only appear when the ledger and the check sites
# DISAGREE, which never happens in a healthy tree. So the classifier's whole reason for
# existing -- catching the eighth failure, the repaired-but-still-listed entry, the ledger
# key that names nothing -- would ship untested. Here each verdict is produced on purpose,
# by mutating a COPY, and the subprocess's output tokens and exit code are asserted.

# NOTHING IN THE REPOSITORY IS MUTATED. Every mutation is applied to a temp copy of the
# subject; the copy's REPO_ROOT is re-pinned at the real tree so the checks still read the
# real SKILL.md files and the baseline is the same seven XFAILs a direct run produces.

# TL3 gap: this proves the classifier's verdict logic and exit code. It does not prove that
# the seven ledger entries describe real, still-broken behaviour -- that is judged by a
# human reading the tracking issue, and no test can stand in for it.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUBJECT="$AGENTS_DIR/tests/feature-confirm-flags-static.sh"
EXPECTED_XFAIL=7

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- want [$2] got [$3]"; fi
}

TMP="$(mktemp -d "${TMPDIR:-/tmp}/fix-1967-known-red-ledger.XXXXXX")" || {
  echo "FATAL: mktemp -d failed" >&2
  exit 2
}
trap 'rm -rf "$TMP"' EXIT

if [ ! -f "$SUBJECT" ]; then
  fail "L0: the subject tests/feature-confirm-flags-static.sh exists"
  echo ""
  echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
  exit "$FAIL"
fi

# ---- the baseline copy ------------------------------------------------------
# REPO_ROOT in the subject is derived from $0, so a copy in a temp directory would look for
# skills/ next to itself and report every check as a missing file. Re-pin it at the real
# tree: the copy must differ from the original in that ONE line and nothing else.
BASE="$TMP/base.sh"
sed -e "s#^REPO_ROOT=.*#REPO_ROOT='$AGENTS_DIR'#" "$SUBJECT" > "$BASE"
check "L0a: the temp copy re-pins REPO_ROOT at the real tree (one line)" \
  "1" "$(grep -c "^REPO_ROOT='" "$BASE" || true)"

# ---- mutators ---------------------------------------------------------------
# awk with -v rather than sed with an interpolated pattern: the ids and the surrounding
# text contain `[`, `]` and backticks, and a mutation that silently matched nothing would
# make its whole case pass for the wrong reason.

ledger_delete() { # <src> <dst> <id> -- drop one entry from EXPECTED_FAILURES
  awk -v id="$3" 'index($0, id) == 1 { next } { print }' "$1" > "$2"
}

ledger_insert() { # <src> <dst> <id> -- add one entry to EXPECTED_FAILURES
  awk -v id="$3" '
    { print }
    index($0, "EXPECTED_FAILURES=") == 1 { print id "   # injected by the ledger harness" }
  ' "$1" > "$2"
}

id_corrupt() { # <src> <dst> -- turn one check site id into an id the charset forbids
  sed 's/"C9-a"/"C9_a"/g' "$1" > "$2"
}

mutate() { # <variant> <dst>
  case "$1" in
    none)       cp "$BASE" "$2" ;;
    drop-c2)    ledger_delete "$BASE" "$2" "C2-write-tests" ;;
    add-passing) ledger_insert "$BASE" "$2" "C7-worktree-askuserquestion-prohibited" ;;
    add-unknown) ledger_insert "$BASE" "$2" "C99-nonexistent-check-site" ;;
    add-duplicate) ledger_insert "$BASE" "$2" "C2-write-tests" ;;
    bad-id)     id_corrupt "$BASE" "$2" ;;
    *) echo "HARNESS ERROR: unknown mutation '$1'" >&2; exit 2 ;;
  esac
}

# ---- the case table ---------------------------------------------------------
# Columns: case-id | mutation | want-rc | must-appear (ERE, `-` for none) | must-not-appear

# The verdicts, and what each row is really asking:
#   xfail        a ledger entry that fails stays off the exit code -- the whole point
#   new-fail     the EIGHTH failure is not absorbed by the ledger; it is red
#   xpass        a ledger entry that started passing is red, so the ledger gets pruned
#   stale-ledger a ledger key no check site reports is red, so the ledger cannot rot
#   invalid-id   a malformed id aborts on the spot instead of detaching a check silently
#   dup-id       one id listed twice aborts: in_ledger would still say yes, but the
#                ledger would no longer state how many known failures there are
LEDGER_CASES='
xfail|none|0|^XFAIL: \[C2-write-tests\]|^(FAIL|XPASS|STALE-LEDGER):
new-fail|drop-c2|1|^FAIL: \[C2-write-tests\]|^XFAIL: \[C2-write-tests\]
xpass|add-passing|1|^XPASS: \[C7-worktree-askuserquestion-prohibited\]|^PASS: \[C7-worktree-askuserquestion-prohibited\]
stale-ledger|add-unknown|1|^STALE-LEDGER: \[C99-nonexistent-check-site\]|^Total: .* 0 unexpected
invalid-id|bad-id|2|^HARNESS ERROR: invalid check id|^Total:
dup-id|add-duplicate|2|^HARNESS ERROR: duplicate id\(s\) in EXPECTED_FAILURES: C2-write-tests|^Total:
'

run_cases() {
  local id variant want_rc want_re forbid_re copy out rc hits
  while IFS='|' read -r id variant want_rc want_re forbid_re; do
    [ -n "$id" ] || continue
    copy="$TMP/$id.sh"
    out="$TMP/$id.out"
    mutate "$variant" "$copy"

    # A mutation that changed nothing would make the rest of the row assert the baseline's
    # behaviour under a name that promises otherwise -- the classic silently-vacuous case.
    if [ "$variant" = "none" ]; then
      if cmp -s "$BASE" "$copy"; then
        pass "L1[$id]: the baseline copy is byte-identical to the re-pinned subject"
      else
        fail "L1[$id]: the baseline copy differs from the re-pinned subject"
      fi
    elif cmp -s "$BASE" "$copy"; then
      fail "L1[$id]: the '$variant' mutation changed nothing, so every assertion below would be measuring the baseline"
      continue
    else
      pass "L1[$id]: the '$variant' mutation actually altered the copy"
    fi

    bash "$copy" > "$out" 2>&1
    rc=$?
    check "L2[$id]: exit code" "$want_rc" "$rc"

    if [ "$want_re" != "-" ]; then
      hits="$(grep -cE -- "$want_re" "$out" || true)"
      if [ "$hits" -ge 1 ]; then
        pass "L3[$id]: the run reports the expected verdict line"
      else
        fail "L3[$id]: the run never printed a line matching /$want_re/ -- the verdict was classified as something else"
      fi
    fi

    if [ "$forbid_re" != "-" ]; then
      hits="$(grep -cE -- "$forbid_re" "$out" || true)"
      check "L4[$id]: no line matching /$forbid_re/" "0" "$hits"
    fi
  done <<EOF
$LEDGER_CASES
EOF
}

# The ledger's SIZE, asserted once on the untouched baseline. The exit code alone cannot
# tell "seven known failures" from "seven known failures and one that was quietly added to
# the ledger instead of being fixed", and that difference is the one #1967 is about.
l5_ledger_size() {
  local out="$TMP/xfail.out" n
  [ -f "$out" ] || { fail "L5: the baseline run produced no output to count"; return 0; }
  n="$(grep -cE '^XFAIL: \[' "$out" || true)"
  check "L5: the baseline reports exactly $EXPECTED_XFAIL XFAIL rows (a new one must be fixed or explicitly tracked, never quietly listed)" \
    "$EXPECTED_XFAIL" "$n"
  n="$(grep -cE "^Total: .* $EXPECTED_XFAIL expected-fail" "$out" || true)"
  check "L6: the baseline summary line agrees with the XFAIL rows it printed" "1" "$n"
}

# The ORDINARY path, asserted on the same untouched baseline. Every row above drives a
# ledger-related verdict, so the branch a healthy check actually takes -- id not in the
# ledger, predicate true, `PASS:` printed, PASSED incremented -- was only ever exercised
# incidentally. If `pass()` regressed into counting a plain success as XPASS (or into
# printing nothing at all), the ledger rows would still be green and the exit code would
# still be 0: the classifier would be reporting on a population it no longer measures.

# C9-a is used as the probe because it is a check site that is deliberately NOT in
# EXPECTED_FAILURES and passes in a healthy tree; L7c re-derives the count from the rows
# rather than hardcoding it, so adding checks to the subject does not falsify this file.
l7_pass_path() {
  local out="$TMP/xfail.out" rows total unexpected
  [ -f "$out" ] || { fail "L7: the baseline run produced no output to inspect"; return 0; }

  rows="$(grep -cE '^PASS: \[C9-a\]' "$out" || true)"
  check "L7a: a non-ledger check that succeeds is reported on the PASS line" "1" "$rows"

  rows="$(grep -cE '^(XFAIL|XPASS|FAIL|STALE-LEDGER): \[C9-a\]' "$out" || true)"
  check "L7b: that same check contributes to neither the XFAIL nor the unexpected tally" "0" "$rows"

  rows="$(grep -cE '^PASS: \[' "$out" || true)"
  total="$(sed -n 's/^Total: \([0-9][0-9]*\) passed.*/\1/p' "$out")"
  check "L7c: the summary's passed count equals the PASS rows the run printed" "$rows" "${total:-<none>}"

  # A PASSED counter that never moves would also satisfy "rows == total" at 0/0.
  if [ "${rows:-0}" -ge 1 ]; then
    pass "L7d: the baseline actually exercises the PASS path (${rows} rows), so L7c is not 0 == 0"
  else
    fail "L7d: the baseline printed no PASS rows at all, so the PASS path is untested here"
  fi

  unexpected="$(sed -n 's/^Total: .* \([0-9][0-9]*\) unexpected$/\1/p' "$out")"
  check "L7e: the untouched baseline reports zero unexpected results" "0" "${unexpected:-<none>}"
}

run_cases
l5_ledger_size
l7_pass_path

echo ""
echo "Total: $PASS passed, $FAIL failed, $SKIP skipped"
exit "$FAIL"
