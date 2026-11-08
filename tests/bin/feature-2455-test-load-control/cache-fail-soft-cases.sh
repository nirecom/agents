#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/cache-fail-soft-cases.sh — C6-C13.
# Retention, off mode, worktree sharing, git failure, a relative cache root, a failing write,
# hostile rows and TAB/CR paths. Split from cache-cases.sh so the parts run as separate
# run-all entries. Relies on _cache-fixture.sh (cc_repo, cc_run, CC_R, QS).

case_begin "corpus-cache-fail-soft" "bin/lib/test-corpus-cache.sh"

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
fork_run "$NEUTRAL_DIR" "RUN_ALL_CACHE_DIR=$C8C" TEST_MAX_JOBS_PER_HOST=4 -- --root "$TMPDIR_BASE/c8-wt2" "${QS[@]}"
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
run_ft "$C10CWD" RUN_ALL_CACHE_DIR=rel TEST_MAX_JOBS_PER_HOST=4 -- --root "$CC_R" "${QS[@]}"
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

grp_done cache-fail-soft-cases.sh
