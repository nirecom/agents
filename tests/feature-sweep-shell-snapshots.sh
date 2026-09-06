#!/bin/bash
# tests/feature-sweep-shell-snapshots.sh
# Tests: bin/sweep-shell-snapshots.sh, bin/lib/session-sync-markers.sh
# Tags: sweep, shell-snapshots, maintenance, scope:common, TL2
#
# bin/sweep-shell-snapshots.sh deletes Claude Code shell snapshots whose first
# `export PATH='...'` line was corrupted by stray login-shell stdout (issue
# #2160). Contract: [--dry-run|--apply] [--min-age-minutes N] (default 1440),
# apply-by-default like the rest of the /sweep family, and a summary line
# `scanned=N candidates=N removed=N kept=N skipped_young=N`.

set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - a real ~/.claude/shell-snapshots/ corpus written by real Claude Code sessions
# - the /sweep hub dispatching this sub-skill and forwarding user flags
# - whether a deleted snapshot is really regenerated on the next session start
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SWEEP="$AGENTS_DIR/bin/sweep-shell-snapshots.sh"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPDIR_BASE="$(mktemp -d)"
trap 'chmod -R u+rwX "$TMPDIR_BASE" 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT

# Backdate well past the 1440-minute (24h) default age guard. Portable GNU/BSD.
backdate() {
    touch -d "2 days ago" "$1" 2>/dev/null || touch -t 202401010000 "$1" 2>/dev/null || true
}

# backdate_hours <file> <hours> — exact relative backdating, used only by T7,
# which needs mtimes that straddle the default threshold rather than clearing it
# by a wide margin. Returns 1 when neither GNU `touch -d` nor BSD `date -v` is
# available, so T7 can skip instead of asserting on an un-backdated file.
backdate_hours() {
    local f="$1" h="$2" ts
    touch -d "$h hours ago" "$f" 2>/dev/null && return 0
    ts="$(date -v-"${h}"H +%Y%m%d%H%M 2>/dev/null)" || ts=""
    if [ -n "$ts" ]; then
        touch -t "$ts" "$f" 2>/dev/null && return 0
    fi
    return 1
}

# field <output> <name> — reads `name=value` out of the summary line.
field() {
    printf '%s' "$1" | tr ' ' '\n' | grep -E "^$2=" | tail -1 | cut -d= -f2
}

FIXTURES="healthy.sh healthy-single-element.sh healthy-double-quoted.sh healthy-unquoted.sh healthy-later-element-missing.sh no-path-line.sh broken-fetch.sh broken-repair.sh broken-generic.sh fresh-broken.sh"
FIXTURE_COUNT=10

# A real Claude Code shell snapshot opens with its own preamble — the
# `export PATH=` line is never line 1. Every fixture therefore carries the same
# two-line preamble, so an implementation that reads `head -1` instead of
# `grep -m1 "^export PATH='"` classifies nothing and reddens here.
PREAMBLE=$'# Snapshot file\nunset __conda_setup 2>/dev/null\n'

# Decoys that must survive every run, one per way a glob can slip its scope:
# DECOY_SIBLING sits in the snapshots dir but is not a `*.sh` snapshot,
# DECOY_OUTSIDE sits one level up, and DECOY_NESTED is a `*.sh` file one level
# DOWN — the only one a recursive `**/*.sh` or `find -name '*.sh'` walk picks up,
# which the other two cannot catch. All three carry a known corruption marker, so
# an implementation that widens its glob past `$SNAPSHOTS_DIR/*.sh` deletes them.
DECOY_SIBLING=".claude/shell-snapshots/snapshot-notes.txt"
DECOY_OUTSIDE=".claude/stray-broken.sh"
DECOY_NESTED=".claude/shell-snapshots/subdir/nested-broken.sh"

# make_fixture <tag> — echoes a sandbox $HOME holding the ten snapshots.
# Everything but fresh-broken.sh is backdated two days; fresh-broken.sh stays new
# so the age guard has a subject (a snapshot the running session may still own).
make_fixture() {
    local tag="$1"
    local home="$TMPDIR_BASE/$tag/home"
    local d="$home/.claude/shell-snapshots"
    mkdir -p "$d"
    printf "%sexport PATH='/usr/bin:/bin'\nexport FOO=1\n" "$PREAMBLE" > "$d/healthy.sh"
    printf "%sexport PATH='/usr/bin'\nexport FOO=1\n" "$PREAMBLE" > "$d/healthy-single-element.sh"
    printf '%sexport PATH="/usr/bin:/bin"\nexport FOO=1\n' "$PREAMBLE" > "$d/healthy-double-quoted.sh"
    # The second shape C17 names: unquoted assignment. Like the double-quoted one
    # it must never reach the corruption heuristics — the shape gate is anchored
    # on `^export PATH='`, and an unquoted line stripped by the same logic would
    # be mis-read as a missing first element and deleted.
    printf '%sexport PATH=/usr/bin:$PATH\nexport FOO=1\n' "$PREAMBLE" > "$d/healthy-unquoted.sh"
    # The approved classifier inspects ONLY the FIRST PATH element (detail plan,
    # answering review comments C12/C18(a)): a healthy snapshot may legitimately
    # carry a stale/absent directory later in the list, and deleting on that would
    # be the false-positive deletion the design exists to prevent. First element
    # present, a missing one after it — the only fixture that separates
    # "check first element" from "check every element".
    printf "%sexport PATH='/usr/bin:/definitely/does/not/exist:/bin'\n" "$PREAMBLE" > "$d/healthy-later-element-missing.sh"
    printf '%salias ll="ls -l"\n' "$PREAMBLE" > "$d/no-path-line.sh"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" "$PREAMBLE" > "$d/broken-fetch.sh"
    printf "%sexport PATH='Repairing agents symlink(s)...\n/usr/bin:/bin'\n" "$PREAMBLE" > "$d/broken-repair.sh"
    printf "%sexport PATH='/definitely/does/not/exist:/usr/bin'\n" "$PREAMBLE" > "$d/broken-generic.sh"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" "$PREAMBLE" > "$d/fresh-broken.sh"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" "$PREAMBLE" > "$home/$DECOY_SIBLING"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" "$PREAMBLE" > "$home/$DECOY_OUTSIDE"
    mkdir -p "$d/subdir"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" "$PREAMBLE" > "$home/$DECOY_NESTED"
    local f
    for f in $FIXTURES; do
        [ "$f" = "fresh-broken.sh" ] && continue
        backdate "$d/$f"
    done
    backdate "$home/$DECOY_SIBLING"
    backdate "$home/$DECOY_OUTSIDE"
    backdate "$home/$DECOY_NESTED"
    printf '%s' "$home"
}

# count_present <dir> — how many of the ten fixtures are still on disk.
count_present() {
    local d="$1" f n=0
    for f in $FIXTURES; do
        [ -f "$d/$f" ] && n=$((n + 1))
    done
    printf '%s' "$n"
}

# ─────────────────────────────────────────────────────────────────────────────
# T1 — --dry-run classifies and writes nothing.
# ─────────────────────────────────────────────────────────────────────────────

T1_dry_run_classifies_without_deleting() {
    if [ ! -f "$SWEEP" ]; then
        fail "T1 dry-run: $SWEEP not found"
        return
    fi
    local home; home="$(make_fixture t1)"
    local d="$home/.claude/shell-snapshots"
    local out rc
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" --dry-run 2>&1)"
    rc=$?

    local scanned candidates removed kept young present
    scanned="$(field "$out" scanned)"
    candidates="$(field "$out" candidates)"
    removed="$(field "$out" removed)"
    kept="$(field "$out" kept)"
    young="$(field "$out" skipped_young)"
    present="$(count_present "$d")"

    if [ "$rc" -eq 0 ] && [ "${scanned:-x}" = "10" ] && [ "${candidates:-x}" = "3" ] \
        && [ "${removed:-x}" = "0" ] && [ "${kept:-x}" = "7" ] && [ "${young:-x}" = "1" ]; then
        pass "T1a dry-run summary: scanned=10 candidates=3 removed=0 kept=7 skipped_young=1"
    else
        fail "T1a dry-run summary wrong (exit=$rc): scanned=${scanned:-?} candidates=${candidates:-?} removed=${removed:-?} kept=${kept:-?} skipped_young=${young:-?}. Output: $out"
    fi
    if [ "$present" = "$FIXTURE_COUNT" ]; then
        pass "T1b dry-run deleted nothing (all $FIXTURE_COUNT snapshots still on disk)"
    else
        fail "T1b dry-run deleted files: only $present/$FIXTURE_COUNT fixtures remain. Output: $out"
    fi

    # The summary counts alone would stay green against any per-candidate line
    # format, yet that line IS the dry-run's whole product: the operator reads it
    # to decide whether to apply. Pin both reason values — broken-fetch.sh trips
    # the known-marker branch, broken-generic.sh only the missing-dir heuristic.
    if printf '%s\n' "$out" | grep -qF "DRY-RUN: candidate snapshot=$d/broken-fetch.sh reason=known-marker"; then
        pass "T1c dry-run prints the candidate line for a known-marker snapshot"
    else
        fail "T1c dry-run candidate line missing/misformatted for broken-fetch.sh (expected 'DRY-RUN: candidate snapshot=$d/broken-fetch.sh reason=known-marker'). Output: $out"
    fi
    # Both known markers are separate `case` arms; T1c alone stays green when the
    # repair arm is missing from the pattern list, since broken-repair.sh would
    # then fall through to the missing-dir heuristic and still be a candidate —
    # same count, wrong reason. Only pinning the reason for BOTH markers catches it.
    if printf '%s\n' "$out" | grep -qF "DRY-RUN: candidate snapshot=$d/broken-repair.sh reason=known-marker"; then
        pass "T1e dry-run prints the candidate line for the repair-marker snapshot"
    else
        fail "T1e dry-run candidate line missing/misformatted for broken-repair.sh (expected 'DRY-RUN: candidate snapshot=$d/broken-repair.sh reason=known-marker'). Output: $out"
    fi
    if printf '%s\n' "$out" | grep -qF "DRY-RUN: candidate snapshot=$d/broken-generic.sh reason=missing-dir"; then
        pass "T1d dry-run prints the candidate line for a missing-dir snapshot"
    else
        fail "T1d dry-run candidate line missing/misformatted for broken-generic.sh (expected 'DRY-RUN: candidate snapshot=$d/broken-generic.sh reason=missing-dir'). Output: $out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T2 / T10 — the destructive run. The flagless invocation (T2, this family's
#      production default) and the explicit `--apply` synonym (T10) must be
#      indistinguishable, so both run through one helper and cannot drift: an
#      implementation that accepts `--apply` but never sets APPLY degrades it
#      into a silent dry-run while T1/T2 stay green. T9 brackets the other side.
# ─────────────────────────────────────────────────────────────────────────────

# assert_destructive_run <tag> <label> [flag...] — three aged corrupted
# snapshots go, seven survive, deletion never leaves $SNAPSHOTS_DIR/*.sh.
assert_destructive_run() {
    local tag="$1" label="$2"
    shift 2
    local home; home="$(make_fixture "$tag")"
    local d="$home/.claude/shell-snapshots"
    local desc="flagless run"
    [ "$#" -gt 0 ] && desc="'$*' run"
    local out rc
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" "$@" 2>&1)"
    rc=$?

    local gone=1 f
    for f in broken-fetch.sh broken-repair.sh broken-generic.sh; do
        [ -f "$d/$f" ] && gone=0
    done
    local kept_all=1
    for f in healthy.sh healthy-single-element.sh healthy-double-quoted.sh healthy-unquoted.sh healthy-later-element-missing.sh no-path-line.sh fresh-broken.sh; do
        [ -f "$d/$f" ] || kept_all=0
    done
    local removed; removed="$(field "$out" removed)"

    if [ "$rc" -eq 0 ] && [ "$gone" = "1" ] && [ "${removed:-x}" = "3" ]; then
        pass "${label}a $desc removed the three corrupted snapshots (removed=3)"
    else
        fail "${label}a $desc wrong (exit=$rc): gone=$gone removed=${removed:-?}. Output: $out"
    fi
    if [ "$kept_all" = "1" ] && [ "$(count_present "$d")" = "7" ]; then
        pass "${label}b $desc left the seven survivors (healthy x5, no-path-line, fresh-broken)"
    else
        fail "${label}b survivors missing: present=$(count_present "$d")/$FIXTURE_COUNT kept_all=$kept_all. Output: $out"
    fi
    # Deletion scope. All three decoys are aged and carry a known corruption
    # marker, so only the `$SNAPSHOTS_DIR/*.sh` glob keeps them: an
    # extension-blind implementation takes the sibling, a parent-walking one the
    # outside file, and a recursive `**/*.sh` the nested one — each while every
    # count above stays green, since no decoy is ever scanned.
    if [ -f "$home/$DECOY_SIBLING" ] && [ -f "$home/$DECOY_OUTSIDE" ] && [ -f "$home/$DECOY_NESTED" ]; then
        pass "${label}c $desc left all three out-of-scope decoys (sibling, outside, nested)"
    else
        fail "${label}c deletion escaped scope: sibling=$([ -f "$home/$DECOY_SIBLING" ] && echo kept || echo DELETED) outside=$([ -f "$home/$DECOY_OUTSIDE" ] && echo kept || echo DELETED) nested=$([ -f "$home/$DECOY_NESTED" ] && echo kept || echo DELETED). Output: $out"
    fi
}

T2_flagless_run_deletes_broken_only() {
    if [ ! -f "$SWEEP" ]; then
        fail "T2 flagless apply: $SWEEP not found"
        return
    fi
    assert_destructive_run t2 T2
}

# ─────────────────────────────────────────────────────────────────────────────
# T3 — missing ~/.claude/shell-snapshots is an ordinary state, not an error.
# ─────────────────────────────────────────────────────────────────────────────

T3_missing_snapshots_dir_exits_zero() {
    if [ ! -f "$SWEEP" ]; then
        fail "T3 missing dir: $SWEEP not found"
        return
    fi
    local out rc
    out="$(HOME="$TMPDIR_BASE/nonexistent-home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "T3 missing shell-snapshots dir → exit 0, no crash"
    else
        fail "T3 missing shell-snapshots dir: exit=$rc, out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T4 — the corruption markers stay a single source of truth: the sweep script
#      sources bin/lib/session-sync-markers.sh by absolute path and never
#      re-hardcodes the literals profile-snippet.sh prints.
# ─────────────────────────────────────────────────────────────────────────────

T4_marker_ssot_is_sourced_not_copied() {
    if [ ! -f "$SWEEP" ]; then
        fail "T4 marker SSOT: $SWEEP not found"
        return
    fi
    if grep -q 'source "$SCRIPT_DIR/lib/session-sync-markers.sh"' "$SWEEP"; then
        pass "T4a sweep sources lib/session-sync-markers.sh via SCRIPT_DIR"
    else
        fail "T4a sweep does not source lib/session-sync-markers.sh via SCRIPT_DIR"
    fi
    if grep -q 'AGENTS_SESSION_SYNC_FETCH_MARKER' "$SWEEP"; then
        pass "T4b sweep matches on the shared AGENTS_SESSION_SYNC_FETCH_MARKER variable"
    else
        fail "T4b sweep does not reference AGENTS_SESSION_SYNC_FETCH_MARKER"
    fi
    # The repair marker is the symmetric half of the SSOT: a script that reads
    # only the fetch constant still classifies broken-repair.sh, via the
    # missing-dir fallback, so no count-based case can miss it. T4b/T4b2 as a
    # pair is what pins both `case` arms to the lib.
    if grep -q 'AGENTS_SYMLINK_REPAIR_MARKER' "$SWEEP"; then
        pass "T4b2 sweep matches on the shared AGENTS_SYMLINK_REPAIR_MARKER variable too"
    else
        fail "T4b2 sweep does not reference AGENTS_SYMLINK_REPAIR_MARKER (only the fetch marker is wired to the lib)"
    fi
    # Executable lines only, matching T4d below and T20d in the marker-ssot-mutation
    # part file: a rationale comment naming where the marker text comes from is
    # sanctioned, so a whole-file grep would false-red a correct implementation.
    if grep -v '^[[:space:]]*#' "$SWEEP" | grep -q "git fetch Claude session sync"; then
        fail "T4c sweep re-hardcodes the fetch marker literal instead of using the lib"
    else
        pass "T4c sweep carries no duplicated marker literal"
    fi
    # `find -mmin` is banned outright: on Windows Git Bash `find` can resolve to
    # C:\Windows\System32\find.exe, which rejects the flag and makes the age gate
    # fail closed. Runtime output is identical either way, so only the source can
    # tell the epoch-arithmetic implementation from the banned one. Comment lines
    # are stripped first: the script is expected to SAY why `-mmin` is banned, and
    # a ban check that reddens on its own rationale is unusable. Leading-`#` lines
    # are enough for this codebase's style — a trailing inline `# ... -mmin ...`
    # comment on a code line would still false-red, and would need a real parser.
    if grep -v '^[[:space:]]*#' "$SWEEP" | grep -q -- '-mmin'; then
        fail "T4d sweep uses the banned 'find -mmin' age check instead of stat epoch arithmetic"
    else
        pass "T4d sweep age guard avoids 'find -mmin' (stat epoch arithmetic only)"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T5 — --min-age-minutes is honoured and validated (non-numeric is rejected).
# ─────────────────────────────────────────────────────────────────────────────

T5_min_age_minutes_flag() {
    if [ ! -f "$SWEEP" ]; then
        fail "T5 --min-age-minutes: $SWEEP not found"
        return
    fi
    local home; home="$(make_fixture t5)"
    local out rc young
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" --dry-run --min-age-minutes 0 2>&1)"
    young="$(field "$out" skipped_young)"
    if [ "${young:-x}" = "0" ]; then
        pass "T5a --min-age-minutes 0 disables the age guard (skipped_young=0)"
    else
        fail "T5a --min-age-minutes 0: skipped_young=${young:-?}. Output: $out"
    fi

    out="$(HOME="$home" run_with_timeout bash "$SWEEP" --dry-run --min-age-minutes abc 2>&1)"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "T5b non-numeric --min-age-minutes rejected (exit=$rc)"
    else
        fail "T5b non-numeric --min-age-minutes accepted: out=$out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# T6 — idempotency: a second flagless run over an already-swept directory finds
#      nothing left to remove and still exits 0.
# ─────────────────────────────────────────────────────────────────────────────

T6_second_run_is_a_no_op() {
    if [ ! -f "$SWEEP" ]; then
        fail "T6 idempotency: $SWEEP not found"
        return
    fi
    local home; home="$(make_fixture t6)"
    local d="$home/.claude/shell-snapshots"
    HOME="$home" run_with_timeout bash "$SWEEP" >/dev/null 2>&1
    local out rc removed
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    removed="$(field "$out" removed)"
    if [ "$rc" -eq 0 ] && [ "${removed:-x}" = "0" ] && [ "$(count_present "$d")" = "7" ]; then
        pass "T6 second run removes nothing more (removed=0, 7 survivors intact)"
    else
        fail "T6 second run: exit=$rc removed=${removed:-?} present=$(count_present "$d"). Output: $out"
    fi
}

# T7-T9 (age/flag guards), T12-T14 (exact age boundary + I/O failures), T15-T16
# (CLI and PATH classifier tables), T17-T19 (adversarial inputs) and T20 (marker
# SSOT mutation) live in sibling part files — rules/coding/file-split.md
# Pattern A. Each self-invokes its cases at source time.
. "$AGENTS_DIR/tests/feature-sweep-shell-snapshots/age-and-flag-guards.sh"
. "$AGENTS_DIR/tests/feature-sweep-shell-snapshots/age-boundary-and-io.sh"
. "$AGENTS_DIR/tests/feature-sweep-shell-snapshots/classifier-tables.sh"
. "$AGENTS_DIR/tests/feature-sweep-shell-snapshots/adversarial-inputs.sh"
. "$AGENTS_DIR/tests/feature-sweep-shell-snapshots/marker-ssot-mutation.sh"

# ─────────────────────────────────────────────────────────────────────────────

# T10 — the explicit `--apply` opt-in. Header above T2 carries the rationale;
#       this case is that helper re-run with the flag, so the two invocations
#       are asserted against one contract rather than two drifting copies.

T10_explicit_apply_matches_flagless() {
    if [ ! -f "$SWEEP" ]; then
        fail "T10 --apply: $SWEEP not found"
        return
    fi
    assert_destructive_run t10 T10 --apply
}

# ─────────────────────────────────────────────────────────────────────────────
# T11 — the classifier checks ONLY the first PATH element. Every other case is
#      satisfied by both the approved heuristic and an over-checking "verify
#      every element" one; only healthy-later-element-missing.sh separates them
#      — first element present, a later one absent. Approved design: HEALTHY.
#      An over-checker calls it missing-dir and deletes an uncorrupted snapshot,
#      the false-positive deletion C12/C18(a) flagged. T1/T2 fold in its counts,
#      but a wrong reason string leaves those green, so pin both modes here.
# ─────────────────────────────────────────────────────────────────────────────

T11_later_missing_path_element_is_healthy() {
    if [ ! -f "$SWEEP" ]; then
        fail "T11 first-element-only classifier: $SWEEP not found"
        return
    fi
    local home; home="$(make_fixture t11)"
    local d="$home/.claude/shell-snapshots"
    local target="$d/healthy-later-element-missing.sh"
    local out rc

    out="$(HOME="$home" run_with_timeout bash "$SWEEP" --dry-run 2>&1)"
    rc=$?
    if [ "$rc" -eq 0 ] && ! printf '%s\n' "$out" | grep -qF "snapshot=$target"; then
        pass "T11a dry-run does not flag a snapshot whose FIRST PATH element exists (later element missing)"
    else
        fail "T11a dry-run flagged healthy-later-element-missing.sh (exit=$rc) — the classifier is checking every PATH element, not just the first. Output: $out"
    fi

    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    local removed; removed="$(field "$out" removed)"
    if [ "$rc" -eq 0 ] && [ -f "$target" ] && [ "${removed:-x}" = "3" ]; then
        pass "T11b apply keeps healthy-later-element-missing.sh (removed=3, no false-positive deletion)"
    else
        fail "T11b apply deleted or miscounted healthy-later-element-missing.sh (exit=$rc): present=$([ -f "$target" ] && echo yes || echo DELETED) removed=${removed:-?}. Output: $out"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────

T1_dry_run_classifies_without_deleting
T2_flagless_run_deletes_broken_only
T3_missing_snapshots_dir_exits_zero
T4_marker_ssot_is_sourced_not_copied
T5_min_age_minutes_flag
T6_second_run_is_a_no_op
T7_default_min_age_is_1440
T8_empty_snapshots_dir_scans_zero
T9_unknown_flag_rejected_without_deleting
T10_explicit_apply_matches_flagless
T11_later_missing_path_element_is_healthy

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
