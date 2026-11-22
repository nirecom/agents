#!/usr/bin/env bash
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/prestaged-path-pass.sh
# Tags: feature-2478, codex-review-loop, cc-fallback, prestaged, cap, scope:issue-specific, TL2
#
# #2478 T1: a CC-fallback round of the four path-kind formats (test-review, security-plan,
# outline-plan, detail-plan) is a prestaged ADVANCE of the real loop, so it is counted and
# capped exactly like a codex round. Under one 2+1 cap three fallback rounds land as rows; a
# round past the cap stops at the pre-check (exit 2, nothing persisted), and a rerun with the
# same input after a terminal round 3 (rc 6) is refused by the wrapper (exit 8).
# TL3 gap: the real test-reviewer / outline-reviewer / detail-reviewer / plan-security-reviewer
# agents writing these reports in a live session (only the report text is stubbed here).

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"
# shellcheck source=tests/bin/feature-2478-fallback/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2478-fallback/helpers.sh"

# fb_at <sid> <fmt> <round> <extensions-used> — one fallback ADVANCE under the 2+1 cap.
fb_at() { fb "$1" "$2" "$FX_TMP/$1-r$3.md" --cap 2 --max-extensions 1 --extensions-used "$4"; }
# frozen <sid> <fmt> — counter, ledger, rows and raw in one comparable line.
frozen() {
    printf '%s|%s|%s|%s' "$(clf_read "$(round_file "$1" "$2")")" "$(clf_digest "$(ledger_of "$1" "$2")")" \
        "$(rows "$1" "$2")" "$(clf_digest "$(raw_of "$1" "$2")")"
}

# two_plus_one <fmt> — every run uses cap 2 / max-ext 1. Rounds 1-2 are counted (rc 1, rc 5);
# a round past the cap without the extension stops at the pre-check; the extension round 3 is
# counted and ends the cycle (rc 6). A rc-1 round 3, hence a counter of 3, is unreachable here.
two_plus_one() {
    local F="$1" sid="t1a-$1" before
    seed_sid "$sid"
    report "$FX_TMP/$sid-r1.md" "$(verdict_of "$F")" "C1. [HIGH] the loop forgets the counter"
    fb_at "$sid" "$F" 1 0
    assert_eq "$F round 1: exit 1 (continue)" "1" "$L_RC"
    assert_not_contains "$F round 1: a path-kind prestaged report is accepted" "not permitted" "$L_ERR"
    report "$FX_TMP/$sid-r2.md" "$(verdict_of "$F")" "C1: unresolved — still not fixed in round 2"
    fb_at "$sid" "$F" 2 0
    assert_eq "$F round 2: exit 5 (AUTO_EXTEND)" "5" "$L_RC"
    assert_eq "$F: ROUND_FILE after round 2" "2" "$(clf_read "$(round_file "$sid" "$F")")"
    report "$FX_TMP/$sid-r3.md" "$(verdict_of "$F")" "C1: unresolved — still not fixed in round 3"
    before="$(frozen "$sid" "$F")"
    fb_at "$sid" "$F" 3 0
    assert_eq "$F round 3 without the extension: exit 2 at the cap pre-check" "2" "$L_RC"
    assert_contains "$F round 3 without the extension: the cap header" "round cap reached" "$L_ERR$L_OUT"
    assert_eq "$F round 3 without the extension: counter, ledger, rows and raw unchanged" \
        "$before" "$(frozen "$sid" "$F")"
    assert_eq "$F round 3 without the extension: no inflight left" "0" "$(inflights "$sid" "$F")"
    fb_at "$sid" "$F" 3 1
    assert_eq "$F round 3 with the extension: exit 6 (HIGH_UNRESOLVED)" "6" "$L_RC"
    assert_eq "$F: three rows" "3" "$(rows "$sid" "$F")"
    assert_eq "$F: row 1 counter_round" "1" "$(row "$sid" "$F" 1 counter_round)"
    assert_eq "$F: row 3 counter_round" "3" "$(row "$sid" "$F" 3 counter_round)"
    assert_eq "$F: row 3 source" "cc-fallback" "$(row "$sid" "$F" 3 source)"
    assert_eq "$F: row 3 exit" "6" "$(row "$sid" "$F" 3 exit)"
    assert_eq "$F: the raw of round 3 is kept at the stage path" \
        "$(clf_digest "$FX_TMP/$sid-r3.md")" "$(clf_digest "$(raw_of "$sid" "$F")")"
}

echo "=== T1 (a): under one 2+1 cap, fallback rounds 1-3 are counted and a round past it is stopped ==="
case_begin "test-review-fallback-rounds-counted-and-capped" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
two_plus_one test-review
case_end
case_begin "security-plan-fallback-rounds-counted-and-capped" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
two_plus_one security-plan
case_end
case_begin "outline-plan-fallback-rounds-counted-and-capped" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
two_plus_one outline-plan
case_end
case_begin "detail-plan-fallback-rounds-counted-and-capped" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
two_plus_one detail-plan
case_end

echo ""
echo "=== T1 (b): round 3 ends rc 6 -> the same input rerun is refused by the wrapper (exit 8) ==="
case_begin "terminal-fallback-round-rerun-refused-by-wrapper" "bin/run-codex-review-loop"
sid="t1b"
F=test-review
# codex stays unusable throughout: only the forwarded fallback report can produce a round.
export FX_RV=1
seed_sid "$sid"
PA=(--prestaged-producer test-reviewer --prestaged-exec PERFORMED)
report "$FX_TMP/$sid-r1.md" "NEEDS_REVISION" "C1. [HIGH] the wrapper drops the fallback round"
WRAP_EXT=0 wrapa review-tests "$sid" --prestaged-report "$FX_TMP/$sid-r1.md" "${PA[@]}"
assert_eq "wrapper round 1: exit 1" "1" "$W_RC"
report "$FX_TMP/$sid-r2.md" "NEEDS_REVISION" "C1: unresolved — still dropped"
WRAP_EXT=0 wrapa review-tests "$sid" --prestaged-report "$FX_TMP/$sid-r2.md" "${PA[@]}"
assert_eq "wrapper round 2: exit 5 (AUTO_EXTEND)" "5" "$W_RC"
WRAP_EXT=1 wrapa review-tests "$sid" --prestaged-report "$FX_TMP/$sid-r2.md" "${PA[@]}"
assert_eq "wrapper round 3: exit 6 (HIGH_UNRESOLVED)" "6" "$W_RC"
assert_eq "three rows" "3" "$(rows "$sid" "$F")"
assert_eq "row 3 exit" "6" "$(row "$sid" "$F" 3 exit)"
assert_eq "row 3 is the fallback's, not the codex stub's" "cc-fallback" "$(row "$sid" "$F" 3 source)"
WRAP_EXT=1 wrapa review-tests "$sid" --prestaged-report "$FX_TMP/$sid-r2.md" "${PA[@]}"
assert_eq "wrapper rerun with the same input: exit 8" "8" "$W_RC"
assert_eq "the refused rerun adds no row" "3" "$(rows "$sid" "$F")"
unset FX_RV
case_end

# restore_probe <mode> — pp_round_restore, sourced and called directly after a real snapshot
# and a round-1 archive. ok: nothing blocks the undo. blocked: a file absent at the snapshot
# reappears as a non-empty directory. present-dir: the snapshotted ledger is replaced by a
# non-empty directory. snap-missing: the snapshot dir is gone. Prints FINAL_RC and what is
# kept; stderr goes to $FX_TMP/restore-<mode>.err.
restore_probe() {
    local mode="$1" d="$FX_TMP/restore-$1"
    rm -rf "$d"
    mkdir -p "$d"
    (
        die() { echo "die: $*" >&2; exit 97; }
        . "$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-review-loop/prestaged-path-pass.sh" || exit 90
        CONTROL_DIR="$d" LEDGER_FORMAT=test-review ROUND=1
        LEDGER="$d/rs-test-review-concern-ledger.txt"
        printf 'C1|old\n' > "$LEDGER"
        pp_round_snapshot
        PP_ARCHIVE_PATH="$d/rs-test-review-concern-ledger.prev-1.txt"
        printf 'C1|old\n' > "$PP_ARCHIVE_PATH"
        printf 'C1|new\n' > "$LEDGER"
        case "$mode" in
            blocked)
                mkdir -p "$d/rs-test-review-concern-carrier.md/inner"
                : > "$d/rs-test-review-concern-carrier.md/inner/f" ;;
            present-dir)
                rm -f "$LEDGER"
                mkdir -p "$LEDGER/inner"
                : > "$LEDGER/inner/f" ;;
            snap-missing) rm -rf "$PP_SNAPSHOT_DIR" ;;
        esac
        pp_round_restore
        printf 'FINAL_RC=%s snap=%s archive=%s ledger=%s' "$FINAL_RC" \
            "$([ -d "$PP_SNAPSHOT_DIR" ] && echo kept || echo gone)" \
            "$([ -f "$PP_ARCHIVE_PATH" ] && echo kept || echo gone)" \
            "$(if [ -f "$LEDGER" ]; then tr -d '\r' < "$LEDGER"; elif [ -d "$LEDGER" ]; then echo dir; else echo absent; fi)"
    ) 2>"$FX_TMP/restore-$mode.err"
}

echo ""
echo "=== C2: pp_round_restore — a failed undo keeps the snapshot and archive and says so ==="
case_begin "pp-round-restore-failure-keeps-snapshot-and-archive" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
out="$(restore_probe ok)"
assert_eq "restore ok: FINAL_RC 4, snapshot and archive dropped, ledger back to the snapshot" \
    "FINAL_RC=4 snap=gone archive=gone ledger=C1|old" "$out"
assert_not_contains "restore ok: no manual-recovery diagnostic" "could not be fully undone" \
    "$(cat "$FX_TMP/restore-ok.err")"
out="$(restore_probe blocked)"
assert_eq "restore blocked: FINAL_RC 4 (never success), snapshot and archive kept" \
    "FINAL_RC=4 snap=kept archive=kept ledger=C1|old" "$out"
assert_contains "restore blocked: stderr names the manual recovery" "could not be fully undone" \
    "$(cat "$FX_TMP/restore-blocked.err")"
assert_contains "restore blocked: stderr names the kept archive" "prev-1.txt" \
    "$(cat "$FX_TMP/restore-blocked.err")"
case_end

# red_expect <desc> <ok?> <detail> — a spec assertion the current source is known to miss.
red_expect() {
    if [ "$2" = 1 ]; then pass "$1"; else fail "$1 — RED-EXPECTED: $3"; fi
}

case_begin "pp-round-restore-target-replaced-by-dir-is-not-silent" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
out="$(restore_probe present-dir)"
err="$(cat "$FX_TMP/restore-present-dir.err")"
ok=0
[[ "$out" == "FINAL_RC=4 snap=kept archive=kept "* && "$err" == *"could not be fully undone"* ]] && ok=1
red_expect "restore target replaced by a directory: FINAL_RC 4, diagnostic, snapshot and archive kept" "$ok" \
    "out=$out err=$err"
case_end

case_begin "pp-round-restore-snapshot-missing-is-not-silent" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
out="$(restore_probe snap-missing)"
err="$(cat "$FX_TMP/restore-snap-missing.err")"
ok=0
[[ "$out" == "FINAL_RC=4 snap=gone archive=kept ledger=C1|new" && "$err" == *"could not be fully undone"* ]] && ok=1
red_expect "snapshot dir missing: diagnostic, restore target not deleted, archive kept" "$ok" \
    "out=$out err=$err"
case_end

finish
