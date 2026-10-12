#!/usr/bin/env bash
# tests/bin/feature-sweep-plans-flagless-output.sh
# Tests: bin/sweep-plans/delete-passes.sh
# Tags: scope:common, TL2, sweep, plans, workflow-plans, retention, listing, dry-run, ci-mode, maintenance, bin, pwsh-not-required
# Listing of sweep-plans without --include-plan-and-user-requested: no PLAN-CANDIDATE /
# USER-REQUESTED-CANDIDATE lines, and no DRY-RUN candidate line for a group holding only
# plan / user-requested files; mixed groups, UNKNOWN lines, the hint line and the summary
# counters are unchanged. With the include flag every line appears as before.
# TL3 gap: none — the real script runs against a temp PLANS_DIR.

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
# P: plan-only group; Q: user-requested-only group; M: plan + non-plan; K: plan + unknown.
P="a1b2c3d4-e5f6-4890-abcd-ef1234567890"
Q="b2c3d4e5-f6a7-4901-bcde-f12345678901"
M="c3d4e5f6-a7b8-4012-8def-123456789012"
K="d4e5f6a7-b8c9-4123-9abc-234567890123"
P_FILES=("$P-intent.md" "$P-detail.md")
Q_FILES=("$Q-user-requested-progress.md")
M_FILES=("$M-outline.md" "$M-survey-code.md")
K_FILES=("$K-intent.md" "$K-x-history-staging.md")
# B: plan + user-requested; N: non-plan only; X: user-requested + non-plan.
B="e5f6a7b8-c9d0-4234-8bcd-345678901234"
N="f6a7b8c9-d0e1-4345-9cde-456789012345"
X="a7b8c9d0-e1f2-4456-8def-567890123456"
B_FILES=("$B-intent.md" "$B-user-requested-progress.md")
N_FILES=("$N-survey-code.md" "$N-outline-codex-round-1-raw.md")
X_FILES=("$X-user-requested-progress.md" "$X-survey-code.md")
HINT_RE='^plan / user-requested files kept: [0-9]+ in [0-9]+ sessions .* run /sweep-plans --include-plan-and-user-requested to review them for deletion$'

backdate() { touch -d "60 days ago" "$1" 2>/dev/null || touch -t 202401010000 "$1" 2>/dev/null || true; }
mk_old() { local d="$1" n; shift; mkdir -p "$d"; for n in "$@"; do printf 'x\n' > "$d/$n"; backdate "$d/$n"; done; }
new_dir() { SEQ=$((SEQ + 1)); printf '%s/plans-%s-%d' "$T_ROOT" "$1" "$SEQ"; }

# run_sweep <plans_dir> <args...> — sets RC, OUT (stdout), ERR (stderr), ALL (both).
run_sweep() {
  local pd="$1"; shift
  RC=0
  OUT="$(WORKFLOW_PLANS_DIR="$pd" SWEEP_AGE_DAYS=30 run_with_timeout 120 bash "$SWEEP" "$@" 2>"$ERRF")" || RC=$?
  OUT="$(printf '%s' "$OUT" | tr -d '\r')"
  ERR="$(tr -d '\r' < "$ERRF")"
  ALL="$OUT"$'\n'"$ERR"
}
JGET_JS="$T_ROOT/jget.js"
cat > "$JGET_JS" <<'JS'
let b = ""; process.stdin.on("data", (c) => (b += c)); process.stdin.on("end", () => {
  for (const line of b.split(/\r?\n/)) {
    const t = line.trim(); if (!t.startsWith("{")) continue;
    let d; try { d = JSON.parse(t); } catch (e) { continue; }
    let v = d;
    for (const p of process.argv[2].split(".")) { if (v === null || v === undefined || !(p in Object(v))) { v = undefined; break; } v = v[p]; }
    process.stdout.write(v === undefined ? "<missing>" : (typeof v === "object" ? JSON.stringify(v) : String(v)));
    return;
  }
  process.stdout.write("<no-json>");
});
JS
jget() { printf '%s' "$1" | node "$(np "$JGET_JS")" "$2" 2>/dev/null; }
check() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
expect_present() { if [[ -e "$2" ]]; then pass "$1"; else fail "$1" "removed: ${2##*/}"; fi; }
expect_gone() { if [[ -e "$2" ]]; then fail "$1" "still present: ${2##*/}"; else pass "$1"; fi; }
has_line() { if printf '%s\n' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1" "no line matching /$3/"; fi; }
lacks_line() { if printf '%s\n' "$2" | grep -qE "$3"; then fail "$1" "unexpected line matching /$3/"; else pass "$1"; fi; }
expect_all_present() { local l="$1" d="$2" n; shift 2; for n in "$@"; do expect_present "$l keeps $n" "$d/$n"; done; }

case_begin "O1-flagless-plan-only-no-candidate-line" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o1)"; mk_old "$D" "${P_FILES[@]}"
run_sweep "$D"
check "O1 flagless run exits 0" "0" "$RC"
lacks_line "O1 no PLAN-CANDIDATE line" "$ALL" "^PLAN-CANDIDATE:"
has_line "O1 the hint line is printed" "$OUT" "$HINT_RE"
has_line "O1 the hint counts 2 files in 1 session" "$OUT" "^plan / user-requested files kept: 2 in 1 sessions "
expect_all_present "O1 flagless" "$D" "${P_FILES[@]}"
case_end

case_begin "O2-dry-run-plan-only-no-candidate-lines" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o2)"; mk_old "$D" "${P_FILES[@]}"
run_sweep "$D" --dry-run
check "O2 --dry-run exits 0" "0" "$RC"
lacks_line "O2 no PLAN-CANDIDATE line" "$ALL" "^PLAN-CANDIDATE:"
lacks_line "O2 no DRY-RUN candidate line for the plan-only group" "$ALL" "^DRY-RUN: candidate session=$P "
has_line "O2 the hint line is printed" "$OUT" "$HINT_RE"
expect_all_present "O2 --dry-run" "$D" "${P_FILES[@]}"
case_end

case_begin "O3-dry-run-user-requested-only-no-candidate-lines" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o3)"; mk_old "$D" "${Q_FILES[@]}"
run_sweep "$D" --dry-run
check "O3 --dry-run exits 0" "0" "$RC"
lacks_line "O3 no USER-REQUESTED-CANDIDATE line" "$ALL" "^USER-REQUESTED-CANDIDATE:"
lacks_line "O3 no DRY-RUN candidate line for the user-requested-only group" "$ALL" "^DRY-RUN: candidate session=$Q "
has_line "O3 the hint counts 1 file in 1 session" "$OUT" "^plan / user-requested files kept: 1 in 1 sessions "
expect_all_present "O3 --dry-run" "$D" "${Q_FILES[@]}"
case_end

case_begin "O4-dry-run-mixed-group-keeps-candidate-line" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o4)"; mk_old "$D" "${M_FILES[@]}" "${P_FILES[@]}"
run_sweep "$D" --dry-run
check "O4 --dry-run exits 0" "0" "$RC"
has_line "O4 the mixed group's DRY-RUN candidate line carries every class count" "$OUT" \
  "^DRY-RUN: candidate session=$M files=2 oldest=[^ ]+ newest=[^ ]+ plan=1 user-requested=0 non-plan=1 unknown=0$"
has_line "O4 the would-remove line names the non-plan file" "$OUT" "^DRY-RUN: would remove non-plan $M-survey-code\.md$"
lacks_line "O4 no DRY-RUN candidate line for the plan-only group in the same run" "$ALL" "^DRY-RUN: candidate session=$P "
lacks_line "O4 no PLAN-CANDIDATE line" "$ALL" "^PLAN-CANDIDATE:"
has_line "O4 the hint counts 3 files in 2 sessions" "$OUT" "^plan / user-requested files kept: 3 in 2 sessions "
expect_all_present "O4 --dry-run" "$D" "${M_FILES[@]}" "${P_FILES[@]}"
case_end

case_begin "O5-dry-run-unknown-group-keeps-candidate-and-unknown-lines" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o5)"; mk_old "$D" "${K_FILES[@]}"
run_sweep "$D" --dry-run
check "O5 --dry-run exits 0" "0" "$RC"
has_line "O5 the DRY-RUN candidate line is printed" "$OUT" \
  "^DRY-RUN: candidate session=$K files=2 oldest=[^ ]+ newest=[^ ]+ plan=1 user-requested=0 non-plan=0 unknown=1$"
has_line "O5 the UNKNOWN line names the unknown file" "$OUT" "^UNKNOWN: $K-x-history-staging\.md$"
lacks_line "O5 no PLAN-CANDIDATE line" "$ALL" "^PLAN-CANDIDATE:"
case_end

# o6_run <label> <extra args...> — plan-only P, user-requested-only Q and mixed M under --ci-mode.
o6_run() {
  local label="$1" d; shift
  d="$(new_dir o6)"; mk_old "$d" "${P_FILES[@]}" "${Q_FILES[@]}" "${M_FILES[@]}"
  run_sweep "$d" --ci-mode "$@"
  check "O6 [$label] exits 0" "0" "$RC"
  check "O6 [$label] stdout is exactly one line" "1" "$(printf '%s\n' "$OUT" | grep -c '')"
  lacks_line "O6 [$label] no PLAN-CANDIDATE line on stdout or stderr" "$ALL" "^PLAN-CANDIDATE:"
  lacks_line "O6 [$label] no USER-REQUESTED-CANDIDATE line on stdout or stderr" "$ALL" "^USER-REQUESTED-CANDIDATE:"
  lacks_line "O6 [$label] no DRY-RUN candidate line for the plan-only group" "$ALL" "^DRY-RUN: candidate session=$P "
  lacks_line "O6 [$label] no DRY-RUN candidate line for the user-requested-only group" "$ALL" "^DRY-RUN: candidate session=$Q "
  has_line "O6 [$label] the hint line goes to stderr" "$ERR" "^plan / user-requested files kept: 4 in 3 sessions "
  check "O6 [$label] files_plan_candidates=3" "3" "$(jget "$OUT" files_plan_candidates)"
  check "O6 [$label] files_user_requested_candidates=1" "1" "$(jget "$OUT" files_user_requested_candidates)"
  check "O6 [$label] files_non_plan_candidates=1" "1" "$(jget "$OUT" files_non_plan_candidates)"
  check "O6 [$label] groups_candidates=3" "3" "$(jget "$OUT" groups_candidates)"
  check "O6 [$label] groups_approval_candidates=3" "3" "$(jget "$OUT" groups_approval_candidates)"
  check "O6 [$label] approval_candidates has 3 entries" "3" "$(jget "$OUT" approval_candidates.length)"
  O6_DIR="$d"
}
case_begin "O6-ci-mode-no-candidate-lines-counters-unchanged" "bin/sweep-plans/delete-passes.sh"
o6_run flagless
expect_gone "O6 [flagless] the mixed group's non-plan is removed" "$O6_DIR/$M-survey-code.md"
expect_all_present "O6 [flagless]" "$O6_DIR" "${P_FILES[@]}" "${Q_FILES[@]}" "$M-outline.md"
o6_run dry-run --dry-run
has_line "O6 [dry-run] the mixed group's DRY-RUN candidate line goes to stderr" "$ERR" "^DRY-RUN: candidate session=$M "
case_end

case_begin "O7-include-flag-lists-every-candidate" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o7)"; mk_old "$D" "${P_FILES[@]}" "${Q_FILES[@]}"
run_sweep "$D" --include-plan-and-user-requested --dry-run
check "O7 exits 0" "0" "$RC"
has_line "O7 a PLAN-CANDIDATE line names the plan-only session" "$OUT" "^PLAN-CANDIDATE: session=$P files=2 "
has_line "O7 a USER-REQUESTED-CANDIDATE line names the user-requested-only session" "$OUT" "^USER-REQUESTED-CANDIDATE: session=$Q files=1 "
has_line "O7 the plan-only group's DRY-RUN candidate line is printed" "$OUT" \
  "^DRY-RUN: candidate session=$P files=2 oldest=[^ ]+ newest=[^ ]+ plan=2 user-requested=0 non-plan=0 unknown=0$"
has_line "O7 the user-requested-only group's DRY-RUN candidate line is printed" "$OUT" \
  "^DRY-RUN: candidate session=$Q files=1 oldest=[^ ]+ newest=[^ ]+ plan=0 user-requested=1 non-plan=0 unknown=0$"
lacks_line "O7 the include flag prints no hint line" "$OUT" "$HINT_RE"
expect_all_present "O7 --dry-run" "$D" "${P_FILES[@]}" "${Q_FILES[@]}"
case_end

case_begin "O8-plan-plus-user-requested-group-no-candidate-lines" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o8)"; mk_old "$D" "${B_FILES[@]}"
run_sweep "$D" --dry-run
check "O8 --dry-run exits 0" "0" "$RC"
lacks_line "O8 no DRY-RUN candidate line for the plan + user-requested group" "$ALL" "^DRY-RUN: candidate session=$B "
lacks_line "O8 no PLAN-CANDIDATE line" "$ALL" "^PLAN-CANDIDATE:"
lacks_line "O8 no USER-REQUESTED-CANDIDATE line" "$ALL" "^USER-REQUESTED-CANDIDATE:"
has_line "O8 the hint counts 2 files in 1 session" "$OUT" "^plan / user-requested files kept: 2 in 1 sessions "
expect_all_present "O8 --dry-run" "$D" "${B_FILES[@]}"
D="$(new_dir o8)"; mk_old "$D" "${B_FILES[@]}"
run_sweep "$D" --ci-mode
check "O8 --ci-mode exits 0" "0" "$RC"
lacks_line "O8 --ci-mode no PLAN-CANDIDATE line" "$ALL" "^PLAN-CANDIDATE:"
lacks_line "O8 --ci-mode no USER-REQUESTED-CANDIDATE line" "$ALL" "^USER-REQUESTED-CANDIDATE:"
check "O8 --ci-mode groups_approval_candidates=1" "1" "$(jget "$OUT" groups_approval_candidates)"
check "O8 --ci-mode approval_candidates has 1 entry" "1" "$(jget "$OUT" approval_candidates.length)"
check "O8 --ci-mode approval_candidates[0].plan_files=1" "1" "$(jget "$OUT" approval_candidates.0.plan_files)"
check "O8 --ci-mode approval_candidates[0].user_requested_files=1" "1" "$(jget "$OUT" approval_candidates.0.user_requested_files)"
expect_all_present "O8 --ci-mode" "$D" "${B_FILES[@]}"
case_end

case_begin "O9-dry-run-non-plan-only-group-keeps-candidate-line" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o9)"; mk_old "$D" "${N_FILES[@]}"
run_sweep "$D" --dry-run
check "O9 --dry-run exits 0" "0" "$RC"
has_line "O9 the non-plan-only group's DRY-RUN candidate line is printed" "$OUT" \
  "^DRY-RUN: candidate session=$N files=2 oldest=[^ ]+ newest=[^ ]+ plan=0 user-requested=0 non-plan=2 unknown=0$"
has_line "O9 a would-remove line names $N-survey-code.md" "$OUT" "^DRY-RUN: would remove non-plan $N-survey-code\.md$"
has_line "O9 a would-remove line names $N-outline-codex-round-1-raw.md" "$OUT" \
  "^DRY-RUN: would remove non-plan $N-outline-codex-round-1-raw\.md$"
expect_all_present "O9 --dry-run" "$D" "${N_FILES[@]}"
case_end

case_begin "O10-dry-run-user-requested-plus-non-plan-keeps-candidate-line" "bin/sweep-plans/delete-passes.sh"
D="$(new_dir o10)"; mk_old "$D" "${X_FILES[@]}"
run_sweep "$D" --dry-run
check "O10 --dry-run exits 0" "0" "$RC"
has_line "O10 the mixed group's DRY-RUN candidate line carries every class count" "$OUT" \
  "^DRY-RUN: candidate session=$X files=2 oldest=[^ ]+ newest=[^ ]+ plan=0 user-requested=1 non-plan=1 unknown=0$"
has_line "O10 the would-remove line names the non-plan file" "$OUT" "^DRY-RUN: would remove non-plan $X-survey-code\.md$"
lacks_line "O10 no USER-REQUESTED-CANDIDATE line" "$ALL" "^USER-REQUESTED-CANDIDATE:"
expect_all_present "O10 --dry-run" "$D" "${X_FILES[@]}"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
