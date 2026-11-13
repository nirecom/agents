# P5B-1 through P5B-13 (#3013): run-phase5-record.sh records one title per manifest row, warns per fallback row,
# and removes the manifest only on --remove-manifest. Fixture: temp repo + linked worktree (--skip-if-main
# skips the main worktree, so the notes file lives in the linked one), core.hooksPath=/dev/null.
# Tests: skills/issue-create/scripts/run-phase5-record.sh
# Tags: issue-create, bulk-sub-of, phase5, worktree-notes, manifest, tests, scope:issue-specific
# Each case is a function; run_case backgrounds it (own subshell, so exports never leak).

# _p5_path <posix path> — Node needs a Windows-style path on Git Bash.
_p5_path() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }

# _p5_fixture — sets NOTES (abs path in a linked worktree on a feature branch).
_p5_fixture() {
    local main="$TMP/main" wt="$TMP/wt"
    git init -q "$main"
    git -C "$main" config core.hooksPath /dev/null
    git -C "$main" -c user.name=tester -c user.email=tester@example.com commit -q --allow-empty -m init
    git -C "$main" worktree add -q -b feature/p5 "$wt"
    NOTES="$(_p5_path "$wt")/WORKTREE_NOTES.md"
}

# _p5_urls <file> <n>... — dispatch stdout fixture, one URL per number.
_p5_urls() {
    local f="$1" n; shift
    : >"$f"
    for n in "$@"; do printf 'https://github.com/example/repo/issues/%s\n' "$n" >>"$f"; done
}

# _p5_run <id> <verdict> <manifest> <urls_file> [flags...] — sets RC, ERR.
_p5_run() {
    local id="$1" verdict="$2" manifest="$3" urls="$4"; shift 4
    ERR="$TMP/p5-$id-stderr.txt"
    RC=0
    run_with_timeout 60 bash "$PHASE5_SCRIPT" "$verdict" "$NOTES" "Phase1 title" "$manifest" --input-file "$urls" "$@" >"$TMP/p5-$id-stdout.txt" 2>"$ERR" || RC=$?
}

# _p5_entry <title> <n> — 0 when the notes hold "- <title> (#<n>)".
_p5_entry() { grep -qF -- "- $1 (#$2)" "$NOTES" 2>/dev/null; }

# _p5_warn_count — warning lines on stderr.
_p5_warn_count() { grep -ciE 'warning' "$ERR" 2>/dev/null || true; }

# _p5_warned <n> <reason> — 0 when one stderr warning line names issue #<n> and carries <reason>.
_p5_warned() { grep -F -- "warning: issue #$1:" "$ERR" 2>/dev/null | grep -qF -- "$2"; }

# _p5_unnamed <n>... — 0 when stderr names none of these issue numbers.
_p5_unnamed() { local n; for n in "$@"; do ! grep -qF -- "#$n" "$ERR" 2>/dev/null || return 1; done; }

_p5_manifest3() {
    printf 'Alpha\tBackground: a\\nChanges: a\n'  >  "$1"
    printf 'Beta\tBackground: b\\nChanges: b\n'   >> "$1"
    printf 'Gamma\tBackground: c\\nChanges: c\n'  >> "$1"
}

# P5B-1: 3-row manifest + 3 URLs → 3 entries, each with its own row title; no warning (the #3013 cause)
case_p5b_1() {
    local RC ERR NOTES M
    setup_mock; _p5_fixture
    M="$TMP/sidx-bulk-dispatch-100.tsv"; _p5_manifest3 "$M"
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 1 bulk-sub-of "$M" "$TMP/urls"
    if [[ "$RC" -eq 0 ]] && _p5_entry Alpha 301 && _p5_entry Beta 302 && _p5_entry Gamma 303 \
       && ! grep -qF 'Phase1 title' "$NOTES" && [[ "$(_p5_warn_count)" -eq 0 ]]; then
        pass "P5B-1: three entries recorded with three distinct row titles, no warning, exit 0"
    else
        fail "P5B-1: rc=$RC notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_1

# P5B-2: manifest absent → warning(s), every entry falls back to the Phase 1 title, exit 0
case_p5b_2() {
    local RC ERR NOTES
    setup_mock; _p5_fixture
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 2 bulk-sub-of "$TMP/sidx-bulk-dispatch-100.tsv" "$TMP/urls"
    if [[ "$RC" -eq 0 ]] && _p5_entry 'Phase1 title' 301 && _p5_entry 'Phase1 title' 302 \
       && _p5_entry 'Phase1 title' 303 && [[ "$(_p5_warn_count)" -ge 3 ]] \
       && _p5_warned 301 'manifest unreadable' && _p5_warned 302 'manifest unreadable' \
       && _p5_warned 303 'manifest unreadable'; then
        pass "P5B-2: missing manifest → per-row warnings ($(_p5_warn_count)), all entries use the Phase 1 title, exit 0"
    else
        fail "P5B-2: rc=$RC warnings=$(_p5_warn_count) notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_2

# P5B-3: manifest shorter than the URL list → only the missing row warns and falls back
case_p5b_3() {
    local RC ERR NOTES M
    setup_mock; _p5_fixture
    M="$TMP/sidx-bulk-dispatch-100.tsv"
    printf 'Alpha\tBackground: a\\nChanges: a\n' >  "$M"
    printf 'Beta\tBackground: b\\nChanges: b\n'  >> "$M"
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 3 bulk-sub-of "$M" "$TMP/urls"
    if [[ "$RC" -eq 0 ]] && _p5_entry Alpha 301 && _p5_entry Beta 302 && _p5_entry 'Phase1 title' 303 \
       && [[ "$(_p5_warn_count)" -eq 1 ]] \
       && _p5_warned 303 'manifest has no row 3' && _p5_unnamed 301 302; then
        pass "P5B-3: short manifest → exactly one warning, row 3 uses the Phase 1 title, rows 1-2 keep theirs"
    else
        fail "P5B-3: rc=$RC warnings=$(_p5_warn_count) notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_3

# P5B-4: a row with an empty title → only that row warns and falls back
case_p5b_4() {
    local RC ERR NOTES M
    setup_mock; _p5_fixture
    M="$TMP/sidx-bulk-dispatch-100.tsv"
    printf 'Alpha\tBackground: a\\nChanges: a\n'  >  "$M"
    printf '\tBackground: b\\nChanges: b\n'        >> "$M"
    printf 'Gamma\tBackground: c\\nChanges: c\n'   >> "$M"
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 4 bulk-sub-of "$M" "$TMP/urls"
    if [[ "$RC" -eq 0 ]] && _p5_entry Alpha 301 && _p5_entry 'Phase1 title' 302 && _p5_entry Gamma 303 \
       && [[ "$(_p5_warn_count)" -eq 1 ]] \
       && _p5_warned 302 'manifest row 2 has an empty title' && _p5_unnamed 301 303; then
        pass "P5B-4: empty-title row → one warning, that row uses the Phase 1 title, the others keep theirs"
    else
        fail "P5B-4: rc=$RC warnings=$(_p5_warn_count) notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_4

# P5B-5: script-level flag contract only — the script deletes a conforming manifest when the caller passes
# --remove-manifest; without the flag it stays. WHEN to pass the flag (dispatch exited 0) is the SKILL.md
# procedure's policy, pinned in section-scripts-existence.sh (IC-3013-6) and BMP-7, not decided here.
case_p5b_5() {
    local RC ERR NOTES M1 M2 gone kept
    setup_mock; _p5_fixture
    M1="$TMP/sidx-bulk-dispatch-100.tsv"; M2="$TMP/sidx-bulk-dispatch-200.tsv"
    _p5_manifest3 "$M1"; _p5_manifest3 "$M2"
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 5a bulk-sub-of "$M1" "$TMP/urls" --remove-manifest
    gone=0; [[ ! -e "$M1" ]] || gone=1
    local rc_a="$RC"
    _p5_run 5b bulk-sub-of "$M2" "$TMP/urls"
    kept=0; [[ -f "$M2" ]] || kept=1
    if [[ "$rc_a" -eq 0 ]] && [[ "$RC" -eq 0 ]] && [[ "$gone" -eq 0 ]] && [[ "$kept" -eq 0 ]] \
       && _p5_entry Alpha 301; then
        pass "P5B-5: script deletes the conforming manifest only when the caller passes the flag; no flag => kept"
    else
        fail "P5B-5: rc_a=$rc_a rc_b=$RC removed_with_flag_ok=$((1-gone)) kept_without_flag_ok=$((1-kept)) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_5

# P5B-6: a fallback warning in the run keeps the manifest even with the flag
case_p5b_6() {
    local RC ERR NOTES M
    setup_mock; _p5_fixture
    M="$TMP/sidx-bulk-dispatch-100.tsv"
    printf 'Alpha\tBackground: a\\nChanges: a\n' >"$M"
    _p5_urls "$TMP/urls" 301 302
    _p5_run 6 bulk-sub-of "$M" "$TMP/urls" --remove-manifest
    if [[ "$RC" -eq 0 ]] && [[ -f "$M" ]] && _p5_entry 'Phase1 title' 302 \
       && [[ "$(_p5_warn_count)" -ge 2 ]]; then
        pass "P5B-6: fallback warning in the run → manifest kept despite the flag, plus an extra warning line saying so"
    else
        fail "P5B-6: rc=$RC manifest_kept=$([[ -f "$M" ]] && echo y || echo n) warnings=$(_p5_warn_count) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_6

# P5B-7: a file whose name does not conform is never removed; warning, still exit 0
case_p5b_7() {
    local RC ERR NOTES M
    setup_mock; _p5_fixture
    M="$TMP/important-notes.tsv"; _p5_manifest3 "$M"
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 7 bulk-sub-of "$M" "$TMP/urls" --remove-manifest
    if [[ "$RC" -eq 0 ]] && [[ -f "$M" ]] && _p5_entry Alpha 301 && [[ "$(_p5_warn_count)" -ge 1 ]]; then
        pass "P5B-7: non-conforming name + flag → file kept, warning, exit 0"
    else
        fail "P5B-7: rc=$RC kept=$([[ -f "$M" ]] && echo y || echo n) warnings=$(_p5_warn_count) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_7

# P5B-8: non-bulk verdict with the flag records as before and removes nothing
case_p5b_8() {
    local RC ERR NOTES M
    setup_mock; _p5_fixture
    M="$TMP/sidx-bulk-dispatch-100.tsv"; _p5_manifest3 "$M"
    _p5_urls "$TMP/urls" 301
    _p5_run 8 sub-of "$M" "$TMP/urls" --remove-manifest
    if [[ "$RC" -eq 0 ]] && [[ -f "$M" ]] && _p5_entry 'Phase1 title' 301; then
        pass "P5B-8: non-bulk verdict + flag → entry recorded with the Phase 1 title, manifest untouched"
    else
        fail "P5B-8: rc=$RC kept=$([[ -f "$M" ]] && echo y || echo n) notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_8

# P5B-9: idempotency — re-running over the same URLs adds no duplicate entry
case_p5b_9() {
    local RC ERR NOTES M count
    setup_mock; _p5_fixture
    M="$TMP/sidx-bulk-dispatch-100.tsv"; _p5_manifest3 "$M"
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 9a bulk-sub-of "$M" "$TMP/urls"
    _p5_run 9b bulk-sub-of "$M" "$TMP/urls"
    count="$(grep -c 'promoted: #' "$NOTES" 2>/dev/null)" || true
    if [[ "$RC" -eq 0 ]] && [[ "$count" -eq 3 ]] && _p5_entry Gamma 303; then
        pass "P5B-9: second identical run keeps exactly 3 entries"
    else
        fail "P5B-9: rc=$RC entries=$count notes=$(cat "$NOTES" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_9

# P5B-10: deletion itself fails (rm stub on PATH exits 1) → warning, records still written with the row titles,
# manifest still on disk, exit 0. The stub logs each call, proving the delete path ran through rm.
case_p5b_10() {
    local RC ERR NOTES M stub rmlog
    setup_mock; _p5_fixture
    M="$TMP/sidx-bulk-dispatch-100.tsv"; _p5_manifest3 "$M"
    _p5_urls "$TMP/urls" 301 302 303
    stub="$TMP/rmstub"; rmlog="$TMP/rm-stub.log"; mkdir -p "$stub"; : >"$rmlog"
    printf '#!/bin/sh\necho "$@" >> "%s"\necho "rm: simulated failure" >&2\nexit 1\n' "$rmlog" >"$stub/rm"
    chmod +x "$stub/rm"
    PATH="$stub:$PATH" _p5_run 10 bulk-sub-of "$M" "$TMP/urls" --remove-manifest
    if [[ "$RC" -eq 0 ]] && [[ -f "$M" ]] && [[ -s "$rmlog" ]] \
       && _p5_entry Alpha 301 && _p5_entry Beta 302 && _p5_entry Gamma 303 \
       && grep -iE 'warning' "$ERR" | grep -qiE 'remov|delet|rm'; then
        pass "P5B-10: manifest deletion failure → warning, three row-title entries recorded, manifest kept, exit 0"
    else
        fail "P5B-10: rc=$RC kept=$([[ -f "$M" ]] && echo y || echo n) rm_calls=$(wc -l <"$rmlog" 2>/dev/null) notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_10

# P5B-11: notes append fails for every row (the notes path is a directory) → warning per row, manifest kept
# despite --remove-manifest and a keep-reason warning, exit 0.
case_p5b_11() {
    local RC ERR NOTES M
    setup_mock; _p5_fixture
    rm -rf -- "$NOTES"; mkdir -p "$NOTES"
    M="$TMP/sidx-bulk-dispatch-100.tsv"; _p5_manifest3 "$M"
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 11 bulk-sub-of "$M" "$TMP/urls" --remove-manifest
    if [[ "$RC" -eq 0 ]] && [[ -f "$M" ]] \
       && [[ "$(grep -c 'worktree-notes-append.js failed' "$ERR" 2>/dev/null)" -eq 3 ]] \
       && grep -qF 'manifest kept' "$ERR" && grep -qF 'failed to record' "$ERR"; then
        pass "P5B-11: append failure on every row → 3 warnings, manifest kept with a keep-reason warning, exit 0"
    else
        fail "P5B-11: rc=$RC kept=$([[ -f "$M" ]] && echo y || echo n) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_11

# P5B-12: bulk-sub-of with an EMPTY manifest argument → record skipped entirely, one stderr warning, exit 0, no entries
case_p5b_12() {
    local RC ERR NOTES count
    setup_mock; _p5_fixture
    _p5_urls "$TMP/urls" 301 302 303
    _p5_run 12 bulk-sub-of "" "$TMP/urls"
    count="$(grep -c 'promoted: #' "$NOTES" 2>/dev/null)" || true
    if [[ "$RC" -eq 0 ]] && grep -qF 'requires manifest path; skipping record' "$ERR" \
       && [[ "${count:-0}" -eq 0 ]] && ! grep -qF 'Phase1 title' "$NOTES" 2>/dev/null; then
        pass "P5B-12: empty manifest arg → warning 'requires manifest path; skipping record', exit 0, no entry written"
    else
        fail "P5B-12: rc=$RC entries=$count notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_12

# P5B-13: chained run, no hand-written manifest. run-bulk-dispatch.sh writes the manifest at the given path; the
# SAME path, unchanged, goes to run-phase5-record.sh --remove-manifest with the dispatch stdout as the URL list.
# Part a: clean chain → one entry per row title, no warning, manifest deleted.
# Part b: a second chain whose URL list is longer than the manifest (row 3 has no title) → fallback, manifest kept.
case_p5b_13() {
    local RC ERR NOTES M1 M2 stdin_f drc gone_a kept_b rc_a warns_a
    setup_mock; _p5_fixture
    export GH_MOCK_ISSUE_NUMS="601,602"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    M1="$TMP/sidx-bulk-dispatch-100.tsv"; M2="$TMP/sidx-bulk-dispatch-200.tsv"
    stdin_f="$TMP/stdin13.tsv"
    printf 'First child\tBackground: a\\nChanges: a\n'  >  "$stdin_f"
    printf 'Second child\tBackground: b\\nChanges: b\n' >> "$stdin_f"
    drc=0
    run_with_timeout 30 bash "$BULK_SCRIPT" "$M1" 100 <"$stdin_f" >"$TMP/p5-13a-dispatch.txt" 2>"$TMP/p5-13a-dispatch-err.txt" || drc=$?
    _p5_run 13a bulk-sub-of "$M1" "$TMP/p5-13a-dispatch.txt" --remove-manifest
    rc_a="$RC"; warns_a="$(_p5_warn_count)"
    gone_a=0; [[ ! -e "$M1" ]] || gone_a=1
    local ok_a=0
    if [[ "$drc" -eq 0 ]] && [[ "$rc_a" -eq 0 ]] && [[ "$gone_a" -eq 0 ]] && [[ "$warns_a" -eq 0 ]] \
       && _p5_entry 'First child' 601 && _p5_entry 'Second child' 602 \
       && ! grep -qF 'Phase1 title' "$NOTES"; then
        ok_a=1
    fi
    export GH_MOCK_ISSUE_NUMS="603,604"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor-b"
    drc=0
    run_with_timeout 30 bash "$BULK_SCRIPT" "$M2" 200 <"$stdin_f" >"$TMP/p5-13b-dispatch.txt" 2>"$TMP/p5-13b-dispatch-err.txt" || drc=$?
    printf 'https://github.com/example/repo/issues/605\n' >>"$TMP/p5-13b-dispatch.txt"
    _p5_run 13b bulk-sub-of "$M2" "$TMP/p5-13b-dispatch.txt" --remove-manifest
    kept_b=0; [[ -f "$M2" ]] || kept_b=1
    if [[ "$ok_a" -eq 1 ]] && [[ "$drc" -eq 0 ]] && [[ "$RC" -eq 0 ]] && [[ "$kept_b" -eq 0 ]] \
       && _p5_entry 'Phase1 title' 605 && _p5_warned 605 'manifest has no row 3'; then
        pass "P5B-13: chained dispatch→record uses the manifest unchanged: row titles recorded, manifest removed; fallback run keeps it"
    else
        fail "P5B-13: ok_a=$ok_a drc=$drc rc_a=$rc_a warns_a=$warns_a gone_a=$((1-gone_a)) rc_b=$RC kept_b=$((1-kept_b)) notes=$(cat "$NOTES" 2>/dev/null) stderr=$(cat "$ERR" 2>/dev/null)"
    fi
    teardown_mock
}
run_case case_p5b_13
