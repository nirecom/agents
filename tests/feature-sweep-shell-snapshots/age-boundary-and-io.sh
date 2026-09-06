#!/bin/bash
# Tests: bin/sweep-shell-snapshots.sh
# Tags: sweep, shell-snapshots, boundary, io-failure, scope:common, TL2
# Part file of tests/feature-sweep-shell-snapshots.sh: T12 pins the exact 1440
# default (T7 only straddles it, and SKIPs where relative backdating is absent);
# T13/T14 cover the I/O failure paths. Age semantics SSOT: the plan's age gate —
# elapsed/60 < min_age keeps, so exactly 1440 minutes is swept.
_ssb_age_minutes() {
    # <file> <minutes> — absolute mtime via perl utime, the primitive this repo
    # already depends on (run-with-timeout.sh falls back to it), so no host needs
    # `touch -d`/`date -v` and no case has to SKIP. Whole minutes absorb the
    # seconds of drift before the sweep reads its own clock.
    perl -e 'my $t = time - ($ARGV[1] * 60); utime $t, $t, $ARGV[0] or exit 1' "$1" "$2"
}

# _ssb_one_snapshot_home <tag> <minutes> — a sandbox HOME holding exactly one
# aged, known-marker-corrupted snapshot. Echoes nothing when the mtime could not
# be set, so the caller fails loudly rather than asserting on an un-aged file.
_ssb_one_snapshot_home() {
    local tag="$1" minutes="$2"
    local home="$TMPDIR_BASE/$tag/home"
    local d="$home/.claude/shell-snapshots"
    mkdir -p "$d"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" \
        "$PREAMBLE" > "$d/aged.sh"
    _ssb_age_minutes "$d/aged.sh" "$minutes" || { printf ''; return; }
    printf '%s' "$home"
}

# _ssb_age_case <label> <minutes> <expect-removed 0|1> <why>
_ssb_age_case() {
    local label="$1" minutes="$2" expect="$3" why="$4"
    local home; home="$(_ssb_one_snapshot_home "age$minutes" "$minutes")"
    if [ -z "$home" ]; then
        fail "$label: perl utime could not set an absolute mtime, so the 1440-minute default cannot be pinned on this host"
        return
    fi
    local d="$home/.claude/shell-snapshots"
    local out rc removed young present
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    removed="$(field "$out" removed)"
    young="$(field "$out" skipped_young)"
    present=0
    [ -f "$d/aged.sh" ] && present=1
    local want_present=$(( 1 - expect ))
    local want_young=$(( 1 - expect ))
    if [ "$rc" -eq 0 ] && [ "${removed:-x}" = "$expect" ] \
        && [ "$present" = "$want_present" ] && [ "${young:-x}" = "$want_young" ]; then
        pass "$label: a snapshot exactly ${minutes}min old is $([ "$expect" = "1" ] && echo swept || echo "held back") ($why)"
    else
        fail "$label: exit=$rc removed=${removed:-?} (expected $expect) skipped_young=${young:-?} (expected $want_young) on-disk=$present — the default age threshold is not 1440 minutes with '<' semantics ($why). Output: $out"
    fi
}

# T12 — 1439 vs 1440 pins the number; 1440 vs 1441 pins the comparison. An age
# gate written with `-le` keeps a 1440-minute snapshot and only T12b catches it.
T12_default_age_boundary_is_exactly_1440() {
    if [ ! -f "$SWEEP" ]; then
        fail "T12 exact age boundary: $SWEEP not found"
        return
    fi
    _ssb_age_case "T12a" 1439 0 "1439 < 1440 → still too young to touch"
    _ssb_age_case "T12b" 1440 1 "1440 is NOT less than 1440 → old enough"
    _ssb_age_case "T12c" 1441 1 "1441 > 1440 → old enough"
}

# T13 — entries the loop cannot treat as ordinary files: a directory named
# `*.sh` matches the glob, and a binary blob defeats a line-oriented read.
# Neither may abort the run or let a real candidate escape — this tool deletes
# by default, so a mid-loop abort silently leaves corrupted snapshots in place.
T13_unreadable_entries_do_not_abort_the_sweep() {
    if [ ! -f "$SWEEP" ]; then
        fail "T13 I/O edges: $SWEEP not found"
        return
    fi
    local home="$TMPDIR_BASE/t13/home"
    local d="$home/.claude/shell-snapshots"
    mkdir -p "$d/dir-entry.sh"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" \
        "$PREAMBLE" > "$d/broken.sh"
    printf '\001\002\003binary-no-newline' > "$d/binary.sh"
    _ssb_age_minutes "$d/broken.sh" 3000
    _ssb_age_minutes "$d/binary.sh" 3000
    local out rc
    out="$(HOME="$home" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    local swept=0
    [ -f "$d/broken.sh" ] || swept=1
    if [ "$rc" -eq 0 ] && [ "$swept" = "1" ] && [ -d "$d/dir-entry.sh" ] \
        && [ -f "$d/binary.sh" ]; then
        pass "T13 a directory entry and a binary snapshot are skipped without aborting; the real candidate is still swept"
    else
        fail "T13 exit=$rc real-candidate-swept=$swept dir-entry=$([ -d "$d/dir-entry.sh" ] && echo kept || echo GONE) binary=$([ -f "$d/binary.sh" ] && echo kept || echo DELETED) — an unreadable entry must neither abort the loop nor be deleted on a failed read. Output: $out"
    fi
}

# T14 — a removal that fails. The count is the operator's receipt: reporting a
# file as removed when `rm` failed sends them away believing a corrupted
# snapshot is gone. The shim fails for one candidate only, so the same run also
# shows the loop continuing to the others.
T14_failed_removal_is_not_counted_as_removed() {
    if [ ! -f "$SWEEP" ]; then
        fail "T14 failed removal: $SWEEP not found"
        return
    fi
    local home="$TMPDIR_BASE/t14/home"
    local d="$home/.claude/shell-snapshots"
    local shim="$TMPDIR_BASE/t14/bin"
    mkdir -p "$d" "$shim"
    local f
    for f in stuck.sh other.sh; do
        printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" \
            "$PREAMBLE" > "$d/$f"
        _ssb_age_minutes "$d/$f" 3000
    done
    local real_rm; real_rm="$(command -v rm)"
    cat > "$shim/rm" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        stuck.sh|*/stuck.sh) echo "rm: cannot remove '\$a': Operation not permitted" >&2; exit 1 ;;
    esac
done
exec "$real_rm" "\$@"
EOF
    chmod +x "$shim/rm"
    local out rc removed
    out="$(HOME="$home" PATH="$shim:$PATH" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    removed="$(field "$out" removed)"
    local other_gone=0
    [ -f "$d/other.sh" ] || other_gone=1
    if [ -f "$d/stuck.sh" ] && [ "$other_gone" = "1" ] && [ "${removed:-x}" = "1" ] \
        && printf '%s\n' "$out" | grep -qF "stuck.sh"; then
        pass "T14 a failed removal is reported, excluded from removed=, and does not stop the remaining candidates"
    else
        fail "T14 exit=$rc removed=${removed:-?} (expected 1) stuck=$([ -f "$d/stuck.sh" ] && echo kept || echo GONE) other-gone=$other_gone named-in-output=$(printf '%s\n' "$out" | grep -cF stuck.sh) — a removal that failed must not be counted as removed nor swallowed silently. Output: $out"
    fi
}

# T20 — TOCTOU re-check (CPR-ORTH sibling of bin/sweep-plans.sh:220-249's
# revived-file re-check before delete). This script has no separate scan/apply
# pass, so the equivalent race window is narrower: between classifying a file
# as a candidate and its own `rm -f "$f"` for that file. A `rm` shim (T14's
# stuck.sh technique) swaps the candidate out from under the real rm call —
# deletes what the script saw, then drops a fresh healthy file back at the same
# path, as a session regenerating its snapshot mid-sweep would. The only
# assertion this can honestly make is sweep-plans' own contract (a race must
# not corrupt the run): no crash, no abandoned loop — not which file
# generation "wins", since this script has no re-check to arbitrate that.
T20_toctou_swap_during_removal_does_not_abort_the_sweep() {
    if [ ! -f "$SWEEP" ]; then
        fail "T20 TOCTOU swap: $SWEEP not found"
        return
    fi
    local home="$TMPDIR_BASE/t20/home"
    local d="$home/.claude/shell-snapshots"
    local shim="$TMPDIR_BASE/t20/bin"
    mkdir -p "$d" "$shim"
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" \
        "$PREAMBLE" > "$d/raced.sh"
    _ssb_age_minutes "$d/raced.sh" 3000
    printf "%sexport PATH='git fetch Claude session sync ...\n/usr/bin:/bin'\n" \
        "$PREAMBLE" > "$d/other.sh"
    _ssb_age_minutes "$d/other.sh" 3000
    local real_rm; real_rm="$(command -v rm)"
    cat > "$shim/rm" <<EOF
#!/bin/bash
for a in "\$@"; do
    case "\$a" in
        raced.sh|*/raced.sh)
            "$real_rm" "\$@"
            rc=\$?
            printf 'export PATH="/usr/bin:/bin"\n' > "\$a"
            exit \$rc
            ;;
    esac
done
exec "$real_rm" "\$@"
EOF
    chmod +x "$shim/rm"
    local out rc
    out="$(HOME="$home" PATH="$shim:$PATH" run_with_timeout bash "$SWEEP" 2>&1)"
    rc=$?
    local other_gone=0
    [ -f "$d/other.sh" ] || other_gone=1
    local raced_present=0
    [ -f "$d/raced.sh" ] && raced_present=1
    local removed; removed="$(field "$out" removed)"
    if [ "$rc" -eq 0 ] && [ "$other_gone" = "1" ] && [ "$raced_present" = "1" ] \
        && [ "${removed:-x}" = "2" ]; then
        pass "T20 a file replaced out from under the sweep's own rm does not abort the run or stop the remaining candidate (removed=2, replacement survives)"
    else
        fail "T20 exit=$rc removed=${removed:-?} (expected 2) other-gone=$other_gone raced-present=$raced_present — a concurrent swap at rm-time must not crash the sweep or skip the rest of the loop. Output: $out"
    fi
}

T12_default_age_boundary_is_exactly_1440
T13_unreadable_entries_do_not_abort_the_sweep
T14_failed_removal_is_not_counted_as_removed
T20_toctou_swap_during_removal_does_not_abort_the_sweep
