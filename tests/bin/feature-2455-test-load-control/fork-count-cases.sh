#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/fork-count-cases.sh — FC1-FC5.
# Counts process launches, never wall time: a fork count is deterministic on every
# host, while a timing bound is either flaky or too loose to catch O(N) regressions.

case_begin "fork-count" "bin/find-tests-for-source.sh"

FC_R30="$(mk_repo)"; synth_corpus "$FC_R30" 30
FC_R120="$(mk_repo)"; synth_corpus "$FC_R120" 120
FC_C30="$TMPDIR_BASE/fc-cache-30"
FC_C120="$TMPDIR_BASE/fc-cache-120"
# Pinned empty (#2932): a duration ledger under the cache would let the heavy test judge start
# its awk pass and break the FC1 hit awk=0 premise, so the fixture caches start with no ledger.
mkdir -p "$FC_C30" "$FC_C120"
if [ ! -e "$FC_C30/durations" ] && [ ! -e "$FC_C120/durations" ]; then
    pass "FC1 premise: the fixture cache roots hold no duration ledger"
else
    fail "FC1 premise: a duration ledger exists under the fixture cache roots"
fi
# Host limit and AUTO_CONFIG_TEST_MAX_JOBS pinned in the environment: a valid env value
# skips its .env resolver, so no host-dependent launch is added to the tally.
FC_ENV=(TEST_MAX_JOBS_PER_HOST=4 AUTO_CONFIG_TEST_MAX_JOBS=on)

# fc_measure <repo> <cache> <mode:off|miss|hit> <args...> — echo-free; sets FC_TALLY.
fc_measure() {
    local repo="$1" cache="$2" mode="$3"; shift 3
    local -a extra=("RUN_ALL_CACHE_DIR=$cache" "${FC_ENV[@]}")
    [ "$mode" = "off" ] && extra+=(FIND_TESTS_CORPUS_CACHE=off)
    FT_TIMEOUT=300 fork_run "$NEUTRAL_DIR" "${extra[@]}" -- --root "$repo" "$@"
}

# ── FC1 O(1) in corpus size, per mode ───────────────────────────────────────
for _mode in off miss hit; do
    fc_measure "$FC_R30" "$FC_C30" "$_mode" --sources src/common.js
    _rc30="$RC"; _t30="$FC_TALLY"; _o30="$OUT"
    fc_caps_check "N=30 $_mode"
    # Positive control: a cold run must scan, so the shim does see awk and git.
    if [ "$_mode" = "miss" ]; then
        [ "$(fc_count awk)" -ge 1 ] && pass "FC1 miss: the shim counts awk launches (positive control)" || fail "FC1 miss: awk count $(fc_count awk) — the fork shim sees nothing"
        [ "$(fc_count git)" -ge 1 ] && pass "FC1 miss: the shim counts git launches (positive control)" || fail "FC1 miss: git count $(fc_count git) — the fork shim sees nothing"
    fi
    fc_measure "$FC_R120" "$FC_C120" "$_mode" --sources src/common.js
    _rc120="$RC"; _t120="$FC_TALLY"; _o120="$OUT"
    fc_caps_check "N=120 $_mode"
    if [ "$_mode" = "off" ]; then
        FC_OFF30="$_o30"; FC_OFF120="$_o120"
    elif [ "$_mode" = "hit" ]; then
        if [ -n "$FC_OFF30" ] && [ "$_o30" = "$FC_OFF30" ] && [ "$_o120" = "$FC_OFF120" ]; then
            pass "FC1 hit: N=30 and N=120 hit output equals the uncached output"
        else
            fail "FC1 hit: hit output differs from the uncached output (rc=$_rc30/$_rc120)"
        fi
    fi
    if [ "$_rc30" -eq 0 ] && [ "$_rc120" -eq 0 ] && [ "$_t30" = "$_t120" ]; then
        pass "FC1 $_mode: per-command launch counts identical for N=30 and N=120 [$_t30]"
    else
        fail "FC1 $_mode: launch counts depend on corpus size — rc=$_rc30/$_rc120 N=30=[$_t30] N=120=[$_t120]"
    fi
    if [ "$_mode" = "hit" ]; then
        if [ "$(fc_count awk)" = "0" ]; then
            pass "FC1 hit: awk launched 0 times (the cached corpus replaced the scan)"
        else
            fail "FC1 hit: awk launched $(fc_count awk) times on a warm cache — the corpus cache is not being used"
        fi
    fi
done
case_ran FC1

# ── FC2 independent of the query count (warm cache) ─────────────────────────
_tf1=(--test-file tests/bin/t1.sh)
_tf10=()
_src1=(--sources src/u1.js)
_src10=()
for _i in 1 2 3 4 5 6 7 8 9 10; do
    _tf10+=(--test-file "tests/bin/t$_i.sh")
    _src10+=(--sources "src/u$_i.js")
done
fc_measure "$FC_R30" "$FC_C30" hit "${_tf1[@]}"; _a="$FC_TALLY"; _arc="$RC"; fc_caps_check "--test-file x1"
fc_measure "$FC_R30" "$FC_C30" hit "${_tf10[@]}"; _b="$FC_TALLY"; _brc="$RC"; fc_caps_check "--test-file x10"
if [ "$_arc" -eq 0 ] && [ "$_brc" -eq 0 ] && [ "$_a" = "$_b" ]; then
    pass "FC2 --test-file: 1 and 10 queries launch the same commands [$_a]"
else
    fail "FC2 --test-file: launch counts grow with the query count — rc=$_arc/$_brc x1=[$_a] x10=[$_b]"
fi
fc_measure "$FC_R30" "$FC_C30" hit "${_src1[@]}"; _a="$FC_TALLY"; _arc="$RC"; fc_caps_check "--sources x1"
fc_measure "$FC_R30" "$FC_C30" hit "${_src10[@]}"; _b="$FC_TALLY"; _brc="$RC"; fc_caps_check "--sources x10"
if [ "$_arc" -eq 0 ] && [ "$_brc" -eq 0 ] && [ "$_a" = "$_b" ]; then
    pass "FC2 --sources: 1 and 10 queries launch the same commands [$_a]"
else
    fail "FC2 --sources: launch counts grow with the query count — rc=$_arc/$_brc x1=[$_a] x10=[$_b]"
fi
case_ran FC2
case_ran FC3

# ── FC4 static shape of the hot path ────────────────────────────────────────
for _f in "$ROUTE_LIB" "$HELPER"; do
    for _pat in '$(trd_file_lines' '$(tdg_escape_field' '$(trd_list_column' '| LC_ALL=C sort'; do
        _n="$(grep -cF -- "$_pat" "$_f" 2>/dev/null || true)"
        assert_eq "FC4 ${_f#"$AGENTS_ROOT"/} has no '$_pat' (a per-row fork)" "0" "${_n:-0}"
    done
done
_n="$(grep -cE '^[[:space:]]*(function[[:space:]]+)?trd_validate_test_file[[:space:]]*\(\)' "$ROUTE_LIB" 2>/dev/null || true)"
assert_eq "FC4 trd_validate_test_file is no longer defined (replaced by trd_validate_test_matches)" "0" "${_n:-0}"

# fc4_scan <file> — non-comment `dirname` lines, and `$(date` lines outside a
# function whose body also carries the builtin `%(` primary path.
fc4_scan() {
    awk '
        /^[[:space:]]*#/ { next }
        /dirname/ { print NR ": " $0 }
        /^[A-Za-z_][A-Za-z0-9_]*[[:space:]]*\(\)/ { infn = 1; body = ""; hasfmt = 0 }
        {
            if ($0 ~ /\$\(date/) {
                if (infn) body = body NR ": " $0 "\n"; else print NR ": " $0
            }
            if (infn && $0 ~ /%\(/) hasfmt = 1
        }
        infn && /^}/ { if (!hasfmt && body != "") printf "%s", body; infn = 0 }
    ' "$1"
}
# The #2687 siblings the lanes lib sources share its hot path (CPR-ORTH).
for _f in "$CORPUS_LIB" "$LANES_LIB" "$AGENTS_ROOT/bin/lib/test-host-lanes-share.sh" \
    "$AGENTS_ROOT/bin/lib/test-host-load.sh" "$AGENTS_ROOT/bin/lib/test-host-load-probe.sh"; do
    _rel="${_f#"$AGENTS_ROOT"/}"
    if [ ! -f "$_f" ]; then
        fail "FC4 $_rel missing (not implemented) — dirname/date scan impossible"
        continue
    fi
    _v="$(fc4_scan "$_f")"
    if [ -z "$_v" ]; then
        pass "FC4 $_rel launches no dirname and no \$(date outside a builtin-%( fallback"
    else
        fail "FC4 $_rel forks on the hot path: $(printf '%s' "$_v" | tr '\n' '|')"
    fi
done
case_ran FC4

# ── FC5 the heavy test judge: one awk pass whatever the rows and queries (#2932) ──
FC5_DRV="$TMPDIR_BASE/fc5-drv.sh"
printf '%s\n' '#!/usr/bin/env bash' 'set -u' \
    '. "$DRV_PAR_LIB" || exit 90' '. "$DRV_DUR_LIB" || exit 90' \
    '[ -f "$DRV_THJ_LIB" ] || exit 91' '. "$DRV_THJ_LIB" || exit 91' \
    'run_all_dur_repo_id "$DRV_REPO" >/dev/null' 'run_all_dur_host_token >/dev/null' \
    'd="$(run_all_dur_dir)"' 'mkdir -p "$d"' \
    'f="$d/dur.$RUN_ALL_DUR_SCHEMA.$RUN_ALL_DUR_HOST_TOKEN.20200101T000001-1.log"' \
    'printf "#os %s\n" "${RUN_ALL_DUR_OS_ATTR:-fixture}" >"$f"' \
    'i=0' 'while [ "$i" -lt "$DRV_ROWS" ]; do i=$((i + 1))' \
    '  printf "%s|%s|PASS|completed|tests/bin/t%s.sh\n" "$RUN_ALL_DUR_REPO_ID" $((i % 7 + 1)) $(((i - 1) % 30 + 1)) >>"$f"' \
    'done' ': >"$FORK_LOG"' 'PATH="$DRV_SHIM:$PATH"' \
    'thj_judge "$DRV_REPO" "$DRV_PATHS" "$DRV_OUT"' > "$FC5_DRV"
# fc5_judge <rows> <queries> — judges <queries> paths over a fresh <rows>-row ledger; sets FC_TALLY / RC.
fc5_judge() {
    local cache="$TMPDIR_BASE/fc5-cache-$1-$2" pf="$TMPDIR_BASE/fc5-paths-$2" i
    : > "$pf"
    for ((i = 1; i <= $2; i++)); do printf 'tests/bin/t%s.sh\n' "$i" >> "$pf"; done
    : > "$FORK_LOG_FILE"
    (
        cd "$NEUTRAL_DIR" || exit 2
        bash "$RUN_TIMEOUT" 60 env "RUN_ALL_CACHE_DIR=$cache" "FORK_LOG=$FORK_LOG_FILE" \
            "DRV_PAR_LIB=$PAR_LIB" "DRV_DUR_LIB=$AGENTS_ROOT/bin/lib/run-all-durations.sh" \
            "DRV_THJ_LIB=$AGENTS_ROOT/bin/lib/test-heavy-judge.sh" "DRV_REPO=$FC_R30" "DRV_ROWS=$1" \
            "DRV_PATHS=$pf" "DRV_OUT=$cache/judge.tsv" "DRV_SHIM=$SHIM_DIR" bash "$FC5_DRV"
    ) >/dev/null 2>&1
    RC=$?
    FC_TALLY="$(LC_ALL=C sort "$FORK_LOG_FILE" | uniq -c | awk '{ printf "%s=%s ", $2, $1 }')"
}
fc5_judge 30 2; _a="$FC_TALLY"; _arc="$RC"; _awk_a="$(fc_count awk)"
fc5_judge 30 10; _b="$FC_TALLY"; _brc="$RC"; _awk_b="$(fc_count awk)"
fc5_judge 300 10; _c="$FC_TALLY"; _crc="$RC"; _awk_c="$(fc_count awk)"
if [ "$_arc" = "91" ]; then
    fail "FC5 bin/lib/test-heavy-judge.sh missing (not implemented) — the judge's launches cannot be counted"
elif [ "$_arc" -eq 0 ] && [ "$_brc" -eq 0 ] && [ "$_crc" -eq 0 ] && [ "$_awk_a" = "1" ] && [ "$_awk_b" = "1" ] && [ "$_awk_c" = "1" ]; then
    pass "FC5 thj_judge launches awk exactly once for 2 and 10 queries over 30 and 300 rows"
else
    fail "FC5 thj_judge awk launches — rc=$_arc/$_brc/$_crc awk=$_awk_a/$_awk_b/$_awk_c"
fi
if [ "$_arc" -eq 0 ] && [ "$_a" = "$_b" ] && [ "$_b" = "$_c" ]; then
    pass "FC5 thj_judge launch counts independent of the query and row counts [$_a]"
else
    fail "FC5 thj_judge launch counts vary — q2=[$_a] q10=[$_b] rows300=[$_c] rc=$_arc/$_brc/$_crc"
fi
case_ran FC5

case_end

grp_done fork-count-cases.sh
