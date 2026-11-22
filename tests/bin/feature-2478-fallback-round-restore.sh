#!/usr/bin/env bash
# Tests: bin/lib/codex-review-loop/prestaged-path-pass.sh, bin/lib/codex-review-loop/verdict-sentinel.sh
# Tags: feature-2478, codex-review-loop, cc-fallback, prestaged, round-restore, review-record, round-lock, scope:issue-specific, TL2
#
# #2478 T6 (S1-4): a CC-fallback round that does not reach the review record is undone whole:
# counter rolled back, ledger / unresolved-concerns / round-1 archive restored, row neither
# appended nor parked (append --no-park). Row, counter and ledger move together; a codex
# round whose record fails still parks (unchanged). The record fails for real: the copied
# bin/review-rounds delegates to the real CLI with the record path made a directory (EISDIR).
# TL3 gap: a disk-full or permission failure of the real host filesystem mid-round.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2937-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2937-review-loop/fixture.sh"
# shellcheck source=tests/bin/feature-2478-fallback/helpers.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2478-fallback/helpers.sh"

# The copied bin/review-rounds becomes a delegating wrapper. FX_APPEND_FAIL=1 makes `append`
# meet a directory at the record path; FX_CLOSE_FAIL=1 lets the append land but turns this
# run's inflight into a non-empty directory, so the close after it fails.
# FX_APPEND_LAND_THEN_FAIL=1 runs the real append, then ends 4 whatever it returned.
# FX_MOVE_ROUND_NAME / FX_MOVE_ROUND_TO: derive-ext (between prestaged_next_round and the
# advance) writes that counter file as another writer would.
mv "$ROOT/bin/review-rounds" "$ROOT/bin/review-rounds-real"
cat > "$ROOT/bin/review-rounds" <<'STUB'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const path = require("path");
const { spawnSync } = require("child_process");
const argv = process.argv.slice(2);
const opt = (k) => { const i = argv.indexOf(`--${k}`); return i < 0 ? "" : argv[i + 1]; };
const real = () => spawnSync(process.execPath, [path.join(__dirname, "review-rounds-real"), ...argv], { stdio: "inherit" }).status;
if (argv[0] === "derive-ext" && process.env.FX_MOVE_ROUND_NAME) {
  const ctlDir = path.join(process.env.WORKFLOW_STATE_DIR, `${opt("session")}.control`);
  fs.writeFileSync(path.join(ctlDir, process.env.FX_MOVE_ROUND_NAME), `${process.env.FX_MOVE_ROUND_TO}\n`);
}
if (argv[0] === "append" && process.env.FX_APPEND_LAND_THEN_FAIL === "1") { real(); process.exit(4); }
if (argv[0] !== "append" || (process.env.FX_APPEND_FAIL !== "1" && process.env.FX_CLOSE_FAIL !== "1")) process.exit(real());
const dir = path.join(process.env.WORKFLOW_STATE_DIR, `${opt("session")}.control`);
const rec = path.join(dir, `${opt("format")}-review-rounds.jsonl`);
if (process.env.FX_CLOSE_FAIL === "1") {
  const inf = path.join(dir, `${opt("format")}-review-rounds-inflight-${opt("run-id")}.json`);
  fs.rmSync(inf, { force: true });
  fs.mkdirSync(path.join(inf, "keep"), { recursive: true });
  process.exit(real());
}
const aside = `${rec}.fx-aside`;
const had = fs.existsSync(rec);
if (had) fs.renameSync(rec, aside);
fs.mkdirSync(rec);
const rc = real();
fs.rmSync(rec, { recursive: true, force: true });
if (had) fs.renameSync(aside, rec);
process.exit(rc);
STUB
# FX_REDUCE_FAIL=1: the concern-ledger reduce writes the ledger and unresolved-concerns, then fails.
mv "$ROOT/bin/concern-ledger" "$ROOT/bin/concern-ledger.real"
cat > "$ROOT/bin/concern-ledger" <<'STUB'
#!/usr/bin/env bash
self_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
bash "$self_dir/concern-ledger.real" "$@"
rc=$?
if [[ "${1:-}" == reduce && "${FX_REDUCE_FAIL:-}" == 1 ]]; then exit 7; fi
exit "$rc"
STUB

CAP=(--cap 4 --max-extensions 0 --extensions-used 0)
# state <sid> <fmt> — ledger | unresolved-concerns | ROUND_FILE | rows, as one comparable line.
state() {
    printf '%s|%s|%s|%s' "$(clf_digest "$(ledger_of "$1" "$2")")" "$(clf_digest "$(artifact_of "$1" "$2")")" \
        "$(clf_read "$(round_file "$1" "$2")")" "$(rows "$1" "$2")"
}
# round_one <sid> <fmt> — a completed fallback round 1 with two open HIGHs.
round_one() {
    seed_sid "$1"
    report "$FX_TMP/$1-r1.md" "$(verdict_of "$2")" "C1. [HIGH] the counter is lost" "C2. [HIGH] the ledger is rewritten"
    fb "$1" "$2" "$FX_TMP/$1-r1.md" "${CAP[@]}"
    assert_eq "$1 setup round 1: exit 1" "1" "$L_RC"
}
# undone <label> <sid> <fmt> <state-before> — the round left no trace at all.
undone() {
    assert_eq "$1: exit 4" "4" "$L_RC"
    assert_not_contains "$1: not refused as a format without prestaged support" "not permitted" "$L_ERR"
    assert_eq "$1: ledger / unresolved-concerns / ROUND_FILE / rows as before the round" "$4" "$(state "$2" "$3")"
    assert_eq "$1: the row is not parked for replay" "missing" "$(clf_file_state "$(side "$2" "$3" -unrecorded.jsonl)")"
    assert_eq "$1: no inflight left" "0" "$(inflights "$2" "$3")"
    rr preflight --session "$2" --format "$3"
    assert_eq "$1: the next preflight succeeds" "0" "$R_RC"
    assert_eq "$1: the next preflight replays no row" "$(printf '%s' "$4" | cut -d'|' -f4)" "$(rows "$2" "$3")"
    rr inflight-close --session "$2" --format "$3" --run-id "$R_OUT"
}

echo "=== T6: a NEEDS_REVISION round whose append fails is undone ==="
case_begin "needs-revision-round-with-failed-append-is-undone" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t6n
F=detail-plan
round_one "$sid" "$F"
before="$(state "$sid" "$F")"
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: resolved — kept now" "C2: unresolved — still rewritten"
FX_APPEND_FAIL=1 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
undone "append failure at round 2" "$sid" "$F" "$before"
assert_eq "C1 is still open after the undo" "open" \
    "$(ledger_rows "$sid" "$F" | awk -F'|' '$1 == "C1" { print $3 }')"
case_end

case_begin "approved-round-with-failed-append-restores-the-ledger" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t6a
F=test-review
round_one "$sid" "$F"
before="$(state "$sid" "$F")"
report "$FX_TMP/$sid-r2.md" APPROVED
FX_APPEND_FAIL=1 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
undone "APPROVED with append failure" "$sid" "$F" "$before"
assert_eq "the converged ledger is back, not deleted" "present" "$(clf_file_state "$(ledger_of "$sid" "$F")")"
case_end

echo ""
echo "=== T6: a ledger write that fails mid-way (after reduce wrote) is undone ==="
case_begin "mid-reduce-failure-is-undone" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t6m
F=security-plan
round_one "$sid" "$F"
before="$(state "$sid" "$F")"
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: resolved — kept now" "C2: unresolved — still rewritten"
FX_REDUCE_FAIL=1 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
undone "reduce failure at round 2" "$sid" "$F" "$before"
case_end

echo ""
echo "=== T6: a failed round 1 brings the archived old-cycle ledger back ==="
case_begin "round-one-failure-restores-the-archived-ledger" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t6r
F=outline-plan
seed_sid "$sid"
loop "$sid" "$F" "${CAP[@]}"
rm -f "$(round_file "$sid" "$F")"
old="$(clf_digest "$(ledger_of "$sid" "$F")")"
assert_ne "setup: an old-cycle ledger exists" "absent" "$old"
before="$(state "$sid" "$F")"
report "$FX_TMP/$sid-r1.md" "$(verdict_of "$F")" "C1. [HIGH] the new cycle's concern"
FX_REDUCE_FAIL=1 fb "$sid" "$F" "$FX_TMP/$sid-r1.md" "${CAP[@]}"
undone "round 1 failure" "$sid" "$F" "$before"
assert_eq "the old-cycle ledger is back with its content" "$old" "$(clf_digest "$(ledger_of "$sid" "$F")")"
assert_eq "no .prev-* archive is left" "0" "$(find "$(ctl "$sid")" -maxdepth 1 -name '.prev-*' | grep -c .)"
assert_eq "no ROUND_FILE" "missing" "$(clf_file_state "$(round_file "$sid" "$F")")"
case_end

echo ""
echo "=== T6: an append that lands but whose inflight close fails keeps row, counter and ledger in step ==="
case_begin "row-counter-ledger-stay-in-step-on-close-failure" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t6c
F=detail-plan
round_one "$sid" "$F"
led0="$(clf_digest "$(ledger_of "$sid" "$F")")"
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: resolved — kept now" "C2: unresolved — still rewritten"
FX_CLOSE_FAIL=1 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
assert_not_contains "close failure: not refused as a format without prestaged support" "not permitted" "$L_ERR"
yn() { if [ "$1" = "$2" ]; then printf n; else printf y; fi; }
triple="$(yn "$(rows "$sid" "$F")" 1)$(yn "$(clf_read "$(round_file "$sid" "$F")")" 1)$(yn "$(clf_digest "$(ledger_of "$sid" "$F")")" "$led0")"
case "$triple" in
    yyy|nnn) pass "close failure: row / counter / ledger moved together ($triple)" ;;
    *) fail "close failure: row / counter / ledger out of step (row,counter,ledger changed = $triple)" ;;
esac
assert_eq "close failure: the row is not parked for a second replay" "missing" \
    "$(clf_file_state "$(side "$sid" "$F" -unrecorded.jsonl)")"
find "$(ctl "$sid")" -maxdepth 1 -name "$F-review-rounds-inflight-*" -exec rm -rf {} +
case_end

echo ""
echo "=== Unchanged: a codex round whose record fails still parks the row ==="
case_begin "codex-round-record-failure-still-parks" "bin/lib/codex-review-loop/verdict-sentinel.sh"
sid=t6p
F=detail-plan
seed_sid "$sid"
FX_APPEND_FAIL=1 loop "$sid" "$F" "${CAP[@]}"
assert_ne "codex round with a failed record: not a clean exit" "0" "$L_RC"
assert_eq "codex round: the row is parked" "present" "$(clf_file_state "$(side "$sid" "$F" -unrecorded.jsonl)")"
assert_eq "codex round: the counter is committed" "1" "$(clf_read "$(round_file "$sid" "$F")")"
rr preflight --session "$sid" --format "$F"
assert_eq "codex round: the next preflight replays the parked row" "1" "$(rows "$sid" "$F")"
case_end

snaps() { find "$(ctl "$1")" -maxdepth 1 -name '.pp-snap-*' | grep -c .; }

echo ""
echo "=== C1: an append that lands although the CLI ends non-zero keeps the round ==="
case_begin "landed-append-with-failed-cli-is-not-undone" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t7l
F=detail-plan
round_one "$sid" "$F"
led0="$(clf_digest "$(ledger_of "$sid" "$F")")"
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: resolved — kept now" "C2: unresolved — still rewritten"
FX_APPEND_LAND_THEN_FAIL=1 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
assert_eq "landed append: the record holds round 1 and round 2" "2" "$(rows "$sid" "$F")"
assert_eq "landed append: the last row is round 2" "2" "$(row "$sid" "$F" -1 counter_round)"
assert_eq "landed append: the counter holds round 2 (NEEDS_REVISION continues)" "2" "$(clf_read "$(round_file "$sid" "$F")")"
assert_ne "landed append: the ledger keeps this round's fold" "$led0" "$(clf_digest "$(ledger_of "$sid" "$F")")"
assert_eq "landed append: C1 is resolved by this round" "resolved" \
    "$(ledger_rows "$sid" "$F" | awk -F'|' '$1 == "C1" { print $3 }')"
assert_eq "landed append: no snapshot dir is left" "0" "$(snaps "$sid")"
assert_contains "landed append: stderr says the row landed" "landed" "$L_ERR"
assert_eq "landed append: the row is not parked" "missing" "$(clf_file_state "$(side "$sid" "$F" -unrecorded.jsonl)")"
case_end

echo ""
echo "=== C2: the path-kind round holds the round lock ==="
case_begin "held-round-lock-refuses-the-round-untouched" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t7k
F=test-review
round_one "$sid" "$F"
before="$(state "$sid" "$F")"
lock="$(round_file "$sid" "$F").lock"
mkdir "$lock"
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: resolved — kept now" "C2: unresolved — still rewritten"
LOCK_SLEEP=0.01 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
undone "held round lock" "$sid" "$F" "$before"
assert_eq "held round lock: no snapshot dir is left" "0" "$(snaps "$sid")"
assert_eq "held round lock: the other holder's lock is not removed" "present" "$([[ -d "$lock" ]] && printf present || printf missing)"
rmdir "$lock"
case_end

case_begin "path-round-snapshot-is-taken-under-the-round-lock" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t7i
F=detail-plan
round_one "$sid" "$F"
uc="$(artifact_of "$sid" "$F")"
lock="$(round_file "$sid" "$F").lock"
mkdir "$lock"
# The other holder writes once this run waits (its snapshot is taken, or 3 s pass), then lets go.
(
    for _ in $(seq 1 200); do [[ "$(inflights "$sid" "$F")" != 0 ]] && break; sleep 0.05; done
    for _ in $(seq 1 30); do [[ "$(snaps "$sid")" != 0 ]] && break; sleep 0.1; done
    printf '\n' >> "$uc"
    cp -p "$uc" "$FX_TMP/$sid-uc-by-holder"
    rmdir "$lock"
) &
holder=$!
report "$FX_TMP/$sid-r2.md" NEEDS_REVISION "C1: resolved — kept now" "C2: unresolved — still rewritten"
LOCK_SLEEP=0.1 FX_APPEND_FAIL=1 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
wait "$holder"
assert_eq "interleaved holder: the failed round exits 4" "4" "$L_RC"
assert_eq "interleaved holder: the undo keeps the holder's write" \
    "$(clf_digest "$FX_TMP/$sid-uc-by-holder")" "$(clf_digest "$uc")"
assert_eq "interleaved holder: no snapshot dir is left" "0" "$(snaps "$sid")"
case_end

case_begin "successful-path-round-leaves-no-round-lock" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t7s
F=security-plan
round_one "$sid" "$F"
assert_eq "after a recorded fallback round: no round lock is left" "missing" \
    "$(clf_file_state "$(round_file "$sid" "$F").lock")"
case_end

echo ""
echo "=== C3: a round counter moved between the next-round read and the advance halts untouched ==="
case_begin "round-moved-before-the-advance-exits-4-untouched" "bin/lib/codex-review-loop/prestaged-path-pass.sh"
sid=t7m
F=outline-plan
round_one "$sid" "$F"
rf="$(round_file "$sid" "$F")"
led0="$(clf_digest "$(ledger_of "$sid" "$F")")|$(clf_digest "$(artifact_of "$sid" "$F")")"
report "$FX_TMP/$sid-r2.md" "$(verdict_of "$F")" "C1: resolved — kept now" "C2: unresolved — still rewritten"
FX_MOVE_ROUND_NAME="${rf#"$(ctl "$sid")/"}" FX_MOVE_ROUND_TO=3 fb "$sid" "$F" "$FX_TMP/$sid-r2.md" "${CAP[@]}"
assert_eq "round moved: exit 4" "4" "$L_RC"
assert_contains "round moved: stderr names the move" "the round moved from 2 to 4" "$L_ERR"
assert_eq "round moved: ledger and unresolved-concerns as before the round" "$led0" \
    "$(clf_digest "$(ledger_of "$sid" "$F")")|$(clf_digest "$(artifact_of "$sid" "$F")")"
assert_eq "round moved: the counter rolls back to the other writer's value, not this run's 4" "3" "$(clf_read "$rf")"
assert_eq "round moved: no row is appended" "1" "$(rows "$sid" "$F")"
assert_eq "round moved: the row is not parked" "missing" "$(clf_file_state "$(side "$sid" "$F" -unrecorded.jsonl)")"
assert_eq "round moved: no inflight left" "0" "$(inflights "$sid" "$F")"
assert_eq "round moved: no snapshot dir is left" "0" "$(snaps "$sid")"
assert_eq "round moved: no round lock is left" "missing" "$(clf_file_state "$rf.lock")"
case_end

finish
