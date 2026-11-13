# BMP-1 through BMP-8 (#3013): run-bulk-dispatch.sh takes the manifest path as arg 1.
# Tests: skills/issue-create/scripts/run-bulk-dispatch.sh
# Tags: issue-create, bulk-sub-of, manifest, stdin, tests, scope:issue-specific
# Each case is a function; run_case backgrounds it (own subshell, so exports never leak).

# _bmp_run <id> <manifest_path> <stdin_file> [parent_n=100] — runs run-bulk-dispatch.sh <manifest_path> <parent_n>
# with stdin from a file; sets RC, OUT, ERR.
_bmp_run() {
    OUT="$TMP/bmp-$1-stdout.txt"
    ERR="$TMP/bmp-$1-stderr.txt"
    RC=0
    run_with_timeout 30 bash "$BULK_SCRIPT" "$2" "${4:-100}" <"$3" >"$OUT" 2>"$ERR" || RC=$?
}

# _bmp_two_rows <file> — the canonical 2-row TSV used as stdin.
_bmp_two_rows() {
    printf 'First child\tBackground: a\\nChanges: a\n'  >  "$1"
    printf 'Second child\tBackground: b\\nChanges: b\n' >> "$1"
}

# BMP-1: normal — manifest at the given path equals stdin; stdout is URLs only, manifest order
case_bmp_1() {
    local RC OUT ERR MANIFEST STDIN_F BAD_LINES ORDER
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/sidx-bulk-dispatch-100.tsv"
    STDIN_F="$TMP/stdin.tsv"
    _bmp_two_rows "$STDIN_F"
    _bmp_run 1 "$MANIFEST" "$STDIN_F"
    BAD_LINES="$(tr -d '\r' <"$OUT" | grep -vcE '^https://github.com/.+/issues/[0-9]+$')" || true
    ORDER="$(tr -d '\r' <"$OUT" | grep -oE '[0-9]+$' | paste -sd, -)" || true
    if [[ "$RC" -eq 0 ]] && [[ -f "$MANIFEST" ]] && diff -q "$STDIN_F" "$MANIFEST" >/dev/null 2>&1 \
       && [[ "$BAD_LINES" -eq 0 ]] && [[ "$ORDER" == "300,301" ]] \
       && ! grep -qiE 'overwrit|replac' "$ERR"; then
        pass "BMP-1: manifest written at arg 1 equals stdin, stdout URLs only (300,301), no overwrite warning"
    else
        fail "BMP-1: rc=$RC manifest_exists=$([[ -f "$MANIFEST" ]] && echo y || echo n) bad_stdout_lines=$BAD_LINES order='$ORDER' stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_bmp_1

# _bmp_early_reject <id> <label> <path> — usage error (exit 2) must land before stdin is read:
# stdin is a pipe that stays open for 8 s, so a script that reads it first cannot finish in 5 s.
_bmp_early_reject() {
    local started elapsed rc=0
    started=$SECONDS
    run_with_timeout 30 bash "$BULK_SCRIPT" "$3" 100 < <(sleep 8) >"$TMP/bmp-$1-out.txt" 2>"$TMP/bmp-$1-err.txt" || rc=$?
    elapsed=$((SECONDS - started))
    # Nothing may be written and the dispatcher mock (gh) must never run: a script that writes the invalid
    # path (or starts dispatching) before exiting 2 is wrong.
    local created=0 gh_calls=0
    if [[ -d "$3" ]]; then
        [[ -z "$(ls -A "$3" 2>/dev/null)" ]] || created=1
    elif [[ -n "$3" ]]; then
        [[ ! -e "$3" ]] || created=1
    fi
    [[ ! -s "$GH_MOCK_ARGS_LOG" ]] || gh_calls=1
    if [[ "$rc" -eq 2 ]] && [[ "$elapsed" -lt 5 ]] && [[ "$created" -eq 0 ]] && [[ "$gh_calls" -eq 0 ]]; then
        pass "BMP-$1: $2 → exit 2 before stdin is read (${elapsed}s), nothing created, dispatcher not called"
    else
        fail "BMP-$1: $2 should exit 2 within 5s with nothing created and no dispatcher call, got rc=$rc elapsed=${elapsed}s created=$created gh_calls=$gh_calls"
    fi
}

# BMP-2: arg 1 is an existing directory (the pre-#3013 call form)
case_bmp_2() {
    setup_mock
    mkdir -p "$TMP/plans"
    _bmp_early_reject 2 "directory as arg 1" "$TMP/plans"
    teardown_mock
}
run_case case_bmp_2

# BMP-3: parent directory of the manifest path does not exist
case_bmp_3() {
    setup_mock
    _bmp_early_reject 3 "missing parent directory" "$TMP/no-such-dir/sidx-bulk-dispatch-100.tsv"
    if [[ ! -e "$TMP/no-such-dir" ]]; then
        pass "BMP-3b: the missing parent directory was not created"
    else
        fail "BMP-3b: the missing parent directory was created by the script"
    fi
    teardown_mock
}
run_case case_bmp_3

# BMP-4: file name does not match *-bulk-dispatch-*.tsv
case_bmp_4() {
    setup_mock
    _bmp_early_reject 4 "name outside the pattern" "$TMP/manifest.tsv"
    teardown_mock
}
run_case case_bmp_4

# BMP-5: empty arg 1
case_bmp_5() {
    setup_mock
    _bmp_early_reject 5 "empty path" ""
    teardown_mock
}
run_case case_bmp_5

# BMP-6: an existing manifest at the path is replaced, with a stderr warning; stdout stays URLs only
case_bmp_6() {
    local RC OUT ERR MANIFEST STDIN_F BAD_LINES ORDER
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    MANIFEST="$TMP/sidx-bulk-dispatch-100.tsv"
    STDIN_F="$TMP/stdin.tsv"
    printf 'OLD title\told body\n' >"$MANIFEST"
    _bmp_two_rows "$STDIN_F"
    _bmp_run 6 "$MANIFEST" "$STDIN_F"
    BAD_LINES="$(tr -d '\r' <"$OUT" | grep -vcE '^https://github.com/.+/issues/[0-9]+$')" || true
    ORDER="$(tr -d '\r' <"$OUT" | grep -oE '[0-9]+$' | paste -sd, -)" || true
    if [[ "$RC" -eq 0 ]] && diff -q "$STDIN_F" "$MANIFEST" >/dev/null 2>&1 \
       && ! grep -q 'OLD title' "$MANIFEST" \
       && grep -qiE 'overwrit|replac' "$ERR" \
       && [[ "$BAD_LINES" -eq 0 ]] && [[ "$ORDER" == "300,301" ]]; then
        pass "BMP-6: existing manifest replaced by new stdin, overwrite warning on stderr, stdout URLs only (300,301)"
    else
        fail "BMP-6: rc=$RC bad_stdout_lines=$BAD_LINES order='$ORDER' manifest=$(cat "$MANIFEST" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_bmp_6

# BMP-7: partial failure (2nd attach fails) → non-zero exit and the manifest is kept for retry
case_bmp_7() {
    local RC OUT ERR MANIFEST STDIN_F
    setup_mock
    export GH_MOCK_ISSUE_NUMS="400,401"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    export GH_MOCK_SUBISSUE_FAIL_FROM=2
    export GH_MOCK_SUBISSUE_CURSOR="$TMP/subissue-cursor"
    MANIFEST="$TMP/sidx-bulk-dispatch-100.tsv"
    STDIN_F="$TMP/stdin.tsv"
    _bmp_two_rows "$STDIN_F"
    _bmp_run 7 "$MANIFEST" "$STDIN_F"
    local rc1="$RC" kept=0
    # The non-zero exit is the signal the SKILL.md procedure uses to withhold --remove-manifest, so the manifest
    # must be on disk afterwards with the stdin content. It is not a whole-manifest retry input: re-running it
    # would duplicate the rows already created.
    [[ -f "$MANIFEST" ]] && diff -q "$STDIN_F" "$MANIFEST" >/dev/null 2>&1 && kept=1
    # The first row was created and attached before the failure, so its URL must still be on stdout.
    local first_url=0
    tr -d '\r' <"$OUT" | grep -qE '^https://github.com/.+/issues/400$' && first_url=1
    if [[ "$rc1" -ne 0 ]] && [[ "$kept" -eq 1 ]] && [[ "$first_url" -eq 1 ]]; then
        pass "BMP-7: partial failure → non-zero exit (rc=$rc1), manifest kept with stdin content, first URL on stdout"
    else
        fail "BMP-7: rc=$rc1 manifest_kept=$kept stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_bmp_7

# BMP-8: two parents in one plans dir never share a manifest path (parent N is part of the name)
case_bmp_8() {
    local RC OUT ERR STDIN_F M100 M200
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    M100="$TMP/sidx-bulk-dispatch-100.tsv"
    M200="$TMP/sidx-bulk-dispatch-200.tsv"
    STDIN_F="$TMP/stdin.tsv"
    _bmp_two_rows "$STDIN_F"
    _bmp_run 8a "$M100" "$STDIN_F"
    printf 'Other parent child\tBackground: z\\nChanges: z\n' >"$TMP/stdin2.tsv"
    export GH_MOCK_ISSUE_NUMS="302"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor2"
    : >"$GH_MOCK_ARGS_LOG"
    _bmp_run 8b "$M200" "$TMP/stdin2.tsv" 200
    if [[ "$RC" -eq 0 ]] && diff -q "$STDIN_F" "$M100" >/dev/null 2>&1 \
       && grep -q 'Other parent child' "$M200" && ! grep -q 'Other parent child' "$M100" \
       && grep -qE '(^|[^0-9])200([^0-9]|$)' "$GH_MOCK_ARGS_LOG" && ! grep -qE '(^|[^0-9])100([^0-9]|$)' "$GH_MOCK_ARGS_LOG" \
       && ! grep -qiE 'overwrit|replac' "$ERR"; then
        pass "BMP-8: distinct parent N → distinct manifests, first one untouched, no overwrite warning"
    else
        fail "BMP-8: rc=$RC stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_bmp_8

# BMP-9: file-name boundary table for *-bulk-dispatch-*.tsv — "accept|<name>" must dispatch (exit 0, manifest
# created), "reject|<name>" must exit 2 with nothing created. Names stay in $TMP so the parent dir exists.
case_bmp_9() {
    local verdict name rc made bad=0 n=0 stdin_f
    setup_mock
    stdin_f="$TMP/stdin9.tsv"
    printf 'Only child\tBackground: a\\nChanges: a\n' >"$stdin_f"
    while IFS='|' read -r verdict name; do
        [[ -n "$verdict" ]] || continue
        n=$((n + 1))
        export GH_MOCK_ISSUE_NUMS="$((500 + n))"
        export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor-$n"
        rc=0
        run_with_timeout 30 bash "$BULK_SCRIPT" "$TMP/$name" 100 <"$stdin_f" >"$TMP/bmp-9-$n-out.txt" 2>"$TMP/bmp-9-$n-err.txt" || rc=$?
        made=0; [[ -e "$TMP/$name" ]] && made=1
        if [[ "$verdict" == accept && ( "$rc" -ne 0 || "$made" -ne 1 ) ]]; then
            bad=$((bad + 1)); echo "BMP-9: '$name' should be accepted, got rc=$rc created=$made" >&2
        elif [[ "$verdict" == reject && ( "$rc" -ne 2 || "$made" -ne 0 ) ]]; then
            bad=$((bad + 1)); echo "BMP-9: '$name' should be rejected, got rc=$rc created=$made" >&2
        fi
    done <<'TABLE'
accept|sidx-bulk-dispatch-100.tsv
accept|a-bulk-dispatch-x.tsv
reject|bulk-dispatch-100.tsv
reject|sidx-bulk-dispatch-100.txt
reject|sidx-bulk-dispatch-100.tsv.bak
reject|sidx-bulk_dispatch-100.tsv
reject|sidx-bulkdispatch-100.tsv
TABLE
    if [[ "$bad" -eq 0 && "$n" -eq 7 ]]; then
        pass "BMP-9: $n file-name boundary cases behave as tabulated (accept/reject)"
    else
        fail "BMP-9: $bad of $n boundary cases misbehaved"
    fi
    teardown_mock
}
run_case case_bmp_9

# BMP-10: a manifest path whose directory contains a space is passed through intact (argument quoting)
case_bmp_10() {
    local RC OUT ERR MANIFEST STDIN_F BAD_LINES ORDER
    setup_mock
    export GH_MOCK_ISSUE_NUMS="300,301"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    mkdir -p "$TMP/plans dir"
    MANIFEST="$TMP/plans dir/sidx-bulk-dispatch-100.tsv"
    STDIN_F="$TMP/stdin.tsv"
    _bmp_two_rows "$STDIN_F"
    _bmp_run 10 "$MANIFEST" "$STDIN_F"
    BAD_LINES="$(tr -d '\r' <"$OUT" | grep -vcE '^https://github.com/.+/issues/[0-9]+$')" || true
    ORDER="$(tr -d '\r' <"$OUT" | grep -oE '[0-9]+$' | paste -sd, -)" || true
    if [[ "$RC" -eq 0 ]] && diff -q "$STDIN_F" "$MANIFEST" >/dev/null 2>&1 \
       && [[ "$BAD_LINES" -eq 0 ]] && [[ "$ORDER" == "300,301" ]]; then
        pass "BMP-10: manifest dir with a space → written intact at the given path, URLs 300,301"
    else
        fail "BMP-10: rc=$RC bad_stdout_lines=$BAD_LINES order='$ORDER' stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_bmp_10
