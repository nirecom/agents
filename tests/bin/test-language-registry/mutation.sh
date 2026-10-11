# bin/mutation-probe.sh on fixture checkouts, mapped from the launcher state (#2501):
# PASS -> LIVE, FAIL / TIMEOUT -> KILLED, and SKIP (a test's own 77), UNRUNNABLE (a
# missing tool) or a mutant that was not launched -> NOT RUN, never KILLED.
# Sourced by the dispatcher.

echo ""
echo "=== mutation-probe ==="

FX_MUT="$TMPBASE/co-mutation"
fx_checkout "$FX_MUT"
mkdir -p "$FX_MUT/tests/hooks"
printf '%s\n' 'const ALPHA = /alpha/;' 'const BETA = /beta/;' 'module.exports = { ALPHA, BETA };' >"$FX_MUT/hooks/lib/mpa.js"
printf '%s\n' 'const GAMMA = /gamma/;' 'module.exports = { GAMMA };' >"$FX_MUT/hooks/lib/mpg.js"
printf '%s\n' 'const PEE = /pee/;' 'module.exports = { PEE };' >"$FX_MUT/hooks/lib/mpp.js"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/mpa.js' 'root="$(cd "$(dirname "$0")/../.." && pwd)"' \
  "grep -q '^const ALPHA = /alpha/;' \"\$root/hooks/lib/mpa.js\" || exit 1" >"$FX_MUT/tests/hooks/mpa-test.sh"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/mpg.js' 'root="$(cd "$(dirname "$0")/../.." && pwd)"' \
  "grep -q '^const GAMMA = /gamma/;' \"\$root/hooks/lib/mpg.js\" || exit 77" >"$FX_MUT/tests/hooks/mpg-test.sh"
printf '%s\n' '# Tests: hooks/lib/mpp.js' 'Describe "mpp" { It "x" { $true | Should -Be $true } }' >"$FX_MUT/tests/hooks/mpp.Tests.ps1"
printf '%s\n' 'const TAU = /tau/;' 'module.exports = { TAU };' >"$FX_MUT/hooks/lib/mpt.js"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/mpt.js' 'root="$(cd "$(dirname "$0")/../.." && pwd)"' \
  "grep -q '^const TAU = /tau/;' \"\$root/hooks/lib/mpt.js\" || sleep 20" >"$FX_MUT/tests/hooks/mpt-test.sh"
MPT_BEFORE="$(cksum <"$FX_MUT/hooks/lib/mpt.js")"

# mp <checkout> <target-rel> — sets MP_RC / MP_OUT.
mp() {
  MP_RC=0
  MP_OUT="$(run_with_timeout 180 bash "$1/bin/mutation-probe.sh" "$1/$2" 2>&1)" || MP_RC=$?
}

case_begin "mutation-bash-killed-and-live" "bin/mutation-probe.sh"
mp "$FX_MUT" hooks/lib/mpa.js
has_line "ALPHA is KILLED" "$MP_OUT" "KILLED: ALPHA (line 1)"
has_line "BETA is LIVE" "$MP_OUT" "LIVE:   BETA (line 2 — coverage gap)"
has_line "score line" "$MP_OUT" "KILLED: 1 / 2 (score: 50%)"
assert_eq "below threshold rc=$MP_RC" "below threshold rc=1"
case_end

case_begin "mutation-timeout-is-killed" "bin/mutation-probe.sh"
# TIMEOUT -> KILLED: RUN_ALL_TIMEOUT_SECONDS, inherited by the probe's launcher, cuts off the mutant run.
export RUN_ALL_TIMEOUT_SECONDS=2
mp "$FX_MUT" hooks/lib/mpt.js
unset RUN_ALL_TIMEOUT_SECONDS
has_line "TAU (test times out) is KILLED" "$MP_OUT" "KILLED: TAU (line 1)"
assert_eq "timeout full score rc=$MP_RC" "timeout full score rc=0"
assert_eq "timeout target restored: $(cksum <"$FX_MUT/hooks/lib/mpt.js")" "timeout target restored: $MPT_BEFORE"
case_end

case_begin "mutation-bash-77-is-not-run" "bin/mutation-probe.sh"
# A test's own 77 is SKIP: the mutant was not observed, so it is NOT RUN, never KILLED.
mp "$FX_MUT" hooks/lib/mpg.js
# The NOT RUN detail suffix (after "line 1") is the probe's to word.
assert_eq "GAMMA NOT RUN lines=$(printf '%s\n' "$MP_OUT" | grep -c '^NOT RUN: GAMMA (line 1')" "GAMMA NOT RUN lines=1"
assert_eq "77 KILLED lines=$(printf '%s\n' "$MP_OUT" | grep -c '^KILLED:')" "77 KILLED lines=0"
assert_eq "77 nothing scored rc=$MP_RC" "77 nothing scored rc=2"
case_end

case_begin "mutation-missing-tool-is-not-run" "bin/mutation-probe.sh"
# Only a .Tests.ps1 test names mpp.js; without pwsh the launcher reports UNRUNNABLE,
# so the mutant is NOT RUN. There is no up-front requires SKIP any more.
before="$(cksum <"$FX_MUT/hooks/lib/mpp.js")"
NOPWSH_PATH="$(path_without pwsh)"
MP_RC=0
MP_OUT="$(PATH="$NOPWSH_PATH" run_with_timeout 180 bash "$FX_MUT/bin/mutation-probe.sh" "$FX_MUT/hooks/lib/mpp.js" 2>&1)" || MP_RC=$?
assert_eq "no pwsh rc=$MP_RC" "no pwsh rc=2"
assert_eq "PEE NOT RUN lines=$(printf '%s\n' "$MP_OUT" | grep -c '^NOT RUN: PEE (line 1')" "PEE NOT RUN lines=1"
if printf '%s\n' "$MP_OUT" | grep -qF "SKIP: pwsh not on PATH"; then
  fail "no requires SKIP line" "$(printf '%s' "$MP_OUT" | head -n 5)"
else
  pass "no requires SKIP line"
fi
assert_eq "no pwsh KILLED lines=$(printf '%s\n' "$MP_OUT" | grep -c '^KILLED:')" "no pwsh KILLED lines=0"
assert_eq "target restored: $(cksum <"$FX_MUT/hooks/lib/mpp.js")" "target restored: $before"
if [ -e "$FX_MUT/hooks/lib/mpp.js.probe-backup" ]; then
  fail "no probe backup left" "found mpp.js.probe-backup"
else
  pass "no probe backup left"
fi
case_end

case_begin "mutation-prepare-failed-is-not-run" "bin/mutation-probe.sh"
# A suite- or file-unit test whose prepare fails never ran its command (prepare-failed, launched=0):
# the mutant was not observed, so it is NOT RUN, never KILLED, and nothing is scored.
FX_MUT_PF="$TMPBASE/co-mutation-prepfail"
fx_table_edit "$FIXTURES/fake-suite.json" "$TMPBASE/mut-prepfail.json" \
  't.entries[1].launch.prepare = ["bash", "-c", "exit 3"];'
fx_checkout "$FX_MUT_PF" "$TMPBASE/mut-prepfail.json"
mkdir -p "$FX_MUT_PF/tests/suites/pf"
: >"$FX_MUT_PF/tests/suites/pf/fake.root"
printf '%s\n' 'const ZETA = /zeta/;' 'module.exports = { ZETA };' >"$FX_MUT_PF/hooks/lib/mpz.js"
printf '%s\n' '# Tests: hooks/lib/mpz.js' >"$FX_MUT_PF/tests/suites/pf/z.fakesuite"
before="$(cksum <"$FX_MUT_PF/hooks/lib/mpz.js")"
mp "$FX_MUT_PF" hooks/lib/mpz.js
assert_eq "prepare failed rc=$MP_RC" "prepare failed rc=2"
assert_eq "ZETA NOT RUN lines=$(printf '%s\n' "$MP_OUT" | grep -c '^NOT RUN: ZETA (line 1')" "ZETA NOT RUN lines=1"
assert_eq "prepare failed KILLED lines=$(printf '%s\n' "$MP_OUT" | grep -c '^KILLED:')" "prepare failed KILLED lines=0"
assert_eq "prepare failed score printed=$(printf '%s\n' "$MP_OUT" | grep -c 'Mutation Score')" "prepare failed score printed=0"
assert_eq "prepare failed target restored: $(cksum <"$FX_MUT_PF/hooks/lib/mpz.js")" "prepare failed target restored: $before"
# File unit: the test would kill ETA if its command ran, so KILLED here means prepare was ignored.
FX_MUT_FPF="$TMPBASE/co-mutation-fileprepfail"
fx_table_edit "$FIXTURES/fake-suite.json" "$TMPBASE/mut-fileprepfail.json" \
  't.entries[0].launch.prepare = ["bash", "-c", "exit 3"];'
fx_checkout "$FX_MUT_FPF" "$TMPBASE/mut-fileprepfail.json"
mkdir -p "$FX_MUT_FPF/tests/hooks"
printf '%s\n' 'const ETA = /eta/;' 'module.exports = { ETA };' >"$FX_MUT_FPF/hooks/lib/mpe.js"
printf '%s\n' '#!/usr/bin/env bash' '# Tests: hooks/lib/mpe.js' 'root="$(cd "$(dirname "$0")/../.." && pwd)"' \
  "grep -q '^const ETA = /eta/;' \"\$root/hooks/lib/mpe.js\" || exit 1" >"$FX_MUT_FPF/tests/hooks/mpe-test.sh"
before="$(cksum <"$FX_MUT_FPF/hooks/lib/mpe.js")"
mp "$FX_MUT_FPF" hooks/lib/mpe.js
assert_eq "file prepare failed rc=$MP_RC" "file prepare failed rc=2"
assert_eq "ETA NOT RUN lines=$(printf '%s\n' "$MP_OUT" | grep -c '^NOT RUN: ETA (line 1')" "ETA NOT RUN lines=1"
assert_eq "file prepare failed KILLED lines=$(printf '%s\n' "$MP_OUT" | grep -c '^KILLED:')" "file prepare failed KILLED lines=0"
assert_eq "file prepare failed score printed=$(printf '%s\n' "$MP_OUT" | grep -c 'Mutation Score')" "file prepare failed score printed=0"
assert_eq "file prepare failed target restored: $(cksum <"$FX_MUT_FPF/hooks/lib/mpe.js")" "file prepare failed target restored: $before"
case_end

case_begin "mutation-not-launched-is-not-run" "bin/mutation-probe.sh"
# A stub launcher that never launches: every mutant is NOT RUN, nothing is scored.
FX_MUT_STUB="$TMPBASE/co-mutation-stub"
fx_checkout "$FX_MUT_STUB"
mkdir -p "$FX_MUT_STUB/tests/hooks"
cp "$FX_MUT/hooks/lib/mpa.js" "$FX_MUT_STUB/hooks/lib/mpa.js"
cp "$FX_MUT/tests/hooks/mpa-test.sh" "$FX_MUT_STUB/tests/hooks/mpa-test.sh"
printf '%s\n' 'run_all_exec() { RUN_ALL_EXEC_LAUNCHED=0; printf "UNSUPPORTED: %s (language: stub; not run)\n" "$1" >"$2"; return 78; }' \
  >"$FX_MUT_STUB/bin/lib/run-all-launch.sh"
before="$(cksum <"$FX_MUT_STUB/hooks/lib/mpa.js")"
mp "$FX_MUT_STUB" hooks/lib/mpa.js
assert_eq "not launched rc=$MP_RC" "not launched rc=2"
assert_eq "NOT RUN lines=$(printf '%s\n' "$MP_OUT" | grep -c '^NOT RUN:')" "NOT RUN lines=2"
assert_eq "KILLED lines=$(printf '%s\n' "$MP_OUT" | grep -c '^KILLED:')" "KILLED lines=0"
assert_eq "score printed=$(printf '%s\n' "$MP_OUT" | grep -c 'Mutation Score')" "score printed=0"
assert_eq "target restored: $(cksum <"$FX_MUT_STUB/hooks/lib/mpa.js")" "target restored: $before"
case_end

# Test discovery reads each candidate's own header.commentPrefix (#2500): slash-lang
# (*.slt, "//") from fixtures/slash-header.json. bash is first in table order, so a
# .sh whose only reference is a `//` decoy would win if the prefix were not per file.
FX_MUT_SL="$TMPBASE/co-mutation-slash"
fx_checkout "$FX_MUT_SL" "$FIXTURES/slash-header.json"
mkdir -p "$FX_MUT_SL/tests/hooks"
printf '%s\n' 'const SIGMA = /sigma/;' 'module.exports = { SIGMA };' >"$FX_MUT_SL/hooks/lib/mps.js"
printf '%s\n' 'const DELTA = /delta/;' 'module.exports = { DELTA };' >"$FX_MUT_SL/hooks/lib/mpd.js"
printf '%s\n' '// Tests: hooks/lib/mps.js' 'root="$(cd "$(dirname "$0")/../.." && pwd)"' \
  "grep -q '^const SIGMA = /sigma/;' \"\$root/hooks/lib/mps.js\" || exit 1" >"$FX_MUT_SL/tests/hooks/mps-test.slt"
printf '%s\n' '#!/usr/bin/env bash' '// Tests: hooks/lib/mps.js' 'exit 0' >"$FX_MUT_SL/tests/hooks/mps-decoy.sh"
printf '%s\n' '# Tests: hooks/lib/mpd.js' 'exit 1' >"$FX_MUT_SL/tests/hooks/mpd-decoy.slt"
printf '%s\n' '#!/usr/bin/env bash' '// Tests: hooks/lib/mpd.js' 'exit 1' >"$FX_MUT_SL/tests/hooks/mpd-decoy.sh"

case_begin "mutation-comment-prefix-per-file" "bin/mutation-probe.sh"
mp "$FX_MUT_SL" hooks/lib/mps.js
has_line "SIGMA is KILLED by the // header test, not the // decoy in a .sh" "$MP_OUT" "KILLED: SIGMA (line 1)"
assert_eq "slash test full score rc=$MP_RC" "slash test full score rc=0"
case_end

case_begin "mutation-comment-prefix-decoy-only" "bin/mutation-probe.sh"
before="$(cksum <"$FX_MUT_SL/hooks/lib/mpd.js")"
mp "$FX_MUT_SL" hooks/lib/mpd.js
assert_eq "decoy-only rc=$MP_RC" "decoy-only rc=2"
has_line "no test found" "$MP_OUT" "ERROR: no test file found for mpd.js"
assert_eq "KILLED lines=$(printf '%s\n' "$MP_OUT" | grep -c '^KILLED:')" "KILLED lines=0"
assert_eq "decoy target unchanged: $(cksum <"$FX_MUT_SL/hooks/lib/mpd.js")" "decoy target unchanged: $before"
case_end
