#!/usr/bin/env bash
# tests/bin/feature-sweep-plans-age-boundary.sh
# Tests: bin/sweep-plans.sh, bin/sweep-plans/discover.sh
# Tags: scope:common, TL2, sweep, plans, workflow-plans, age-threshold, boundary, ci-mode, maintenance, bin, pwsh-not-required, performance, dry-run
# Serial: P1 asserts a wall-clock 60 s budget over 900 files, so it must not compete with other tests
# Age-threshold boundary of sweep-plans: a group whose newest mtime equals
# now - SWEEP_AGE_DAYS*86400 is still young (kept); one second older is a candidate.
# A PATH `date` stub pins `date +%s` to a fixed NOW so the boundary is exact.
# SWEEP_AGE_DAYS=0 is not a boundary: the entrypoint validates a minimum of 1 (B6 asserts the rejection).
# TL3 gap: none — the real script runs against a temp PLANS_DIR; only the clock is stubbed.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

readonly T_ROOT="$(make_tmp)"
trap 'chmod -R u+rwX "$T_ROOT" 2>/dev/null; rm -rf "$T_ROOT"' EXIT
harness_isolate "$T_ROOT/wf"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
export CLAUDE_TRANSCRIPT_BASE_DIR="$T_ROOT/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"
cd "$T_ROOT" || exit 1

SWEEP="$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans.sh"
ERRF="$T_ROOT/stderr.txt"
SEQ=0
readonly NOW=1767225600
readonly DAY=86400
U_EDGE="a1b2c3d4-e5f6-4890-abcd-ef1234567890"
U_OLD="b2c3d4e5-f6a7-4901-bcde-f12345678901"
U_NEWER="c3d4e5f6-a7b8-4012-8def-123456789012"
# "<uuid>-survey-code.md" is classified non-plan by the registry (see feature-sweep-plans-retention.sh R1).
NON_PLAN_SUFFIX="survey-code.md"

AB_REAL_DATE="$(command -v date)"
STUB_DIR="$T_ROOT/clock-stub-bin"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/date" <<'SH'
#!/usr/bin/env bash
if [[ "$#" -eq 1 && "$1" == "+%s" ]]; then
  printf '%s\n' "${AB_STUB_NOW:?}"
  exit 0
fi
exec "${AB_REAL_DATE:?}" "$@"
SH
chmod +x "$STUB_DIR/date"
export AB_REAL_DATE AB_STUB_NOW="$NOW"

new_dir() { SEQ=$((SEQ + 1)); local d="$T_ROOT/plans-$1-$SEQ"; mkdir -p "$d"; printf '%s' "$d"; }
file_mtime() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null; }
# mk_aged <dir> <uuid> <epoch> — one non-plan file of the group, mtime pinned to <epoch> and verified.
mk_aged() {
  local f="$1/$2-$NON_PLAN_SUFFIX" got
  printf 'x\n' > "$f"
  touch -d "@$3" "$f"
  got="$(file_mtime "$f")"
  if [[ "$got" == "$3" ]]; then pass "precondition: ${f##*/} mtime is exactly $3"; else fail "precondition: ${f##*/} mtime is exactly $3" "got=$got"; fi
}

# run_sweep <plans_dir> <age_days> <args...> — stubbed clock; sets RC, OUT (stdout), ERR (stderr).
run_sweep() {
  local pd="$1" age="$2"; shift 2
  RC=0
  OUT="$(PATH="$STUB_DIR:$PATH" WORKFLOW_PLANS_DIR="$pd" SWEEP_AGE_DAYS="$age" run_with_timeout 120 bash "$SWEEP" "$@" 2>"$ERRF")" || RC=$?
  OUT="$(printf '%s' "$OUT" | tr -d '\r')"
  ERR="$(tr -d '\r' < "$ERRF")"
}
JGET_JS="$T_ROOT/jget.js"
cat > "$JGET_JS" <<'JS'
let b = ""; process.stdin.on("data", (c) => (b += c)); process.stdin.on("end", () => {
  for (const line of b.split(/\r?\n/)) {
    const t = line.trim(); if (!t.startsWith("{")) continue;
    let d; try { d = JSON.parse(t); } catch (e) { continue; }
    const v = d[process.argv[2]];
    process.stdout.write(v === undefined ? "<missing>" : String(v));
    return;
  }
  process.stdout.write("<no-json>");
});
JS
jget() { printf '%s' "$1" | node "$(np "$JGET_JS")" "$2" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
expect_present() { if [[ -e "$2" ]]; then pass "$1"; else fail "$1" "removed: ${2##*/}"; fi; }
expect_gone() { if [[ -e "$2" ]]; then fail "$1" "still present: ${2##*/}"; else pass "$1"; fi; }

# boundary_case <label> <age_days> <mtime offset from threshold> <kept|removed>
# Runs the flagless default on one dir and --ci-mode on a twin dir.
boundary_case() {
  local label="$1" age="$2" off="$3" want="$4" d m young removed
  m=$(( NOW - age * DAY + off ))
  if [[ "$want" == "kept" ]]; then young=1; removed=0; else young=0; removed=1; fi
  d="$(new_dir "$label")"; mk_aged "$d" "$U_EDGE" "$m"
  run_sweep "$d" "$age"
  check "$label default run exits 0" "0" "$RC"
  if [[ "$want" == "kept" ]]; then
    expect_present "$label default run keeps the group" "$d/$U_EDGE-$NON_PLAN_SUFFIX"
  else
    expect_gone "$label default run removes the group" "$d/$U_EDGE-$NON_PLAN_SUFFIX"
  fi
  d="$(new_dir "$label-ci")"; mk_aged "$d" "$U_EDGE" "$m"
  run_sweep "$d" "$age" --ci-mode
  check "$label --ci-mode exits 0" "0" "$RC"
  check "$label groups_skipped_young=$young" "$young" "$(jget "$OUT" groups_skipped_young)"
  check "$label groups_removed=$removed" "$removed" "$(jget "$OUT" groups_removed)"
  check "$label groups_candidates=$removed" "$removed" "$(jget "$OUT" groups_candidates)"
  if [[ "$want" == "kept" ]]; then
    expect_present "$label --ci-mode keeps the group" "$d/$U_EDGE-$NON_PLAN_SUFFIX"
  else
    expect_gone "$label --ci-mode removes the group" "$d/$U_EDGE-$NON_PLAN_SUFFIX"
  fi
}

case_begin "B0-clock-stub-sanity" "bin/sweep-plans.sh"
check "B0 the stub is the date bash resolves" "$STUB_DIR/date" "$(PATH="$STUB_DIR:$PATH" command -v date)"
check "B0 the stub prints NOW for +%s" "$NOW" "$(PATH="$STUB_DIR:$PATH" date +%s | tr -d '\r')"
check "B0 the stub delegates other forms to the real date" "1970" "$(PATH="$STUB_DIR:$PATH" date -u -d @0 +%Y | tr -d '\r')"
if [[ "$AB_REAL_DATE" != "$STUB_DIR/date" ]]; then pass "B0 the real date was resolved before shadowing"; else fail "B0 the real date was resolved before shadowing" "got=$AB_REAL_DATE"; fi
case_end

case_begin "B1-exact-threshold-is-kept" "bin/sweep-plans/discover.sh"
boundary_case "B1" 30 0 kept
case_end

case_begin "B2-one-second-older-is-removed" "bin/sweep-plans/discover.sh"
boundary_case "B2" 30 -1 removed
case_end

case_begin "B3-mixed-boundary-and-older-in-one-run" "bin/sweep-plans/discover.sh"
B3_EDGE_M=$(( NOW - 30 * DAY )); B3_OLD_M=$(( B3_EDGE_M - 1 ))
D="$(new_dir b3)"; mk_aged "$D" "$U_EDGE" "$B3_EDGE_M"; mk_aged "$D" "$U_OLD" "$B3_OLD_M"
run_sweep "$D" 30
check "B3 default run exits 0" "0" "$RC"
expect_present "B3 default run keeps the boundary group" "$D/$U_EDGE-$NON_PLAN_SUFFIX"
expect_gone "B3 default run removes the older group" "$D/$U_OLD-$NON_PLAN_SUFFIX"
D="$(new_dir b3-ci)"; mk_aged "$D" "$U_EDGE" "$B3_EDGE_M"; mk_aged "$D" "$U_OLD" "$B3_OLD_M"
run_sweep "$D" 30 --ci-mode
check "B3 --ci-mode exits 0" "0" "$RC"
check "B3 groups_skipped_young=1" "1" "$(jget "$OUT" groups_skipped_young)"
check "B3 groups_removed=1" "1" "$(jget "$OUT" groups_removed)"
check "B3 groups_candidates=1" "1" "$(jget "$OUT" groups_candidates)"
expect_present "B3 --ci-mode keeps the boundary group" "$D/$U_EDGE-$NON_PLAN_SUFFIX"
expect_gone "B3 --ci-mode removes the older group" "$D/$U_OLD-$NON_PLAN_SUFFIX"
case_end

case_begin "B4-one-second-newer-is-kept" "bin/sweep-plans/discover.sh"
boundary_case "B4" 30 1 kept
case_end

case_begin "B5-boundary-holds-for-another-age" "bin/sweep-plans/discover.sh"
boundary_case "B5-age1-edge" 1 0 kept
boundary_case "B5-age1-older" 1 -1 removed
case_end

case_begin "B6-age-zero-is-rejected" "bin/sweep-plans.sh"
D="$(new_dir b6)"; mk_aged "$D" "$U_NEWER" "$NOW"
run_sweep "$D" 0 --ci-mode
check "B6 SWEEP_AGE_DAYS=0 exits 2 (validation minimum is 1)" "2" "$RC"
expect_present "B6 a rejected run deletes nothing" "$D/$U_NEWER-$NON_PLAN_SUFFIX"
case_end

# P1: the real clock (no stub); per-file / per-group forks made this take minutes on Windows.
case_begin "P1-many-old-plan-files-dry-run-is-fast" "bin/sweep-plans/discover.sh"
P1_DIR="$(new_dir p1)"
P1_OLD=$(( $(date +%s) - 60 * DAY ))
for (( s = 1; s <= 300; s++ )); do
  printf -v P1_U '%08x-0000-4000-8000-%012x' "$s" "$s"
  for n in intent outline detail; do printf 'x\n' > "$P1_DIR/$P1_U-$n.md"; done
done
find "$P1_DIR" -type f -exec touch -d "@$P1_OLD" {} +
check "P1 precondition: 900 plan files created" "900" "$(find "$P1_DIR" -type f | grep -c '')"
check "P1 precondition: every file is aged" "$P1_OLD" "$(file_mtime "$P1_DIR/00000001-0000-4000-8000-000000000001-intent.md")"
P1_RC=0
P1_OUT="$(WORKFLOW_PLANS_DIR="$P1_DIR" SWEEP_AGE_DAYS=30 run_with_timeout 60 bash "$SWEEP" --dry-run 2>"$ERRF")" || P1_RC=$?
P1_OUT="$(printf '%s' "$P1_OUT" | tr -d '\r')"
check "P1 a flagless --dry-run over 900 files finishes within 60 s with exit 0" "0" "$P1_RC"
P1_LINES="$(printf '%s\n' "$P1_OUT" | grep -c '')"
if (( P1_LINES < 40 )); then pass "P1 stdout does not scale with the session count ($P1_LINES lines)"; else fail "P1 stdout does not scale with the session count" "lines=$P1_LINES"; fi
check "P1 summary files_plan_candidates=900" "1" "$(printf '%s\n' "$P1_OUT" | grep -cE '^  files_plan_candidates: 900$')"
check "P1 summary groups_approval_candidates=300" "1" "$(printf '%s\n' "$P1_OUT" | grep -cE '^  groups_approval_candidates: 300$')"
check "P1 the hint line counts 900 files in 300 sessions" "1" "$(printf '%s\n' "$P1_OUT" | grep -cE '^plan / user-requested files kept: 900 in 300 sessions ')"
check "P1 --dry-run deletes nothing" "900" "$(find "$P1_DIR" -type f | grep -c '')"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
