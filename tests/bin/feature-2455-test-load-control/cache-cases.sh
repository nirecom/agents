#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/cache-cases.sh — EQ1, C1, C2.
# The corpus cache must be invisible: every hit, miss, invalidation or failure
# path returns exactly what an uncached (FIND_TESTS_CORPUS_CACHE=off) run returns.
# C3-C5 live in cache-rekey-cases.sh and C6-C13 in cache-fail-soft-cases.sh.
# Relies on _cache-fixture.sh (cc_repo, cc_run, CC_R, QS).

case_begin "corpus-cache" "bin/lib/test-corpus-cache.sh"

# ── EQ1 hit / miss / off are byte-identical ─────────────────────────────────
QT=(--test-file tests/bin/a.sh --test-file tests/hooks/c.sh --test-file tests/bin/missing.sh)
for _set in QS QT; do
    eval "_q=(\"\${${_set}[@]}\")"
    _cache="$TMPDIR_BASE/eq1-$_set"
    cc_run "$CC_R" "$_cache" off "${_q[@]}"; _off="$OUT"; _orc="$RC"
    cc_run "$CC_R" "$_cache" on "${_q[@]}"; _miss="$OUT"; _mrc="$RC"
    cc_run "$CC_R" "$_cache" on "${_q[@]}"; _hit="$OUT"; _hrc="$RC"
    if [ "$_orc$_mrc$_hrc" = "000" ] && [ -n "$_off" ] && [ "$_off" = "$_miss" ] && [ "$_off" = "$_hit" ]; then
        pass "EQ1 $_set: off, miss and hit print the same bytes"
    else
        fail "EQ1 $_set: outputs differ — rc=$_orc/$_mrc/$_hrc off=$(printf '%q' "$_off") miss=$(printf '%q' "$_miss") hit=$(printf '%q' "$_hit")"
    fi
done
case_ran EQ1

# ── C1 first run writes one file, second run hits ───────────────────────────
C1C="$TMPDIR_BASE/c1-cache"
cc_run "$CC_R" "$C1C" on "${QS[@]}"
_files="$(cc_files "$C1C")"
_n="$(printf '%s' "$_files" | grep -c . || true)"
assert_eq "C1 the first run writes exactly one corpus.1.<stamp>.<digest>.tsv" "1" "$_n"
if [ "$_n" = "1" ] && cc_valid "$C1C/corpus/$_files" \
    && [[ "$_files" =~ ^corpus\.1\.[0-9T]+\.[A-Za-z0-9]+\.tsv$ ]]; then
    pass "C1 the cache file name and schema-1 content are well formed ($_files)"
else
    fail "C1 cache file missing or malformed: [$_files]"
fi
cc_run "$CC_R" "$TMPDIR_BASE/c1-off" off "${QS[@]}"; C1_OFF="$OUT"
fork_run "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C1C" TEST_MAX_JOBS_PER_HOST=4 -- --root "$CC_R" "${QS[@]}"
assert_eq "C1 the second run is a hit (awk launched 0 times)" "0" "$(fc_count awk)"
assert_eq "C1 the hit run exits 0" "0" "$RC"
if [ -n "$C1_OFF" ] && [ "$OUT" = "$C1_OFF" ]; then
    pass "C1 the hit run prints the uncached answer"
else
    fail "C1 hit output differs from the uncached run — hit=$(printf '%q' "$OUT") off=$(printf '%q' "$C1_OFF")"
fi
case_ran C1

# ── C2 every corpus-affecting change invalidates ────────────────────────────
C2R="$(mk_repo)"
printf 'tests/bin/ign*.sh\n' > "$C2R/.gitignore"
add_tf "$C2R" bin/t1.sh "src/x.js"
add_tf "$C2R" bin/t2.sh "src/x.js,src/y.js"
add_tf "$C2R" bin/t3.sh "src/z.js"
commit_all "$C2R" "base"
C2C="$TMPDIR_BASE/c2-cache"
C2Q=(--sources src/x.js --sources src/n1.js --sources src/changed.js --sources src/i.js)
cc_run "$C2R" "$C2C" on "${C2Q[@]}"

# c2_step <label> — after a mutation: output equals off, and exactly one new digest.
c2_step() {
    local label="$1" before after off orc
    before="$(cc_ndigests "$C2C")"
    cc_run "$C2R" "$C2C" off "${C2Q[@]}"; off="$OUT"; orc="$RC"
    cc_run "$C2R" "$C2C" on "${C2Q[@]}"
    if [ "$orc" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$OUT" = "$off" ]; then
        pass "C2 $label: cached output equals the uncached output"
    else
        fail "C2 $label: cached output differs — rc=$orc/$RC off=$(printf '%q' "$off") on=$(printf '%q' "$OUT")"
    fi
    after="$(cc_ndigests "$C2C")"
    assert_eq "C2 $label: the key changed (a new digest was written)" "$((before + 1))" "$after"
}
add_tf "$C2R" bin/new1.sh "src/n1.js"; git -C "$C2R" add tests/bin/new1.sh
c2_step "staged new test"
add_tf "$C2R" bin/t1.sh "src/x.js,src/changed.js"
c2_step "unstaged header change"
add_tf "$C2R" bin/t1.sh "src/x.js,src/changed2.js"
c2_step "M->M content-only change (status letters unchanged)"
add_tf "$C2R" bin/untr.sh "src/u.js"
c2_step "untracked new file"
rm -f "$C2R/tests/bin/t2.sh"
c2_step "deleted test file"
add_tf "$C2R" bin/ign1.sh "src/i.js"
if git -C "$C2R" check-ignore -q tests/bin/ign1.sh; then
    c2_step "ignored file"
else
    fail "C2 ignored file: fixture error — tests/bin/ign1.sh is not ignored"
fi
commit_all "$C2R" "advance HEAD:tests"
c2_step "commit moved HEAD:tests"
case_ran C2

case_end

grp_done cache-cases.sh
