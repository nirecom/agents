# bin/mutation-probe.sh on fixture checkouts: bash output unchanged (a test's own 77
# still counts as KILLED), a missing tool skips before any mutation, and a mutant
# that was not launched is NOT RUN, never KILLED. Sourced by the dispatcher.

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

case_begin "mutation-bash-77-counts-killed" "bin/mutation-probe.sh"
mp "$FX_MUT" hooks/lib/mpg.js
has_line "GAMMA (test exits 77) is KILLED" "$MP_OUT" "KILLED: GAMMA (line 1)"
assert_eq "full score rc=$MP_RC" "full score rc=0"
case_end

case_begin "mutation-missing-tool-skips" "bin/mutation-probe.sh"
# Only a .Tests.ps1 test names mpp.js; without pwsh nothing may be mutated.
before="$(cksum <"$FX_MUT/hooks/lib/mpp.js")"
NOPWSH_PATH="$(path_without pwsh)"
MP_RC=0
MP_OUT="$(PATH="$NOPWSH_PATH" run_with_timeout 180 bash "$FX_MUT/bin/mutation-probe.sh" "$FX_MUT/hooks/lib/mpp.js" 2>&1)" || MP_RC=$?
assert_eq "no pwsh rc=$MP_RC" "no pwsh rc=77"
has_line "SKIP line" "$MP_OUT" "SKIP: pwsh not on PATH (mutation probe not run)"
assert_eq "target unchanged: $(cksum <"$FX_MUT/hooks/lib/mpp.js")" "target unchanged: $before"
if [ -e "$FX_MUT/hooks/lib/mpp.js.probe-backup" ]; then
  fail "no probe backup left" "found mpp.js.probe-backup"
else
  pass "no probe backup left"
fi
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
