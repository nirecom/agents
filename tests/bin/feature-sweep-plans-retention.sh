#!/usr/bin/env bash
# tests/bin/feature-sweep-plans-retention.sh
# Tests: bin/sweep-plans.sh, bin/sweep-plans/retention-class.js
# Tags: scope:common, TL2, sweep, plans, workflow-plans, retention, registry, ci-mode, maintenance, bin, pwsh-not-required, toctou, revival
# Retention classes in sweep-plans: non-plan deleted by default, plan and
# user-requested only listed, unknown always kept; the bash -> node classifier
# bridge contract (incl. the empty-prefix named exception) and its fail-safe; and
# --ci-mode keeping stdout to exactly one JSON line. Standalone file: modules under
# tests/bin/feature-sweep-plans/ are not run by tests/run-all.sh on their own.
# TL3 gap: none — the script and the bridge run for real against a temp PLANS_DIR.

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

SWEEP="$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans.sh"
BRIDGE="$SCRIPT_CHECKOUT_ROOT/bin/sweep-plans/retention-class.js"
U="a1b2c3d4-e5f6-4890-abcd-ef1234567890"
GATE_SID="9f000000-0000-4000-8000-00000000a001"
ERRF="$T_ROOT/stderr.txt"
SEQ=0

backdate() { touch -d "60 days ago" "$1" 2>/dev/null || touch -t 202401010000 "$1" 2>/dev/null || true; }
# mk_files <dir> <old|new> <basename...>
mk_files() {
  local d="$1" age="$2" n; shift 2
  mkdir -p "$d"
  for n in "$@"; do
    printf 'x\n' > "$d/$n"
    [ "$age" = "old" ] && backdate "$d/$n"
  done
}
new_dir() { SEQ=$((SEQ + 1)); printf '%s/plans-%s-%d' "$T_ROOT" "$1" "$SEQ"; }

# run_sweep <script> <plans_dir> <args...> — sets RC, OUT (stdout), ERR (stderr).
run_sweep() {
  local script="$1" pd="$2"; shift 2
  RC=0
  OUT="$(WORKFLOW_PLANS_DIR="$pd" SWEEP_AGE_DAYS=30 run_with_timeout 120 bash "$script" "$@" 2>"$ERRF")" || RC=$?
  OUT="$(printf '%s' "$OUT" | tr -d '\r')"
  ERR="$(tr -d '\r' < "$ERRF")"
}
# jget <text> <dotted.path> — value from the first JSON line of <text> ("<missing>" when absent).
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
check() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi; }
expect_present() { if [ -e "$2" ]; then pass "$1"; else fail "$1" "removed: ${2##*/}"; fi; }
expect_gone() { if [ -e "$2" ]; then fail "$1" "still present: ${2##*/}"; else pass "$1"; fi; }
has_line() { if printf '%s\n' "$2" | grep -qE "$3"; then pass "$1"; else fail "$1" "no line matching /$3/"; fi; }
lacks_line() { if printf '%s\n' "$2" | grep -qE "$3"; then fail "$1" "unexpected line matching /$3/"; else pass "$1"; fi; }

R1_PLAN="$U-intent.md"
R1_UR="$U-user-requested-progress.md"
R1_NON_PLAN=("$U-note-scratch.md" "$U-survey-code.md" "$U-outline-codex-round-1-raw.md")
R1_UNKNOWN=("$U-x-history-staging.md" "$U-note-intent.md")
mk_r1() { mk_files "$1" old "$R1_PLAN" "$R1_UR" "${R1_NON_PLAN[@]}" "${R1_UNKNOWN[@]}"; }

# expect_r1_files <label> <dir> — non-plan gone; plan, user-requested and unknown kept.
expect_r1_files() {
  local label="$1" d="$2" n
  for n in "${R1_NON_PLAN[@]}"; do expect_gone "$label non-plan $n is removed" "$d/$n"; done
  expect_present "$label plan $R1_PLAN is kept" "$d/$R1_PLAN"
  expect_present "$label user-requested $R1_UR is kept" "$d/$R1_UR"
  for n in "${R1_UNKNOWN[@]}"; do expect_present "$label unknown $n is kept" "$d/$n"; done
}
expect_r1_json() {
  local label="$1"
  check "$label files_non_plan_candidates=3" "3" "$(jget "$OUT" files_non_plan_candidates)"
  check "$label files_plan_candidates=1" "1" "$(jget "$OUT" files_plan_candidates)"
  check "$label files_user_requested_candidates=1" "1" "$(jget "$OUT" files_user_requested_candidates)"
  check "$label files_unknown_kept=2" "2" "$(jget "$OUT" files_unknown_kept)"
  check "$label groups_removed=1" "1" "$(jget "$OUT" groups_removed)"
  check "$label classifier_failed=0" "0" "$(jget "$OUT" classifier_failed)"
}

case_begin "R1-flagless-deletes-non-plan-only" "bin/sweep-plans.sh"
D="$(new_dir r1)"; mk_r1 "$D"
run_sweep "$SWEEP" "$D"
check "R1 flagless run exits 0" "0" "$RC"
expect_r1_files "R1" "$D"
lacks_line "R1 no PLAN-CANDIDATE line without the include flag" "$OUT" "^PLAN-CANDIDATE:"
lacks_line "R1 no USER-REQUESTED-CANDIDATE line without the include flag" "$OUT" "^USER-REQUESTED-CANDIDATE:"
has_line "R1 the hint line points at --include-plan-and-user-requested" "$OUT" \
  "^plan / user-requested files kept: 2 in 1 sessions .* run /sweep-plans --include-plan-and-user-requested to review them for deletion$"
lacks_line "R1 the flagless output never says dry-run" "$OUT" "dry-run"
D="$(new_dir r1j)"; mk_r1 "$D"
run_sweep "$SWEEP" "$D" --ci-mode
expect_r1_json "R1 --ci-mode"
case_end

case_begin "R2-apply-is-the-flagless-default" "bin/sweep-plans.sh"
D="$(new_dir r2)"; mk_r1 "$D"
run_sweep "$SWEEP" "$D" --apply --ci-mode
check "R2 --apply exits 0" "0" "$RC"
expect_r1_files "R2 --apply" "$D"
expect_r1_json "R2 --apply"
case_end

case_begin "R3-dry-run-lists-every-class" "bin/sweep-plans.sh"
D="$(new_dir r3)"; mk_r1 "$D"
run_sweep "$SWEEP" "$D" --dry-run
check "R3 --dry-run exits 0" "0" "$RC"
for n in "$R1_PLAN" "$R1_UR" "${R1_NON_PLAN[@]}" "${R1_UNKNOWN[@]}"; do
  expect_present "R3 --dry-run keeps $n" "$D/$n"
done
has_line "R3 the DRY-RUN candidate line carries the per-class counts" "$OUT" \
  "^DRY-RUN: candidate session=$U files=7 oldest=[^ ]+ newest=[^ ]+ plan=1 user-requested=1 non-plan=3 unknown=2$"
for n in "${R1_UNKNOWN[@]}"; do has_line "R3 UNKNOWN line for $n" "$OUT" "^UNKNOWN: $n$"; done
lacks_line "R3 no PLAN-CANDIDATE line without the include flag" "$OUT" "^PLAN-CANDIDATE:"
case_end

case_begin "R4-young-group-non-plan-kept" "bin/sweep-plans.sh"
D="$(new_dir r4)"
mk_files "$D" new "$U-survey-code.md" "$U-outline-codex-round-1-raw.md"
run_sweep "$SWEEP" "$D" --ci-mode
check "R4 exits 0" "0" "$RC"
expect_present "R4 a young group's non-plan survey is kept" "$D/$U-survey-code.md"
expect_present "R4 a young group's non-plan raw is kept" "$D/$U-outline-codex-round-1-raw.md"
check "R4 groups_skipped_young=1" "1" "$(jget "$OUT" groups_skipped_young)"
case_end

case_begin "R5-classifier-failure-keeps-everything" "bin/sweep-plans.sh"
# A bin-only checkout copy has no hooks/lib, so the bridge's registry require fails.
COPY="$T_ROOT/bin-only-checkout"
mkdir -p "$COPY"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin" "$COPY/bin"
D="$(new_dir r5)"; mk_r1 "$D"
run_sweep "$COPY/bin/sweep-plans.sh" "$D" --ci-mode
check "R5 exits 0 (fail-safe, not an error)" "0" "$RC"
for n in "$R1_PLAN" "$R1_UR" "${R1_NON_PLAN[@]}" "${R1_UNKNOWN[@]}"; do
  expect_present "R5 classifier failure keeps $n" "$D/$n"
done
check "R5 classifier_failed=1" "1" "$(jget "$OUT" classifier_failed)"
check "R5 files_removed=0" "0" "$(jget "$OUT" files_removed)"
has_line "R5 stderr names the unavailable classifier" "$ERR" \
  "^WARN: sweep-plans: retention classifier unavailable \(.+\); keeping every plan, user-requested and non-plan file$"
case_end

# R6 rows: <group-prefix>|<basename>|<expected class>; an empty prefix is the #847 named exception.
R6_ROWS=(
  "$U|$U-detail.md|plan"
  "$U|$U-user-requested-project-progress.md|user-requested"
  "$U|$U-outline-codex-round-2-raw.md|non-plan"
  "$U|$U-history-staging.md|unknown"
  "$U|$U-note-intent.md|unknown"
  "|-intent.md|plan"
  "|-detail-codex-round-1-raw.md|non-plan"
  "|-commit-push-worker.log|unknown"
)
case_begin "R6-bridge-contract" "bin/sweep-plans/retention-class.js"
if [ ! -f "$BRIDGE" ]; then
  fail "R6 bridge bin/sweep-plans/retention-class.js exists" "missing"
else
  R6_IN="$T_ROOT/r6-input.bin"; : > "$R6_IN"; R6_WANT=()
  for row in "${R6_ROWS[@]}"; do
    IFS='|' read -r r_pfx r_base r_want <<< "$row"
    printf '%s\0%s\0' "$r_pfx" "$r_base" >> "$R6_IN"; R6_WANT+=("$r_want")
  done
  R6_RC=0
  R6_OUT="$(run_with_timeout 30 node "$(np "$BRIDGE")" < "$R6_IN" 2>/dev/null)" || R6_RC=$?
  mapfile -t R6_GOT < <(printf '%s\n' "$R6_OUT" | tr -d '\r' | sed '/^$/d')
  check "R6 the bridge exits 0" "0" "$R6_RC"
  check "R6 one output line per input pair" "${#R6_ROWS[@]}" "${#R6_GOT[@]}"
  for i in "${!R6_ROWS[@]}"; do
    IFS='|' read -r r_pfx r_base r_want <<< "${R6_ROWS[$i]}"
    check "R6 row $i prefix='$r_pfx' $r_base -> $r_want" "$r_want" "${R6_GOT[$i]:-<none>}"
  done
fi
case_end

# R8 rows: <stub mode>|<what the stub breaks>; each stub exits as named and claims every file non-plan.
R8_ROWS=(
  "short|one line fewer than the input pairs"
  "extra|one line more than the input pairs"
  "badword|a word outside the four classes"
  "nonzero|a non-zero exit after a full answer"
)
# write_stub_bridge <path> <mode> — a bridge that answers wrongly in the named way.
write_stub_bridge() {
  mkdir -p "${1%/*}"
  printf 'const MODE = "%s";\n' "$2" > "$1"
  cat >> "$1" <<'JS'
const chunks = [];
process.stdin.on("data", (c) => chunks.push(c));
process.stdin.on("end", () => {
  const n = Math.floor(Buffer.concat(chunks).toString("utf8").split("\0").length / 2);
  let words = Array(n).fill("non-plan");
  if (MODE === "short") words = words.slice(0, Math.max(0, n - 1));
  if (MODE === "extra") words.push("non-plan");
  if (MODE === "badword" && n > 0) words[0] = "deletable";
  process.stdout.write(words.map((w) => w + "\n").join(""));
  process.exitCode = MODE === "nonzero" ? 3 : 0;
});
JS
}
case_begin "R8-bad-bridge-answer-keeps-everything" "bin/sweep-plans.sh"
STUB_COPY="$T_ROOT/stub-bridge-checkout"
mkdir -p "$STUB_COPY"
cp -r "$SCRIPT_CHECKOUT_ROOT/bin" "$STUB_COPY/bin"
for row in "${R8_ROWS[@]}"; do
  IFS='|' read -r r_mode r_why <<< "$row"
  write_stub_bridge "$STUB_COPY/bin/sweep-plans/retention-class.js" "$r_mode"
  D="$(new_dir "r8-$r_mode")"; mk_r1 "$D"
  run_sweep "$STUB_COPY/bin/sweep-plans.sh" "$D" --ci-mode
  check "R8 [$r_mode: $r_why] exits 0 (fail-safe)" "0" "$RC"
  for n in "$R1_PLAN" "$R1_UR" "${R1_NON_PLAN[@]}" "${R1_UNKNOWN[@]}"; do
    expect_present "R8 [$r_mode] keeps $n" "$D/$n"
  done
  check "R8 [$r_mode] classifier_failed=1" "1" "$(jget "$OUT" classifier_failed)"
  check "R8 [$r_mode] files_removed=0" "0" "$(jget "$OUT" files_removed)"
  has_line "R8 [$r_mode] stderr names the unavailable classifier" "$ERR" \
    "^WARN: sweep-plans: retention classifier unavailable \(.+\); keeping every plan, user-requested and non-plan file$"
done
case_end

case_begin "R9-second-flagless-run-removes-nothing" "bin/sweep-plans.sh"
D="$(new_dir r9)"; mk_r1 "$D"
run_sweep "$SWEEP" "$D"
check "R9 first run exits 0" "0" "$RC"
run_sweep "$SWEEP" "$D" --ci-mode
check "R9 second run exits 0" "0" "$RC"
check "R9 second run files_removed=0" "0" "$(jget "$OUT" files_removed)"
check "R9 second run groups_removed=0" "0" "$(jget "$OUT" groups_removed)"
check "R9 second run files_non_plan_candidates=0" "0" "$(jget "$OUT" files_non_plan_candidates)"
expect_r1_files "R9 after two runs" "$D"
case_end

case_begin "R7-ci-mode-stdout-is-one-json-line" "bin/sweep-plans.sh"
r7_mode() {
  local label="$1"; shift
  local d lines
  d="$(new_dir r7)"; mk_r1 "$d"
  run_sweep "$SWEEP" "$d" --ci-mode "$@"
  check "R7 [$label] exits 0" "0" "$RC"
  lines="$(printf '%s\n' "$OUT" | grep -c '')"
  check "R7 [$label] stdout is exactly one line" "1" "$lines"
  check "R7 [$label] stdout parses as JSON" "ok" \
    "$(printf '%s' "$OUT" | node -e 'let b="";process.stdin.on("data",c=>b+=c);process.stdin.on("end",()=>{try{JSON.parse(b);process.stdout.write("ok")}catch(e){process.stdout.write("bad")}})' 2>/dev/null)"
  check "R7 [$label] approval_candidates[0].token" "$U" "$(jget "$OUT" approval_candidates.0.token)"
  check "R7 [$label] approval_candidates[0].plan_files" "1" "$(jget "$OUT" approval_candidates.0.plan_files)"
  check "R7 [$label] approval_candidates[0].user_requested_files" "1" "$(jget "$OUT" approval_candidates.0.user_requested_files)"
  lacks_line "R7 [$label] no PLAN-CANDIDATE line on stdout" "$OUT" "^PLAN-CANDIDATE:"
  if [[ "$label" == "pass1" ]]; then
    has_line "R7 [$label] the PLAN-CANDIDATE line goes to stderr" "$ERR" "^PLAN-CANDIDATE: session=$U "
  else
    lacks_line "R7 [$label] no PLAN-CANDIDATE line on stderr without the include flag" "$ERR" "^PLAN-CANDIDATE:"
  fi
  lacks_line "R7 [$label] no gate block on stdout" "$OUT" "^<<<APPROVAL-GATE-SP3$"
}
r7_mode flagless
check "R7 [flagless] gate_id is null" "null" "$(jget "$OUT" gate_id)"
r7_mode dry-run --dry-run
check "R7 [dry-run] gate_id is null" "null" "$(jget "$OUT" gate_id)"
r7_mode pass1 --include-plan-and-user-requested --gate-session "$GATE_SID"
GID="$(jget "$OUT" gate_id)"
if printf '%s' "$GID" | grep -qE '^[0-9a-f]{32}$'; then pass "R7 [pass1] gate_id is 32 hex chars"; else fail "R7 [pass1] gate_id is 32 hex chars" "got=$GID"; fi
has_line "R7 [pass1] the gate block goes to stderr" "$ERR" "^<<<APPROVAL-GATE-SP3$"
case_end

# R10: delete-time TOCTOU recheck (_group_revived). A PATH `date` stub fires inside
# format_date, which only sweep_plans_list calls — after selection, before deletion; the
# include flag (no --gate-session: deletion scope unchanged) keeps the PLAN-CANDIDATE line that calls it.
# The stub only fires because format_date forks the external `date`; it must keep doing so.
SP_REAL_DATE="$(command -v date)"
R10_STUB_DIR="$T_ROOT/r10-stub-bin"
mkdir -p "$R10_STUB_DIR"
cat > "$R10_STUB_DIR/date" <<'SH'
#!/usr/bin/env bash
if [[ "${1:-}" == "-d" || "${1:-}" == "-r" ]] && [[ -n "${SP_STUB_TARGET:-}" && ! -e "${SP_STUB_FIRED:?}" ]]; then
  : > "$SP_STUB_FIRED"
  if [[ "${SP_STUB_ACTION:-}" == "rm" ]]; then
    rm -f -- "$SP_STUB_TARGET"
  elif [[ "${SP_STUB_ACTION:-}" == "old" ]]; then
    touch -d "60 days ago" "$SP_STUB_TARGET" 2>/dev/null || touch -t 202401010000 "$SP_STUB_TARGET"
  else
    touch "$SP_STUB_TARGET"
  fi
fi
exec "${SP_REAL_DATE:?}" "$@"
SH
chmod +x "$R10_STUB_DIR/date"
export SP_REAL_DATE
R10_NON_PLAN=("$U-survey-code.md" "$U-outline-codex-round-1-raw.md")
R10_FOREIGN="b2c3d4e5-f6a7-4901-bcde-f12345678901"
# R10 rows: <mode>|<basename the stub acts on; empty = pass-through>|<action: empty = touch now, old = backdate 60 days, rm = delete it>|<revived|removed>
# A matching-name set that differs from the scan (a file appeared or vanished) revives the group (detail.md).
R10_ROWS=(
  "control|||removed"
  "indexed|$U-intent.md||revived"
  "new-file|$U-late-note.md||revived"
  "new-file-backdated|$U-late-note.md|old|revived"
  "foreign-backdated|$R10_FOREIGN-late-note.md|old|removed"
  "vanished-known-file|$U-intent.md|rm|revived"
)
case_begin "R10-delete-time-revival-keeps-non-plan" "bin/sweep-plans.sh"
for row in "${R10_ROWS[@]}"; do
  IFS='|' read -r r_mode r_target r_age r_want <<< "$row"
  D="$(new_dir "r10-$r_mode")"; mk_files "$D" old "$U-intent.md" "${R10_NON_PLAN[@]}"
  export SP_STUB_FIRED="$T_ROOT/r10-$r_mode.fired"
  if [[ -n "$r_target" ]]; then export SP_STUB_TARGET="$D/$r_target"; else export SP_STUB_TARGET=""; fi
  export SP_STUB_ACTION="$r_age"
  R10_SAVED_PATH="$PATH"; PATH="$R10_STUB_DIR:$PATH"
  run_sweep "$SWEEP" "$D" --ci-mode --include-plan-and-user-requested
  PATH="$R10_SAVED_PATH"
  check "R10 [$r_mode] exits 0" "0" "$RC"
  check "R10 [$r_mode] the group was old at selection (groups_candidates=1)" "1" "$(jget "$OUT" groups_candidates)"
  check "R10 [$r_mode] groups_skipped_young=0" "0" "$(jget "$OUT" groups_skipped_young)"
  if [[ -n "$r_target" ]]; then
    expect_present "R10 [$r_mode] precondition: the stub fired after selection" "$SP_STUB_FIRED"
    if [[ "$r_age" == "rm" ]]; then
      expect_gone "R10 [$r_mode] precondition: the stub removed the scan-time $r_target" "$D/$r_target"
    else
      expect_present "R10 [$r_mode] the stub-created/touched $r_target still exists" "$D/$r_target"
    fi
  fi
  if [[ "$r_want" == "removed" ]]; then
    check "R10 [$r_mode] groups_skipped_revived=0" "0" "$(jget "$OUT" groups_skipped_revived)"
    for n in "${R10_NON_PLAN[@]}"; do expect_gone "R10 [$r_mode] non-plan $n is removed" "$D/$n"; done
  else
    check "R10 [$r_mode] groups_skipped_revived=1" "1" "$(jget "$OUT" groups_skipped_revived)"
    check "R10 [$r_mode] files_removed=0" "0" "$(jget "$OUT" files_removed)"
    for n in "${R10_NON_PLAN[@]}"; do expect_present "R10 [$r_mode] aged non-plan $n is kept" "$D/$n"; done
    has_line "R10 [$r_mode] stderr names the revived session" "$ERR" "^WARN: session $U touched since scan; skipping \(revived\)$"
  fi
done
unset SP_STUB_FIRED SP_STUB_TARGET SP_STUB_ACTION
case_end

# R11: one failed removal is recorded and skipped; the run goes on. A PATH `rm` stub
# fails only for the named basename (a read-only dir does not block deletion on Windows).
SP_REAL_RM="$(command -v rm)"
R11_STUB_DIR="$T_ROOT/r11-stub-bin"
mkdir -p "$R11_STUB_DIR"
cat > "$R11_STUB_DIR/rm" <<'SH'
#!/usr/bin/env bash
for a in "$@"; do
  if [[ -n "${SP_RM_FAIL_BASE:-}" && "${a##*/}" == "$SP_RM_FAIL_BASE" ]]; then
    : > "${SP_RM_FIRED:?}"
    printf "rm: cannot remove '%s': Permission denied\n" "$a" >&2
    exit 1
  fi
done
exec "${SP_REAL_RM:?}" "$@"
SH
chmod +x "$R11_STUB_DIR/rm"
case_begin "R11-rm-failure-recorded-run-continues" "bin/sweep-plans.sh"
R11_FAIL="$U-survey-code.md"
R11_OK=("$U-outline-codex-round-1-raw.md" "$U-note-scratch.md")
D="$(new_dir r11)"; mk_files "$D" old "$U-intent.md" "$R11_FAIL" "${R11_OK[@]}"
export SP_REAL_RM SP_RM_FAIL_BASE="$R11_FAIL" SP_RM_FIRED="$T_ROOT/r11.fired"
R11_SAVED_PATH="$PATH"; PATH="$R11_STUB_DIR:$PATH"
run_sweep "$SWEEP" "$D" --ci-mode
PATH="$R11_SAVED_PATH"
unset SP_RM_FAIL_BASE
expect_present "R11 precondition: the rm stub fired for $R11_FAIL" "$SP_RM_FIRED"
check "R11 a failed removal still exits 0 (normal completion)" "0" "$RC"
expect_present "R11 the file whose removal failed still exists" "$D/$R11_FAIL"
for n in "${R11_OK[@]}"; do expect_gone "R11 the other deletable $n is still removed" "$D/$n"; done
expect_present "R11 the plan file is kept" "$D/$U-intent.md"
check "R11 errors carries exactly one entry" "1" "$(jget "$OUT" errors.length)"
R11_ERR0="$(jget "$OUT" errors.0)"
if [[ "$R11_ERR0" == rm-failed:*"/$R11_FAIL" ]]; then pass "R11 errors[0] is rm-failed:<path of $R11_FAIL>"; else fail "R11 errors[0] is rm-failed:<path of $R11_FAIL>" "got=$R11_ERR0"; fi
check "R11 files_removed=2 (the failed one not counted)" "2" "$(jget "$OUT" files_removed)"
check "R11 groups_removed=1" "1" "$(jget "$OUT" groups_removed)"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
