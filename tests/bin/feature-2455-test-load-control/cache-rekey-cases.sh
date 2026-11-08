#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/cache-rekey-cases.sh — C3, C3b, C4, C5.
# The parser libs and the registry are part of the key, an LF path disables the write, and a
# damaged cache file is a miss that is regenerated. Split from cache-cases.sh so the parts
# run as separate run-all entries. Relies on _cache-fixture.sh (cc_repo, cc_run, CC_R, QS).

case_begin "corpus-cache-rekey" "bin/lib/test-corpus-cache.sh"

# ── C3 the parser libs are part of the key ──────────────────────────────────
C3L="$TMPDIR_BASE/c3-logic"
mkdir -p "$C3L"
for _b in test-route-destination.sh test-dup-group.sh test-frontmatter-fix.sh test-frontmatter-constants.sh test-corpus-cache.sh test-language-registry.sh; do
    cp "$AGENTS_ROOT/bin/lib/$_b" "$C3L/$_b" 2>/dev/null || true
done
C3C="$TMPDIR_BASE/c3-cache"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3C" TEST_MAX_JOBS_PER_HOST=4 "TCC_LOGIC_DIR=$C3L" -- --root "$CC_R" "${QS[@]}"
_d1="$(cc_ndigests "$C3C")"
printf '#\n' >> "$C3L/test-corpus-cache.sh"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3C" TEST_MAX_JOBS_PER_HOST=4 "TCC_LOGIC_DIR=$C3L" -- --root "$CC_R" "${QS[@]}"
_d2="$(cc_ndigests "$C3C")"
if [ "$_d1" = "1" ] && [ "$_d2" = "2" ]; then
    pass "C3 a one-byte change to a TCC_LOGIC_DIR lib changes the digest"
else
    fail "C3 lib change did not re-key the cache — digests before=$_d1 after=$_d2 (want 1 then 2)"
fi
case_ran C3

# ── C3b the registry table and its reader are part of the key ──────────────
C3G="$TMPDIR_BASE/c3-registry"
mkdir -p "$C3G"
for _b in test-language-registry.json test-language-registry.js; do
    cp "$AGENTS_ROOT/hooks/lib/$_b" "$C3G/$_b" 2>/dev/null || true
done
C3GC="$TMPDIR_BASE/c3g-cache"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3GC" TEST_LANES_BUDGET=4 "TCC_REGISTRY_DIR=$C3G" -- --root "$CC_R" "${QS[@]}"
_g1="$(cc_ndigests "$C3GC")"; _go1="$OUT"
printf ' ' >> "$C3G/test-language-registry.json"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3GC" TEST_LANES_BUDGET=4 "TCC_REGISTRY_DIR=$C3G" -- --root "$CC_R" "${QS[@]}"
_g2="$(cc_ndigests "$C3GC")"
if [ -f "$C3G/test-language-registry.json" ] && [ "$_g1" = "1" ] && [ "$_g2" = "2" ]; then
    pass "C3b a one-byte change to the TCC_REGISTRY_DIR table changes the digest"
else
    fail "C3b registry change did not re-key the cache — digests before=$_g1 after=$_g2 (want 1 then 2)"
fi
# Only the reader changes now (the table stays as the previous run left it).
printf '\n' >> "$C3G/test-language-registry.js"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3GC" TEST_LANES_BUDGET=4 "TCC_REGISTRY_DIR=$C3G" -- --root "$CC_R" "${QS[@]}"
_g3="$(cc_ndigests "$C3GC")"
if [ -f "$C3G/test-language-registry.js" ] && [ "$_g2" = "2" ] && [ "$_g3" = "3" ]; then
    pass "C3b a one-byte change to the TCC_REGISTRY_DIR reader alone changes the digest"
else
    fail "C3b reader change did not re-key the cache — digests before=$_g2 after=$_g3 (want 2 then 3)"
fi
# The same reader again: a cache hit (no awk launched, no new digest) with the very same selection.
_go3="$OUT"
fork_run "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3GC" TEST_LANES_BUDGET=4 "TCC_REGISTRY_DIR=$C3G" -- --root "$CC_R" "${QS[@]}"
assert_eq "C3b the repeat run is a hit (awk 0)" "0" "$(fc_count awk)"
_g4="$(cc_ndigests "$C3GC")"
if [ "$RC" -eq 0 ] && [ "$_g3" = "3" ] && [ "$_g4" = "3" ] && [ -n "$OUT" ] && [ "$OUT" = "$_go3" ] && [ "$OUT" = "$_go1" ]; then
    pass "C3b a repeat run with the same reader hits the cache and selects byte-identically"
else
    fail "C3b repeat run with the same reader — rc=$RC digests=$_g3 then $_g4 (want 3 then 3) same-as-reader-run=$([ "$OUT" = "$_go3" ] && echo yes || echo no) same-as-first-run=$([ "$OUT" = "$_go1" ] && echo yes || echo no) empty=$([ -z "$OUT" ] && echo yes || echo no)"
fi
case_ran C3b

# ── C4 an LF in a corpus path disables the write, never the answer ──────────
C4R="$(cc_repo)"
_lf="bin/n"$'\n'"l.sh"
add_tf "$C4R" "$_lf" "src/x.js" 2>/dev/null
if [ -f "$C4R/tests/$_lf" ]; then
    C4C="$TMPDIR_BASE/c4-cache"
    cc_run "$C4R" "$C4C" off "${QS[@]}"; _off="$OUT"; _orc="$RC"
    cc_run "$C4R" "$C4C" on "${QS[@]}"
    if [ "$_orc" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$OUT" = "$_off" ]; then
        pass "C4 LF path: cached-mode output equals the uncached output"
    else
        fail "C4 LF path: output differs — rc=$_orc/$RC"
    fi
    assert_eq "C4 LF path: no cache file is written" "0" "$(cc_ndigests "$C4C")"
else
    skip "C4 the filesystem rejects LF in file names (expected on Windows)"
fi
case_ran C4

# ── C5 a damaged cache file is a miss, is regenerated, and is then a hit ────
C5C="$TMPDIR_BASE/c5-cache"
cc_run "$CC_R" "$C5C" off "${QS[@]}"; C5_OFF="$OUT"
cc_run "$CC_R" "$C5C" on "${QS[@]}"
C5_NAME="$(cc_files "$C5C" | head -n 1)"
if [ -n "$C5_NAME" ]; then
    cp "$C5C/corpus/$C5_NAME" "$TMPDIR_BASE/c5-good.tsv"
    for _kind in bad-header end-count ntok-mismatch truncated; do
        rm -f "$C5C"/corpus/corpus.*
        _dst="$C5C/corpus/$C5_NAME"
        case "$_kind" in
            bad-header)    awk 'NR == 1 { print "#trd-corpus\tschema=9"; next } { print }' "$TMPDIR_BASE/c5-good.tsv" > "$_dst" ;;
            end-count)     awk -F'\t' -v OFS='\t' '$1 == "#end" { $2 = $2 + 7 } { print }' "$TMPDIR_BASE/c5-good.tsv" > "$_dst" ;;
            ntok-mismatch) awk -F'\t' -v OFS='\t' 'NR == 2 { $1 = $1 + 1 } { print }' "$TMPDIR_BASE/c5-good.tsv" > "$_dst" ;;
            truncated)     head -n 2 "$TMPDIR_BASE/c5-good.tsv" > "$_dst" ;;
        esac
        cc_run "$CC_R" "$C5C" on "${QS[@]}"
        if [ "$RC" -eq 0 ] && [ "$OUT" = "$C5_OFF" ]; then
            pass "C5 $_kind: output equals the uncached output"
        else
            fail "C5 $_kind: damaged cache leaked into the answer — rc=$RC out=$(printf '%q' "$OUT")"
        fi
        _last="$(cc_files "$C5C" | tail -n 1)"
        if [ -n "$_last" ] && cc_valid "$C5C/corpus/$_last"; then
            pass "C5 $_kind: the cache file was regenerated in the valid format"
        else
            fail "C5 $_kind: no valid cache file after the run [$_last]"
        fi
        fork_run "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C5C" TEST_MAX_JOBS_PER_HOST=4 -- --root "$CC_R" "${QS[@]}"
        assert_eq "C5 $_kind: the next run is a hit (awk 0)" "0" "$(fc_count awk)"
        if [ "$RC" -eq 0 ] && [ "$OUT" = "$C5_OFF" ]; then
            pass "C5 $_kind: the hit run exits 0 with the uncached answer"
        else
            fail "C5 $_kind: hit run rc=$RC or output differs from the uncached run"
        fi
    done
else
    for _kind in bad-header end-count ntok-mismatch truncated; do
        fail "C5 $_kind: no cache file was written, so corruption is untestable (cache not implemented)"
    done
fi
case_ran C5

case_end

grp_done cache-rekey-cases.sh
