#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/cache-cases.sh — EQ1, C1-C13.
# The corpus cache must be invisible: every hit, miss, invalidation or failure
# path returns exactly what an uncached (FIND_TESTS_CORPUS_CACHE=off) run returns.

case_begin "corpus-cache" "bin/lib/test-corpus-cache.sh"

# cc_repo — a small committed corpus used by most cases. Echoes its root.
cc_repo() {
    local r
    r="$(mk_repo)"
    add_tf "$r" bin/a.sh "src/x.js,src/y.js"
    add_tf "$r" bin/b.sh "src/x.js"
    add_tf "$r" hooks/c.sh "src/common.js,src/x.js"
    add_tf "$r" skills/d.sh "src/z.js"
    commit_all "$r" "corpus"
    echo "$r"
}

# cc_run <repo> <cache> <mode:on|off> <args...> — run_ft from the neutral dir.
cc_run() {
    local repo="$1" cache="$2" mode="$3"; shift 3
    local -a extra=("RUN_ALL_CACHE_DIR=$cache" TEST_LANES_BUDGET=4)
    [ "$mode" = "off" ] && extra+=(FIND_TESTS_CORPUS_CACHE=off)
    run_ft "$NEUTRAL_DIR" "${extra[@]}" -- --root "$repo" "$@"
}

# ── EQ1 hit / miss / off are byte-identical ─────────────────────────────────
CC_R="$(cc_repo)"
QS=(--sources src/x.js --sources src/x.js,src/y.js --sources src/none.js)
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
fork_run "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C1C" TEST_LANES_BUDGET=4 -- --root "$CC_R" "${QS[@]}"
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

# ── C3 the parser libs are part of the key ──────────────────────────────────
C3L="$TMPDIR_BASE/c3-logic"
mkdir -p "$C3L"
for _b in test-route-destination.sh test-dup-group.sh test-frontmatter-fix.sh test-frontmatter-constants.sh test-corpus-cache.sh; do
    cp "$AGENTS_ROOT/bin/lib/$_b" "$C3L/$_b" 2>/dev/null || true
done
C3C="$TMPDIR_BASE/c3-cache"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3C" TEST_LANES_BUDGET=4 "TCC_LOGIC_DIR=$C3L" -- --root "$CC_R" "${QS[@]}"
_d1="$(cc_ndigests "$C3C")"
printf '#\n' >> "$C3L/test-corpus-cache.sh"
run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C3C" TEST_LANES_BUDGET=4 "TCC_LOGIC_DIR=$C3L" -- --root "$CC_R" "${QS[@]}"
_d2="$(cc_ndigests "$C3C")"
if [ "$_d1" = "1" ] && [ "$_d2" = "2" ]; then
    pass "C3 a one-byte change to a TCC_LOGIC_DIR lib changes the digest"
else
    fail "C3 lib change did not re-key the cache — digests before=$_d1 after=$_d2 (want 1 then 2)"
fi
case_ran C3

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
        fork_run "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C5C" TEST_LANES_BUDGET=4 -- --root "$CC_R" "${QS[@]}"
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

# ── C6 retention keeps the newest TCC_KEEP=16 by stamp ──────────────────────
C6C="$TMPDIR_BASE/c6-cache"
mkdir -p "$C6C/corpus"
for _i in $(seq -w 0 19); do
    printf '#trd-corpus\tschema=1\n#end\t0\n' > "$C6C/corpus/corpus.1.20200101T0000$_i.dddddddddddddd$_i.tsv"
done
cc_run "$CC_R" "$C6C" on "${QS[@]}"
assert_eq "C6 one write leaves exactly 16 cache files" "16" "$(cc_files "$C6C" | grep -c . || true)"
_gone=""; _kept=""
for _i in 00 01 02 03 04; do [ -e "$C6C/corpus/corpus.1.20200101T0000$_i.dddddddddddddd$_i.tsv" ] && _kept="$_kept $_i"; done
for _i in 05 10 19; do [ -e "$C6C/corpus/corpus.1.20200101T0000$_i.dddddddddddddd$_i.tsv" ] || _gone="$_gone $_i"; done
if [ -z "$_kept" ] && [ -z "$_gone" ]; then
    pass "C6 the five oldest stamps were pruned and the newer ones kept"
else
    fail "C6 wrong files pruned — oldest still present:[${_kept# }] newer missing:[${_gone# }]"
fi
case_ran C6

# ── C7 off never creates corpus/ ────────────────────────────────────────────
C7C="$TMPDIR_BASE/c7-cache"
cc_run "$CC_R" "$C7C" off "${QS[@]}"
if [ "$RC" -eq 0 ] && [ ! -e "$C7C/corpus" ]; then
    pass "C7 FIND_TESTS_CORPUS_CACHE=off creates no corpus/ directory"
else
    fail "C7 off run: rc=$RC corpus/ exists=$([ -e "$C7C/corpus" ] && echo yes || echo no)"
fi
case_ran C7

# ── C8 identical linked worktrees share one key ─────────────────────────────
C8R="$(cc_repo)"
git -C "$C8R" worktree add -q "$TMPDIR_BASE/c8-wt1" -b c8w1 >/dev/null 2>&1
git -C "$C8R" worktree add -q "$TMPDIR_BASE/c8-wt2" -b c8w2 >/dev/null 2>&1
C8C="$TMPDIR_BASE/c8-cache"
cc_run "$TMPDIR_BASE/c8-wt1" "$C8C" on "${QS[@]}"; _o1="$OUT"
fork_run "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C8C" TEST_LANES_BUDGET=4 -- --root "$TMPDIR_BASE/c8-wt2" "${QS[@]}"
if [ "$RC" -eq 0 ] && [ "$(cc_ndigests "$C8C")" = "1" ] && [ "$(fc_count awk)" = "0" ] && [ "$OUT" = "$_o1" ]; then
    pass "C8 the second worktree reuses the first worktree's digest and hits"
else
    fail "C8 worktree reuse — rc=$RC digests=$(cc_ndigests "$C8C") awk=$(fc_count awk) same-output=$([ "$OUT" = "$_o1" ] && echo yes || echo no)"
fi
case_ran C8

# ── C9 no HEAD yet / git failing ────────────────────────────────────────────
C9R="$(mk_repo)"
add_tf "$C9R" bin/a.sh "src/x.js"
add_tf "$C9R" bin/b.sh "src/x.js,src/y.js"
C9C="$TMPDIR_BASE/c9-cache"
cc_run "$C9R" "$C9C" off "${QS[@]}"; _off="$OUT"; _orc="$RC"
cc_run "$C9R" "$C9C" on "${QS[@]}"
if [ "$_orc" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$OUT" = "$_off" ] && [ "$(cc_ndigests "$C9C")" = "1" ]; then
    pass "C9 pre-commit repo: the key is built (one cache file) and the output is correct"
else
    fail "C9 pre-commit repo — rc=$_orc/$RC same-output=$([ "$OUT" = "$_off" ] && echo yes || echo no) digests=$(cc_ndigests "$C9C")"
fi
C9E="$(cc_repo)"
printf 'not an index' > "$C9E/.git/index"
C9EC="$TMPDIR_BASE/c9e-cache"
if git -C "$C9E" status --porcelain >/dev/null 2>&1; then
    fail "C9 fixture error: a corrupted .git/index did not make git status fail"
else
    cc_run "$C9E" "$C9EC" off "${QS[@]}"; _off="$OUT"; _orc="$RC"
    cc_run "$C9E" "$C9EC" on "${QS[@]}"
    if [ "$_orc" -eq 0 ] && [ -n "$_off" ] && [ "$RC" -eq 0 ] && [ "$OUT" = "$_off" ] && [ "$(cc_ndigests "$C9EC")" = "0" ]; then
        pass "C9 git error: the cache is skipped and the output equals the uncached run (rc=$RC)"
    else
        fail "C9 git error — rc=$_orc/$RC same-output=$([ "$OUT" = "$_off" ] && echo yes || echo no) digests=$(cc_ndigests "$C9EC")"
    fi
fi
case_ran C9

# ── C10 a relative RUN_ALL_CACHE_DIR resolves against the caller's cwd ──────
C10CWD="$TMPDIR_BASE/c10-cwd"
mkdir -p "$C10CWD"
run_ft "$C10CWD" RUN_ALL_CACHE_DIR=rel TEST_LANES_BUDGET=4 -- --root "$CC_R" "${QS[@]}"
if [ "$RC" -eq 0 ] && [ -d "$C10CWD/rel/corpus" ] && [ -d "$C10CWD/rel/slots" ] && [ ! -e "$CC_R/rel" ]; then
    pass "C10 corpus/ and slots/ land under <caller cwd>/rel, not under --root"
else
    fail "C10 relative cache root — rc=$RC cwd/rel/corpus=$([ -d "$C10CWD/rel/corpus" ] && echo yes || echo no) cwd/rel/slots=$([ -d "$C10CWD/rel/slots" ] && echo yes || echo no) root/rel=$([ -e "$CC_R/rel" ] && echo yes || echo no)"
fi
case_ran C10

# ── C11 a cache write that fails is silent and never changes the answer ─────
# Lanes are off so the only thing the cache root can break is the corpus write.
cc_run "$CC_R" "$TMPDIR_BASE/c11-off" off "${QS[@]}"; C11_OFF="$OUT"; C11_ORC="$RC"
# c11_check <label> <cache> — cached-mode run equals the uncached run.
c11_check() {
    run_ft "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$2" TEST_LANES=off -- --root "$CC_R" "${QS[@]}"
    if [ "$C11_ORC" -eq 0 ] && [ -n "$C11_OFF" ] && [ "$RC" -eq 0 ] && [ "$OUT" = "$C11_OFF" ]; then
        pass "C11 $1: the write failure is fail-soft (rc 0, uncached answer)"
    else
        fail "C11 $1: rc=$C11_ORC/$RC out=$(printf '%q' "$OUT") off=$(printf '%q' "$C11_OFF")"
    fi
}
C11F="$TMPDIR_BASE/c11-file"
mkdir -p "$C11F"; printf 'not a dir\n' > "$C11F/corpus"
c11_check "corpus/ is a regular file" "$C11F"
C11RO="$TMPDIR_BASE/c11-ro"
mkdir -p "$C11RO/corpus"; chmod 555 "$C11RO/corpus"
if touch "$C11RO/corpus/.probe" 2>/dev/null; then
    rm -f "$C11RO/corpus/.probe"
    skip "C11 read-only corpus/: chmod 555 does not block writes on this filesystem"
else
    c11_check "corpus/ is read-only" "$C11RO"
fi
chmod 755 "$C11RO/corpus"
case_ran C11

# ── C12 shell metacharacters in a cache row are data, never code ────────────
C12C="$TMPDIR_BASE/c12-cache"
C12M="$TMPDIR_BASE/c12-pwned"
cc_run "$CC_R" "$C12C" on "${QS[@]}"
C12_NAME="$(cc_files "$C12C" | head -n 1)"
if [ -n "$C12_NAME" ]; then
    cp "$C12C/corpus/$C12_NAME" "$TMPDIR_BASE/c12-good.tsv"
    for _pl in '$(touch '"$C12M"')' '`touch '"$C12M"'`'; do
        rm -f "$C12M"
        awk -F'\t' -v OFS='\t' -v pl="$_pl" 'NR == 2 { $3 = pl } { print }' "$TMPDIR_BASE/c12-good.tsv" > "$C12C/corpus/$C12_NAME"
        cc_run "$CC_R" "$C12C" on "${QS[@]}"
        assert_eq "C12 payload $(printf '%q' "$_pl"): find-tests exits 0" "0" "$RC"
        [ -e "$C12M" ] && fail "C12 payload $(printf '%q' "$_pl") was executed (marker created)" || pass "C12 payload $(printf '%q' "$_pl") was not executed"
    done
else
    fail "C12 no cache file was written, so row tampering is untestable (cache not implemented)"
fi
case_ran C12

# ── C13 a TAB or CR in a corpus path disables the write, never the answer ───
for _ck in TAB CR; do
    if [ "$_ck" = TAB ]; then _ch=$'\t'; else _ch=$'\r'; fi
    C13R="$(cc_repo)"
    _p="bin/c13${_ck}x${_ch}y.sh"
    add_tf "$C13R" "$_p" "src/x.js" 2>/dev/null
    if [ -f "$C13R/tests/$_p" ]; then
        C13C="$TMPDIR_BASE/c13-$_ck-cache"
        cc_run "$C13R" "$C13C" off "${QS[@]}"; _off="$OUT"; _orc="$RC"
        cc_run "$C13R" "$C13C" on "${QS[@]}"
        if [ "$_orc" -eq 0 ] && [ "$RC" -eq 0 ] && [ "$OUT" = "$_off" ]; then
            pass "C13 $_ck path: cached-mode output equals the uncached output"
        else
            fail "C13 $_ck path: output differs — rc=$_orc/$RC"
        fi
        assert_eq "C13 $_ck path: no cache file is written" "0" "$(cc_ndigests "$C13C")"
    else
        skip "C13 the filesystem rejects $_ck in file names"
    fi
done
case_ran C13

case_end

grp_done cache-cases.sh
