#!/usr/bin/env bash
# Tests: skills/session-close/scripts/close-alert-phase.sh
# Tags: fix-2766, supervisor, alert-phase, paused, closed, session-close, never-armed, supervisor-report, scope:issue-specific, TL2, pwsh-not-required
# #2766: close-alert-phase.sh could not close a paused alert (the transition table refused it) and
# hid the refusal behind `|| true`. A paused alert now closes, and a refused call is reported on
# stderr and to supervisor-report while the script still exits 0 (advisory).
# The transition table itself: tests/hooks/fix-2766-paused-to-closed.js.
# TL3 gap (what this test does NOT catch):
# - the real Stop-hook process path: the script is run directly, never from session-close under a
#   live Claude Code host whose Stop hook reads the alert phase it leaves;
# - the report content sent to the real bin/supervisor-report is not inspected.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
mkdir -p "$_ISOLATION_TMP_ROOT/transcripts" "$_ISOLATION_TMP_ROOT/cwd"
export CLAUDE_TRANSCRIPT_BASE_DIR="$_ISOLATION_TMP_ROOT/transcripts"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT

SCRIPT="$SCRIPT_CHECKOUT_ROOT/skills/session-close/scripts/close-alert-phase.sh"
export F2766_WRITER
F2766_WRITER="$(np "$SCRIPT_CHECKOUT_ROOT")/hooks/lib/supervisor-state-writer.js"
REAL_NODE="$(command -v node)"

# seed_paused <sid> — alert_phase=paused through the writer (null->paused is a valid transition).
seed_paused() {
    run_with_timeout 20 node -e 'process.exit(require(process.env.F2766_WRITER).writeAlertState(process.argv[1], { alert_phase: "paused" }) ? 0 : 3)' "$1" >/dev/null 2>&1
}
# phase_of <sid> — the stored alert_phase, or <none>.
phase_of() {
    run_with_timeout 20 node -e 'const st = require(process.env.F2766_WRITER).readState(process.argv[1]); process.stdout.write(String((st && st.alert && st.alert.alert_phase) || "<none>"))' "$1" 2>/dev/null
}

case_begin "close-alert-phase-closes-a-paused-alert" "skills/session-close/scripts/close-alert-phase.sh"
run_p1() {
    local sid="f2766-p1" err rc phase
    seed_paused "$sid" || { fail "P1: fixture: seed paused failed"; return; }
    [ "$(phase_of "$sid")" = "paused" ] || { fail "P1: fixture: phase is not paused"; return; }
    err=$(cd "$_ISOLATION_TMP_ROOT/cwd" && run_with_timeout 60 bash "$SCRIPT" "$sid" 2>&1 >/dev/null); rc=$?
    phase=$(phase_of "$sid")
    if [ "$rc" -ne 0 ]; then fail "P1: advisory script must exit 0 (rc=$rc, stderr=$err)"; return; fi
    if [ "$phase" = "closed" ]; then pass "P1: paused alert becomes closed at session close, exit 0"
    else fail "P1: paused alert must become closed at session close; phase=$phase stderr=$err"; fi
}
run_p1
case_end

# alert_field_of <sid> <field> — the stored alert.<field> as JSON (null when absent), or <none>.
alert_field_of() {
    run_with_timeout 20 node -e 'const st = require(process.env.F2766_WRITER).readState(process.argv[1]); const a = st && st.alert; process.stdout.write(a ? JSON.stringify(a[process.argv[2]] === undefined ? null : a[process.argv[2]]) : "<none>")' "$1" "$2" 2>/dev/null
}

# A pass-through `node` stub: every call is logged and forwarded to the real node, so the success
# path is observed without changing it. No refusal -> no `refused` and no session-close report;
# a second run on the already-closed alert is a no-op that still exits 0.
case_begin "success-path-reports-nothing-and-rerun-is-idempotent" "skills/session-close/scripts/close-alert-phase.sh"
run_p2() {
    local sid="f2766-p2" stub_dir="$_ISOLATION_TMP_ROOT/stub-p2" log="$_ISOLATION_TMP_ROOT/calls-p2.log"
    local err rc reports phase err2 rc2
    seed_paused "$sid" || { fail "P2: fixture: seed paused failed"; return; }
    mkdir -p "$stub_dir"; : > "$log"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$STUB_LOG"' 'exec "$REAL_NODE" "$@"' > "$stub_dir/node"
    chmod +x "$stub_dir/node"
    err=$(cd "$_ISOLATION_TMP_ROOT/cwd" && PATH="$stub_dir:$PATH" STUB_LOG="$log" REAL_NODE="$REAL_NODE" run_with_timeout 60 bash "$SCRIPT" "$sid" 2>&1 >/dev/null); rc=$?
    phase=$(phase_of "$sid")
    [ -s "$log" ] || { fail "P2: fixture: the pass-through stub saw no node call"; return; }
    reports=$(grep -c -- "--reporter session-close" "$log" 2>/dev/null); reports=${reports:-0}
    if [ "$rc" -ne 0 ]; then fail "P2: advisory script must exit 0 (rc=$rc, stderr=$err)"; return; fi
    if [ "$phase" != "closed" ]; then fail "P2: alert must end closed; phase=$phase stderr=$err"; return; fi
    if printf '%s' "$err" | grep -q "refused"; then fail "P2: success path must not say refused; got: $(printf '%q' "$err")"; return; fi
    if [ "$reports" != "0" ]; then fail "P2: success path must not call supervisor-report --reporter session-close (got $reports)"; return; fi
    err2=$(cd "$_ISOLATION_TMP_ROOT/cwd" && PATH="$stub_dir:$PATH" STUB_LOG="$log" REAL_NODE="$REAL_NODE" run_with_timeout 60 bash "$SCRIPT" "$sid" 2>&1 >/dev/null); rc2=$?
    phase=$(phase_of "$sid")
    if [ "$rc2" -ne 0 ]; then fail "P2: re-run on a closed alert must exit 0 (rc=$rc2, stderr=$err2)"; return; fi
    if [ "$phase" != "closed" ]; then fail "P2: re-run must leave the alert closed; phase=$phase"; return; fi
    if printf '%s' "$err2" | grep -q "refused"; then fail "P2: re-run on a closed alert must not say refused; got: $(printf '%q' "$err2")"; return; fi
    pass "P2: success path -> no refused, no session-close report, exit 0; re-run idempotent"
}
run_p2
case_end

# run_passthrough <label> <sid> — run the script under a logging pass-through `node` stub.
# Sets PT_ERR PT_RC PT_REPORTS PT_CALLS for the caller.
run_passthrough() {
    local label="$1" sid="$2" stub_dir="$_ISOLATION_TMP_ROOT/stub-pt-$1" log="$_ISOLATION_TMP_ROOT/calls-pt-$1.log"
    mkdir -p "$stub_dir"; : > "$log"
    printf '%s\n' '#!/usr/bin/env bash' 'printf "%s\n" "$*" >> "$STUB_LOG"' 'exec "$REAL_NODE" "$@"' > "$stub_dir/node"
    chmod +x "$stub_dir/node"
    PT_ERR=$(cd "$_ISOLATION_TMP_ROOT/cwd" && PATH="$stub_dir:$PATH" STUB_LOG="$log" REAL_NODE="$REAL_NODE" run_with_timeout 60 bash "$SCRIPT" "$sid" 2>&1 >/dev/null); PT_RC=$?
    PT_REPORTS=$(grep -c -- "--reporter session-close" "$log" 2>/dev/null); PT_REPORTS=${PT_REPORTS:-0}
    PT_CALLS=$(grep -c . "$log" 2>/dev/null); PT_CALLS=${PT_CALLS:-0}
}

# assert_quiet_close <id> <sid> — shared verdict: exit 0, no `refused`, no session-close report, closed.
assert_quiet_close() {
    local id="$1" sid="$2" phase
    phase=$(phase_of "$sid")
    if [ "$PT_CALLS" = "0" ]; then fail "$id: fixture: the pass-through stub saw no node call"; return; fi
    if [ "$PT_RC" -ne 0 ]; then fail "$id: advisory script must exit 0 (rc=$PT_RC, stderr=$PT_ERR)"; return; fi
    if printf '%s' "$PT_ERR" | grep -q "refused"; then fail "$id: must not say refused; got: $(printf '%q' "$PT_ERR")"; return; fi
    if [ "$PT_REPORTS" != "0" ]; then fail "$id: must not call supervisor-report --reporter session-close (got $PT_REPORTS)"; return; fi
    if [ "$phase" = "closed" ]; then pass "$id: exit 0, no refused, no session-close report, alert closed"
    else fail "$id: alert must end closed; phase=$phase stderr=$PT_ERR"; fi
}

# A session whose alert was never armed has no supervisor state at all; closing it is not a refusal.
case_begin "never-armed-session-closes-quietly" "skills/session-close/scripts/close-alert-phase.sh"
run_p2n() {
    local sid="f2766-p2n"
    [ "$(phase_of "$sid")" = "<none>" ] || { fail "P2n: fixture: session must have no alert state"; return; }
    run_passthrough p2n "$sid"
    assert_quiet_close "P2n" "$sid"
}
run_p2n
case_end

# done -> closed is an allowed transition; the success path stays silent.
case_begin "done-alert-closes-quietly" "skills/session-close/scripts/close-alert-phase.sh"
run_p2d() {
    local sid="f2766-p2d"
    run_with_timeout 20 node -e 'process.exit(require(process.env.F2766_WRITER).writeAlertState(process.argv[1], { alert_phase: "done" }) ? 0 : 3)' "$sid" >/dev/null 2>&1 \
        || { fail "P2d: fixture: seed done failed"; return; }
    [ "$(phase_of "$sid")" = "done" ] || { fail "P2d: fixture: phase is not done"; return; }
    run_passthrough p2d "$sid"
    assert_quiet_close "P2d" "$sid"
}
run_p2d
case_end

# WSID mirror success: the notes backup names the worktree Session-ID, so both alerts close and
# the mirror's arm timestamp is cleared.
case_begin "wsid-mirror-closes-both-alerts-on-success" "skills/session-close/scripts/close-alert-phase.sh"
run_p3w() {
    local sid="f2766-p3w" wsid="f2766-p3w-worktree" backup="$_ISOLATION_TMP_ROOT/notes-p3w.md"
    local err rc p_sid p_wsid armed
    seed_paused "$sid" || { fail "P3w: fixture: seed paused failed"; return; }
    # The writer clears alert_armed_at on a paused alert, so the mirror is seeded as an armed
    # pending alert: a non-null alert_armed_at makes the "becomes null" verdict meaningful.
    run_with_timeout 20 node -e 'process.exit(require(process.env.F2766_WRITER).writeAlertState(process.argv[1], { alert_phase: "pending", alert_armed_at: new Date().toISOString() }) ? 0 : 3)' "$wsid" >/dev/null 2>&1 \
        || { fail "P3w: fixture: seed armed (wsid) failed"; return; }
    armed=$(alert_field_of "$wsid" alert_armed_at)
    case "$armed" in '"'*) ;; *) fail "P3w: fixture: mirror alert_armed_at must start non-null; got $armed"; return ;; esac
    printf '%s\n' '# Worktree notes' "Session-ID: $wsid" > "$backup"
    err=$(cd "$_ISOLATION_TMP_ROOT/cwd" && run_with_timeout 60 bash "$SCRIPT" "$sid" "$(np "$backup")" 2>&1 >/dev/null); rc=$?
    p_sid=$(phase_of "$sid"); p_wsid=$(phase_of "$wsid"); armed=$(alert_field_of "$wsid" alert_armed_at)
    if [ "$rc" -ne 0 ]; then fail "P3w: advisory script must exit 0 (rc=$rc, stderr=$err)"; return; fi
    if [ "$p_sid" != "closed" ]; then fail "P3w: closing session's alert must end closed; phase=$p_sid stderr=$err"; return; fi
    if [ "$p_wsid" != "closed" ]; then fail "P3w: WSID mirror alert must end closed; phase=$p_wsid stderr=$err"; return; fi
    if [ "$armed" = "null" ]; then pass "P3w: sid and WSID mirror both closed, mirror alert_armed_at null, exit 0"
    else fail "P3w: WSID mirror alert_armed_at must be null; got $armed"; fi
}
run_p3w
case_end

# A `node` stub first in PATH: supervisor-report calls are logged (checked first, since the
# report's --detail may name the refused writer), the alert writer call fails, the rest runs node.
case_begin "refused-alert-write-is-reported-and-still-exits-zero" "skills/session-close/scripts/close-alert-phase.sh"
run_p4() {
    local sid="f2766-p4" stub_dir="$_ISOLATION_TMP_ROOT/stub-bin" log="$_ISOLATION_TMP_ROOT/stub-report.log"
    local err rc reports phase
    seed_paused "$sid" || { fail "P4: fixture: seed paused failed"; return; }
    mkdir -p "$stub_dir"; : > "$log"
    printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in' \
        '  *bin/supervisor-report*) printf "%s\n" "$*" >> "$STUB_LOG"; exit 0 ;;' \
        '  *bin/supervisor-write-alert*) exit 1 ;;' 'esac' 'exec "$REAL_NODE" "$@"' > "$stub_dir/node"
    chmod +x "$stub_dir/node"
    err=$(cd "$_ISOLATION_TMP_ROOT/cwd" && PATH="$stub_dir:$PATH" STUB_LOG="$log" REAL_NODE="$REAL_NODE" run_with_timeout 60 bash "$SCRIPT" "$sid" 2>&1 >/dev/null); rc=$?
    phase=$(phase_of "$sid")
    reports=$(grep -c -- "--reporter session-close" "$log" 2>/dev/null); reports=${reports:-0}
    if [ "$phase" != "paused" ]; then fail "P4: fixture: the stub did not refuse the alert write (phase=$phase)"; return; fi
    if [ "$rc" -ne 0 ]; then fail "P4: advisory script must exit 0 (rc=$rc)"; return; fi
    if ! printf '%s' "$err" | grep -q "refused"; then fail "P4: stderr must name the refusal; got: $(printf '%q' "$err")"; return; fi
    if [ "$reports" = "1" ]; then pass "P4: refused alert write -> stderr 'refused', one supervisor-report --reporter session-close, exit 0"
    else fail "P4: exactly one supervisor-report call expected, got $reports: $(cat "$log")"; fi
}
run_p4
case_end

# run_refused_one <label> <sid> <refuse-pattern> [notes-backup] — the stub refuses only the node call
# whose arguments match <refuse-pattern> (logged to a refusal log, so the fixture proves it fired);
# supervisor-report calls are logged as in P4; every other call runs the real node.
# Sets RR_ERR RR_RC RR_REPORTS RR_REFUSED for the caller.
run_refused_one() {
    local label="$1" sid="$2" pattern="$3" backup="${4-}"
    local stub_dir="$_ISOLATION_TMP_ROOT/stub-$label" log="$_ISOLATION_TMP_ROOT/report-$label.log" rlog="$_ISOLATION_TMP_ROOT/refused-$label.log"
    mkdir -p "$stub_dir"; : > "$log"; : > "$rlog"
    printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in' \
        '  *bin/supervisor-report*) printf "%s\n" "$*" >> "$STUB_LOG"; exit 0 ;;' \
        "  $pattern) printf '%s\n' \"\$*\" >> \"\$STUB_REFUSED\"; exit 1 ;;" 'esac' 'exec "$REAL_NODE" "$@"' > "$stub_dir/node"
    chmod +x "$stub_dir/node"
    RR_ERR=$(cd "$_ISOLATION_TMP_ROOT/cwd" && PATH="$stub_dir:$PATH" STUB_LOG="$log" STUB_REFUSED="$rlog" REAL_NODE="$REAL_NODE" run_with_timeout 60 bash "$SCRIPT" "$sid" $backup 2>&1 >/dev/null); RR_RC=$?
    RR_REPORTS=$(grep -c -- "--reporter session-close" "$log" 2>/dev/null); RR_REPORTS=${RR_REPORTS:-0}
    RR_REFUSED=$(grep -c . "$rlog" 2>/dev/null); RR_REFUSED=${RR_REFUSED:-0}
    RR_LOG="$log"
}

# assert_refused_reported <id> <sid> — shared verdict of the P5 variants: refused once, reported once,
# exit 0, and the closing session's alert still ends closed.
assert_refused_reported() {
    local id="$1" sid="$2" phase
    phase=$(phase_of "$sid")
    if [ "$RR_REFUSED" != "1" ]; then fail "$id: fixture: the stub refused $RR_REFUSED call(s), want 1"; return; fi
    if [ "$RR_RC" -ne 0 ]; then fail "$id: advisory script must exit 0 (rc=$RR_RC)"; return; fi
    if ! printf '%s' "$RR_ERR" | grep -q "refused"; then fail "$id: stderr must name the refusal; got: $(printf '%q' "$RR_ERR")"; return; fi
    if [ "$RR_REPORTS" != "1" ]; then fail "$id: exactly one supervisor-report call expected, got $RR_REPORTS: $(cat "$RR_LOG")"; return; fi
    if [ "$phase" = "closed" ]; then pass "$id: refused call -> stderr 'refused', one supervisor-report --reporter session-close, exit 0, alert closed"
    else fail "$id: alert phase must still end closed; phase=$phase"; fi
}

case_begin "refused-audit-clear-is-reported-and-alert-still-closes" "skills/session-close/scripts/close-alert-phase.sh"
run_p5() {
    local sid="f2766-p5"
    seed_paused "$sid" || { fail "P5: fixture: seed paused failed"; return; }
    run_refused_one p5 "$sid" '*bin/supervisor-write-audit*'
    assert_refused_reported "P5" "$sid"
}
run_p5
case_end

case_begin "refused-wsid-mirror-close-is-reported-and-alert-still-closes" "skills/session-close/scripts/close-alert-phase.sh"
run_p5w() {
    local sid="f2766-p5w" wsid="f2766-p5w-worktree" backup="$_ISOLATION_TMP_ROOT/notes-p5w.md"
    seed_paused "$sid" || { fail "P5w: fixture: seed paused failed"; return; }
    seed_paused "$wsid" || { fail "P5w: fixture: seed paused (wsid) failed"; return; }
    printf '%s\n' '# Worktree notes' "Session-ID: $wsid" > "$backup"
    run_refused_one p5w "$sid" "*bin/supervisor-write-alert*--session-id\\ $wsid*" "$(np "$backup")"
    [ "$(phase_of "$wsid")" = "paused" ] || { fail "P5w: fixture: the stub did not refuse the WSID mirror (phase=$(phase_of "$wsid"))"; return; }
    assert_refused_reported "P5w" "$sid"
}
run_p5w
case_end

# run_refused_many <label> <sid> <report-exit> <pattern>... — like run_refused_one, but the stub refuses
# every node call matching any <pattern>, and supervisor-report calls are logged then exit <report-exit>.
# Sets RR_ERR RR_RC RR_REPORTS RR_REFUSED RR_LOG for the caller.
run_refused_many() {
    local label="$1" sid="$2" report_rc="$3"; shift 3
    local stub_dir="$_ISOLATION_TMP_ROOT/stub-$label" log="$_ISOLATION_TMP_ROOT/report-$label.log" rlog="$_ISOLATION_TMP_ROOT/refused-$label.log"
    local p lines=()
    for p in "$@"; do lines+=("  $p) printf '%s\n' \"\$*\" >> \"\$STUB_REFUSED\"; exit 1 ;;"); done
    mkdir -p "$stub_dir"; : > "$log"; : > "$rlog"
    printf '%s\n' '#!/usr/bin/env bash' 'case "$*" in' \
        "  *bin/supervisor-report*) printf '%s\n' \"\$*\" >> \"\$STUB_LOG\"; exit $report_rc ;;" \
        "${lines[@]}" 'esac' 'exec "$REAL_NODE" "$@"' > "$stub_dir/node"
    chmod +x "$stub_dir/node"
    RR_ERR=$(cd "$_ISOLATION_TMP_ROOT/cwd" && PATH="$stub_dir:$PATH" STUB_LOG="$log" STUB_REFUSED="$rlog" REAL_NODE="$REAL_NODE" run_with_timeout 60 bash "$SCRIPT" "$sid" 2>&1 >/dev/null); RR_RC=$?
    RR_REPORTS=$(grep -c -- "--reporter session-close" "$log" 2>/dev/null); RR_REPORTS=${RR_REPORTS:-0}
    RR_REFUSED=$(grep -c . "$rlog" 2>/dev/null); RR_REFUSED=${RR_REFUSED:-0}
    RR_LOG="$log"
}

# Two refusals in one close (alert write and audit clear): one report per refused call (2), no dedup.
case_begin "two-refusals-produce-one-report-per-refused-call" "skills/session-close/scripts/close-alert-phase.sh"
run_p6() {
    local sid="f2766-p6"
    seed_paused "$sid" || { fail "P6: fixture: seed paused failed"; return; }
    run_refused_many p6 "$sid" 0 '*bin/supervisor-write-alert*' '*bin/supervisor-write-audit*'
    if [ "$RR_REFUSED" != "2" ]; then fail "P6: fixture: the stub refused $RR_REFUSED call(s), want 2"; return; fi
    if [ "$RR_RC" -ne 0 ]; then fail "P6: advisory script must exit 0 (rc=$RR_RC)"; return; fi
    if ! printf '%s' "$RR_ERR" | grep -q "refused"; then fail "P6: stderr must name the refusal; got: $(printf '%q' "$RR_ERR")"; return; fi
    if [ "$RR_REPORTS" = "2" ]; then pass "P6: two refusals -> one supervisor-report --reporter session-close per refused call (2), exit 0"
    else fail "P6: one supervisor-report per refused call (2) expected, got $RR_REPORTS: $(cat "$RR_LOG")"; fi
}
run_p6
case_end

# The report is best effort: a failing supervisor-report must not turn the advisory script into a failure.
case_begin "failing-supervisor-report-still-exits-zero" "skills/session-close/scripts/close-alert-phase.sh"
run_p7() {
    local sid="f2766-p7"
    seed_paused "$sid" || { fail "P7: fixture: seed paused failed"; return; }
    run_refused_many p7 "$sid" 1 '*bin/supervisor-write-alert*'
    if [ "$RR_REFUSED" != "1" ]; then fail "P7: fixture: the stub refused $RR_REFUSED call(s), want 1"; return; fi
    if [ "$RR_REPORTS" != "1" ]; then fail "P7: the refusal must still attempt supervisor-report once, got $RR_REPORTS"; return; fi
    if ! printf '%s' "$RR_ERR" | grep -q "refused"; then fail "P7: stderr must name the refusal; got: $(printf '%q' "$RR_ERR")"; return; fi
    if [ "$RR_RC" -eq 0 ]; then pass "P7: supervisor-report itself failing -> script still exits 0"
    else fail "P7: advisory script must exit 0 even when supervisor-report fails (rc=$RR_RC)"; fi
}
run_p7
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
