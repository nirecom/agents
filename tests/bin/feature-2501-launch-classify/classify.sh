# tests/bin/feature-2501-launch-classify/classify.sh
# Tests: bin/lib/run-all-classify.sh
# Tags: TL1, bin, run-all, classify, timeout, prepare-failed, scope:issue-specific
# rac_classify <rc> <launched> <resultdir>: every branch in its order (UNSUPPORTED > UNRUNNABLE >
# prepare-failed > timed-out marker > FAIL record > all-SKIP > rc). No elapsed argument: TIMEOUT is
# the timer's fired marker, never inferred from rc and time (#2501 C2). rac_effective_timeout
# <entry-timeout>: the entry value capped by a positive-integer RUN_ALL_TIMEOUT_SECONDS.
# Sourced by the dispatcher.

echo ""
echo "=== classify ==="

CD="$TMPBASE/cls-dirs"
mkdir -p "$CD/empty"

case_begin "unsupported-only-when-not-launched" "bin/lib/run-all-classify.sh"
assert_eq "78 not launched: $(cls_state 78 0 "$CD/empty")" "78 not launched: UNSUPPORTED"
assert_eq "78 launched: $(cls_state 78 1 "$CD/empty")" "78 launched: FAIL"
case_end

case_begin "unrunnable-needs-the-marker" "bin/lib/run-all-classify.sh"
mkdir -p "$CD/m-pwsh" "$CD/m-pester"
printf 'pwsh\n' >"$CD/m-pwsh/unrunnable"
printf 'Pester>=5.0\n' >"$CD/m-pester/unrunnable"
assert_eq "79 + marker pwsh: $(cls 79 0 "$CD/m-pwsh")" "79 + marker pwsh: UNRUNNABLE|79|pwsh"
assert_eq "79 + marker Pester: $(cls 79 1 "$CD/m-pester")" "79 + marker Pester: UNRUNNABLE|79|Pester>=5.0"
# A test's own exit 79 (no marker) is a failure, never UNRUNNABLE.
assert_eq "79 without marker: $(cls_state 79 1 "$CD/empty")" "79 without marker: FAIL"
# A launched child may name only a minimum-version label; an executable is the launcher's finding.
assert_eq "79 + marker pwsh, launched: $(cls_state 79 1 "$CD/m-pwsh")" "79 + marker pwsh, launched: FAIL"
assert_eq "79 + marker Pester, not launched: $(cls_state 79 0 "$CD/m-pester")" "79 + marker Pester, not launched: FAIL"
case_end

case_begin "prepare-failed-marker-is-fail" "bin/lib/run-all-classify.sh"
# A suite prepare that failed never started the command: FAIL with the prepare's rc, whatever it was.
mkdir -p "$CD/prep-failed"
: >"$CD/prep-failed/prepare-failed"
assert_eq "rc 3 + prepare-failed: $(cls 3 0 "$CD/prep-failed")" "rc 3 + prepare-failed: FAIL|3|"
assert_eq "rc 0 + prepare-failed: $(cls_state 0 0 "$CD/prep-failed")" "rc 0 + prepare-failed: FAIL"
assert_eq "rc 77 + prepare-failed: $(cls_state 77 0 "$CD/prep-failed")" "rc 77 + prepare-failed: FAIL"
# Order: UNRUNNABLE is decided before prepare-failed.
mkdir -p "$CD/prep-unrun"
: >"$CD/prep-unrun/prepare-failed"
printf 'pwsh\n' >"$CD/prep-unrun/unrunnable"
assert_eq "79 + unrunnable + prepare-failed: $(cls_state 79 0 "$CD/prep-unrun")" "79 + unrunnable + prepare-failed: UNRUNNABLE"
case_end

case_begin "timeout-needs-the-fired-marker" "bin/lib/run-all-classify.sh"
mkdir -p "$CD/fired"
: >"$CD/fired/timed-out"
# With the marker, any rc is TIMEOUT 124: the marker is written only when the timer fired.
for rc in 124 137 142 143 0 1 77; do
  assert_eq "rc $rc + timed-out: $(cls "$rc" 1 "$CD/fired")" "rc $rc + timed-out: TIMEOUT|124|"
done
# Without it, a child's own signal-shaped rc is its failure, kept as the child's rc.
for rc in 124 137 142 143; do
  assert_eq "rc $rc, no marker: $(cls "$rc" 1 "$CD/empty")" "rc $rc, no marker: FAIL|$rc|"
done
# Order: prepare-failed is decided before the timed-out marker.
mkdir -p "$CD/prep-fired"
: >"$CD/prep-fired/prepare-failed"
: >"$CD/prep-fired/timed-out"
assert_eq "prepare-failed + timed-out: $(cls_state 124 0 "$CD/prep-fired")" "prepare-failed + timed-out: FAIL"
case_end

case_begin "all-explicit-skip-records-make-skip" "bin/lib/run-all-classify.sh"
mkcases "$CD/allskip" "1 OPEN a" "1 SKIP a" "2 OPEN b" "2 SKIP b"
assert_eq "rc 0 + all SKIP: $(cls 0 1 "$CD/allskip")" "rc 0 + all SKIP: SKIP|77|"
# An unfinished OPEN case never counts against the all-SKIP rule.
mkcases "$CD/skip-open" "1 OPEN a" "1 SKIP a" "2 OPEN b"
assert_eq "rc 0 + SKIP/OPEN: $(cls 0 1 "$CD/skip-open")" "rc 0 + SKIP/OPEN: SKIP|77|"
case_end

# A deferred-assertion file (bq_flush after case_end) records its passing cases UNOBSERVED.
case_begin "unobserved-record-defeats-all-skip" "bin/lib/run-all-classify.sh"
mkcases "$CD/unobs-skip" "1 OPEN a" "1 UNOBSERVED a" "2 OPEN b" "2 UNOBSERVED b" "3 OPEN c" "3 SKIP c"
assert_eq "rc 0 + UNOBSERVED x2 + SKIP: $(cls 0 1 "$CD/unobs-skip")" "rc 0 + UNOBSERVED x2 + SKIP: PASS|0|"
mkcases "$CD/skip-unobs-open" "1 OPEN a" "1 SKIP a" "2 OPEN b" "2 UNOBSERVED b" "3 OPEN c"
assert_eq "rc 0 + SKIP/UNOBSERVED/OPEN: $(cls 0 1 "$CD/skip-unobs-open")" "rc 0 + SKIP/UNOBSERVED/OPEN: PASS|0|"
assert_eq "rc 1 + UNOBSERVED + SKIP: $(cls 1 1 "$CD/unobs-skip")" "rc 1 + UNOBSERVED + SKIP: FAIL|1|"
assert_eq "rc 77 + UNOBSERVED + SKIP: $(cls 77 1 "$CD/unobs-skip")" "rc 77 + UNOBSERVED + SKIP: SKIP|77|"
case_end

case_begin "unobserved-resolution-last-record-wins" "bin/lib/run-all-classify.sh"
mkcases "$CD/seq-unobs-last" "1 OPEN a" "1 SKIP a" "1 UNOBSERVED a" "2 OPEN b" "2 SKIP b"
assert_eq "SKIP then UNOBSERVED on one seq: $(cls_state 0 1 "$CD/seq-unobs-last")" "SKIP then UNOBSERVED on one seq: PASS"
mkcases "$CD/seq-unobs-first" "1 OPEN a" "1 UNOBSERVED a" "1 SKIP a" "2 OPEN b" "2 SKIP b"
assert_eq "UNOBSERVED then SKIP on one seq: $(cls_state 0 1 "$CD/seq-unobs-first")" "UNOBSERVED then SKIP on one seq: SKIP"
case_end

case_begin "rc0-without-explicit-skip-stays-pass" "bin/lib/run-all-classify.sh"
mkcases "$CD/unobs" "1 OPEN a" "1 UNOBSERVED a"
assert_eq "rc 0 + only UNOBSERVED: $(cls 0 1 "$CD/unobs")" "rc 0 + only UNOBSERVED: PASS|0|"
mkcases "$CD/open-only" "1 OPEN a"
assert_eq "rc 0 + only OPEN: $(cls_state 0 1 "$CD/open-only")" "rc 0 + only OPEN: PASS"
mkcases "$CD/pass-skip" "1 OPEN a" "1 PASS a" "2 OPEN b" "2 SKIP b"
assert_eq "rc 0 + PASS and SKIP: $(cls 0 1 "$CD/pass-skip")" "rc 0 + PASS and SKIP: PASS|0|"
assert_eq "rc 0 + no cases.tsv: $(cls 0 1 "$CD/empty")" "rc 0 + no cases.tsv: PASS|0|"
mkdir -p "$CD/emptyfile"
: >"$CD/emptyfile/cases.tsv"
assert_eq "rc 0 + empty cases.tsv: $(cls_state 0 1 "$CD/emptyfile")" "rc 0 + empty cases.tsv: PASS"
case_end

case_begin "last-record-per-seq-wins" "bin/lib/run-all-classify.sh"
mkcases "$CD/seq-skip-last" "1 PASS a" "1 SKIP a"
assert_eq "PASS then SKIP on one seq: $(cls_state 0 1 "$CD/seq-skip-last")" "PASS then SKIP on one seq: SKIP"
mkcases "$CD/seq-pass-last" "1 SKIP a" "1 PASS a"
assert_eq "SKIP then PASS on one seq: $(cls_state 0 1 "$CD/seq-pass-last")" "SKIP then PASS on one seq: PASS"
mkcases "$CD/seq-mixed" "1 OPEN a" "1 SKIP a" "2 OPEN b" "2 PASS b"
assert_eq "SKIP seq + PASS seq: $(cls_state 0 1 "$CD/seq-mixed")" "SKIP seq + PASS seq: PASS"
case_end

case_begin "plain-rc-classes" "bin/lib/run-all-classify.sh"
assert_eq "rc 0: $(cls 0 1 "$CD/empty")" "rc 0: PASS|0|"
assert_eq "rc 77: $(cls 77 1 "$CD/empty")" "rc 77: SKIP|77|"
assert_eq "rc 1: $(cls 1 1 "$CD/empty")" "rc 1: FAIL|1|"
assert_eq "rc 2: $(cls_state 2 1 "$CD/empty")" "rc 2: FAIL"
# rc 77 with all-SKIP records stays SKIP; rc 1 with all-SKIP records stays FAIL.
assert_eq "rc 1 + all SKIP records: $(cls_state 1 1 "$CD/allskip")" "rc 1 + all SKIP records: FAIL"
case_end

# A harness that records a failed case but still exits 0 must not pass: the resolved record (the last
# line of a seq) decides, read from the state column only. An XPASS the harness resolved (its seq has
# an OPEN line) is a failure, as xfail.sh counts it; a wrapper's XPASS (no OPEN: non-strict pytest)
# stays a pass.
# rec_table <rc> <dir-prefix> — reads `name | records (';'-separated) | state | rc` rows on stdin,
# builds each record set and asserts `cls <rc> 1` gives `<state>|<rc>|` (no missing label).
rec_table() {
  local run_rc="$1" pfx="$2" name recs st want_rc
  local -a list
  while IFS='|' read -r name recs st want_rc; do
    name="${name//[[:space:]]/}"
    [ -n "$name" ] || continue
    recs="$(printf '%s' "$recs" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//')"
    IFS=';' read -r -a list <<<"$recs"
    mkcases "$CD/$pfx-$name" "${list[@]}"
    assert_eq "rc $run_rc + $name: $(cls "$run_rc" 1 "$CD/$pfx-$name")" \
      "rc $run_rc + $name: ${st//[[:space:]]/}|${want_rc//[[:space:]]/}|"
  done
}

case_begin "rc0-with-a-resolved-fail-record-is-fail" "bin/lib/run-all-classify.sh"
rec_table 0 fr <<'ROWS'
fail-among-pass                    | 1 OPEN a;1 PASS a;2 OPEN b;2 FAIL b;3 OPEN c;3 PASS c | FAIL | 1
fail-only                          | 1 OPEN a;1 FAIL a                                     | FAIL | 1
fail-and-skip-only                 | 1 OPEN a;1 FAIL a;2 OPEN b;2 SKIP b                   | FAIL | 1
fail-last-seq                      | 1 OPEN a;1 SKIP a;2 OPEN b;2 PASS b;3 OPEN c;3 FAIL c | FAIL | 1
fail-without-open-lines            | 1 PASS a;2 FAIL b                                     | FAIL | 1
fail-then-unfinished-case          | 1 OPEN a;1 FAIL a;2 OPEN b                            | FAIL | 1
harness-xpass-only                 | 1 OPEN a;1 XPASS a                                    | FAIL | 1
harness-xpass-and-pass             | 1 OPEN a;1 XPASS a;2 OPEN b;2 PASS b                  | FAIL | 1
harness-xpass-last-seq             | 1 OPEN a;1 PASS a;2 OPEN b;2 XPASS b                  | FAIL | 1
harness-xpass-then-pass-on-one-seq | 1 OPEN a;1 XPASS a;1 PASS a                           | PASS | 0
wrapper-xpass-only                 | 1 XPASS a                                             | PASS | 0
wrapper-xpass-and-pass             | 1 XPASS a;2 PASS b                                    | PASS | 0
wrapper-xpass-beside-harness-pass  | 1 XPASS a;2 OPEN b;2 PASS b                           | PASS | 0
xfail-only                         | 1 OPEN a;1 XFAIL a                                    | PASS | 0
open-only                          | 1 OPEN a;2 OPEN b                                     | PASS | 0
open-then-pass                     | 1 OPEN a;1 PASS a                                     | PASS | 0
case-named-fail-that-passed        | 1 OPEN FAIL;1 PASS FAIL                               | PASS | 0
ROWS
# CRLF records, as a Windows text-mode writer leaves them.
mkdir -p "$CD/fr-crlf"
printf '%s\t%s\t%s\t%s\r\n' 1 OPEN a t 1 FAIL a t 2 OPEN b t 2 PASS b t >"$CD/fr-crlf/cases.tsv"
assert_eq "rc 0 + CRLF FAIL record: $(cls 0 1 "$CD/fr-crlf")" "rc 0 + CRLF FAIL record: FAIL|1|"
case_end

# A skip exit hides no recorded failure either; without one, rc 77 stays SKIP whatever else is there.
case_begin "rc77-with-a-resolved-fail-record-is-fail" "bin/lib/run-all-classify.sh"
rec_table 77 sk <<'ROWS'
fail-among-pass           | 1 OPEN a;1 PASS a;2 OPEN b;2 FAIL b | FAIL | 1
fail-only                 | 1 OPEN a;1 FAIL a                   | FAIL | 1
fail-and-skip             | 1 OPEN a;1 SKIP a;2 OPEN b;2 FAIL b | FAIL | 1
fail-without-open-lines   | 1 FAIL a                            | FAIL | 1
harness-xpass             | 1 OPEN a;1 XPASS a                  | FAIL | 1
fail-then-pass-on-one-seq | 1 OPEN a;1 FAIL a;1 PASS a          | SKIP | 77
pass-only                 | 1 OPEN a;1 PASS a                   | SKIP | 77
skip-only                 | 1 OPEN a;1 SKIP a                   | SKIP | 77
open-only                 | 1 OPEN a                            | SKIP | 77
wrapper-xpass             | 1 XPASS a                           | SKIP | 77
ROWS
case_end

case_begin "fail-record-leaves-other-verdicts-alone" "bin/lib/run-all-classify.sh"
FRD="$CD/fr-fail-among-pass"
assert_eq "rc 1 + FAIL record: $(cls 1 1 "$FRD")" "rc 1 + FAIL record: FAIL|1|"
assert_eq "rc 2 + FAIL record: $(cls 2 1 "$FRD")" "rc 2 + FAIL record: FAIL|2|"
mkcases "$CD/fr-fired" "1 OPEN a" "1 FAIL a"
: >"$CD/fr-fired/timed-out"
assert_eq "rc 124 + timed-out + FAIL record: $(cls 124 1 "$CD/fr-fired")" "rc 124 + timed-out + FAIL record: TIMEOUT|124|"
mkcases "$CD/fr-unrunnable" "1 OPEN a" "1 FAIL a"
printf 'pwsh\n' >"$CD/fr-unrunnable/unrunnable"
assert_eq "rc 79 + marker + FAIL record: $(cls 79 0 "$CD/fr-unrunnable")" "rc 79 + marker + FAIL record: UNRUNNABLE|79|pwsh"
case_end

case_begin "effective-timeout-entry-only" "bin/lib/run-all-classify.sh"
assert_eq "entry 180: [$(eto 180)]" "entry 180: [180]"
assert_eq "entry 1: [$(eto 1)]" "entry 1: [1]"
# A null (empty) or non-positive-integer entry means no per-file kill.
assert_eq "entry empty: [$(eto '')]" "entry empty: []"
assert_eq "entry null: [$(eto null)]" "entry null: []"
assert_eq "entry 0: [$(eto 0)]" "entry 0: []"
assert_eq "entry -5: [$(eto -5)]" "entry -5: []"
assert_eq "entry 1.5: [$(eto 1.5)]" "entry 1.5: []"
case_end

case_begin "effective-timeout-env-minimum" "bin/lib/run-all-classify.sh"
assert_eq "env 5 < entry 180: [$(eto 180 5)]" "env 5 < entry 180: [5]"
assert_eq "env 900 > entry 180: [$(eto 180 900)]" "env 900 > entry 180: [180]"
assert_eq "env 180 = entry 180: [$(eto 180 180)]" "env 180 = entry 180: [180]"
assert_eq "entry empty + env 7: [$(eto '' 7)]" "entry empty + env 7: [7]"
assert_eq "entry null + env 7: [$(eto null 7)]" "entry null + env 7: [7]"
case_end

case_begin "effective-timeout-invalid-env-ignored" "bin/lib/run-all-classify.sh"
assert_eq "env abc, entry 180: [$(eto 180 abc)]" "env abc, entry 180: [180]"
assert_eq "env 0, entry 180: [$(eto 180 0)]" "env 0, entry 180: [180]"
assert_eq "env -3, entry 180: [$(eto 180 -3)]" "env -3, entry 180: [180]"
assert_eq "env empty, entry 180: [$(eto 180 '')]" "env empty, entry 180: [180]"
assert_eq "env abc, entry empty: [$(eto '' abc)]" "env abc, entry empty: []"
case_end
