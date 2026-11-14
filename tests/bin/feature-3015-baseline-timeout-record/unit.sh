# shellcheck shell=bash
# tests/bin/feature-3015-baseline-timeout-record/unit.sh
# Tests: bin/lib/run-tests-baseline-timeout.sh
# Tags: run-tests, baseline, timeout, rename, unit, scope:issue-specific, pwsh-not-required, TL2
# #3015 helpers, all probed in one child (tr_unit_probe): requested timeout and its source, the
# recordable predicate, the unrecordable note, and the base path of a test (itself, its rename
# source, or none). One assertion function per case; the entrypoint wraps each in case markers.

tr_unit_probe() {
  tr_drive "$TMPROOT/c-unit" '
for a in "|" "10|" "151|" "250|" "400|" "|20" "151|20"; do
  rtb_timeout_requested_into "${a%%|*}" "${a#*|}"
  printf "REQ %s -> %s %s %s\n" "$a" "${RTB_TIMEOUT_DERIVED_OUT:-}" "${RTB_TIMEOUT_REQUESTED_OUT:-}" "${RTB_TIMEOUT_SRC_OUT:-}"
done
for a in "300 300 300" "299 300 300" "300 20 300" "20 20 10" "540 540 540" "403 500 500"; do
  rc=0; rtb_timeout_recordable $a || rc=$?; printf "REC %s -> %s\n" "$a" "$rc"
done
rtb_timeout_unrecordable_note tests/bin/t.sh 500 500 403
rtb_timeout_unrecordable_note tests/bin/t.sh 10 300 ""
for t in tests/bin/t.sh tests/bin/new-t.sh tests/bin/added.sh; do
  RTB_BASE_REL_OUT=unset RTB_BASE_OLD_OUT=unset
  rtb_rename_base_path_into "$ROOT" "$B2" "$t"
  printf "BASE %s -> [%s] [%s]\n" "$t" "${RTB_BASE_REL_OUT:-}" "${RTB_BASE_OLD_OUT:-}"
done'
}

tr_unit_requested() {
  tr_ck "unmeasured, no explicit: default 300" "REQ | -> 300 300 default" "$(tr_line 'REQ | ')"
  tr_ck "measured 10: derived floor 300" "REQ 10| -> 300 300 derived" "$(tr_line 'REQ 10| ')"
  tr_ck "measured 151: derived 302" "REQ 151| -> 302 302 derived" "$(tr_line 'REQ 151| ')"
  tr_ck "measured 250: derived 500" "REQ 250| -> 500 500 derived" "$(tr_line 'REQ 250| ')"
  tr_ck "measured 400: derived cap 540" "REQ 400| -> 540 540 derived" "$(tr_line 'REQ 400| ')"
  tr_ck "explicit 20, unmeasured: requested 20, derived still 300" "REQ |20 -> 300 20 explicit" "$(tr_line 'REQ |20 ')"
  tr_ck "explicit 20, measured 151: requested 20, derived 302" "REQ 151|20 -> 302 20 explicit" "$(tr_line 'REQ 151|20 ')"
}

tr_unit_recordable() {
  tr_ck "applied = requested = derived: recordable" "REC 300 300 300 -> 0" "$(tr_line 'REC 300 300 300 ')"
  tr_ck "applied below requested: not recordable" "REC 299 300 300 -> 1" "$(tr_line 'REC 299 300 300 ')"
  tr_ck "requested below derived: not recordable" "REC 300 20 300 -> 1" "$(tr_line 'REC 300 20 300 ')"
  tr_ck "requested above derived, applied in full: recordable" "REC 20 20 10 -> 0" "$(tr_line 'REC 20 20 10 ')"
  tr_ck "cap value applied in full: recordable" "REC 540 540 540 -> 0" "$(tr_line 'REC 540 540 540 ')"
  tr_ck "requested above the stage maximum: not recordable" "REC 403 500 500 -> 1" "$(tr_line 'REC 403 500 500 ')"
}

tr_unit_note() {
  tr_has "stage maximum below requested: shorten or split" \
    "run-tests-baseline: timeout not recorded: tests/bin/t.sh requested 500s; the branch stage applies at most 403s: shorten or split the test"
  tr_has "explicit below derived: drop it or raise it" \
    "run-tests-baseline: timeout not recorded: tests/bin/t.sh requested 10s; explicit --per-test-timeout is below the derived 300s: drop it or raise it"
}

tr_unit_base_path() {
  tr_ck "present at base: itself, no old path" "BASE tests/bin/t.sh -> [tests/bin/t.sh] []" "$(tr_line 'BASE tests/bin/t.sh ')"
  tr_ck "renamed on the branch: the old path, twice" \
    "BASE tests/bin/new-t.sh -> [tests/bin/old-t.sh] [tests/bin/old-t.sh]" "$(tr_line 'BASE tests/bin/new-t.sh ')"
  tr_ck "added on the branch: none" "BASE tests/bin/added.sh -> [] []" "$(tr_line 'BASE tests/bin/added.sh ')"
}
