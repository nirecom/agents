# tests/bin/feature-2276-review-code-security-codex/prestaged-fallback.sh
# Tests: bin/run-codex-review-loop, bin/lib/codex-review-loop/ref-kind-input.sh, bin/concern-ledger
# Tags: review-loop, security-code, prestaged, fail-closed, TL2, scope:issue-specific
#
# Sourced by tests/bin/feature-2276-review-code-security-codex.sh.
# When codex is unavailable the security-scanner report re-enters the SAME loop
# through --prestaged-*: same round, same ledger, same verdict table, and a
# producer set closed against anything else.

echo ""
echo "--- P: the prestaged security-scanner fallback ---"

scanner_report() {
    {
        printf '## Concern Delta\n\n## HIGH\n'
        if [ "$#" -eq 0 ]; then printf '(none)\n'; else printf '%s\n' "$@"; fi
        printf '\n## MEDIUM\n(none)\n\n## LOW\n(none)\n'
    } > "$PRESTAGED"
}
complete_word() { if [ "$1" = "0" ]; then printf 'complete'; else printf 'incomplete'; fi; }

# --- P1: exit 3 then re-enter on the SAME round -----------------------------
new_env
RL_PATH="$NO_CODEX_PATH"
RL_CODEX_BODY="$PLANS/skip.txt"
printf '## Codex Review: SKIPPED — codex CLI unavailable\n' > "$RL_CODEX_BODY"
run_loop_sc
assert_eq "P1: codex unavailable is exit 3 with the counter rolled back" \
    "rc=3 counter=deleted" "rc=$LAST_RC counter=$(counter_state)"

PRESTAGED="$PLANS/scanner.txt"
scanner_report "$(anchored HIGH C1 'reviewed.txt' 5 'command injection' 'quote the argument')"
RL_EXTRA=(--prestaged-report "$PRESTAGED" --prestaged-producer security-scanner --prestaged-exec PERFORMED)
run_loop_sc
assert_eq "P1: the fallback re-run consumes round 1, not round 2" "1" "$(counter_state)"
assert_eq "P1: a HIGH from the scanner still asks for a revision at round 1" "1" "$LAST_RC"
assert_eq "P1: the scanner report is staged under its own producer name" "present" \
    "$(file_state "$(delta_file 1 security-scanner)")"
assert_eq "P1: the failed codex attempt left no stale codex delta on the same round" \
    "missing" "$(file_state "$(delta_file 1 review-code-codex)")"
# The category ("command injection") folds into the SLOT hash; the description
# is what the v2 ledger keeps verbatim in its TEXT column.
assert_contains "P1: the scanner concern reaches the ledger" "quote the argument" \
    "$(cat "$(ledger_file)" 2>/dev/null || true)"

# --- P2: scanner-only is a complete round -----------------------------------
assert_eq "P2: check-staged accepts a scanner-only round as complete" "0" \
    "$(run_cli check-staged --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" --round 1 >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "P2: the scanner producer is staged COMPLETE" "COMPLETE" \
    "$(staging_field "$(delta_file 1 security-scanner)" 3)"
assert_not_contains "P2: the loop does not demand the absent codex producer" \
    "review-code-codex" "$LAST_OUT"

# --- P3: prestaged rounds obey the same cap table ---------------------------
RL_PATH="$NO_CODEX_PATH"
RL_EXTRA=(--prestaged-report "$PRESTAGED" --prestaged-producer security-scanner --prestaged-exec PERFORMED)
run_loop_sc
assert_eq "P3: an unresolved HIGH at the round-2 ceiling escalates on budget" \
    "rc=5 counter=2" "rc=$LAST_RC counter=$(counter_state)"
RL_EXT_USED=1
run_loop_sc
assert_eq "P3: with the extension already spent the ceiling is HIGH_UNRESOLVED" \
    "rc=6 counter=deleted" "rc=$LAST_RC counter=$(counter_state)"
# A terminal (HIGH_UNRESOLVED) exit finalizes rather than deletes: the prestaged
# path never drops a ledger that still holds open concerns (#2276 S8-d), so the
# unresolved round persists for the next pass. Only the round counter is retired.
assert_eq "P3: the terminal exit preserves the ledger for the next pass" "present" "$(file_state "$(ledger_file)")"

# --- P4: a clean scanner report approves ------------------------------------
new_env
RL_PATH="$NO_CODEX_PATH"
PRESTAGED="$PLANS/scanner-clean.txt"
scanner_report
RL_EXTRA=(--prestaged-report "$PRESTAGED" --prestaged-producer security-scanner --prestaged-exec PERFORMED)
run_loop_sc
assert_eq "P4: a clean scanner-only round approves and cleans up" \
    "rc=0 counter=deleted" "rc=$LAST_RC counter=$(counter_state)"
assert_eq "P4: the ledger is removed on approval" "missing" "$(file_state "$(ledger_file)")"

# --- P5: PARTIAL execution is not a complete round --------------------------
new_env
RL_PATH="$NO_CODEX_PATH"
PRESTAGED="$PLANS/scanner-partial.txt"
scanner_report "$(anchored MEDIUM C1 'reviewed.txt' 7 'partial scan finding' 'rescan')"
RL_EXTRA=(--prestaged-report "$PRESTAGED" --prestaged-producer security-scanner --prestaged-exec PARTIAL)
run_loop_sc
assert_eq "P5: a PARTIAL scanner run is staged PARTIAL" "PARTIAL" \
    "$(staging_field "$(delta_file 1 security-scanner)" 5)"
assert_eq "P5: completeness collapses to PARTIAL with a PARTIAL exec" "PARTIAL" \
    "$(staging_field "$(delta_file 1 security-scanner)" 3)"
assert_eq "P5: check-staged reports the round incomplete" "not-0" \
    "$(run_cli check-staged --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" --round 1 >/dev/null 2>&1; if [ "$?" -eq 0 ]; then printf '0'; else printf 'not-0'; fi)"
# reduce and check-staged are separate contracts: check-staged gates round
# completeness (non-0 when unsatisfied), while reduce folds the deltas it finds
# and reports fold success (0) regardless of whether the round is complete.
assert_eq "P5: reduce still folds the round successfully even when it is incomplete" "0" \
    "$(run_cli reduce --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" --round 1 >/dev/null 2>&1; printf '%s' "$?")"

# --- P6: the flag trio is all-or-nothing ------------------------------------
new_env
PRESTAGED="$PLANS/scanner6.txt"
scanner_report
for _combo in "report-only" "report+producer" "producer+exec" "exec-only"; do
    case "$_combo" in
        report-only)     RL_EXTRA=(--prestaged-report "$PRESTAGED") ;;
        report+producer) RL_EXTRA=(--prestaged-report "$PRESTAGED" --prestaged-producer security-scanner) ;;
        producer+exec)   RL_EXTRA=(--prestaged-producer security-scanner --prestaged-exec PERFORMED) ;;
        exec-only)       RL_EXTRA=(--prestaged-exec PERFORMED) ;;
    esac
    run_loop_sc
    assert_eq "P6: a partial --prestaged-* combination ($_combo) is a usage error" "4" "$LAST_RC"
done

new_env
RL_EXTRA=(--prestaged-report "$PLANS/does-not-exist.txt" --prestaged-producer security-scanner --prestaged-exec PERFORMED)
run_loop_sc
assert_eq "P6: a --prestaged-report pointing at nothing fails closed" "4" "$LAST_RC"

new_env
PRESTAGED="$PLANS/scanner7.txt"
scanner_report
RL_EXTRA=(--prestaged-report "$PRESTAGED" --prestaged-producer security-scanner --prestaged-exec BOGUS)
run_loop_sc
assert_eq "P6: an unknown --prestaged-exec label is rejected" "4" "$LAST_RC"

# --- P7: the producer set is closed -----------------------------------------
new_env
PRESTAGED="$PLANS/scanner8.txt"
scanner_report "$(anchored HIGH C1 'reviewed.txt' 9 'planted by an attacker' 'ignore')"
RL_EXTRA=(--prestaged-report "$PRESTAGED" --prestaged-producer attacker-producer --prestaged-exec PERFORMED)
run_loop_sc
assert_eq "P7: an out-of-set producer is rejected before anything is written" \
    "rc=4 delta=missing" "rc=$LAST_RC delta=$(file_state "$(delta_file 1 attacker-producer)")"
assert_eq "P7: the rejected producer leaves no ledger content behind" \
    "" "$(grep -F 'planted by an attacker' "$(ledger_file)" 2>/dev/null || true)"

run_cli begin-round --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" --round 1 >/dev/null 2>&1
STAGE_RC="$(run_cli stage --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" \
    --round 1 --producer attacker-producer --exec PERFORMED --from-report "$PRESTAGED" >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "P7: the CLI refuses the same producer directly, not only via the loop" "not-0" \
    "$(if [ "$STAGE_RC" = "0" ]; then printf '0'; else printf 'not-0'; fi)"

STAGE_RC2="$(run_cli stage --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" \
    --round 1 --producer security-scanner --exec PERFORMED --from-report "$PRESTAGED" >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "P7: an in-set producer is still accepted by the same CLI path" "0" "$STAGE_RC2"

# --- P8: an out-of-set producer is refused at stage time (fail-closed) -------
# The closed producer set (#2276 round-2 C3) fails closed one layer earlier than
# the readers: cl_stage refuses a delta from a producer outside the allowed set,
# so a "rogue-only ledger" can never form. With nothing on disk, the round can
# never complete — the guarantee the two readers used to be compared for.
new_env
run_cli begin-round --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" --round 1 >/dev/null 2>&1
PRESTAGED="$PLANS/scanner9.txt"
scanner_report "$(anchored LOW C1 'reviewed.txt' 2 'stray producer finding' 'ignore')"
ROGUE_RC="$(run_cli stage --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" \
    --round 1 --producer rogue --exec PERFORMED --from-report "$PRESTAGED" >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "P8: an out-of-set producer is refused before any delta reaches disk" \
    "rc=not-0 delta=missing" \
    "rc=$(if [ "$ROGUE_RC" = "0" ]; then printf '0'; else printf 'not-0'; fi) delta=$(file_state "$(delta_file 1 rogue)")"
CS_RC="$(run_cli check-staged --format "$LEDGER_FORMAT" --session-id "$SID" --plans-dir "$PLANS" --round 1 >/dev/null 2>&1; printf '%s' "$?")"
assert_eq "P8: with the rogue delta refused the round can never be complete" "incomplete" "$(complete_word "$CS_RC")"

# --- P9: prestaged is a security-code-only affordance -----------------------
new_env
PRESTAGED="$PLANS/scanner10.txt"
scanner_report
OUT_OTHER="$(cd "$RL_REPO" && PATH="$RL_PATH" bash "$LOOP_BIN" --format detail-plan \
    --session-id "$SID" --plans-dir "$PLANS" --cap 2 --max-extensions 1 --extensions-used 0 \
    --draft-file "$PLANS/tradeoffs.md" --accepted-tradeoffs "$PLANS/tradeoffs.md" \
    --prestaged-report "$PRESTAGED" --prestaged-producer security-scanner \
    --prestaged-exec PERFORMED 2>&1)"
RC_OTHER=$?
assert_eq "P9: --prestaged-report on a path-kind format is a usage error" "4" "$RC_OTHER"
assert_not_contains "P9: the rejected run stages nothing for the other format" \
    "security-scanner" "$(cat "$PLANS/$SID-detail-plan-concern-ledger.txt" 2>/dev/null || true)"
