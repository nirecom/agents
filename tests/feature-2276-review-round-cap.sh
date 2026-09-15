#!/usr/bin/env bash
# tests/feature-2276-review-round-cap.sh
# Tests: bin/review-loop-verdict, bin/run-codex-review-loop, skills/_shared/codex-review-loop.md
# Tags: review-loop, round-cap, round-counter, issue-2276, TL2, scope:issue-specific, pwsh-not-required
#
# #2276 unifies every review loop on CAP=2 / MAX_EXTENSIONS=1. The cap stops
# being hardcoded in bin/review-loop-verdict and becomes an argument, and a
# review-only format's round counter survives an exit 1 so the skill restart
# that follows is counted as round 2 rather than a fresh round 1.
set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERDICT_BIN="$AGENTS_ROOT/bin/review-loop-verdict"
LOOP_BIN="$AGENTS_ROOT/bin/run-codex-review-loop"
DISPATCH_LIB="$AGENTS_ROOT/bin/lib/codex-review-loop/verdict-dispatch.sh"
SHARED_MD="$AGENTS_ROOT/skills/_shared/codex-review-loop.md"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name (want: [$want] got: [$got])"; fi
}
assert_contains() {
    local name="$1" needle="$2" hay="$3"
    if [ -z "$needle" ]; then fail "$name (needle is empty)"; return; fi
    if printf '%s' "$hay" | grep -Fq -- "$needle"; then pass "$name"
    else fail "$name (missing: [$needle] in: [$(printf '%s' "$hay" | head -c 300)])"; fi
}
trim() { printf '%s' "$1" | tr -d '\r' | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//'; }

TMPDIR_BASE=$(mktemp -d)
trap 'cd / 2>/dev/null; rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID 2>/dev/null || true
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
unset CLAUDE_ENV_FILE 2>/dev/null || true
export CLAUDE_WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPDIR_BASE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"
cd "$TMPDIR_BASE" || exit 1

for _f in "$VERDICT_BIN" "$LOOP_BIN" "$DISPATCH_LIB" "$SHARED_MD"; do
    [ -f "$_f" ] || fail "implementation missing: ${_f#"$AGENTS_ROOT/"} (cases below fail for this reason)"
done

run_verdict() {
    V_OUT="$(bash "$VERDICT_BIN" "$@" 2>&1)"
    V_RC=$?
    V_OUT="$(trim "$V_OUT")"
}

# --- A. the cap is an argument, and it moves the decision point -------------
echo ""
echo "--- A: cap argument moves the decision point ---"

while IFS='|' read -r name capflag round high med low budget risk want_rc want_word; do
    name="$(trim "$name")"; capflag="$(trim "$capflag")"
    [ -z "$name" ] && continue
    case "$name" in \#*) continue ;; esac
    ARGS=("$(trim "$round")" "$(trim "$high")" "$(trim "$med")" "$(trim "$low")")
    [ -n "$capflag" ] && [ "$capflag" != "-" ] && ARGS+=(--cap "$capflag")
    ARGS+=(--budget-remaining "$(trim "$budget")")
    [ "$(trim "$risk")" != "-" ] && ARGS+=(--risk-signal "$(trim "$risk")")
    run_verdict "${ARGS[@]}"
    assert_eq "A: $name — exit code" "$(trim "$want_rc")" "$V_RC"
    assert_eq "A: $name — decision word" "$(trim "$want_word")" "$V_OUT"
done <<'TABLE'
default-r1-high      | -  | 1 | 1 | 0 | 0 | 1 | -    | 1 | CONTINUE
default-r1-medium    | -  | 1 | 0 | 1 | 0 | 1 | -    | 1 | CONTINUE
default-r1-low-only  | -  | 1 | 0 | 0 | 3 | 1 | -    | 0 | APPROVED
default-r2-extend    | -  | 2 | 1 | 0 | 0 | 1 | -    | 5 | AUTO_EXTEND
default-r2-ceiling   | -  | 2 | 1 | 0 | 0 | 0 | -    | 6 | HIGH_UNRESOLVED
default-r2-risk      | -  | 2 | 1 | 0 | 0 | 0 | hook | 2 | ESCALATE
default-r2-medium    | -  | 2 | 0 | 2 | 0 | 0 | -    | 0 | APPROVED
default-r3-ceiling   | -  | 3 | 1 | 0 | 0 | 0 | -    | 6 | HIGH_UNRESOLVED
cap3-r2-continues    | 3  | 2 | 1 | 0 | 0 | 1 | -    | 1 | CONTINUE
cap3-r3-extend       | 3  | 3 | 1 | 0 | 0 | 1 | -    | 5 | AUTO_EXTEND
cap3-r3-ceiling      | 3  | 3 | 1 | 0 | 0 | 0 | -    | 6 | HIGH_UNRESOLVED
cap3-r3-risk         | 3  | 3 | 1 | 0 | 0 | 0 | hook | 2 | ESCALATE
cap3-r1-continues    | 3  | 1 | 1 | 0 | 0 | 1 | -    | 1 | CONTINUE
cap1-r1-extend       | 1  | 1 | 1 | 0 | 0 | 1 | -    | 5 | AUTO_EXTEND
cap1-r1-ceiling      | 1  | 1 | 1 | 0 | 0 | 0 | -    | 6 | HIGH_UNRESOLVED
cap1-r1-risk         | 1  | 1 | 1 | 0 | 0 | 0 | hook | 2 | ESCALATE
cap1-r1-medium       | 1  | 1 | 0 | 1 | 0 | 0 | -    | 0 | APPROVED
cap2-r1-continues    | 2  | 1 | 1 | 0 | 0 | 1 | -    | 1 | CONTINUE
cap2-r2-extend       | 2  | 2 | 1 | 0 | 0 | 1 | -    | 5 | AUTO_EXTEND
clean-any-round      | 3  | 5 | 0 | 0 | 0 | 0 | -    | 0 | APPROVED
TABLE

# An explicit --cap 2 and an omitted cap must be the same run, not two literals.
run_verdict 2 1 0 0 --budget-remaining 1
DEFAULT_R2="$V_RC/$V_OUT"
run_verdict 2 1 0 0 --cap 2 --budget-remaining 1
assert_eq "A: an omitted cap defaults to 2" "$DEFAULT_R2" "$V_RC/$V_OUT"

run_verdict 2 1 0 0 --budget-remaining 1 --cap 3
assert_eq "A: --cap is order-independent (trailing form)" "1" "$V_RC"

# --- B. cap argument validation ---------------------------------------------
echo ""
echo "--- B: cap argument validation ---"

run_verdict 1 1 0 0 --cap
assert_eq "B: --cap without a value is an argument error" "4" "$V_RC"
run_verdict 1 1 0 0 --cap abc
assert_eq "B: a non-integer cap is an argument error" "4" "$V_RC"
run_verdict 1 1 0 0 --cap 0
assert_eq "B: a cap of 0 is an argument error" "4" "$V_RC"
run_verdict 1 1 0 0 --cap -1
assert_eq "B: a negative cap is an argument error" "4" "$V_RC"
run_verdict 1 1 0 0 --cap 2 --unknown-flag x
assert_eq "B: an unknown flag is still an argument error" "4" "$V_RC"
assert_contains "B: the cap is documented in the usage header" "--cap" \
    "$(head -n 20 "$VERDICT_BIN" 2>/dev/null || true)"

# --- C. round-counter lifecycle through the real loop -----------------------
echo ""
echo "--- C: round-counter lifecycle (review-only format) ---"

FAKE_ROOT="$TMPDIR_BASE/fake-agents"
mkdir -p "$FAKE_ROOT/rules"
cp -R "$AGENTS_ROOT/bin" "$FAKE_ROOT/bin"
cp "$AGENTS_ROOT/rules/core-principles.md" "$FAKE_ROOT/rules/core-principles.md"

STUB="$FAKE_ROOT/bin/review-plan-codex"
printf '%s\n' '#!/usr/bin/env bash' \
    'R=1' \
    'while [ $# -gt 0 ]; do case "$1" in --round) R="$2"; shift 2 ;; *) shift ;; esac; done' \
    'printf "%s\n" "${STUB_HEADER:-## Codex Review: PERFORMED}"' \
    'case "${STUB_HEADER:-}" in "## Codex Review: SKIPPED"*|"## Codex Review: FAILED"*) exit 0 ;; esac' \
    'printf "%s\n" "<!-- begin-codex-output -->"' \
    'if [ "${STUB_APPROVED:-no}" = "yes" ]; then printf "%s\n" "APPROVED"' \
    'elif [ "$R" = "1" ]; then printf "%s\n%s\n" "NEEDS_REVISION" "1. [HIGH] the fixture concern that stays open"' \
    'else printf "%s\n%s\n" "NEEDS_REVISION" "C1: still open"; fi' \
    'printf "%s\n" "<!-- end-codex-output -->"' \
    'exit 0' > "$STUB"

CN=0
new_loop_env() {
    CN=$((CN + 1))
    LP="$TMPDIR_BASE/cl$CN"
    mkdir -p "$LP"
    printf 'draft\n' > "$LP/draft.md"
    printf 'none\n' > "$LP/tradeoffs.md"
    SID="capsess$CN"
    : > "$LP/$SID-codex-context.test-review.built"
    RCOUNTER="$LP/$SID-test-review-round-number.txt"
}
loop_run() {
    local approved="${1:-no}" header="${2:-## Codex Review: PERFORMED}" extused="${3:-0}" risk="${4:-}"
    local extra=()
    [ -n "$risk" ] && extra=(--risk-signal "$risk")
    L_OUT="$(AGENTS_CONFIG_DIR="$FAKE_ROOT" STUB_APPROVED="$approved" STUB_HEADER="$header" \
        bash "$FAKE_ROOT/bin/run-codex-review-loop" \
        --format test-review --session-id "$SID" --plans-dir "$LP" \
        --draft-file "$LP/draft.md" --cap 2 --max-extensions 1 \
        --extensions-used "$extused" --accepted-tradeoffs "$LP/tradeoffs.md" \
        "${extra[@]+"${extra[@]}"}" 2>&1)"
    L_RC=$?
}
counter_state() {
    if [ -f "$RCOUNTER" ]; then trim "$(cat "$RCOUNTER" 2>/dev/null || true)"; else printf 'deleted'; fi
}

new_loop_env
loop_run
assert_eq "C1: round 1 with a HIGH concern continues (exit 1)" "1" "$L_RC"
assert_eq "C1: round 1 exit 1 keeps the round counter at 1" "1" "$(counter_state)"
loop_run
assert_eq "C1: the restart is counted as round 2 and auto-extends (exit 5)" "5" "$L_RC"
assert_eq "C1: an AUTO_EXTEND keeps the counter at 2" "2" "$(counter_state)"
loop_run no "## Codex Review: PERFORMED" 1
assert_eq "C1: round 3 at the ceiling is HIGH_UNRESOLVED and drops the counter" \
    "rc=6 counter=deleted" "rc=$L_RC counter=$(counter_state)"

new_loop_env
loop_run
assert_eq "C2: precondition — round 1 continues" "1" "$L_RC"
loop_run no "## Codex Review: PERFORMED" 1 "hook-blocked"
assert_eq "C2: a risk signal at the ceiling escalates and drops the counter" \
    "rc=2 counter=deleted" "rc=$L_RC counter=$(counter_state)"

new_loop_env
loop_run yes
assert_eq "C3: an APPROVED round 1 exits 0 and drops the counter" \
    "rc=0 counter=deleted" "rc=$L_RC counter=$(counter_state)"

new_loop_env
loop_run
assert_eq "C4: precondition — round 1 continues and holds the counter" "1" "$(counter_state)"
loop_run no "## Codex Review: SKIPPED — codex CLI not installed"
assert_eq "C4: an unusable reviewer falls back (exit 3)" "3" "$L_RC"
assert_eq "C4: exit 3 rolls the counter back to the pre-call value" "1" "$(counter_state)"

new_loop_env
loop_run no "## Codex Review: FAILED — codex exec exit code 9"
assert_eq "C5: a failed round 1 falls back and leaves no counter behind" \
    "rc=3 counter=deleted" "rc=$L_RC counter=$(counter_state)"

# --- D. the loop and the wrappers carry the unified cap ---------------------
echo ""
echo "--- D: cap wiring and unified parameter values ---"

# S9-b moved the verdict dispatch out of the loop entrypoint and into its lib;
# both passes (reviewer and prestaged/fallback) forward the loop's own CAP.
assert_eq "D: both verdict dispatch paths forward the loop's CAP to review-loop-verdict" \
    "2" "$(grep -c '"--cap" "\$CAP"' "$DISPATCH_LIB" 2>/dev/null || true)"
assert_eq "D: exit 1 no longer special-cases the review-only formats" \
    "0" "$(grep -c 'security-plan|test-review) (( ROUND >= CAP ))' "$LOOP_BIN" 2>/dev/null || true)"

for _w in make-outline-plan make-detail-plan review-tests review-plan-security review-code-security; do
    _f="$AGENTS_ROOT/skills/$_w/scripts/run-codex-review-loop.sh"
    if [ ! -f "$_f" ]; then
        fail "D: $_w — skills/$_w/scripts/run-codex-review-loop.sh is missing"
        continue
    fi
    assert_eq "D: $_w — wrapper passes --cap 2" \
        "1" "$(grep -c -- '--cap 2' "$_f" 2>/dev/null || true)"
    assert_eq "D: $_w — wrapper passes --max-extensions 1" \
        "1" "$(grep -c -- '--max-extensions 1' "$_f" 2>/dev/null || true)"
done

assert_eq "D: the shared parameter table has no CAP=1 row left" \
    "0" "$(grep -c 'CAP=1' "$SHARED_MD" 2>/dev/null || true)"
assert_eq "D: the shared parameter table has no MAX_EXTENSIONS=0 row left" \
    "0" "$(grep -c 'MAX_EXTENSIONS=0' "$SHARED_MD" 2>/dev/null || true)"
assert_contains "D: the shared doc names the security-code format" \
    "security-code" "$(cat "$SHARED_MD" 2>/dev/null || true)"

for _s in review-tests review-plan-security; do
    _f="$AGENTS_ROOT/skills/$_s/SKILL.md"
    assert_eq "D: $_s SKILL.md drops the 'exit 5 does not occur' claim" \
        "0" "$(grep -c 'exit 5 → does not occur' "$_f" 2>/dev/null || true)"
    assert_eq "D: $_s SKILL.md drops the single-round claim" \
        "0" "$(grep -c 'single-round' "$_f" 2>/dev/null || true)"
done

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
