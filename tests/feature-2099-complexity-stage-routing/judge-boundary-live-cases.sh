#!/bin/bash
# tests/feature-2099-complexity-stage-routing/judge-boundary-live-cases.sh
# Tests: skills/_shared/judge-task-complexity.md, bin/workflow/derive-complexity-level
# Tags: complexity, routing, judge, live-agent, boundary, tl3, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh AFTER
# judge-threshold-live-cases.sh — every d2099j_* helper comes from there.
# The two numeric rows the S1b boundary suite leaves untested: S1-multi-file's
# file count and S6-long-plan's line count. Billable; gated exactly like JT-1.

# Both numbers come off the rubric row (CPR-SSOT) and are then PINNED against the
# value the design fixed, so a rubric edit — or wording the reader misparses —
# fails here rather than silently re-aiming the fixtures at another boundary.
d2099j_s1_threshold() { d2099j_row_threshold 'S1-multi-file' 'files?'; }
d2099j_s6_threshold() { d2099j_row_threshold 'S6-long-plan' 'lines?'; }

# S1: "spans <n> or more files" — <n> is the FIRST TRIPPING value, so the absent
# case is <n>-1. S6: "exceed <n> lines combined" — <n> is the LAST SAFE value, so
# the tripping case is <n>+1. The two directions are opposite on purpose; getting
# one backwards is exactly the drift these rows exist to catch.
D2099J_S1_DOCUMENTED=3
D2099J_S6_DOCUMENTED=200

# An intent.md of EXACTLY $2 lines describing deliberately trivial work, so length
# is the only axis the judge can move on. The head is a fixed 8 lines; the rest is
# filler discussion. Padding is added, never prose removed, so the denial of every
# other signal survives at both boundary sizes.
D2099J_LINE_HEAD=8
d2099j_line_fixture() {
    local dir="$1" n="$2" i
    mkdir -p "$dir"
    cat > "$dir/settings.json" <<'SET'
{ "hooks": {} }
SET
    {
        printf '# Intent\n'
        printf '\n'
        printf 'Correct the wording of one log message in one file. No behaviour change, no\n'
        printf 'design decision, architectural change or refactor; no authentication,\n'
        printf 'authorization, secret, credential, cryptography or permission surface; no\n'
        printf 'install script, dotfile bootstrap or system configuration; no public API or\n'
        printf 'inter-process contract; EXACTLY ONE file is touched. This document is the only\n'
        printf 'prior-stage artifact and it is exactly %d lines long.\n' "$n"
        i=$((D2099J_LINE_HEAD + 1))
        while [ "$i" -le "$n" ]; do
            printf 'Discussion note %03d: the reviewer preferred the shorter phrasing here.\n' \
                "$((i - D2099J_LINE_HEAD))"
            i=$((i + 1))
        done
    } > "$dir/intent.md"
}

# One boundary case: judge the fixture, pin the EXACT signal set, then route that
# same line through the real derive CLI at all three stages.
d2099j_boundary_case() {
    local id="$1" dir="$2" want_set="$3" want_levels="$4" line ids
    line=$(d2099j_judge "$dir")
    case "$line" in
        RC*) fail "$id the gated live judge invocation FAILED on the boundary fixture — an unreachable judge is a broken integration, not a skip: [$line]"; return ;;
        '')  fail "$id the live judge emitted no parseable 'SIGNALS:' line for the boundary fixture"; return ;;
        *)   pass "$id the live judge produced a verdict for the boundary fixture ($line)" ;;
    esac
    ids=$(d2099j_ids "$line")
    if [ "$want_set" = "none" ]; then
        assert_eq "${id}a the fixture on the safe side of the boundary trips nothing at all" "none" "$ids"
    else
        d2099j_assert_exact_set "${id}set" "$want_set" "$ids"
    fi
    d2099j_assert_stage_levels "${id}b" "$ids" "$want_levels"
}

# --- JT-11 / JT-12: the S1-multi-file file-count pair -------------------------
# d2099j_fixture is the same mechanical-rename body JT-2..JT-4 use, so the file
# count really is the only difference between the two members of the pair.
d2099j_live_s1_boundary() {
    local reason thr dir
    reason=$(d2099j_gate_reason)
    if [ -n "$reason" ]; then
        gated_skip "JT-11 live judge S1-multi-file file-count boundary: $reason"
        gated_skip "JT-12 live judge S1-multi-file file-count boundary: $reason"
        return
    fi

    thr=$(d2099j_s1_threshold)
    case "$thr" in
        ''|*[!0-9]*)
            fail "JT-11 no '<n> ... files' file-count phrase for S1-multi-file is stated in $RUBRIC, so its boundary cannot be tested"
            fail "JT-12 same: the S1-multi-file file-count phrase is unreadable, so the at-boundary member cannot be tested"
            return ;;
    esac
    if [ "$thr" != "$D2099J_S1_DOCUMENTED" ]; then
        fail "JT-11 the S1-multi-file file-count threshold parsed from the rubric is [$thr], not the documented $D2099J_S1_DOCUMENTED — either the rubric drifted or its wording no longer matches the file-count phrase"
        fail "JT-12 same threshold mismatch — the at-boundary member would probe a number nobody chose"
        return
    fi
    pass "JT-11 the S1-multi-file file-count threshold in the rubric is the documented value (threshold=$thr)"

    # One under: a two-file rename is not multi-file, and nothing else is present,
    # so every stage must take the cheap path. This is the row that proves the
    # cheap path is reachable on the file-count axis at all.
    dir="$TMPDIR_BASE/jt-s1-below"
    d2099j_fixture "$dir" "$((thr - 1))"
    d2099j_boundary_case "JT-11" "$dir" "none" "detail:low write_tests:low write_code:low"

    # At the boundary: S1 alone. D2 keeps write_code high on [S1-multi-file] while
    # detail and write_tests fall to low — the #2099 split itself, on a real verdict.
    dir="$TMPDIR_BASE/jt-s1-at"
    d2099j_fixture "$dir" "$thr"
    d2099j_boundary_case "JT-12" "$dir" "S1-multi-file" "detail:low write_tests:low write_code:high"
}

# --- JT-13 / JT-14: the S6-long-plan line-count pair --------------------------
d2099j_live_s6_boundary() {
    local reason thr dir got
    reason=$(d2099j_gate_reason)
    if [ -n "$reason" ]; then
        gated_skip "JT-13 live judge S6-long-plan line-count boundary: $reason"
        gated_skip "JT-14 live judge S6-long-plan line-count boundary: $reason"
        return
    fi

    thr=$(d2099j_s6_threshold)
    case "$thr" in
        ''|*[!0-9]*)
            fail "JT-13 no '<n> ... lines' line-count phrase for S6-long-plan is stated in $RUBRIC, so its boundary cannot be tested"
            fail "JT-14 same: the S6-long-plan line-count phrase is unreadable, so the tripping member cannot be tested"
            return ;;
    esac
    if [ "$thr" != "$D2099J_S6_DOCUMENTED" ]; then
        fail "JT-13 the S6-long-plan line-count threshold parsed from the rubric is [$thr], not the documented $D2099J_S6_DOCUMENTED"
        fail "JT-14 same threshold mismatch — the tripping member would probe a number nobody chose"
        return
    fi
    pass "JT-13 the S6-long-plan line-count threshold in the rubric is the documented value (threshold=$thr)"

    # AT the documented number: "exceed 200" means 200 is still safe. The fixture's
    # own size is asserted first — a generator off by one line would move the case
    # to the other side of the boundary and the verdict would be unattributable.
    dir="$TMPDIR_BASE/jt-s6-at"
    d2099j_line_fixture "$dir" "$thr"
    got=$(wc -l < "$dir/intent.md" | tr -d ' ')
    if [ "$got" != "$thr" ]; then
        fail "JT-13 unattributable: the boundary fixture is $got lines, not the $thr the case needs"
        return
    fi
    pass "JT-13a the at-boundary fixture really is exactly $thr lines"
    d2099j_boundary_case "JT-13" "$dir" "none" "detail:low write_tests:low write_code:low"

    # One line PAST it: the first tripping value. D2 gives S6 no detail or
    # write_tests escalation, so only write_code moves — without this pair a rubric
    # that fired S6 at 200 would inflate write_code on every ordinary long plan.
    dir="$TMPDIR_BASE/jt-s6-above"
    d2099j_line_fixture "$dir" "$((thr + 1))"
    got=$(wc -l < "$dir/intent.md" | tr -d ' ')
    if [ "$got" != "$((thr + 1))" ]; then
        fail "JT-14 unattributable: the tripping fixture is $got lines, not the $((thr + 1)) the case needs"
        return
    fi
    pass "JT-14a the first-tripping fixture really is exactly $((thr + 1)) lines"
    d2099j_boundary_case "JT-14" "$dir" "S6-long-plan" "detail:low write_tests:low write_code:high"
}

d2099j_live_s1_boundary
d2099j_live_s6_boundary
