#!/bin/bash
# tests/feature-sweep-shell-snapshots/age-and-flag-guards.sh
# Tests: bin/sweep-shell-snapshots.sh
# Tags: sweep, shell-snapshots, maintenance, scope:common, TL2
#
# Part file of tests/feature-sweep-shell-snapshots.sh — the two guards standing
# between a delete-by-default tool and an operator's live snapshots: the age
# threshold (T7) and the flag parser (T9), plus the empty-directory edge (T8)
# the same loop skeleton must survive. The parent owns PASS/FAIL, make_fixture,
# count_present, field, run_with_timeout, backdate_hours, PREAMBLE, SWEEP and
# FIXTURE_COUNT.

AGE_FIXTURES="age-12h.sh age-23h.sh age-25h.sh age-36h.sh"

# ─────────────────────────────────────────────────────────────────────────────
# T7 — the DEFAULT --min-age-minutes really is 1440. Every other case backdates
#      two days, which any default from 1 minute to ~2879 also clears, so none
#      of them can tell 1440 from 60. These four straddle the boundary: 12h and
#      23h must be held back as too young, 25h and 36h swept. Run with no
#      --min-age-minutes flag — passing one here would defeat the whole case.
# ─────────────────────────────────────────────────────────────────────────────

# make_age_fixture <tag> — echoes a sandbox $HOME, or nothing if this host
# cannot backdate by an exact number of hours.
make_age_fixture() {
    local tag="$1"
    local home="$TMPDIR_BASE/$tag/home"
    local d="$home/.claude/shell-snapshots"
    mkdir -p "$d"
    local f h
    for f in $AGE_FIXTURES; do
        printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" "$PREAMBLE" > "$d/$f"
        h="${f#age-}"; h="${h%h.sh}"
        backdate_hours "$d/$f" "$h" || return 0
    done
    printf '%s' "$home"
}

T7_default_min_age_is_1440() {
    if [ ! -f "$SWEEP" ]; then
        fail "T7 default age boundary: $SWEEP not found"
        return
    fi
    local home; home="$(make_age_fixture t7)"
    if [ -z "$home" ]; then
        echo "SKIP: T7 default age boundary — host cannot backdate by exact hours"
        return
    fi
    local d="$home/.claude/shell-snapshots"
    local out rc
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?

    local young_kept=1 old_swept=1 f
    for f in age-12h.sh age-23h.sh; do
        [ -f "$d/$f" ] || young_kept=0
    done
    for f in age-25h.sh age-36h.sh; do
        [ -f "$d/$f" ] && old_swept=0
    done
    local scanned candidates removed young
    scanned="$(field "$out" scanned)"
    candidates="$(field "$out" candidates)"
    removed="$(field "$out" removed)"
    young="$(field "$out" skipped_young)"

    if [ "$rc" -eq 0 ] && [ "$young_kept" = "1" ] && [ "$old_swept" = "1" ] \
        && [ "${scanned:-x}" = "4" ] && [ "${candidates:-x}" = "2" ] \
        && [ "${removed:-x}" = "2" ] && [ "${young:-x}" = "2" ]; then
        pass "T7 default --min-age-minutes is 1440: 12h/23h held back, 25h/36h swept"
    else
        fail "T7 default age threshold is not 1440 (exit=$rc): young_kept=$young_kept old_swept=$old_swept scanned=${scanned:-?} candidates=${candidates:-?} removed=${removed:-?} skipped_young=${young:-?}. Output: $out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T8 — an existing but empty snapshots dir. Distinct from T3 (dir missing): here
#      the glob matches nothing, and without `shopt -s nullglob` the unexpanded
#      literal enters the loop as a filename and stat/grep run on a path that
#      does not exist. scanned=0 is the proof the loop body never ran.
# ─────────────────────────────────────────────────────────────────────────────

T8_empty_snapshots_dir_scans_zero() {
    if [ ! -f "$SWEEP" ]; then
        fail "T8 empty dir: $SWEEP not found"
        return
    fi
    local home="$TMPDIR_BASE/t8/home"
    mkdir -p "$home/.claude/shell-snapshots"
    local out rc scanned candidates removed
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    scanned="$(field "$out" scanned)"
    candidates="$(field "$out" candidates)"
    removed="$(field "$out" removed)"
    if [ "$rc" -eq 0 ] && [ "${scanned:-x}" = "0" ] && [ "${candidates:-x}" = "0" ] \
        && [ "${removed:-x}" = "0" ]; then
        pass "T8 empty snapshots dir → exit 0, scanned=0 candidates=0 removed=0"
    else
        fail "T8 empty snapshots dir (exit=$rc): scanned=${scanned:-?} candidates=${candidates:-?} removed=${removed:-?}. Output: $out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

# T9 — an unrecognized flag must be rejected before anything is deleted. This is
#      a delete-by-default tool, so a mistyped `--dryrun` or `--min-age` that
#      falls through the flag `case` to the default path destroys the operator's
#      snapshots while they believe they asked for a preview. Mirrors the sibling
#      convention in bin/sweep-plans.sh:67-71 — message on stderr naming the
#      offending flag, then usage, non-zero exit — the shape T5b pins for the
#      numeric --min-age-minutes validator.

T9_unknown_flag_rejected_without_deleting() {
    if [ ! -f "$SWEEP" ]; then
        fail "T9 unknown flag: $SWEEP not found"
        return
    fi
    local bad home d err rc
    for bad in --dryrun --min-age; do
        home="$(make_fixture "t9${bad//-/}")"
        d="$home/.claude/shell-snapshots"
        err="$(HOME="$home" run_with_timeout bash "$SWEEP" "$bad" 2>&1 >/dev/null)"
        rc=$?
        if [ "$rc" -ne 0 ] && printf '%s' "$err" | grep -qF -- "$bad" \
            && [ "$(count_present "$d")" = "$FIXTURE_COUNT" ]; then
            pass "T9 unknown flag '$bad' rejected on stderr (exit=$rc), all $FIXTURE_COUNT snapshots intact"
        else
            fail "T9 unknown flag '$bad': exit=$rc present=$(count_present "$d")/$FIXTURE_COUNT stderr=[$err] (expected non-zero exit naming the flag, nothing deleted)"
        fi
    done
}
