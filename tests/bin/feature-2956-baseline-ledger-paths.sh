#!/usr/bin/env bash
# tests/bin/feature-2956-baseline-ledger-paths.sh
# Tests: bin/run-tests-baseline, bin/lib/run-tests-baseline-ledger.sh, bin/lib/run-all-ledger-migrate.sh
# Tags: run-tests, baseline, ledger, cache, migrate, scope:issue-specific, pwsh-not-required, TL2
# #2956 S6/S7 - a same-base ledger hit counts only with a readable v3 row file (missing or hash
# mismatch = miss, the base re-runs), the branch cache hit carries the same fp, v2 rows are never
# read, migrate leaves v3.* alone, and two writers of one row file leave one verified file.
# S8 table 2 and inheritance: feature-2956-baseline-branch-paths.sh.
# TL3 gap: a rename collision between two real hosts sharing one cache is out of scope.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not available";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2688-branch-rerun/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2688-branch-rerun/_lib.sh"
# shellcheck source=tests/bin/feature-2956-baseline-ledger-paths/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/feature-2956-baseline-ledger-paths/_lib.sh"

R="$TMPROOT/p"; C="$R.cache"; MK="$R.marks"; T=tests/bin/t.sh; U=tests/bin/u.sh
lp_repo "$R"; mkdir -p "$C"
lp_body "$(np "$MK")" t "a" 1 "a" 1 > "$R/$T"
lp_body "$(np "$MK")" u "u" 1 "u" 1 > "$R/$U"
lp_publish "$R" "add t u"
B="$(git -C "$R" rev-parse main)"
FACTS="$(lp_lib "$C" "$R" 'run_all_dur_host_token >/dev/null; printf "%s\t%s\t%s" "$(rtb_ledger_dir)" "$RUN_ALL_DUR_HOST_TOKEN" "$(run_all_os_attr)"')"
LD="${FACTS%%$'\t'*}"; REST="${FACTS#*$'\t'}"; TOK="${REST%%$'\t'*}"; ATTR="${REST#*$'\t'}"

# lp_run <sid> — clear the markers, seed failing t.sh and u.sh and run the CLI.
lp_run() { rm -f "$MK"/*; seed "$1" '{"tests/bin/t.sh":1,"tests/bin/u.sh":1}' "$T" "$U"; rtb "$C" "$R" "$1"; }

case_begin "v2-rows-are-not-read" "bin/lib/run-tests-baseline-ledger.sh"
mkdir -p "$LD"
printf 'v2\t%s\t%s\t%s\tfail\t%s\t%s\n' "$B" "$TOK" "$T" "$(date +%s)" "$ATTR" > "$LD/v2.$TOK-1000000000-1.seg"
lp_run "lp1-$$"
ck "run1: exit 0 (proof)" 0 "$RTB_RC"
has_line "run1: preexisting" "BASELINE: preexisting $T"
present "run1: a v2 fail row at the same base is no hit - the base ran" "$MK/base-t"
present "run1: the branch copy ran" "$MK/branch-t"
FP="$(lp_field "$LD" 'v3.*.seg' v3 8 "$T" 6)"
[[ "$FP" =~ ^[0-9a-f]{64}$ ]] && pass "run1: the v3 row (NF 8) carries a sha256 fp" || fail "run1: v3 row fp" "fp=[$FP] dir=$(ls -A "$LD" 2>&1)"
ck "run1: the v3 row is at the base sha" "$B" "$(lp_field "$LD" 'v3.*.seg' v3 8 "$T" 2)"
ck "run1: the row file is content-addressed (sha256 = fp)" "$FP" "$(lp_sha "$LD/v3.lines.$FP")"
FPU="$(lp_field "$LD" 'v3.*.seg' v3 8 "$U" 6)"
[[ "$FPU" =~ ^[0-9a-f]{64}$ && "$FPU" != "$FP" ]] && pass "run1: other lines give u.sh its own fp" || fail "run1: u.sh fp" "u=[$FPU] t=[$FP]"
case_end

case_begin "branch-cache-hit-carries-the-fp" "bin/lib/run-tests-baseline-branch.sh"
BFP="$(lp_field "$C" 'branch.v2.*.seg' b2 7 "$T" 6)"
[[ "$BFP" =~ ^[0-9a-f]{64}$ && "$BFP" = "$FP" ]] && pass "run1: the b2 row (NF 7) carries the base row's fp" \
  || fail "run1: the b2 row (NF 7) carries the base row's fp" "b2=[$BFP] v3=[$FP]"
lp_run "lp2-$$"
ck "run2: exit 0" 0 "$RTB_RC"
has_line "run2: still preexisting" "BASELINE: preexisting $T"
absent "run2: branch cache hit - no branch re-run" "$MK/branch-t"
absent "run2: same-base hit with its row file - no base run" "$MK/base-t"
absent "run2: u.sh hits too - no base run" "$MK/base-u"
case_end

# run3 removes t.sh's row files and tampers with u.sh's, so one CLI run covers both misses.
case_begin "missing-row-file-is-a-miss" "bin/run-tests-baseline"
if [[ "$FP" =~ ^[0-9a-f]{64}$ && "$FPU" =~ ^[0-9a-f]{64}$ ]]; then
  find "$C" -type f -name "v3.lines.$FP*" -exec rm -f {} +
  while IFS= read -r f; do printf 'tampered\n' >> "$f"; done < <(find "$C" -type f -name "v3.lines.$FPU*")
fi
lp_run "lp3-$$"
ck "run3: exit 0" 0 "$RTB_RC"
present "run3: no row file - the base re-ran" "$MK/base-t"
present "run3: no row file for the cached fp - the branch re-ran" "$MK/branch-t"
has_line "run3: t preexisting after the re-run" "BASELINE: preexisting $T"
ck "run3: the row file is written again" "$FP" "$(lp_sha "$LD/v3.lines.$FP")"
case_end

case_begin "hash-mismatched-row-file-is-a-miss" "bin/run-tests-baseline"
present "run3: a tampered row file - the base re-ran" "$MK/base-u"
present "run3: a tampered row file - the branch re-ran" "$MK/branch-u"
has_line "run3: u preexisting after the re-run" "BASELINE: preexisting $U"
case_end

# Control: a pre-v2 `<tok>-*.seg` is migrated in the same call, so the migrate really ran.
case_begin "migrate-leaves-v3-segments-alone" "bin/lib/run-all-ledger-migrate.sh"
MC="$TMPROOT/mig.cache"; mkdir -p "$MC"
V3ROW="$(printf 'v3\t%s\t%s\t%s\tfail\t-\t1000000000\t%s' "$B" "$TOK" "$T" "$ATTR")"
MD="$(lp_lib "$MC" "$R" 'd="$(rtb_ledger_dir)"; mkdir -p "$d"; printf "%s\n" "$1" > "$d/v3.$2-1000000000-7.seg"
printf "v1\t%s\t%s\t%s\tfail\t1000000000\n" "$3" "$2" "$4" > "$d/$2-1000000000-8.seg"
touch -t 202001010000 "$d"/*.seg; rtb_ledger_migrate "$d"; printf "%s" "$d"' "$V3ROW" "$TOK" "$B" "$T")"
ck "migrate: the v3 segment keeps its name and bytes" "$V3ROW" "$(cat "$MD/v3.$TOK-1000000000-7.seg" 2>/dev/null)"
absent "migrate: no v2 rewrite of the v3 segment" "$MD/v2.$TOK-1000000000-7.seg"
present "migrate: control - the pre-v2 segment was rewritten as v2" "$MD/v2.$TOK-1000000000-8.seg"
case_end

# The writer API this case pins: rtb_ledger_lines_put <fp> <src> / rtb_ledger_lines_get <fp> (stdout, 1 = miss).
case_begin "two-writers-leave-one-verified-row-file" "bin/lib/run-tests-baseline-ledger.sh"
WC="$TMPROOT/w.cache"; mkdir -p "$WC"; SRC="$TMPROOT/lines.src"
printf 'records=cases\na\tviolation a\n' > "$SRC"
WFP="$(lp_sha "$SRC")"
PUT='declare -F rtb_ledger_lines_put >/dev/null || exit 96; for k in 1 2 3 4 5 6 7 8 9 10 11 12 13 14 15; do rtb_ledger_lines_put "$1" "$2" || exit 95; done'
lp_lib "$WC" "$R" "$PUT" "$WFP" "$(np "$SRC")" & P1=$!
lp_lib "$WC" "$R" "$PUT" "$WFP" "$(np "$SRC")" & P2=$!
W1=0; wait "$P1" || W1=$?; W2=0; wait "$P2" || W2=$?
ck "writers: both processes finish (96 = no rtb_ledger_lines_put)" "0 0" "$W1 $W2"
WD="$(lp_lib "$WC" "$R" 'printf "%s" "$(rtb_ledger_dir)"')"
ck "writers: exactly one row file for the fp" 1 "$(find "$WD" -maxdepth 1 -type f -name "v3.lines.$WFP" | wc -l | tr -d ' ')"
ck "writers: no tmp file is left" 0 "$(find "$WD" -maxdepth 1 -name 'v3.lines.*.tmp.*' | wc -l | tr -d ' ')"
ck "writers: the row file verifies (sha256 = fp)" "$WFP" "$(lp_sha "$WD/v3.lines.$WFP")"
GOT="$(lp_lib "$WC" "$R" 'rtb_ledger_lines_get "$1"' "$WFP")"; GRC=$?
ck "reader: a verified row file is returned" "0 $(cat "$SRC")" "$GRC $GOT"
printf 'x\n' >> "$WD/v3.lines.$WFP"
lp_lib "$WC" "$R" 'rtb_ledger_lines_get "$1"' "$WFP" >/dev/null; GRC=$?
ck "reader: a hash mismatch is a miss (rc 1)" 1 "$GRC"
case_end

# A branch-only new FAIL line is new on the first run and on the branch-cache hit (the cached fp must still compare).
case_begin "branch-only-new-line-is-new-on-run-and-cache-hit" "bin/lib/run-tests-baseline-branch.sh"
NR="$TMPROOT/nl"; NC="$NR.cache"; NMK="$NR.marks"; NT=tests/bin/nl.sh
lp_repo "$NR"; mkdir -p "$NC"
lp_body "$(np "$NMK")" nl "a" 1 "a b" 1 > "$NR/$NT"
lp_publish "$NR" "add nl"
rm -f "$NMK"/*; seed "nl1-$$" '{"tests/bin/nl.sh":1}' "$NT"; rtb "$NC" "$NR" "nl1-$$"
ck "nl run1: exit 1 (new line is pending)" 1 "$RTB_RC"
present "nl run1: the branch copy ran" "$NMK/branch-nl"
has_line "nl run1: new-case-failure-on-branch" "BASELINE: new-case-failure-on-branch $NT"
has_line "nl run1: one new line counted" "new_on_branch=1"
rm -f "$NMK"/*; seed "nl2-$$" '{"tests/bin/nl.sh":1}' "$NT"; rtb "$NC" "$NR" "nl2-$$"
ck "nl run2: exit 1" 1 "$RTB_RC"
absent "nl run2: branch cache hit - no branch re-run" "$NMK/branch-nl"
has_line "nl run2: still new-case-failure-on-branch" "BASELINE: new-case-failure-on-branch $NT"
has_line "nl run2: one new line counted from the cache" "new_on_branch=1"
case_end

# #3037 table: which und:<reason> verdicts RTB_LEDGER_UND_CACHEABLE_RE lets the ledger cache (yes) and which it never caches (no).
# The regex is read from the sourced lib in a child shell and evaluated here, so the table pins the real constant.
case_begin "und-cacheable-regex-table" "bin/lib/run-tests-baseline-ledger.sh"
UND_RE="$(lp_lib "$C" "$R" 'printf "%s" "$RTB_LEDGER_UND_CACHEABLE_RE"')"
[[ -n "$UND_RE" ]] && pass "und-re: the lib defines RTB_LEDGER_UND_CACHEABLE_RE" || fail "und-re: the lib defines RTB_LEDGER_UND_CACHEABLE_RE" "empty"
while IFS='|' read -r name input want; do
  [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
  name="${name//[[:space:]]/}"; want="${want//[[:space:]]/}"
  input="${input#"${input%%[![:space:]]*}"}"; input="${input%"${input##*[![:space:]]}"}"
  [[ "$input" == "(empty)" ]] && input=""
  if [[ -n "$UND_RE" && "$input" =~ $UND_RE ]]; then got=yes; else got=no; fi
  ck "und-re $name" "$want" "$got"
done <<'TABLE'
cache-unsupported-at-base                | und:unsupported-at-base                        | yes
cache-launcher-predates-conversion       | und:base-launcher-predates-result-conversion   | yes
cache-timeout-after-600s                 | und:timeout-at-base-after-600s                 | yes
cache-root-decoy-hit-at-base             | und:root-decoy-hit-at-base                     | yes
nocache-unrunnable-at-base               | und:unrunnable-at-base                         | no
nocache-skip-at-base                     | und:skip-at-base                               | no
nocache-root-decoy-suffix                | und:root-decoy-hit-at-base-x                   | no
nocache-root-decoy-prefix                | und:xroot-decoy-hit-at-base                    | no
nocache-timeout-without-digits           | und:timeout-at-base-after-s                    | no
nocache-empty-string                     | (empty)                                        | no
nocache-fail-verdict                     | fail                                           | no
nocache-pass-verdict                     | pass                                           | no
TABLE
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
