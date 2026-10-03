#!/usr/bin/env bash
# tests/bin/feature-2434-exit6-accept-cli.sh
# Tests: bin/accept-exit6-residual, skills/review-plan-security/scripts/run-codex-review-loop.sh, skills/review-code-security/scripts/run-codex-review-loop.sh, skills/review-tests/scripts/run-codex-review-loop.sh, skills/review-tests/SKILL.md, skills/review-plan-security/SKILL.md, skills/review-code-security/SKILL.md
# Tags: feature-2434, control-dir, exit6-accept, codex-review-loop, TL1, TL2, terminal-guard, risk-signal, scope:issue-specific, pwsh-not-required
#
# #2434 Step 5-7: the exit-6 residual-HIGH accept marker is a control file with
# one writer, bin/accept-exit6-residual. It serves security-code, security-plan
# and test-review only; outline/detail escalate instead (exit-codes.md, C4).
# The wrappers point at the CLI, never at `touch`.
set -uo pipefail

# TL1 — the CLI against the shared fixture's temp dirs, plus static checks of
# the hint text. TL2 — the wrapper-side exit 9 (all three formats) and the
# security-plan risk-signal guard run the real wrappers at the end of this file.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2434-review-loop/fixture.sh
. "$AGENTS_DIR/tests/bin/feature-2434-review-loop/fixture.sh"

CLI="$AGENTS_DIR/bin/accept-exit6-residual"
[ -f "$CLI" ] || fail "implementation missing: bin/accept-exit6-residual"

# accept <args...> — one CLI call. Sets A_RC / A_ERR.
accept() {
    A_RC=0
    run_bin "$CLI" "$@" >/dev/null 2>"$TMP/accept.err" || A_RC=$?
    A_ERR="$(cat "$TMP/accept.err" 2>/dev/null)"
}

# format | marker name in the control dir | skill
ROWS="security-code|security-code-exit6-accepted.txt|review-code-security
security-plan|review-plan-security-exit6-accepted.txt|review-plan-security
test-review|review-tests-exit6-accepted.txt|review-tests"

case_begin "cli-writes-the-marker-per-format" "bin/accept-exit6-residual"
while IFS='|' read -r FMT MARK SKILL; do
    SID="ac-$FMT"
    accept --session "$SID" --format "$FMT" --reason "user accepted residual HIGH"
    assert_eq "$FMT: accept exits 0" "0" "$A_RC"
    assert_eq "$FMT: marker $MARK in the control dir" "present" "$(state "$(ctl "$SID")/$MARK")"
    assert_eq "$FMT: nothing written under PLANS_DIR" "" "$(plans_leftovers "$SID")"
done <<EOF
$ROWS
EOF
SID="ac-date"
accept --session 20260601-120000 --format security-code --reason "date-shaped sid"
assert_eq "a date-shaped sid is accepted" "0" "$A_RC"
assert_eq "its marker lands in <sid>.control" "present" \
    "$(state "$(ctl 20260601-120000)/security-code-exit6-accepted.txt")"
case_end

case_begin "cli-rejects-outline-detail-and-bad-input" "bin/accept-exit6-residual"
# outline/detail have no accept step: exit 2 and a pointer to the table.
for FMT in outline-plan detail-plan; do
    SID="rj-$FMT"
    accept --session "$SID" --format "$FMT" --reason "should not be accepted"
    assert_eq "$FMT is refused with exit 2" "2" "$A_RC"
    assert_contains "$FMT refusal points at exit-codes.md" "exit-codes.md" "$A_ERR"
    assert_eq "$FMT: no control dir was created" "absent" "$(state "$(ctl "$SID")")"
done
accept --session rj-bogus --format bogus --reason "x"
assert_eq "an unknown format is refused with exit 2" "2" "$A_RC"
accept --session "../escape" --format security-code --reason "x"
assert_eq "a traversing sid is refused with exit 2" "2" "$A_RC"
assert_eq "no directory escaped the workflow dir" "absent" "$(state "$TMP/escape.control")"
accept --session rj-noreason --format security-code
assert_ne "a missing --reason is refused" "0" "$A_RC"
assert_eq "and leaves no marker" "absent" \
    "$(state "$(ctl rj-noreason)/security-code-exit6-accepted.txt")"
case_end

case_begin "idempotent-accept" "bin/accept-exit6-residual"
# C10: re-running accept-exit6-residual must not alter an existing marker (byte-unchanged).
[ -f "$CLI" ] || fail "implementation missing: bin/accept-exit6-residual"
if [ -f "$CLI" ]; then
    SID_I="idem-sc"
    accept --session "$SID_I" --format security-code --reason "first accept"
    assert_eq "idempotent: first accept exits 0" "0" "$A_RC"
    MARK_I="$(ctl "$SID_I")/security-code-exit6-accepted.txt"
    D_BEFORE="$(cat "$MARK_I" 2>/dev/null)"
    accept --session "$SID_I" --format security-code --reason "second accept"
    D_AFTER="$(cat "$MARK_I" 2>/dev/null)"
    assert_eq "idempotent: marker content byte-unchanged after second accept" "$D_BEFORE" "$D_AFTER"
fi
case_end

case_begin "no-touch-instruction-left" "skills/review-tests/SKILL.md"
for S in review-plan-security review-code-security review-tests; do
    W="$AGENTS_DIR/skills/$S/scripts/run-codex-review-loop.sh"
    assert_eq "$S wrapper: no 'Create it: touch' hint" "0" "$(grep -c 'Create it: touch' "$W")"
    K="$AGENTS_DIR/skills/$S/SKILL.md"
    assert_eq "$S SKILL.md: no accept-marker file name spelled out" "0" "$(grep -c 'exit6-accepted' "$K")"
    assert_contains "$S SKILL.md: refers to the escalation table" "Escalation by format" "$(cat "$K")"
done
case_end

# ── TL2: wrapper-side exit 9 (Step 5-7) ─────────────────────────────────────
# After an exit-6 terminal the edited re-run stops with exit 9 and points at
# bin/accept-exit6-residual (never at `touch`); once the CLI has recorded the
# accept, each wrapper runs a real round again (CPR-ORTH over the 3 formats).
case_begin "security-code-exit9-cleared-by-the-cli" "skills/review-code-security/scripts/run-codex-review-loop.sh"
check_exit9_accept security-code review-code-security
case_end

case_begin "security-plan-exit9-cleared-by-the-cli" "skills/review-plan-security/scripts/run-codex-review-loop.sh"
check_exit9_accept security-plan review-plan-security
case_end

case_begin "test-review-exit9-cleared-by-the-cli" "skills/review-tests/scripts/run-codex-review-loop.sh"
check_exit9_accept test-review review-tests
case_end

case_begin "security-plan-ignores-risk-signal" "skills/review-plan-security/scripts/run-codex-review-loop.sh"
# Step 5-8: security-plan has no risk-signal writer, so its wrapper reads none.
# A hand-placed file, in either directory, can no longer turn HIGH_UNRESOLVED
# into ESCALATE and skip the exit-6 accept.
SID="rs-secplan"
seed_sid "$SID"
mkdir -p "$(ctl "$SID")"
printf 'hand-placed reason\n' > "$(ctl "$SID")/security-plan-risk-signal.txt"
printf 'hand-placed reason\n' > "$P/$SID-security-plan-risk-signal.txt"
wrap review-plan-security "$SID" 0
assert_eq "round 1 continues" "1" "$W_RC"
wrap review-plan-security "$SID" 1
assert_eq "round 2 at cap stays HIGH_UNRESOLVED (exit 6), not ESCALATE" "6" "$W_RC"
assert_eq "the wrapper source no longer reads a risk-signal file" "0" \
    "$(grep -c 'risk-signal' "$AGENTS_DIR/skills/review-plan-security/scripts/run-codex-review-loop.sh")"
case_end

finish
