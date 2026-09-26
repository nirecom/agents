#!/bin/bash
# tests/unit-worktree-notes-append/mode-b-tests.sh
# Tests: bin/worktree-notes-append.js, bin/worktree-notes-append/args.js
# Tags: worktree-notes, append-cli, mode-b, severity, TL2, scope:common
#
# Sourced by tests/unit-worktree-notes-append.sh — not a standalone runner.
# Uses the parent's helpers: pass/fail/skip, require_helper, setup_tmp,
# cleanup_tmp, run_with_timeout, HELPER_JS.
#
# Mode B is the finding-authoring mode (#1886): no --issue-number, an explicit
# --section, and a --severity that is mandatory for BugsFound and forbidden
# everywhere else. Mode A (promotion pointer, --issue-number) must not shift by
# a single byte — B0 pins that first, because every Mode-B case below is only
# meaningful if the existing producer still works.

# ---- B0: Mode A output is byte-identical to the pre-#1886 contract ----
test_B0_mode_a_byte_identical() {
    require_helper "B0: Mode A byte-identical" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md" want="$TMP/want.md"
    printf '# Worktree Notes\n\n## RelatedTasks\n- Reg (#60) <!-- promoted: #60 -->\n' > "$want"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" --issue-number 60 --title "Reg" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && cmp -s "$notes" "$want"; then
        pass "B0: Mode A --label type:task output byte-identical"
    else
        fail "B0: rc=$rc diff=$(diff "$want" "$notes" 2>&1 | head -5)"
    fi
    cleanup_tmp
}

# ---- B1: Mode A + type:incident routes to BugsFound WITHOUT --severity ----
# C9 pin: the severity requirement keys on Mode B's --section only. If it ever
# leaks into targetSectionForLabels(), /issue-create's incident path breaks.
test_B1_mode_a_incident_no_severity_required() {
    require_helper "B1: Mode A incident needs no severity" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" --issue-number 61 --title "Crash" \
        --label "type:incident" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && grep -q "## BugsFound" "$notes" 2>/dev/null \
       && grep -qF "Crash (#61)" "$notes" 2>/dev/null \
       && ! grep -qF "severity:" "$notes" 2>/dev/null; then
        pass "B1: Mode A incident → BugsFound, no --severity demanded"
    else
        fail "B1: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- B2: mode conflict — Mode A flags mixed with Mode B flags → exit 2 ----
test_B2_mode_conflict() {
    require_helper "B2: mode conflict" || return
    local notes err rc bad=""
    setup_tmp
    notes="$TMP/WORKTREE_NOTES.md"

    err="$(run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" --issue-number 62 --title "X" \
        --severity high 2>&1 >/dev/null)"
    rc=$?
    [ "$rc" -eq 2 ] || bad="$bad severity+issue-number-rc=$rc"
    printf '%s' "$err" | grep -qiE 'mode|severity|issue-number' \
        || bad="$bad severity+issue-number-no-reason"
    [ -f "$notes" ] && bad="$bad severity+issue-number-wrote-file"

    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" --issue-number 63 --title "X" \
        --section BugsFound >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 2 ] || bad="$bad section+issue-number-rc=$rc"
    [ -f "$notes" ] && bad="$bad section+issue-number-wrote-file"

    if [ -z "$bad" ]; then
        pass "B2: Mode A + --severity / --section → exit 2 with a reason, no write"
    else
        fail "B2:$bad"
    fi
    cleanup_tmp
}

# ---- B3: Mode B happy path — severity:high marker, byte-exact file ----
test_B3_mode_b_high() {
    require_helper "B3: Mode B --severity high" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md" want="$TMP/want.md"
    printf '# Worktree Notes\n\n## BugsFound\n- X <!-- severity: high -->\n' > "$want"
    run_with_timeout 30 node "$HELPER_JS" \
        --notes-path "$notes" --section BugsFound --severity high \
        --title "X" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && cmp -s "$notes" "$want"; then
        pass "B3: Mode B high → '- X <!-- severity: high -->' in ## BugsFound"
    else
        fail "B3: rc=$rc content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- B4: low and none are input-side semantics only — identical output ----
# C7 pin: `<!-- severity: low -->` is never written. Both values must produce a
# plain untagged entry, byte-for-byte the same file.
test_B4_low_none_equivalence() {
    require_helper "B4: low/none equivalence" || return
    setup_tmp
    local a="$TMP/a" b="$TMP/b" want="$TMP/want.md" rc1 rc2
    mkdir -p "$a" "$b"
    printf '# Worktree Notes\n\n## BugsFound\n- X\n' > "$want"
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$a/WORKTREE_NOTES.md" \
        --section BugsFound --severity low --title "X" >/dev/null 2>&1
    rc1=$?
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$b/WORKTREE_NOTES.md" \
        --section BugsFound --severity none --title "X" >/dev/null 2>&1
    rc2=$?
    if [ "$rc1" -eq 0 ] && [ "$rc2" -eq 0 ] \
       && cmp -s "$a/WORKTREE_NOTES.md" "$b/WORKTREE_NOTES.md" \
       && cmp -s "$a/WORKTREE_NOTES.md" "$want"; then
        pass "B4: --severity low and none produce byte-identical untagged entries"
    else
        fail "B4: rc1=$rc1 rc2=$rc2 low=[$(cat "$a/WORKTREE_NOTES.md" 2>/dev/null)] none=[$(cat "$b/WORKTREE_NOTES.md" 2>/dev/null)]"
    fi
    cleanup_tmp
}

# ---- B5: severity vocabulary is exactly high|low|none, lowercase ----
test_B5_severity_strict_values() {
    require_helper "B5: strict severity values" || return
    local bad="" v rc notes
    for v in HIGH High medium "" critical; do
        setup_tmp
        notes="$TMP/WORKTREE_NOTES.md"
        run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
            --section BugsFound --severity "$v" --title "X" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 2 ] || bad="$bad [$v]rc=$rc"
        [ -f "$notes" ] && bad="$bad [$v]wrote-file"
        cleanup_tmp
    done
    if [ -z "$bad" ]; then
        pass "B5: non-{high,low,none} --severity values → exit 2, no write"
    else
        fail "B5:$bad"
    fi
}

# ---- B6: --section BugsFound without --severity → exit 2 ----
test_B6_bugsfound_requires_severity() {
    require_helper "B6: BugsFound requires severity" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --title "X" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 2 ] && [ ! -f "$notes" ]; then
        pass "B6: Mode B BugsFound without --severity → exit 2, no write"
    else
        fail "B6: rc=$rc file_exists=$([ -f "$notes" ] && echo yes || echo no)"
    fi
    cleanup_tmp
}

# ---- B7: --severity outside BugsFound is rejected outright ----
test_B7_severity_only_for_bugsfound() {
    require_helper "B7: severity coupled to BugsFound" || return
    local bad="" s rc notes
    for s in RelatedTasks NextTasks ManualReminders; do
        setup_tmp
        notes="$TMP/WORKTREE_NOTES.md"
        run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
            --section "$s" --severity low --title "X" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 2 ] || bad="$bad [$s]rc=$rc"
        cleanup_tmp
    done
    if [ -z "$bad" ]; then
        pass "B7: --severity outside ## BugsFound → exit 2"
    else
        fail "B7:$bad"
    fi
}

# ---- B8: --section allowlist = triage SECTIONS + ManualReminders ----
# N7 pin: the CLI accepts one section more than the triage promotion set,
# because manual edits of ## ManualReminders need a CLI replacement too.
test_B8_section_allowlist() {
    require_helper "B8: --section allowlist" || return
    local bad="" s rc notes
    for s in RelatedTasks NextTasks ManualReminders; do
        setup_tmp
        notes="$TMP/WORKTREE_NOTES.md"
        run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
            --section "$s" --title "X" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 0 ] || bad="$bad [$s]rc=$rc"
        grep -q "## $s" "$notes" 2>/dev/null || bad="$bad [$s]no-heading"
        grep -qxF "- X" "$notes" 2>/dev/null || bad="$bad [$s]no-untagged-entry"
        cleanup_tmp
    done
    setup_tmp
    notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section Bogus --title "X" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 2 ] || bad="$bad [Bogus]rc=$rc"
    [ -f "$notes" ] && bad="$bad [Bogus]wrote-file"
    cleanup_tmp
    if [ -z "$bad" ]; then
        pass "B8: allowlist accepts RelatedTasks/NextTasks/ManualReminders, rejects Bogus"
    else
        fail "B8:$bad"
    fi
}

# ---- B9: Mode B rejects --label (routing is --section only) ----
test_B9_mode_b_rejects_label() {
    require_helper "B9: Mode B rejects --label" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity high --title "X" \
        --label "type:task" >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 2 ] && [ ! -f "$notes" ]; then
        pass "B9: Mode B + --label → exit 2, no write"
    else
        fail "B9: rc=$rc file_exists=$([ -f "$notes" ] && echo yes || echo no)"
    fi
    cleanup_tmp
}

# ---- B10: idempotency keys on the stripped body, not the raw line ----
test_B10_mode_b_idempotent() {
    require_helper "B10: Mode B idempotency" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md" bad="" h1 h2 h3 rc
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity high --title "Dup me" >/dev/null 2>&1
    rc=$?
    [ "$rc" -eq 0 ] || bad="$bad first-rc=$rc"
    h1="$(sha256sum "$notes" 2>/dev/null | awk '{print $1}')"

    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity high --title "Dup me" >/dev/null 2>&1
    [ $? -eq 0 ] || bad="$bad second-nonzero"
    h2="$(sha256sum "$notes" 2>/dev/null | awk '{print $1}')"
    [ "$h1" = "$h2" ] || bad="$bad same-severity-rewrote"

    # Same title, different severity: the entry body already matches, so this is
    # a no-op — it must not append an untagged duplicate of a tagged entry.
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity none --title "Dup me" >/dev/null 2>&1
    [ $? -eq 0 ] || bad="$bad third-nonzero"
    h3="$(sha256sum "$notes" 2>/dev/null | awk '{print $1}')"
    [ "$h1" = "$h3" ] || bad="$bad none-after-high-rewrote"
    [ "$(grep -cF 'Dup me' "$notes" 2>/dev/null)" = "1" ] || bad="$bad duplicate-line"

    if [ -z "$bad" ]; then
        pass "B10: Mode B re-runs are byte-identical no-ops (body-keyed)"
    else
        fail "B10:$bad content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- B11: title injection — a title may never forge or break a marker ----
test_B11_title_injection() {
    require_helper "B11: title injection" || return
    local bad="" t rc notes
    for t in 'X <!-- severity: high -->' 'X -->' 'X <!--'; do
        setup_tmp
        notes="$TMP/WORKTREE_NOTES.md"
        run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
            --section BugsFound --severity none --title "$t" >/dev/null 2>&1
        rc=$?
        [ "$rc" -eq 2 ] || bad="$bad [$t]rc=$rc"
        [ -f "$notes" ] && bad="$bad [$t]wrote-file"
        cleanup_tmp
    done
    if [ -z "$bad" ]; then
        pass "B11: titles containing '<!--' or '-->' → exit 2, no write"
    else
        fail "B11:$bad"
    fi
}

# ---- B12: placeholder replacement + missing-section append in Mode B ----
test_B12_placeholder_and_missing_section() {
    require_helper "B12: placeholder / missing section" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md" bad=""
    printf '# Worktree Notes\n\n## BugsFound\n- (none)\n' > "$notes"
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity high --title "First" >/dev/null 2>&1
    [ $? -eq 0 ] || bad="$bad replace-rc"
    grep -qF -- "- (none)" "$notes" 2>/dev/null && bad="$bad placeholder-kept"
    grep -qF -- "- First <!-- severity: high -->" "$notes" 2>/dev/null || bad="$bad entry-missing"

    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section NextTasks --title "Later" >/dev/null 2>&1
    [ $? -eq 0 ] || bad="$bad append-rc"
    [ "$(grep -c '^## NextTasks$' "$notes" 2>/dev/null)" = "1" ] || bad="$bad nexttasks-heading"
    grep -qxF -- "- Later" "$notes" 2>/dev/null || bad="$bad later-missing"

    if [ -z "$bad" ]; then
        pass "B12: Mode B replaces '- (none)' and appends an absent section"
    else
        fail "B12:$bad content=$(cat "$notes" 2>/dev/null)"
    fi
    cleanup_tmp
}

# ---- B13: CRLF file stays pure CRLF after a Mode B append ----
test_B13_crlf_preserved() {
    require_helper "B13: CRLF preserved" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md" crlf lf
    printf '# Worktree Notes\r\n\r\n## BugsFound\r\n- (none)\r\n' > "$notes"
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity high --title "CR" >/dev/null 2>&1
    local rc=$?
    crlf="$(grep -c $'\r$' "$notes" 2>/dev/null)"
    lf="$(wc -l < "$notes" 2>/dev/null | tr -d '[:space:]')"
    if [ "$rc" -eq 0 ] && [ "$crlf" = "$lf" ] && [ "$lf" != "0" ]; then
        pass "B13: CRLF file has no mixed line endings after Mode B append"
    else
        fail "B13: rc=$rc crlf_lines=$crlf total_lines=$lf"
    fi
    cleanup_tmp
}

# ---- B14: --skip-if-main applies to Mode B too ----
test_B14_skip_if_main() {
    require_helper "B14: --skip-if-main in Mode B" || return
    setup_tmp
    local repo="$TMP/repo" notes
    mkdir -p "$repo"
    git -C "$repo" init -q 2>/dev/null
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null
    notes="$repo/WORKTREE_NOTES.md"
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity high --title "Main" \
        --skip-if-main >/dev/null 2>&1
    local rc=$?
    if [ "$rc" -eq 0 ] && [ ! -f "$notes" ]; then
        pass "B14: --skip-if-main in Mode B → exit 0, no write in main worktree"
    else
        fail "B14: rc=$rc file_exists=$([ -f "$notes" ] && echo yes || echo no)"
    fi
    cleanup_tmp
}

# ---- B15: atomicity — no .tmp survives a Mode B write ----
test_B15_no_tmp_left() {
    require_helper "B15: Mode B atomicity" || return
    setup_tmp
    local notes="$TMP/WORKTREE_NOTES.md" leftovers
    run_with_timeout 30 node "$HELPER_JS" --notes-path "$notes" \
        --section BugsFound --severity high --title "Atomic B" >/dev/null 2>&1
    local rc=$?
    leftovers="$(find "$TMP" -maxdepth 1 -name 'WORKTREE_NOTES.md.tmp*' 2>/dev/null | wc -l | tr -d '[:space:]')"
    if [ "$rc" -eq 0 ] && [ "$leftovers" = "0" ]; then
        pass "B15: no .tmp left behind after a Mode B write"
    else
        fail "B15: rc=$rc leftovers=$leftovers"
    fi
    cleanup_tmp
}

test_B0_mode_a_byte_identical
test_B1_mode_a_incident_no_severity_required
test_B2_mode_conflict
test_B3_mode_b_high
test_B4_low_none_equivalence
test_B5_severity_strict_values
test_B6_bugsfound_requires_severity
test_B7_severity_only_for_bugsfound
test_B8_section_allowlist
test_B9_mode_b_rejects_label
test_B10_mode_b_idempotent
test_B11_title_injection
test_B12_placeholder_and_missing_section
test_B13_crlf_preserved
test_B14_skip_if_main
test_B15_no_tmp_left
