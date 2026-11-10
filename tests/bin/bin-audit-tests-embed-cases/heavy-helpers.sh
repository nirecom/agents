# Tests: bin/audit-tests.sh
# Tags: TL2, scope:issue-specific, audit-tests, sweep-tests, heavy, durations, fixture
# Sourced by the -flags / -flags-common entrypoints — the #2932 `--heavy` checks, run
# symmetrically on both entrypoints by heavy-cases.sh / heavy-common-cases.sh. Holds no cases.
# --heavy must be read-only, never call gh, print the judge header, sort HARD first then
# median descending, and refuse every other mode flag with exit 2.

HV_REPO="$(ec_make_repo)"
for _n in alpha bravo charlie delta echo; do
  ec_add_test "$HV_REPO" "tests/bin/t-$_n.sh" "bin/$_n.sh"
done
ec_commit "$HV_REPO" init

# A gh stub on a private PATH entry records every call; --heavy must leave the log empty.
HV_GHBIN="$EC_TMP/hv-ghbin"
HV_GHLOG="$EC_TMP/hv-gh-calls.log"
mkdir -p "$HV_GHBIN"
printf '#!/bin/sh\nprintf "gh %%s\\n" "$*" >>"%s"\nexit 0\n' "$HV_GHLOG" >"$HV_GHBIN/gh"
chmod +x "$HV_GHBIN/gh"

# hv_stamp <minutes-ago> — a segment stamp inside every retention window (never a fixed date).
hv_stamp() {
  local t=$(( $(date -u +%s) - $1 * 60 ))
  date -u -d "@$t" +%Y%m%dT%H%M%S 2>/dev/null || date -u -r "$t" +%Y%m%dT%H%M%S
}

# The ledger: 3 PASS|completed samples each. echo 200 / charlie 160 are HARD (> 150),
# delta 100 / alpha 70 are WARN (> 60), bravo 5 is `-`; the suite median (100) keeps
# the relative rule out of play. Want order: HARD by median desc, then WARN, then the rest.
# The names are chosen so the want order differs from the alphabetical (input) order,
# so an unsorted output fails the HV4 ordering check.
HV_CACHE_LEDGER="$EC_TMP/cache-heavy-ledger"
HV_CACHE_EMPTY="$EC_TMP/cache-heavy-empty"
mkdir -p "$HV_CACHE_EMPTY"
export RUN_ALL_CACHE_DIR="$HV_CACHE_LEDGER"
for _i in 1 2 3; do
  _st="$(hv_stamp $((_i * 10)))"
  EC_LEDGER_SECS=70 ec_ledger_segment "$HV_REPO" "$_st" tests/bin/t-alpha.sh
  EC_LEDGER_SECS=5 ec_ledger_segment "$HV_REPO" "$_st" tests/bin/t-bravo.sh
  EC_LEDGER_SECS=160 ec_ledger_segment "$HV_REPO" "$_st" tests/bin/t-charlie.sh
  EC_LEDGER_SECS=100 ec_ledger_segment "$HV_REPO" "$_st" tests/bin/t-delta.sh
  EC_LEDGER_SECS=200 ec_ledger_segment "$HV_REPO" "$_st" tests/bin/t-echo.sh
done
export RUN_ALL_CACHE_DIR="$EC_TMP/run-all-cache"
HV_WANT_ORDER="$(printf '%s\n' tests/bin/t-echo.sh tests/bin/t-charlie.sh tests/bin/t-delta.sh tests/bin/t-alpha.sh tests/bin/t-bravo.sh)"

# hv_run <script> <cache> [args...] — --heavy (plus args) on HV_REPO with the gh stub first on PATH.
hv_run() {
  local script="$1" cache="$2" save_path="$PATH"
  shift 2
  : >"$HV_GHLOG"
  export RUN_ALL_CACHE_DIR="$cache" PATH="$HV_GHBIN:$PATH"
  ec_run "$HV_REPO" "$script" --heavy "$@"
  export RUN_ALL_CACHE_DIR="$EC_TMP/run-all-cache" PATH="$save_path"
}

# hv_snapshot — the fixture corpus and ledger state: worktree status, HEAD, ledger listing+sums.
hv_snapshot() {
  git -C "$HV_REPO" status --porcelain
  git -C "$HV_REPO" rev-parse HEAD
  find "$HV_CACHE_LEDGER" "$HV_CACHE_EMPTY" -type f -exec cksum {} + 2>/dev/null | LC_ALL=C sort
}

# hv_tsv_paths — the t-*.sh paths of the TSV rows, in output order.
hv_tsv_paths() { printf '%s\n' "$OUT" | awk -F'\t' '$1 ~ /^tests\/bin\/t-[a-z]+\.sh$/ { print $1 }'; }

# hv_tier <path> — the tier column of <path>'s TSV row.
hv_tier() { printf '%s\n' "$OUT" | awk -F'\t' -v p="$1" '$1 == p { print $2; exit }'; }

# hv_read_only <script> — the TSV run changes neither the corpus nor the ledger.
hv_read_only() {
  local before after
  before="$(hv_snapshot)"
  hv_run "$1" "$HV_CACHE_LEDGER"
  after="$(hv_snapshot)"
  check_eq "HV1 $(basename "$1") --heavy exits 0 (err=${ERR:0:200})" "0" "$RC"
  check_eq "HV1 $(basename "$1") --heavy leaves the corpus and the ledger untouched" "$before" "$after"
}

# hv_no_gh <script> — neither the ledger nor the no-ledger run calls gh.
hv_no_gh() {
  local c
  for c in "$HV_CACHE_LEDGER" "$HV_CACHE_EMPTY"; do
    hv_run "$1" "$c"
    check_eq "HV2 $(basename "$1") --heavy ($(basename "$c")) makes zero gh calls (rc=$RC)" "" "$(cat "$HV_GHLOG" 2>/dev/null)"
  done
}

# hv_missing <script> — no ledger: exit 0 and the judge header says reason=missing.
hv_missing() {
  hv_run "$1" "$HV_CACHE_EMPTY"
  check_eq "HV3 $(basename "$1") --heavy without a ledger exits 0 (err=${ERR:0:200})" "0" "$RC"
  if printf '%s\n' "$OUT" | grep -q '^#heavy-judge reason=missing\( \|$\)'; then
    pass "HV3 $(basename "$1") --heavy without a ledger prints the reason=missing header"
  else
    fail "HV3 $(basename "$1") --heavy without a ledger prints the reason=missing header" "out=${OUT:0:400}"
  fi
}

# hv_unreadable <script> — a ledger present but the test-time limits unreadable: exit 0 and the
# header says reason=unreadable. The stub node fails only the test-time reads and runs the real
# node for every other call, so the registry read before --heavy is reached still succeeds.
hv_unreadable() {
  local save_path="$PATH"
  mkdir -p "$EC_TMP/hv-failbin"
  printf '#!/bin/sh\ncase " $* " in *" test-time "*|*" --test-time-params "*) exit 1 ;; esac\nexec "%s" "$@"\n' "$(command -v node)" >"$EC_TMP/hv-failbin/node"
  chmod +x "$EC_TMP/hv-failbin/node"
  export PATH="$EC_TMP/hv-failbin:$PATH"
  hv_run "$1" "$HV_CACHE_LEDGER"
  export PATH="$save_path"
  check_eq "HV6 $(basename "$1") --heavy with a failing node exits 0 (err=${ERR:0:200})" "0" "$RC"
  if printf '%s\n' "$OUT" | grep -q '^#heavy-judge reason=unreadable\( \|$\)'; then
    pass "HV6 $(basename "$1") --heavy with a failing node prints the reason=unreadable header"
  else
    fail "HV6 $(basename "$1") --heavy with a failing node prints the reason=unreadable header" "out=${OUT:0:400}"
  fi
}

# hv_order <script> — HARD first, median descending within a tier; the tiers are the judge's.
hv_order() {
  hv_run "$1" "$HV_CACHE_LEDGER"
  check_eq "HV4 $(basename "$1") --heavy exits 0 with a ledger (err=${ERR:0:200})" "0" "$RC"
  if printf '%s\n' "$OUT" | grep -q '^#heavy-judge reason=ok '; then
    pass "HV4 $(basename "$1") --heavy with a ledger prints the reason=ok header"
  else
    fail "HV4 $(basename "$1") --heavy with a ledger prints the reason=ok header" "out=${OUT:0:400}"
  fi
  check_eq "HV4 $(basename "$1") --heavy tiers alpha/bravo/charlie/delta/echo" "WARN - HARD WARN HARD" \
    "$(hv_tier tests/bin/t-alpha.sh) $(hv_tier tests/bin/t-bravo.sh) $(hv_tier tests/bin/t-charlie.sh) $(hv_tier tests/bin/t-delta.sh) $(hv_tier tests/bin/t-echo.sh)"
  check_eq "HV4 $(basename "$1") --heavy orders HARD first, then median descending" "$HV_WANT_ORDER" "$(hv_tsv_paths)"
}

# hv_exclusive <script> — --heavy with each other mode flag is a usage error (exit 2).
hv_exclusive() {
  local combo
  for combo in "--apply" "--fix-headers" "--format json" "--dup-groups"; do
    # shellcheck disable=SC2086  # combo is a flag list on purpose
    hv_run "$1" "$HV_CACHE_LEDGER" $combo
    if [[ "$RC" -eq 2 ]] && ec_not_unknown_arg; then
      pass "HV5 $(basename "$1") --heavy $combo exits 2"
    else
      fail "HV5 $(basename "$1") --heavy $combo exits 2" "rc=$RC err=${ERR:0:200}"
    fi
  done
  check_eq "HV5 $(basename "$1") rejected --heavy combinations leave the corpus clean" "" "$(git -C "$HV_REPO" status --porcelain)"
}

grp_done heavy-helpers.sh
