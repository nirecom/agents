# shellcheck shell=bash
# tests/bin/feature-2431-run-tests-baseline/ledger-newest.sh
# Tests: bin/lib/run-tests-baseline-ledger.sh
# Tags: run-tests, baseline, ledger, inherit, scope:issue-specific, pwsh-not-required, TL2
# #3047 S3-2 (#3016): per base SHA, both inheritable lookups pick the newest reusable row
# (fail / pass / cacheable und) and offer the base only when that row is a fail (the _fp form also
# needs its fp). Sourced by the dispatcher; never run standalone.

LN_FP="$(printf 'f%.0s' $(seq 1 64))"

# ln_rec <sha> <host> <path> <result> <fp> <epoch> — one synthetic v3 record line.
ln_rec() { printf 'v3\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4" "$5" "$6" "$LEDGER_ATTR"; }

run_ledger_newest_row_cases() {
  local repo="$TMPROOT/repo-ln" cache="$TMPROOT/cache-ln" t="tests/bin/test-newest.sh"
  local sa="a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1a1" sb="b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2b2"
  local sc="c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3c3" sd="d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4d4"
  local se="e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5e5"
  mk_fixture_repo "$repo" >/dev/null
  mkdir -p "$cache"
  ledger_call "$cache" "$repo" rtb_ledger_append "$LEDGER_SHA_A" "tests/bin/other.sh" pass >/dev/null 2>&1
  local seg dir host old new
  seg="$(ledger_segments "$cache" | head -1)"
  [ -n "$seg" ] || { fail "LN: rtb_ledger_append wrote no segment to seed beside"; return; }
  dir="$(dirname "$seg")"; host="$(head -1 "$seg" | cut -f3)"
  old=$(( $(date +%s) - 300 )); new=$((old + 100))
  # A: old fail(fp), new pass. B: old pass, new fail(fp). C: old fail(fp), new cacheable und.
  # D: old fail(fp), new fail without fp. E: old fail(fp), new non-cacheable und (not reusable).
  {
    ln_rec "$sa" "$host" "$t" fail "$LN_FP" "$old"; ln_rec "$sa" "$host" "$t" pass - "$new"
    ln_rec "$sb" "$host" "$t" pass - "$old"; ln_rec "$sb" "$host" "$t" fail "$LN_FP" "$new"
    ln_rec "$sc" "$host" "$t" fail "$LN_FP" "$old"; ln_rec "$sc" "$host" "$t" und:timeout-at-base-after-300s - "$new"
    ln_rec "$sd" "$host" "$t" fail "$LN_FP" "$old"; ln_rec "$sd" "$host" "$t" fail - "$new"
    ln_rec "$se" "$host" "$t" fail "$LN_FP" "$old"; ln_rec "$se" "$host" "$t" und:budget-exhausted - "$new"
  } > "$dir/v3.$host-$old-30470.seg"

  local plain fp
  plain="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_inheritable "$t" 2>/dev/null)"
  fp="$(ledger_call "$cache" "$repo" rtb_ledger_lookup_inheritable_fp "$t" 2>/dev/null)"
  ln_absent "LN-plain-fail-then-pass: a newer pass on the same base hides the older fail" "$plain" "$sa"
  ln_present "LN-plain-pass-then-fail: a newer fail is a candidate" "$plain" "$sb"
  ln_absent "LN-plain-fail-then-und: a newer cacheable und hides the older fail" "$plain" "$sc"
  ln_present "LN-plain-fail-then-fail: the newest fail is a candidate" "$plain" "$sd"
  ln_present "LN-plain-non-reusable-und: a newer non-cacheable und is skipped, the fail stays" "$plain" "$se"
  ln_absent "LN-fp-fail-then-pass: a newer pass on the same base hides the older fail" "$fp" "$sa	$LN_FP"
  ln_present "LN-fp-pass-then-fail: a newer fail with fp is a candidate" "$fp" "$sb	$LN_FP"
  ln_absent "LN-fp-fail-then-und: a newer cacheable und hides the older fail" "$fp" "$sc	$LN_FP"
  ln_absent "LN-fp-newest-fail-has-no-fp: the older fail's fp is not used" "$fp" "$sd	$LN_FP"
  ln_present "LN-fp-non-reusable-und: a newer non-cacheable und is skipped, the fail stays" "$fp" "$se	$LN_FP"
}

# ln_present / ln_absent <label> <lookup-output> <exact-line>
ln_present() {
  printf '%s\n' "$2" | grep -qxF -- "$3" && pass "$1" || fail "$1: expected line [$3] in: $(printf '%s' "$2" | tr '\n' '|')"
}
ln_absent() {
  printf '%s\n' "$2" | grep -qF -- "${3%%	*}" && fail "$1: base ${3%%	*} offered: $(printf '%s' "$2" | tr '\n' '|')" || pass "$1"
}
