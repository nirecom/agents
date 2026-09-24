#!/bin/bash
# Tests: bin/sweep-shell-snapshots.sh, bin/lib/session-sync-markers.sh
# Tags: sweep, shell-snapshots, ssot, mutation, scope:common, TL2
# Part file of tests/feature-sweep-shell-snapshots.sh. T4 only greps the sweep's
# text, so a script that sources the lib and then matches its own copy of the
# literals stays green. T20 mirrors sweep + lib, gives the lib unique marker
# values, and reads the classifier's own reason strings back.

MARKERS_LIB_SRC="$AGENTS_DIR/bin/lib/session-sync-markers.sh"
REAL_FETCH_MARKER='git fetch Claude session sync ...'
REAL_REPAIR_MARKER='Repairing agents symlink(s)...'

# _ssm_mirror <dir> <probe-fetch> <probe-repair> — copies the sweep and the lib
# into <dir>/bin, rewrites only the two marker VALUES, and echoes the mirrored
# script path (nothing when either source file is missing).
_ssm_mirror() {
    local root="$1" pf="$2" pr="$3"
    [ -f "$SWEEP" ] && [ -f "$MARKERS_LIB_SRC" ] || { printf ''; return; }
    mkdir -p "$root/bin/lib"
    cp "$SWEEP" "$root/bin/sweep-shell-snapshots.sh"
    sed -E -e "s|(AGENTS_SESSION_SYNC_FETCH_MARKER=).*|\\1'$pf'|" \
           -e "s|(AGENTS_SYMLINK_REPAIR_MARKER=).*|\\1'$pr'|" \
           "$MARKERS_LIB_SRC" > "$root/bin/lib/session-sync-markers.sh"
    printf '%s' "$root/bin/sweep-shell-snapshots.sh"
}

# T20a/b/c — with the lib mutated, a snapshot whose first PATH element is the
# PROBE text must be reported reason=known-marker, and one carrying the REAL
# shipped literal must fall through to reason=missing-dir. A sweep with the
# literals baked in inverts both verdicts.
T20_markers_follow_the_library() {
    if [ ! -f "$SWEEP" ]; then
        fail "T20 marker SSOT mutation: $SWEEP not found"
        return
    fi
    if [ ! -f "$MARKERS_LIB_SRC" ]; then
        fail "T20 marker SSOT mutation: $MARKERS_LIB_SRC not found"
        return
    fi
    local root="$TMPDIR_BASE/t20"
    local pf="ZZPROBE-FETCH-9f3a1c"
    local pr="ZZPROBE-REPAIR-9f3a1c"
    local mirror; mirror="$(_ssm_mirror "$root" "$pf" "$pr")"
    if [ -z "$mirror" ]; then
        fail "T20: could not mirror the sweep and its marker lib"
        return
    fi
    local home="$root/home"
    local d="$home/.claude/shell-snapshots"
    mkdir -p "$d"
    printf "%sexport PATH='%s\n/usr/bin:/bin'\n" "$PREAMBLE" "$pf" > "$d/probe-fetch.sh"
    printf "%sexport PATH='%s\n/usr/bin:/bin'\n" "$PREAMBLE" "$pr" > "$d/probe-repair.sh"
    printf "%sexport PATH='%s\n/usr/bin:/bin'\n" "$PREAMBLE" "$REAL_FETCH_MARKER" > "$d/real-literal.sh"
    local f
    for f in probe-fetch.sh probe-repair.sh real-literal.sh; do backdate "$d/$f"; done

    local out rc
    out="$(HOME="$home" run_with_timeout bash "$mirror" --dry-run 2>&1)"
    rc=$?
    local reason_for
    reason_for() {
        printf '%s\n' "$out" | grep -F "snapshot=$d/$1 " | grep -oE 'reason=[a-z-]+' | tail -1
    }
    local r_pf r_pr r_real
    r_pf="$(reason_for probe-fetch.sh)"
    r_pr="$(reason_for probe-repair.sh)"
    r_real="$(reason_for real-literal.sh)"

    if [ "$rc" -eq 0 ] && [ "$r_pf" = "reason=known-marker" ]; then
        pass "T20a the fetch marker comes from the lib (a rewritten value is what the classifier matches)"
    else
        fail "T20a probe-fetch.sh got '$r_pf' (expected reason=known-marker), exit=$rc — the sweep is not matching the lib's AGENTS_SESSION_SYNC_FETCH_MARKER. Output: $out"
    fi
    if [ "$r_pr" = "reason=known-marker" ]; then
        pass "T20b the repair marker comes from the lib too"
    else
        fail "T20b probe-repair.sh got '$r_pr' (expected reason=known-marker) — the sweep is not matching the lib's AGENTS_SYMLINK_REPAIR_MARKER. Output: $out"
    fi
    if [ "$r_real" = "reason=missing-dir" ]; then
        pass "T20c the shipped literal is NOT baked into the sweep (it falls through to missing-dir once the lib no longer names it)"
    else
        fail "T20c real-literal.sh got '$r_real' (expected reason=missing-dir) — the sweep carries its own copy of '$REAL_FETCH_MARKER'. Output: $out"
    fi
}

# T20d — the static half, over executable lines only: a rationale comment that
# quotes a marker is legitimate, a `case` arm that hard-codes one is not. T4c
# bans the fetch literal; the repair literal is its symmetric twin (CPR-ORTH).
T20_no_marker_literals_in_executable_source() {
    if [ ! -f "$SWEEP" ]; then
        fail "T20d marker literals: $SWEEP not found"
        return
    fi
    local hits=0
    grep -v '^[[:space:]]*#' "$SWEEP" | grep -qF "$REAL_FETCH_MARKER" && hits=$((hits + 1))
    grep -v '^[[:space:]]*#' "$SWEEP" | grep -qF "$REAL_REPAIR_MARKER" && hits=$((hits + 1))
    if [ "$hits" -eq 0 ]; then
        pass "T20d neither shipped marker literal appears in the sweep's executable lines"
    else
        fail "T20d $hits of the 2 shipped marker literals are hard-coded in the sweep's executable lines instead of read from bin/lib/session-sync-markers.sh"
    fi
}

T20_markers_follow_the_library
T20_no_marker_literals_in_executable_source
