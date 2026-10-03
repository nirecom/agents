#!/usr/bin/env bash
# tests/bin/feature-2434-review-loop-risk-signal.sh
# Tests: skills/make-detail-plan/scripts/run-codex-review-loop.sh, bin/record-risk-signal
# Tags: feature-2434, control-dir, codex-review-loop, risk-signal, cli, TL1, TL2, scope:issue-specific, pwsh-not-required
#
# #2434 Step 5-8: the risk signal is a control file with one writer
# (bin/record-risk-signal, outline/detail only), and the detail wrapper reads
# it from the control dir. security-plan, which must read none, is pinned in
# feature-2434-exit6-accept-cli.sh (security-plan-ignores-risk-signal).
set -uo pipefail

# TL2 — shared fixture: tests/bin/feature-2434-review-loop/fixture.sh. TL1 —
# the CLI's own argument rules (merged from feature-2434-risk-signal-cli.sh).

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
# shellcheck source=tests/bin/feature-2434-review-loop/fixture.sh
. "$AGENTS_DIR/tests/bin/feature-2434-review-loop/fixture.sh"

[ -f "$AGENTS_DIR/bin/record-risk-signal" ] || fail "implementation missing: bin/record-risk-signal"

case_begin "detail-risk-signal-escalates-at-cap" "bin/record-risk-signal"
SID="rs-detail"
seed_sid "$SID"
RS_RC=0
run_bin "$AGENTS_DIR/bin/record-risk-signal" --session "$SID" --planner detail \
    --reason "touches a security boundary" >/dev/null 2>"$TMP/rs.err" || RS_RC=$?
assert_eq "record-risk-signal exits 0" "0" "$RS_RC"
assert_eq "signal written to the control dir" "touches a security boundary" \
    "$(clf_read "$(ctl "$SID")/detail-risk-signal.txt")"
assert_eq "nothing written under PLANS_DIR" "absent" "$(state "$P/$SID-detail-risk-signal.txt")"
wrap make-detail-plan "$SID" 0
assert_eq "round 1 continues" "1" "$W_RC"
wrap make-detail-plan "$SID" 1
assert_eq "round 2 at cap with the signal -> ESCALATE (exit 2)" "2" "$W_RC"
case_end

case_begin "detail-without-signal-stays-high-unresolved" "skills/make-detail-plan/scripts/run-codex-review-loop.sh"
# Control for the case above: the same capped HIGH without a signal is exit 6,
# so the exit 2 there is the signal's doing and not the fixture's.
SID="rs-detail-none"
seed_sid "$SID"
wrap make-detail-plan "$SID" 0
wrap make-detail-plan "$SID" 1
assert_eq "round 2 at cap without a signal -> HIGH_UNRESOLVED (exit 6)" "6" "$W_RC"
case_end

# ── TL1: bin/record-risk-signal argument rules ──────────────────────────────
# One line, written once into <sid>.control/, outline/detail only, and no way
# to take it back.
CLI="$AGENTS_DIR/bin/record-risk-signal"

# rs <args...> — one CLI call. Sets R_RC / R_OUT (stdout and stderr together).
rs() {
    R_RC=0
    run_bin "$CLI" "$@" >"$TMP/rs.out" 2>&1 || R_RC=$?
    R_OUT="$(cat "$TMP/rs.out" 2>/dev/null)"
}
sig() { printf '%s/%s-risk-signal.txt' "$(ctl "$1")" "$2"; }

case_begin "writes-once-per-planner" "bin/record-risk-signal"
for PL in outline detail; do
    SID="rs1-$PL"
    rs --session "$SID" --planner "$PL" --reason "first reason"
    assert_eq "$PL: first call exits 0" "0" "$R_RC"
    assert_eq "$PL: reason written to <sid>.control/$PL-risk-signal.txt" "first reason" "$(clf_read "$(sig "$SID" "$PL")")"
    rs --session "$SID" --planner "$PL" --reason "second reason"
    assert_eq "$PL: second call still exits 0" "0" "$R_RC"
    assert_contains "$PL: second call reports already raised" "already raised" "$R_OUT"
    assert_eq "$PL: the first reason is kept (no overwrite)" "first reason" "$(clf_read "$(sig "$SID" "$PL")")"
done
assert_eq "nothing written under PLANS_DIR by the CLI" "0" "$(ls "$P" 2>/dev/null | grep -c 'rs1-.*risk-signal')"
case_end

case_begin "rejects-bad-reasons" "bin/record-risk-signal"
NL="$(printf 'line one\nline two')"
rs --session rs2-nl --planner detail --reason "$NL"
assert_ne "a multi-line reason is refused" "0" "$R_RC"
assert_eq "and leaves no signal" "absent" "$(state "$(sig rs2-nl detail)")"
rs --session rs2-empty --planner detail --reason ""
assert_ne "an empty reason is refused" "0" "$R_RC"
assert_eq "and leaves no signal" "absent" "$(state "$(sig rs2-empty detail)")"
rs --session rs2-none --planner detail
assert_ne "a missing --reason is refused" "0" "$R_RC"
assert_eq "and leaves no signal" "absent" "$(state "$(sig rs2-none detail)")"
R300="$(printf '%0300d' 0)"
rs --session rs2-300 --planner detail --reason "$R300"
assert_eq "a 300-character reason is accepted" "0" "$R_RC"
assert_eq "and stored whole" "$R300" "$(clf_read "$(sig rs2-300 detail)")"
rs --session rs2-301 --planner detail --reason "${R300}1"
assert_ne "a 301-character reason is refused" "0" "$R_RC"
assert_eq "and leaves no signal" "absent" "$(state "$(sig rs2-301 detail)")"
case_end

case_begin "rejects-planners-and-bad-sids" "bin/record-risk-signal"
# security-plan has no risk signal: a writable one would let the model turn
# HIGH_UNRESOLVED into ESCALATE and skip the exit-6 accept.
for PL in security-plan bogus ""; do
    rs --session rs3-pl --planner "$PL" --reason "x"
    assert_ne "planner '$PL' is refused" "0" "$R_RC"
done
rs --session rs3-pl --reason "x"
assert_ne "a missing --planner is refused" "0" "$R_RC"
assert_eq "no refused call created the control dir" "absent" "$(state "$(ctl rs3-pl)")"
rs --session "../escape" --planner detail --reason "x"
assert_ne "a traversing sid is refused" "0" "$R_RC"
assert_eq "nothing escaped the workflow dir" "absent" "$(state "$CLAUDE_WORKFLOW_DIR/../escape.control")"
for SID in 20260601-120000 20260509-bundle-a; do
    rs --session "$SID" --planner outline --reason "non-uuid sid"
    assert_eq "non-UUID sid $SID is accepted" "0" "$R_RC"
    assert_eq "its signal lands in $SID.control" "non-uuid sid" "$(clf_read "$(sig "$SID" outline)")"
done
case_end

case_begin "no-way-to-withdraw" "bin/record-risk-signal"
SID="rs4"
rs --session "$SID" --planner detail --reason "keep me"
for OPT in --delete --clear --remove; do
    rs --session "$SID" --planner detail "$OPT"
    assert_ne "$OPT is not an option" "0" "$R_RC"
done
assert_eq "the signal survives every withdrawal attempt" "keep me" "$(clf_read "$(sig "$SID" detail)")"
case_end

finish
