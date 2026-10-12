#!/usr/bin/env bash
# tests/bin/feature-sweep-plans-approval-gate.sh
# Tests: bin/sweep-plans.sh, bin/sweep-plans/gate-artifact.js
# Tags: scope:common, TL2, sweep, plans, workflow-plans, approval-gate, control-dir, retention, maintenance, bin, pwsh-not-required, gate-signature, table-driven, path-normalization
# Two-pass approval gate of --include-plan-and-user-requested: pass 1 writes the
# control-dir gate artifact + block; pass 2 deletes only approved, shown, still-old,
# unchanged groups; every invalid pass 2 exits 2 deleting nothing. Standalone: the
# tests/bin/feature-sweep-plans/ modules are not run by tests/run-all.sh.
# TL3 gap: the skill's AskUserQuestion step between passes (wording: feature-sweep-plans/skill.sh).
# Entry: setup, shared helpers, G1-G3; the other cases live in sourced part files under
# tests/bin/feature-sweep-plans-approval-gate/ (pass-flow, gate-integrity).

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
PART_DIR="$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-sweep-plans-approval-gate"
GATE_SID="9f000000-0000-4000-8000-00000000a002"
GATE_FILE="$WORKFLOW_STATE_DIR/$GATE_SID.control/sweep-plans-gate.tsv"
GATE_ERR_LINE="ERROR: sweep-plans: approval gate artifact missing or mismatched; nothing deleted"
A="aa000000-0000-4000-8000-0000000000a1"
B="bb000000-0000-4000-8000-0000000000b2"
C="cc000000-0000-4000-8000-0000000000c3"
D_UNSHOWN="dd000000-0000-4000-8000-0000000000d4"
ERRF="$T_ROOT/stderr.txt"
SEQ=0
TAB="$(printf '\t')"

backdate() { touch -d "60 days ago" "$1" 2>/dev/null || touch -t 202401010000 "$1" 2>/dev/null || true; }
mk_old() { local d="$1" n; shift; mkdir -p "$d"; for n in "$@"; do printf 'x\n' > "$d/$n"; backdate "$d/$n"; done; }
new_dir() { SEQ=$((SEQ + 1)); printf '%s/plans-%s-%d' "$T_ROOT" "$1" "$SEQ"; }
reset_gate() { rm -f "$GATE_FILE"; }
# approve_file <token...> — one token per line (CRLF, as a Windows Write may) plus a comment; prints the path.
approve_file() {
  local f t; SEQ=$((SEQ + 1)); f="$T_ROOT/approved-$SEQ.txt"
  printf '# approved tokens\r\n' > "$f"
  for t in "$@"; do printf '%s\r\n' "$t" >> "$f"; done
  printf '%s' "$f"
}

# run_sweep <plans_dir> <args...> — sets RC, OUT, ERR, ALL (stdout + stderr).
run_sweep() {
  local pd="$1"; shift
  RC=0
  OUT="$(WORKFLOW_PLANS_DIR="$pd" SWEEP_AGE_DAYS=30 run_with_timeout 120 bash "$SWEEP" "$@" 2>"$ERRF")" || RC=$?
  OUT="$(printf '%s' "$OUT" | tr -d '\r')"
  ERR="$(tr -d '\r' < "$ERRF")"
  ALL="$OUT"$'\n'"$ERR"
}
gate_id_of() { printf '%s\n' "$1" | sed -n 's/^# gate-id: \([0-9a-f]\{32\}\)$/\1/p' | head -n 1; }
pass1() { run_sweep "$1" --include-plan-and-user-requested --gate-session "$GATE_SID"; GID="$(gate_id_of "$OUT")"; }
# pass2 <plans_dir> <gate-id> <approved-file> [extra args...]
pass2() {
  local pd="$1" gid="$2" af="$3"; shift 3
  run_sweep "$pd" --include-plan-and-user-requested --gate-session "$GATE_SID" --gate-id "$gid" --approved-sessions-file "$af" "$@"
}
# jget <text> <key> — value from the first JSON line of <text> ("<missing>" when absent).
JGET_JS="$T_ROOT/jget.js"
cat > "$JGET_JS" <<'JS'
let b = ""; process.stdin.on("data", (c) => (b += c)); process.stdin.on("end", () => {
  for (const line of b.split(/\r?\n/)) {
    const t = line.trim(); if (!t.startsWith("{")) continue;
    let d; try { d = JSON.parse(t); } catch (e) { continue; }
    const v = d[process.argv[2]];
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
# expect_all_present <label> <dir> <basename...>
expect_all_present() { local l="$1" d="$2" n; shift 2; for n in "$@"; do expect_present "$l keeps $n" "$d/$n"; done; }
GA=("$A-intent.md" "$A-user-requested-progress.md")
GB=("$B-intent.md" "$B-user-requested-progress.md")
RAW_A="$A-outline-codex-round-1-raw.md"

backdate_days() {
  touch -d "$1 days ago" "$2" 2>/dev/null || touch -t "$(date -v-"$1"d +%Y%m%d%H%M 2>/dev/null)" "$2" 2>/dev/null || true
}
mtime_of() { stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || echo 0; }
# lt_mtime <label> <older> <newer> — precondition: a coarse-mtime host fails loudly here.
lt_mtime() {
  local a b; a="$(mtime_of "$2")"; b="$(mtime_of "$3")"
  if (( a > 0 && a < b )); then pass "$1"; else fail "$1" "mtime ${2##*/}=$a ${3##*/}=$b"; fi
}
# recorded_dir_is <path> — 1 when the artifact's `# plans-dir` value is <path> in MSYS, mixed or native form.
recorded_dir_is() {
  local rec f forms=("$1")
  if command -v cygpath >/dev/null 2>&1; then
    forms+=("$(cygpath -m "$1")" "$(cygpath -w "$1")")
  fi
  rec="$(tr -d '\r' < "$GATE_FILE" | sed -n 's/^# plans-dir //p' | head -n 1)"
  for f in "${forms[@]}"; do
    if [[ "$rec" == "$f" ]]; then printf '1'; return; fi
  done
  printf '0 (recorded=%s)' "$rec"
}

case_begin "G1-pass1-writes-gate-and-block" "bin/sweep-plans/gate-artifact.js"
reset_gate
P="$(new_dir g1)"; mk_old "$P" "${GA[@]}"
pass1 "$P"
check "G1 pass 1 exits 0" "0" "$RC"
has_line "G1 the gate block opens" "$OUT" "^<<<APPROVAL-GATE-SP3$"
if printf '%s' "$GID" | grep -qE '^[0-9a-f]{32}$'; then pass "G1 the block carries a 32-hex gate id"; else fail "G1 the block carries a 32-hex gate id" "got=$GID"; fi
has_line "G1 the block lists session A as a token row" "$OUT" "^$A$TAB"
has_line "G1 the gate block closes" "$OUT" "^>>>$"
expect_present "G1 the gate artifact is written to the gate session's control dir" "$GATE_FILE"
if [ -f "$GATE_FILE" ]; then
  check "G1 the artifact header id matches the block id" "# gate-id $GID" "$(head -n 1 "$GATE_FILE" | tr -d '\r')"
  has_line "G1 the artifact carries a nonce line" "$(sed -n 2p "$GATE_FILE" | tr -d '\r')" "^# nonce [0-9a-f]+$"
  has_line "G1 the artifact rows carry session A" "$(tr -d '\r' < "$GATE_FILE")" "^$A$TAB[0-9]+$TAB"
fi
expect_all_present "G1 pass 1" "$P" "${GA[@]}"
case_end

case_begin "G2-no-gate-without-gate-session" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g2)"; mk_old "$P" "${GA[@]}"
run_sweep "$P"
lacks_line "G2 a flagless run prints no gate block" "$ALL" "^<<<APPROVAL-GATE-SP3$"
expect_gone "G2 a flagless run writes no gate artifact" "$GATE_FILE"
run_sweep "$P" --include-plan-and-user-requested
check "G2 --include-plan-and-user-requested without --gate-session exits 0" "0" "$RC"
lacks_line "G2 ... prints no gate block" "$ALL" "^<<<APPROVAL-GATE-SP3$"
has_line "G2 ... still lists the plan candidate" "$ALL" "^PLAN-CANDIDATE: session=$A "
expect_gone "G2 ... writes no gate artifact" "$GATE_FILE"
expect_all_present "G2" "$P" "${GA[@]}"
case_end

case_begin "G3-internal-flags-need-their-pairs" "bin/sweep-plans.sh"
reset_gate
P="$(new_dir g3)"; mk_old "$P" "${GA[@]}" "$RAW_A"
AF="$(approve_file "$A")"
run_sweep "$P" --approved-sessions-file "$AF"
check "G3 --approved-sessions-file alone exits 2" "2" "$RC"
run_sweep "$P" --gate-session "$GATE_SID"
check "G3 --gate-session without --include-plan-and-user-requested exits 2" "2" "$RC"
run_sweep "$P" --gate-id 0123456789abcdef0123456789abcdef
check "G3 --gate-id without --include-plan-and-user-requested exits 2" "2" "$RC"
run_sweep "$P" --include-plan-and-user-requested --gate-id 0123456789abcdef0123456789abcdef --approved-sessions-file "$AF"
check "G3 pass 2 without --gate-session exits 2" "2" "$RC"
run_sweep "$P" --include-plan-and-user-requested --gate-session "$GATE_SID" --approved-sessions-file "$AF"
check "G3 pass 2 without --gate-id exits 2" "2" "$RC"
expect_all_present "G3 rejected runs" "$P" "${GA[@]}" "$RAW_A"
case_end

# ── cases (part files; each uses the helpers above at source time) ───────────
# shellcheck source=tests/bin/feature-sweep-plans-approval-gate/pass-flow.sh
. "$PART_DIR/pass-flow.sh"
# shellcheck source=tests/bin/feature-sweep-plans-approval-gate/gate-integrity.sh
. "$PART_DIR/gate-integrity.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
