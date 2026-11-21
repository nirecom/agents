#!/usr/bin/env bash
# tests/bin/feature-530-notes-promotion-triage-flow/promotion-loop.sh
# Tests: bin/worktree-notes-triage.js, skills/_shared/notes-promotion.md
# Tags: notes-promotion, worktree-notes, triage, issue-create, idempotency, filesystem-errors, TL2, scope:issue-specific
# L: list groups by the #2019 rule table; only autoHigh and the user-picked finalList entries are filed;
#    declined finalList entries are disposed as discard, overflow entries stay unmarked.
# I: annotate idempotency (NP-7 retry safety). E: a failed annotation leaves the file
#    byte-identical with no temp files.
# The test plays the agent against a stub `issue-create` on PATH; assertions are
# content-derived (markers carry the numbers the stub returned, in list order).

# isolation (#2512): pin state and plans dirs once for this file
_ISOLATION_TMP_ROOT="$(mktemp -d)"; readonly _ISOLATION_TMP_ROOT
mkdir -p "$_ISOLATION_TMP_ROOT/workflow-state" "$_ISOLATION_TMP_ROOT/plans"
export WORKFLOW_STATE_DIR="$_ISOLATION_TMP_ROOT/workflow-state" WORKFLOW_PLANS_DIR="$_ISOLATION_TMP_ROOT/plans"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# --------------------------------------------------------------------------
# Stub /issue-create: a real executable on PATH that allocates issue numbers and
# records, in order, the entry text it was asked to file.
# --------------------------------------------------------------------------
STUB_DIR="$TMPD/stub-bin"
mkdir -p "$STUB_DIR"
STUB_LOG="$TMPD/issue-create.log"
STUB_SEQ="$TMPD/issue-create.seq"
cat > "$STUB_DIR/issue-create" <<'STUB'
#!/usr/bin/env bash
# Stand-in for the /issue-create skill: echoes the number it "created" and logs
# the title it was handed, one line per invocation.
n=$(( $(cat "$ISSUE_SEQ_FILE" 2>/dev/null || echo 4000) + 1 ))
printf '%s' "$n" > "$ISSUE_SEQ_FILE"
printf '%s\t%s\n' "$n" "$*" >> "$ISSUE_LOG_FILE"
printf '%s\n' "$n"
STUB
chmod +x "$STUB_DIR/issue-create"
export PATH="$STUB_DIR:$PATH"
export ISSUE_LOG_FILE="$STUB_LOG" ISSUE_SEQ_FILE="$STUB_SEQ"

# ===========================================================================
# L1 — the rule table decides what is filed (#2019): HIGH by rule, finalList only on the user's pick
# ===========================================================================
l1_full_loop() {
    local dir="$TMPD/l1" notes out got missing="" line b num nums=""
    : > "$STUB_LOG"; : > "$STUB_SEQ"
    notes="$(write_triage_notes "$dir" "sess-l1")"
    out="$(FINDING_HANDOFF_BIN="$HANDOFF_OK" run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    got="$(json_groups "$out")"
    # (a) one entry per class lands in its group; finalList is loc-sorted, the loc-less entry last.
    [ "$got" = 'autoHigh=crash on save;finalList=slow index rebuild|maybe cache lookups;overflow=;disposeInPr=intended behaviour|rename helper|tidy log wording;discard=style preference|typo in comment;testFailureHandoff=flaky parser test' ] \
        || missing="$missing groups=[$got]"
    # The pass: every autoHigh entry is filed; the user picks the FIRST finalList entry only; discard is
    # disposed, then every unselected finalList entry is disposed as discard (declined, NP-7).
    { group_rows "$out" autoHigh; group_rows "$out" finalList | head -n 1; } > "$TMPD/l1.file"
    while IFS=$'\t' read -r line b; do
        num="$(issue-create --title "$b" 2>/dev/null)"; nums="$nums$num "
        run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" "$num" >/dev/null 2>&1 || missing="$missing annotate-rc[$b]"
    done < "$TMPD/l1.file"
    while IFS=$'\t' read -r line b; do
        run_with_timeout 30 node "$TRIAGE_BIN" dispose "$notes" "$line" discard >/dev/null 2>&1 || missing="$missing dispose-rc[$b]"
    done < <(group_rows "$out" discard; group_rows "$out" finalList | tail -n +2)
    # (b) exactly the HIGH entry and the selected entry were filed, in that order.
    [ "$(cut -f2- "$STUB_LOG" | sed 's/^--title //' | tr '\n' ';')" = 'crash on save;slow index rebuild;' ] \
        || missing="$missing filed=[$(cut -f2- "$STUB_LOG" | tr '\n' ';')]"
    # (c) LOW / not-defect, this-pr, the declined finalList entry and ManualReminders are never filed;
    #     the declined entry carries a discard marker, so a re-run pass does not ask about it again.
    grep -Eq 'tidy log|typo in|style pref|intended beh|rename helper|maybe cache|rotate the staging|flaky parser' "$STUB_LOG" \
        && missing="$missing filed-outside-the-rules"
    for num in $nums; do grep -q "<!-- promoted: #$num -->" "$dir/WORKTREE_NOTES.md" || missing="$missing marker-#$num-missing"; done
    [ "$(grep -c '<!-- disposed: discard -->' "$dir/WORKTREE_NOTES.md")" = "3" ] || missing="$missing discard-markers"
    grep 'maybe cache lookups' "$dir/WORKTREE_NOTES.md" | grep -q '<!-- disposed: discard -->' \
        || missing="$missing declined-entry-unmarked"
    grep -E 'tidy log|intended beh|rename helper' "$dir/WORKTREE_NOTES.md" | grep -q '<!-- \(promoted\|disposed\)' \
        && missing="$missing unfiled-entry-marked"
    # (d) the re-list keeps only disposeInPr and the hand-off; the declined entry no longer reappears.
    got="$(json_groups "$(FINDING_HANDOFF_BIN="$HANDOFF_OK" run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)")"
    [ "$got" = 'autoHigh=;finalList=;overflow=;disposeInPr=intended behaviour|rename helper|tidy log wording;discard=;testFailureHandoff=flaky parser test' ] \
        || missing="$missing relist=[$got]"
    if [ -z "$missing" ]; then
        pass "L1: the pass files the HIGH entry and the user-selected finalList entry only, disposes discard and the declined finalList entry, and files no LOW / not-defect entry"
    else
        fail "L1: rule-table promotion broken" "$missing (log=$(tr '\n' ';' < "$STUB_LOG"))"
    fi
}

# ===========================================================================
# L1b — overflow entries were never shown, so the pass leaves them unmarked (NP-7)
# ===========================================================================
l1b_overflow_stays_unmarked() {
    local dir="$TMPD/l1b" notes out got missing="" line b i
    : > "$STUB_LOG"; : > "$STUB_SEQ"; mkdir -p "$dir"
    # 17 MEDIUM / other entries: 16 fill the final list (loc-sorted), the loc-less one overflows.
    { printf '%s\n' '# Worktree Notes' 'Branch: feature/np' 'Session-ID: sess-l1b' '' '## RelatedTasks'
      printf '%s\n' '- spill entry <!-- severity: medium --> <!-- pr-scope: other -->'
      for i in $(seq -w 1 16); do printf '%s\n' "- item $i <!-- severity: medium --> <!-- loc: f$i.js --> <!-- pr-scope: other -->"; done
      printf '%s\n' '' '## History Notes' '- (none)'; } > "$dir/WORKTREE_NOTES.md"
    notes="$(nodepath "$dir/WORKTREE_NOTES.md")"
    out="$(FINDING_HANDOFF_BIN="$HANDOFF_OK" run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    [ "$(group_rows "$out" overflow | cut -f2)" = 'spill entry' ] || missing="$missing overflow=[$(group_rows "$out" overflow | cut -f2 | tr '\n' ';')]"
    # The pass: the user picks the first finalList entry; the other 15 are declined; overflow gets nothing.
    group_rows "$out" finalList | head -n 1 > "$TMPD/l1b.file"
    while IFS=$'\t' read -r line b; do
        run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" "$(issue-create --title "$b" 2>/dev/null)" >/dev/null 2>&1 || missing="$missing annotate-rc[$b]"
    done < "$TMPD/l1b.file"
    while IFS=$'\t' read -r line b; do
        run_with_timeout 30 node "$TRIAGE_BIN" dispose "$notes" "$line" discard >/dev/null 2>&1 || missing="$missing dispose-rc[$b]"
    done < <(group_rows "$out" finalList | tail -n +2)
    [ "$(grep -c '<!-- disposed: discard -->' "$dir/WORKTREE_NOTES.md")" = "15" ] || missing="$missing declined-markers"
    grep 'spill entry' "$dir/WORKTREE_NOTES.md" | grep -q '<!-- \(promoted\|disposed\)' && missing="$missing overflow-entry-marked"
    grep -q 'spill entry' "$STUB_LOG" && missing="$missing overflow-entry-filed"
    # The re-list offers the overflow entry, which is still pending ([issue-TBD]).
    got="$(json_groups "$(FINDING_HANDOFF_BIN="$HANDOFF_OK" run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)")"
    [ "$got" = 'autoHigh=;finalList=spill entry;overflow=;disposeInPr=;discard=;testFailureHandoff=' ] || missing="$missing relist=[$got]"
    if [ -z "$missing" ]; then
        pass "L1b: an overflow entry gets no marker in the pass and is still pending on the re-list, while the declined finalList entries are disposed"
    else
        fail "L1b: overflow handling wrong" "$missing"
    fi
}

# ===========================================================================
# L2 — already-promoted entries are not re-filed
# ===========================================================================
l2_marked_entries_skipped() {
    local dir="$TMPD/l2" notes out missing="" line b got
    : > "$STUB_LOG"; : > "$STUB_SEQ"
    notes="$(write_triage_notes "$dir" "sess-l2")"
    # Pre-mark the autoHigh entry (crash on save) as already promoted, as a crashed earlier pass would leave it.
    out="$(FINDING_HANDOFF_BIN="$HANDOFF_OK" run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    IFS=$'\t' read -r line b < <(group_rows "$out" autoHigh)
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "${line:-0}" 3001 >/dev/null 2>&1 || missing="$missing premark-rc"
    # The re-list is the unresolved-work queue: the promoted entry drops out of every group.
    out="$(FINDING_HANDOFF_BIN="$HANDOFF_OK" run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    got="$(json_groups "$out")"
    [ "$got" = 'autoHigh=;finalList=slow index rebuild|maybe cache lookups;overflow=;disposeInPr=intended behaviour|rename helper|tidy log wording;discard=style preference|typo in comment;testFailureHandoff=flaky parser test' ] || missing="$missing relist=[$got]"
    # The re-run pass files autoHigh (now empty) and the user's pick (the first finalList row) only.
    while IFS=$'\t' read -r line b; do issue-create --title "$b" >/dev/null 2>&1; done < <(group_rows "$out" autoHigh; group_rows "$out" finalList | head -n 1)
    [ "$(cut -f2- "$STUB_LOG" | sed 's/^--title //' | tr '\n' ';')" = 'slow index rebuild;' ] || missing="$missing filed=[$(cut -f2- "$STUB_LOG" | tr '\n' ';')]"
    grep -q 'crash on save' "$STUB_LOG" 2>/dev/null && missing="$missing refiled-marked-entry"
    [ "$(grep -c '<!-- promoted: #3001 -->' "$dir/WORKTREE_NOTES.md")" = "1" ] || missing="$missing premark-marker"

    if [ -z "$missing" ]; then
        pass "L2: an entry already carrying a promoted marker is skipped, and the re-run files only the rule-table pick"
    else
        fail "L2: marked-entry handling wrong" "$missing"
    fi
}

# ===========================================================================
# L3 — all-(none) notes produce no work at all
# ===========================================================================
l3_empty_notes_no_calls() {
    local dir="$TMPD/l3" notes out len
    : > "$STUB_LOG"
    notes="$(write_empty_notes "$dir" "sess-l3")"
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    len="$(json_len "$out")"
    if [ "$len" = "0" ] && [ ! -s "$STUB_LOG" ]; then
        pass "L3: notes whose triage sections are all '- (none)' yield zero entries and zero /issue-create calls"
    else
        fail "L3: placeholder-only notes produced work" "len=$len out=$out"
    fi
}

# ===========================================================================
# I1 — annotate is idempotent
# ===========================================================================
i1_annotate_idempotent() {
    local dir="$TMPD/i1" notes out line missing="" md5_1 md5_2 count
    notes="$(write_notes "$dir" "sess-i1")"
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    line="$(json_at "$out" 0 lineNumber)"

    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" 5001 >/dev/null 2>&1
    md5_1="$(file_md5 "$dir/WORKTREE_NOTES.md")"

    # Same line, same issue: the second run must be a no-op.
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" 5001 >/dev/null 2>&1
    [ "$?" = "0" ] || missing="$missing second-run-rc"
    md5_2="$(file_md5 "$dir/WORKTREE_NOTES.md")"
    [ "$md5_1" = "$md5_2" ] || missing="$missing file-changed-on-retry"

    count="$(grep -c '<!-- promoted: #5001 -->' "$dir/WORKTREE_NOTES.md" 2>/dev/null || echo 0)"
    [ "$count" = "1" ] || missing="$missing marker-count=$count"

    local sub
    sub="$(sed -n "${line}p" "$dir/WORKTREE_NOTES.md")"
    case "$sub" in
        *'--> <!-- promoted'*) missing="$missing stacked-markers" ;;
    esac
    [ "$(tmp_residue "$dir/WORKTREE_NOTES.md")" = "0" ] || missing="$missing tmp-residue"

    if [ -z "$missing" ]; then
        pass "I1: re-annotating the same line with the same issue is a byte-identical no-op"
    else
        fail "I1: annotate is not idempotent" "$missing (line=[$sub])"
    fi
}

# ===========================================================================
# E — filesystem error paths
# ===========================================================================
# Every case shares one oracle: nonzero exit, source bytes unchanged, no *.tmp
# residue. A partial write here corrupts the only record of the session's
# findings.
assert_failed_cleanly() {
    local label="$1" file="$2" want_md5="$3" rc="$4" missing=""
    [ "$rc" != "0" ] || missing="$missing exit=0"
    [ "$(file_md5 "$file")" = "$want_md5" ] || missing="$missing content-changed"
    [ "$(tmp_residue "$file")" = "0" ] || missing="$missing tmp-residue=$(tmp_residue "$file")"
    if [ -z "$missing" ]; then
        pass "$label"
    else
        fail "$label" "$missing"
    fi
}

e1_nonexistent_notes() {
    local missing="" rc out
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$(nodepath "$TMPD/nope/WORKTREE_NOTES.md")" 2>&1)"
    rc=$?
    [ "$rc" != "0" ] || missing="$missing list-exit=0"
    case "$out" in *Error*|*error*|*ENOENT*|*not*) ;; *) missing="$missing no-diagnostic" ;; esac

    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$(nodepath "$TMPD/nope/WORKTREE_NOTES.md")" 9 1 \
        >/dev/null 2>&1
    rc=$?
    [ "$rc" != "0" ] || missing="$missing annotate-exit=0"
    [ -e "$TMPD/nope/WORKTREE_NOTES.md" ] && missing="$missing file-created"

    if [ -z "$missing" ]; then
        pass "E1: a non-existent notes file fails with a diagnostic and creates nothing"
    else
        fail "E1: missing-file handling wrong" "$missing (out=$out)"
    fi
}

e2_empty_notes_file() {
    local dir="$TMPD/e2" missing="" out rc md5
    mkdir -p "$dir"
    : > "$dir/WORKTREE_NOTES.md"
    md5="$(file_md5 "$dir/WORKTREE_NOTES.md")"

    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$(nodepath "$dir/WORKTREE_NOTES.md")" 2>/dev/null)"
    rc=$?
    # A zero-byte notes file has no sections — an empty list, not a crash.
    [ "$rc" = "0" ] || missing="$missing list-rc=$rc"
    [ "$(json_len "$out")" = "0" ] || missing="$missing len=$(json_len "$out")"

    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$(nodepath "$dir/WORKTREE_NOTES.md")" 1 42 \
        >/dev/null 2>&1
    rc=$?
    [ "$rc" != "0" ] || missing="$missing annotate-accepted-out-of-range-line"
    [ "$(file_md5 "$dir/WORKTREE_NOTES.md")" = "$md5" ] || missing="$missing content-changed"

    if [ -z "$missing" ]; then
        pass "E2: an empty notes file lists as zero entries and rejects annotation without writing"
    else
        fail "E2: empty-file handling wrong" "$missing (out=$out)"
    fi
}

e3_out_of_range_line() {
    local dir="$TMPD/e3" notes md5 rc
    notes="$(write_notes "$dir" "sess-e3")"
    md5="$(file_md5 "$dir/WORKTREE_NOTES.md")"
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" 9999 42 >/dev/null 2>&1
    rc=$?
    assert_failed_cleanly "E3a: annotating a line past EOF fails cleanly" \
        "$dir/WORKTREE_NOTES.md" "$md5" "$rc"

    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" 0 42 >/dev/null 2>&1
    rc=$?
    assert_failed_cleanly "E3b: annotating line 0 fails cleanly" \
        "$dir/WORKTREE_NOTES.md" "$md5" "$rc"

    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" abc 42 >/dev/null 2>&1
    rc=$?
    assert_failed_cleanly "E3c: a non-numeric line argument fails cleanly" \
        "$dir/WORKTREE_NOTES.md" "$md5" "$rc"
}

# Both subcommands read the file before they do anything with it, so both owe
# the same contract on an unreadable input: nonzero exit, an explicit
# diagnostic, the file left exactly as it was, and — for annotate, which is the
# one that writes — no half-written temp file left behind (CPR-ORTH: the guard is
# not `list`-only).
e4_unreadable_input() {
    local dir="$TMPD/e4" notes md5 rc out line missing=""
    notes="$(write_notes "$dir" "sess-e4")"
    md5="$(file_md5 "$dir/WORKTREE_NOTES.md")"
    # Read the target line while the file is still readable — the annotate case
    # below must fail on the READ, not on an argument it could not obtain.
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    line="$(json_at "$out" 0 lineNumber)"

    chmod 000 "$dir/WORKTREE_NOTES.md" 2>/dev/null
    # Windows ignores POSIX mode bits; running as root also defeats it. Verify
    # the file really is unreadable before asserting on the failure path.
    if head -c 1 "$dir/WORKTREE_NOTES.md" >/dev/null 2>&1; then
        chmod u+rw "$dir/WORKTREE_NOTES.md" 2>/dev/null
        skip "E4a: list on unreadable input (chmod 000 not enforced on this platform)"
        skip "E4b: annotate on unreadable input (chmod 000 not enforced on this platform)"
        return
    fi

    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>&1)"
    rc=$?
    if [ "$rc" != "0" ] && [ "$(file_md5 "$dir/WORKTREE_NOTES.md")" = "$md5" ]; then
        pass "E4a: an unreadable notes file fails list with nonzero exit and is left untouched"
    else
        fail "E4a: unreadable-input handling wrong (list)" "rc=$rc out=$out"
    fi

    # (b) the symmetric annotate path.
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" 6501 2>&1)"
    rc=$?
    [ "$rc" != "0" ] || missing="$missing annotate-exit=0"
    case "$out" in
        *"cannot read"*|*EACCES*|*permission*|*Permission*) ;;
        *) missing="$missing no-diagnostic=[$out]" ;;
    esac
    # Residue check runs while the file is still mode 000: a tmp written before
    # the read failed would be visible here.
    [ "$(tmp_residue "$dir/WORKTREE_NOTES.md")" = "0" ] || missing="$missing tmp-residue"
    chmod u+rw "$dir/WORKTREE_NOTES.md" 2>/dev/null
    [ "$(file_md5 "$dir/WORKTREE_NOTES.md")" = "$md5" ] || missing="$missing content-changed"
    grep -q '<!-- promoted: #6501 -->' "$dir/WORKTREE_NOTES.md" 2>/dev/null \
        && missing="$missing marker-written-anyway"

    if [ -z "$missing" ]; then
        pass "E4b: annotate on an unreadable notes file exits nonzero with a diagnostic, writes no marker and leaves no temp file"
    else
        fail "E4b: unreadable-input handling wrong (annotate)" "$missing (rc=$rc out=$out)"
    fi
}

# The chmod-based E4 cases cannot run where POSIX mode bits are ignored
# (Windows) — but "unreadable input" is not only a permission story. A path
# whose basename is WORKTREE_NOTES.md but which is a DIRECTORY exists, passes
# validation, and then fails the read on every platform. Both subcommands must
# handle it the same way, so this is the portable half of the E4 contract.
e4c_notes_path_is_a_directory() {
    local dir="$TMPD/e4c" notes rc out missing=""
    mkdir -p "$dir/WORKTREE_NOTES.md/inner"
    notes="$(nodepath "$dir/WORKTREE_NOTES.md")"

    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>&1)"
    rc=$?
    [ "$rc" != "0" ] || missing="$missing list-exit=0(out=$out)"
    case "$out" in *"cannot read"*|*EISDIR*|*"not found"*) ;; *) missing="$missing list-no-diagnostic" ;; esac

    out="$(run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" 5 6502 2>&1)"
    rc=$?
    [ "$rc" != "0" ] || missing="$missing annotate-exit=0(out=$out)"
    case "$out" in *"cannot read"*|*EISDIR*|*"not found"*) ;; *) missing="$missing annotate-no-diagnostic" ;; esac
    # The directory must survive intact and no temp sibling may be left behind.
    [ -d "$dir/WORKTREE_NOTES.md/inner" ] || missing="$missing target-directory-damaged"
    [ "$(tmp_residue "$dir/WORKTREE_NOTES.md")" = "0" ] || missing="$missing tmp-residue"

    if [ -z "$missing" ]; then
        pass "E4c: a notes path that is a directory fails both list and annotate with a diagnostic, damaging nothing and leaving no temp file"
    else
        fail "E4c: unreadable-path handling wrong" "$missing"
    fi
}

e5_unwritable_directory() {
    local dir="$TMPD/e5" notes md5 rc out line
    notes="$(write_notes "$dir" "sess-e5")"
    md5="$(file_md5 "$dir/WORKTREE_NOTES.md")"
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    line="$(json_at "$out" 0 lineNumber)"

    chmod 500 "$dir" 2>/dev/null
    if touch "$dir/.writable-probe" 2>/dev/null; then
        rm -f "$dir/.writable-probe"
        chmod u+rwx "$dir" 2>/dev/null
        skip "E5: unwritable target dir (directory permissions not enforced on this platform)"
        return
    fi

    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" 6001 >/dev/null 2>&1
    rc=$?
    chmod u+rwx "$dir" 2>/dev/null
    assert_failed_cleanly "E5: annotate into an unwritable directory fails cleanly, leaving the source intact" \
        "$dir/WORKTREE_NOTES.md" "$md5" "$rc"
}

# The atomic-write path is write-tmp-then-rename. Simulate a rename failure by
# occupying the temp name with a DIRECTORY, which rename cannot clobber.
e6_failed_rename() {
    local dir="$TMPD/e6" notes md5 rc out line
    notes="$(write_notes "$dir" "sess-e6")"
    md5="$(file_md5 "$dir/WORKTREE_NOTES.md")"
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    line="$(json_at "$out" 0 lineNumber)"

    mkdir -p "$dir/WORKTREE_NOTES.md.tmp"
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" 6002 >/dev/null 2>&1
    rc=$?

    local missing=""
    [ "$rc" != "0" ] || missing="$missing exit=0"
    [ "$(file_md5 "$dir/WORKTREE_NOTES.md")" = "$md5" ] || missing="$missing content-changed"
    rmdir "$dir/WORKTREE_NOTES.md.tmp" 2>/dev/null
    [ "$(tmp_residue "$dir/WORKTREE_NOTES.md")" = "0" ] || missing="$missing tmp-residue"

    if [ -z "$missing" ]; then
        pass "E6: a blocked temp-file rename aborts the annotation with the source unchanged and no residue"
    else
        fail "E6: failed-rename handling wrong" "$missing (rc=$rc)"
    fi
}

# ===========================================================================
# G7 — inertness sweep: after ALL failing annotations above, a fresh fixture
# must still round-trip. Guards must not have left global state behind.
# ===========================================================================
g7_still_works_after_failures() {
    local dir="$TMPD/g7" notes out line missing=""
    notes="$(write_notes "$dir" "sess-g7")"
    out="$(run_with_timeout 30 node "$TRIAGE_BIN" list "$notes" 2>/dev/null)"
    line="$(json_at "$out" 0 lineNumber)"
    run_with_timeout 30 node "$TRIAGE_BIN" annotate "$notes" "$line" 7001 >/dev/null 2>&1
    [ "$?" = "0" ] || missing="$missing rc"
    grep -q '<!-- promoted: #7001 -->' "$dir/WORKTREE_NOTES.md" 2>/dev/null || missing="$missing marker"
    [ "$(tmp_residue "$dir/WORKTREE_NOTES.md")" = "0" ] || missing="$missing tmp-residue"
    if [ -z "$missing" ]; then
        pass "G7: a normal list/annotate round-trip still succeeds after every failure case"
    else
        fail "G7: round-trip broken after failure cases" "$missing"
    fi
}

l1_full_loop
l1b_overflow_stays_unmarked
l2_marked_entries_skipped
l3_empty_notes_no_calls
i1_annotate_idempotent
e1_nonexistent_notes
e2_empty_notes_file
e3_out_of_range_line
e4_unreadable_input
e4c_notes_path_is_a_directory
e5_unwritable_directory
e6_failed_rename
g7_still_works_after_failures

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
