#!/usr/bin/env bash
# tests/bin/feature-2434-legacy-arg-shim.sh
# Tests: bin/workflow/normalize-judge-signals, bin/workflow/derive-complexity-level, skills/clarify-intent/scripts/precheck-companions.sh, bin/concern-ledger
# Tags: feature-2434, control-dir, legacy-migration, legacy-arg-shim, TL1, scope:issue-specific, pwsh-not-required
#
# #2434 Step 5-6: a flow that loaded the old SKILL text still passes the old
# PLANS_DIR path. The shim accepts it only when its basename is the expected
# legacy one, and always reads/writes the derived <sid>.control/ path instead.
set -uo pipefail

# TL1 — real CLIs against the shared fixture's temp dirs. The session comes from
# CLAUDE_CODE_SESSION_ID, as it does for a flow that only knows the old arguments.
# Worker payload fields are pinned in feature-2434-worker-payload-cli.sh.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
# shellcheck source=tests/bin/feature-2434-review-loop/fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2434-review-loop/fixture.sh"

NJS="$SCRIPT_CHECKOUT_ROOT/bin/workflow/normalize-judge-signals"
DCL="$SCRIPT_CHECKOUT_ROOT/bin/workflow/derive-complexity-level"

# cli <sid> <cmd...> — one call under CLAUDE_CODE_SESSION_ID=<sid>. Sets C_RC / C_OUT.
cli() {
    local sid="$1"; shift
    C_RC=0
    CLAUDE_CODE_SESSION_ID="$sid" "$@" >"$TMP/cli.out" 2>/dev/null || C_RC=$?
    C_OUT="$(tr -d '\r' < "$TMP/cli.out")"
}

case_begin "normalize-out-accepts-the-legacy-basename" "bin/workflow/normalize-judge-signals"
SID="sh-norm"
for ST in complexity detail write-tests write-code; do
    printf 'not a signals line\n' > "$P/$SID-$ST-judge-raw.txt"
    C_RC=0
    CLAUDE_CODE_SESSION_ID="$SID" node "$NJS" --raw-file "$P/$SID-$ST-judge-raw.txt" \
        --out "$P/$SID-$ST-signals.txt" >/dev/null 2>&1 || C_RC=$?
    assert_eq "$ST: legacy --out is accepted" "0" "$C_RC"
    assert_eq "$ST: written to <sid>.control/$ST-signals.txt" "S0-undecidable" "$(clf_read "$(ctl "$SID")/$ST-signals.txt")"
    assert_eq "$ST: nothing written at the legacy PLANS path" "absent" "$(state "$P/$SID-$ST-signals.txt")"
done
case_end

case_begin "normalize-out-rejects-other-paths" "bin/workflow/normalize-judge-signals"
SID="sh-norm-bad"
printf 'not a signals line\n' > "$P/$SID-detail-judge-raw.txt"
for OUT in "$TMP/elsewhere-signals.txt" "$P/$SID-bogus-signals.txt" "$P/$SID-detail-signals.json"; do
    C_RC=0
    CLAUDE_CODE_SESSION_ID="$SID" node "$NJS" --raw-file "$P/$SID-detail-judge-raw.txt" \
        --out "$OUT" >/dev/null 2>&1 || C_RC=$?
    assert_ne "--out ${OUT##*/} is refused" "0" "$C_RC"
    assert_eq "--out ${OUT##*/} was not written" "absent" "$(state "$OUT")"
done
case_end

case_begin "derive-signals-file-reads-the-derived-path" "bin/workflow/derive-complexity-level"
# The signals sit only in the control dir; the legacy path does not exist, so a
# level can only come from the derived path.
SID="sh-derive"
mkdir -p "$(ctl "$SID")"
for ROW in detail:detail write_tests:write-tests write_code:write-code; do
    STAGE="${ROW%%:*}"; NAME="${ROW#*:}"
    printf 'S0-undecidable' > "$(ctl "$SID")/$NAME-signals.txt"
    WANT="$(node "$DCL" --stage "$STAGE" --signals S0-undecidable 2>/dev/null | tr -d '\r')"
    cli "$SID" node "$DCL" --stage "$STAGE" --signals-file "$P/$SID-$NAME-signals.txt"
    assert_eq "$STAGE: legacy --signals-file is accepted" "0" "$C_RC"
    assert_eq "$STAGE: the level comes from <sid>.control/$NAME-signals.txt" "$WANT" "$C_OUT"
done
printf 'S0-undecidable' > "$TMP/foreign-signals.txt"
cli "$SID" node "$DCL" --stage detail --signals-file "$TMP/foreign-signals.txt"
assert_ne "a --signals-file outside the legacy basename is refused" "0" "$C_RC"
case_end

case_begin "precheck-output-file-accepts-the-legacy-basename" "skills/clarify-intent/scripts/precheck-companions.sh"
# companion-search.sh is mocked beside a copy of the script (it shells out to gh).
SC="$ROOT/skills/clarify-intent/scripts"
mkdir -p "$SC"
cp "$SCRIPT_CHECKOUT_ROOT/skills/clarify-intent/scripts/precheck-companions.sh" "$SC/"
printf '#!/usr/bin/env bash\nprintf "201\\tSome title\\tident:x\\tOPEN\\n"\nexit 0\n' > "$SC/companion-search.sh"
chmod +x "$SC/companion-search.sh"
pre() {
    C_RC=0
    CLAUDE_CODE_SESSION_ID="$1" bash "$SC/precheck-companions.sh" \
        --seed 100 --exclude 100 --output-file "$2" >/dev/null 2>&1 || C_RC=$?
}
SID="sh-pre"
pre "$SID" "$P/$SID-companion-precheck.json"
assert_eq "legacy --output-file is accepted" "0" "$C_RC"
assert_contains "snapshot written to <sid>.control/companion-precheck.json" "201" \
    "$(cat "$(ctl "$SID")/companion-precheck.json" 2>/dev/null)"
assert_eq "nothing written at the legacy PLANS path" "absent" "$(state "$P/$SID-companion-precheck.json")"
pre "$SID" "$TMP/snap.json"
assert_ne "an --output-file outside the legacy basename is refused" "0" "$C_RC"
assert_eq "and is not written" "absent" "$(state "$TMP/snap.json")"
case_end

case_begin "concern-ledger-plans-dir-keeps-the-ledger-in-control" "bin/concern-ledger"
# --plans-dir now names the concerns-log artifact home only; the ledger and
# the round delta are derived from --session-id.
SID="sh-ledger"
REPORT="$TMP/report.md"
printf '## Codex Review: PERFORMED\n\n## Concern Delta\n\n## HIGH\n- [HIGH] - | reviewed.txt#check_input | correctness | unchecked input reaches the shell\n\n## MEDIUM\n(none)\n\n## LOW\n(none)\n' > "$REPORT"
L_RC=0
bash "$SCRIPT_CHECKOUT_ROOT/bin/concern-ledger" stage --plans-dir "$P" --session-id "$SID" \
    --format review-security-shared --round 1 --producer review-code-codex \
    --from-report "$REPORT" >/dev/null 2>&1 || L_RC=$?
assert_eq "stage with --plans-dir exits 0" "0" "$L_RC"
L_RC=0
bash "$SCRIPT_CHECKOUT_ROOT/bin/concern-ledger" reduce --plans-dir "$P" --session-id "$SID" \
    --format review-security-shared --round 1 >/dev/null 2>&1 || L_RC=$?
assert_eq "reduce with --plans-dir exits 0" "0" "$L_RC"
assert_eq "ledger in <sid>.control/" "present" \
    "$(state "$(ctl "$SID")/review-security-shared-concern-ledger.txt")"
assert_eq "no ledger in PLANS_DIR" "absent" "$(state "$P/$SID-review-security-shared-concern-ledger.txt")"
assert_eq "no round delta in PLANS_DIR" "" "$(plans_leftovers "$SID")"
case_end

# --- Narrowed-contract argument validation: --stage / --session become path components.
CAP="$TMP/cap"
mkdir -p "$CAP"
# run2 <cmd...> — sets R_RC / R_OUT / R_ERR; the capture dir is excluded from snap.
run2() {
    R_RC=0
    "$@" >"$CAP/o" 2>"$CAP/e" || R_RC=$?
    R_OUT="$(tr -d '\r' < "$CAP/o")"; R_ERR="$(tr -d '\r' < "$CAP/e")"
}
# snap — every fixture path except the copied agents tree, the repo and the captures.
snap() { find "$TMP" \( -path "$ROOT" -o -path "$REPO" -o -path "$CAP" \) -prune -o -print | LC_ALL=C sort; }
RAW="$TMP/raw-judge.txt"
printf 'SIGNALS: none\n' > "$RAW"
UP="$(dirname "$TMP")"

case_begin "normalize-session-missing-writes-nothing" "bin/workflow/normalize-judge-signals"
BEFORE="$(snap)"
run2 node "$NJS" --raw-file "$RAW" --stage detail
assert_eq "no --session (and no CLAUDE_CODE_SESSION_ID) exits 2" "2" "$R_RC"
assert_contains "the usage error names --session" "--session is required" "$R_ERR"
assert_eq "nothing written under the fixture" "$BEFORE" "$(snap)"
case_end

case_begin "normalize-stage-outside-vocabulary-writes-nothing" "bin/workflow/normalize-judge-signals"
SID="sh-stage"
for ST in "../x" "a/b" ".." "detail/../../x" "" "DETAIL" "write_tests"; do
    BEFORE="$(snap)"
    run2 node "$NJS" --raw-file "$RAW" --session "$SID" --stage "$ST"
    assert_eq "stage '$ST' exits 2" "2" "$R_RC"
    assert_contains "stage '$ST' names the vocabulary" "--stage must be one of" "$R_ERR"
    assert_eq "stage '$ST': nothing written under the fixture" "$BEFORE" "$(snap)"
    assert_eq "stage '$ST': no <sid>.control created" "absent" "$(state "$(ctl "$SID")")"
done
assert_eq "nothing escaped to the fixture parent" "absent" "$(state "$UP/x-signals.txt")"
run2 node "$NJS" --raw-file "$RAW" --session "$SID" --stage detail
assert_eq "control row: the same raw file with stage detail exits 0" "0" "$R_RC"
assert_eq "control row: detail-signals.txt written (empty CSV)" "present" "$(state "$(ctl "$SID")/detail-signals.txt")"
case_end

case_begin "normalize-every-valid-stage-prints-the-derived-path" "bin/workflow/normalize-judge-signals"
SID="sh-stages"
for ST in complexity outline detail write-tests write-code; do
    run2 node "$NJS" --raw-file "$RAW" --session "$SID" --stage "$ST"
    assert_eq "$ST: exits 0" "0" "$R_RC"
    assert_eq "$ST: prints exactly <sid>.control/$ST-signals.txt" "$(np "$(ctl "$SID")")/$ST-signals.txt" "$R_OUT"
    assert_eq "$ST: the printed file exists" "present" "$(state "$(ctl "$SID")/$ST-signals.txt")"
done
case_end

case_begin "normalize-out-with-stage-or-foreign-session-writes-nothing" "bin/workflow/normalize-judge-signals"
SID="sh-outx"
BEFORE="$(snap)"
run2 node "$NJS" --raw-file "$RAW" --session "$SID" --stage detail --out "$P/$SID-detail-signals.txt"
assert_eq "--out with --stage exits 2" "2" "$R_RC"
assert_contains "--out with --stage is a mutual-exclusion error" "mutually exclusive" "$R_ERR"
run2 node "$NJS" --raw-file "$RAW" --session "$SID" --out "$P/other-sid-detail-signals.txt"
assert_eq "--out naming another session's file under --session exits 2" "2" "$R_RC"
assert_eq "nothing written under the fixture" "$BEFORE" "$(snap)"
case_end

case_begin "derive-signals-and-session-are-mutually-exclusive" "bin/workflow/derive-complexity-level"
SID="sh-dmx"
mkdir -p "$(ctl "$SID")"
printf 'S0-undecidable' > "$(ctl "$SID")/detail-signals.txt"
run2 node "$DCL" --stage detail --signals S0-undecidable --session "$SID"
assert_eq "--signals with --session exits 1" "1" "$R_RC"
assert_contains "the usage error names the exclusion" "mutually exclusive" "$R_ERR"
assert_eq "no level is printed" "" "$R_OUT"
run2 node "$DCL" --stage detail --signals S0-undecidable
assert_eq "control: --signals alone exits 0" "0" "$R_RC"
WANT="$R_OUT"
run2 node "$DCL" --stage detail --session "$SID"
assert_eq "control: --session alone exits 0" "0" "$R_RC"
assert_eq "control: --session alone yields the same level" "$WANT" "$R_OUT"
case_end

case_begin "derive-session-without-control-file-fails" "bin/workflow/derive-complexity-level"
run2 node "$DCL" --stage outline --session "sh-nofile"
assert_eq "a missing control file exits 1" "1" "$R_RC"
assert_contains "the error says the signals could not be read" "signals could not be read:" "$R_ERR"
assert_contains "the error names the derived file" "sh-nofile.control/outline-signals.txt" "${R_ERR//\\//}"
assert_eq "no level is printed" "" "$R_OUT"
case_end

case_begin "derive-stage-traversal-reads-nothing-outside" "bin/workflow/derive-complexity-level"
# Decoys sit where the traversal stages would resolve; a level would prove a read.
SID="sh-dtrav"
mkdir -p "$(ctl "$SID")"
printf 'S1-multi-file,S2-architecture,S3-security' > "$WORKFLOW_STATE_DIR/x-signals.txt"
printf 'S1-multi-file,S2-architecture,S3-security' > "$P/x-signals.txt"
for ST in "../x" "../../plans/x" "detail/../../x" "write-tests" "DETAIL" ""; do
    run2 node "$DCL" --stage "$ST" --session "$SID"
    assert_eq "stage '$ST' exits 1" "1" "$R_RC"
    assert_contains "stage '$ST' names the vocabulary" "--stage must be one of" "$R_ERR"
    assert_eq "stage '$ST': no level printed (decoy not read)" "" "$R_OUT"
done
case_end

case_begin "both-clis-reject-a-traversal-shaped-sid" "bin/workflow/normalize-judge-signals"
for BAD in "../x" ".." "a/b" "..\\x" ".hidden"; do
    BEFORE="$(snap)"
    run2 node "$NJS" --raw-file "$RAW" --session "$BAD" --stage detail
    assert_eq "normalize sid '$BAD' exits 2" "2" "$R_RC"
    assert_contains "normalize sid '$BAD' is an invalid sessionId" "Invalid sessionId" "$R_ERR"
    run2 node "$DCL" --stage detail --session "$BAD"
    assert_eq "derive sid '$BAD' exits 1" "1" "$R_RC"
    assert_contains "derive sid '$BAD' is unresolved" "session control dir unresolved" "$R_ERR"
    assert_eq "derive sid '$BAD': no level printed" "" "$R_OUT"
    assert_eq "sid '$BAD': nothing written under the fixture" "$BEFORE" "$(snap)"
done
assert_eq "nothing escaped to the fixture parent" "absent" "$(state "$UP/x.control")"
case_end

finish
