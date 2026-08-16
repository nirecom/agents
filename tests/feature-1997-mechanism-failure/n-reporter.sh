# n-reporter.sh — M6-M11: reportMechanismFailureOnce, the side-effecting half
# that reports a mechanism failure exactly once (#1997).
# Sourced by tests/feature-1997-mechanism-failure.sh.
# Tests: hooks/lib/mechanism-failure.js, hooks/lib/protected-basenames.js, hooks/workflow-state/state-io/zombie-cleanup.js, hooks/stop-premature-stop-guard.js
# Tags: mechanism-failure, supervisor-report, stall-reported, idempotency, ordering, regression-1997, scope:issue-specific, pwsh-not-required, TL1, TL2

# ---------------------------------------------------------------------------
# M6: the first report is made AND leaves a durable record of what was reported.
#     The ledger has to carry the finding, not just exist — a bare touch-file
#     could not tell a second, DIFFERENT stall apart from a repeat of the first.
# ---------------------------------------------------------------------------
run_M6() {
    local tmp tn out problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out="$(report_once "$tn" m6 write_tests in-flight-expired)"
    case "$out" in
        true\|*) : ;;
        *) problems="$problems [first call returned '$out', expected reported=true]" ;;
    esac
    [ -f "$tmp/m6.stall-reported" ] || problems="$problems [no <sid>.stall-reported ledger was written]"
    [ "$(reported_entries "$tmp" m6)" = "1" ] ||
        problems="$problems [ledger holds '$(reported_entries "$tmp" m6)' findings, expected 1]"
    [ "$(reported_keys "$tmp" m6)" = "write_tests:in-flight-expired" ] ||
        problems="$problems [ledger key is '$(reported_keys "$tmp" m6)', expected write_tests:in-flight-expired]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "M6: the first reportMechanismFailureOnce reports and records the finding in <sid>.stall-reported"
    else
        fail "M6: first-report contract broken;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M7: idempotency, tested as A -> B -> A rather than A -> A. Repeating one
#     finding is only half the requirement: the ledger must ALSO stay open to a
#     DIFFERENT finding, because a session can stall twice for unrelated reasons
#     and the second must still reach the supervisor. A -> A alone is satisfied
#     by a reporter that suppresses everything after the first report ever; the
#     B row is what separates "once per finding" from "once per session".
#     Three calls, two distinct findings, so the ledger must end at exactly 2.
# ---------------------------------------------------------------------------
run_M7() {
    local tmp tn a1 b a2 problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"

    a1="$(report_once "$tn" m7 write_tests in-flight-expired)"
    case "$a1" in true\|*) : ;; *) problems="$problems [A(first) returned '$a1', expected reported=true]" ;; esac
    [ "$(reported_entries "$tmp" m7)" = "1" ] ||
        problems="$problems [after A the ledger holds '$(reported_entries "$tmp" m7)', expected 1]"

    b="$(report_once "$tn" m7 detail invalid-timestamp)"
    case "$b" in true\|*) : ;; *) problems="$problems [B (a different step AND kind) returned '$b', expected reported=true]" ;; esac
    [ "$(reported_entries "$tmp" m7)" = "2" ] ||
        problems="$problems [after B the ledger holds '$(reported_entries "$tmp" m7)', expected 2]"

    a2="$(report_once "$tn" m7 write_tests in-flight-expired)"
    case "$a2" in
        false\|?*) : ;;
        *) problems="$problems [A(repeat) returned '$a2', expected reported=false with a reason]" ;;
    esac
    [ "$(reported_entries "$tmp" m7)" = "2" ] ||
        problems="$problems [after the A repeat the ledger holds '$(reported_entries "$tmp" m7)', expected still 2]"
    [ "$(reported_keys "$tmp" m7)" = "detail:invalid-timestamp,write_tests:in-flight-expired" ] ||
        problems="$problems [ledger keys are '$(reported_keys "$tmp" m7)', expected both findings once each]"

    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "M7: A -> B -> A reports A once, reports B (a different finding) too, and leaves exactly 2 ledger entries"
    else
        fail "M7: idempotency is not per-finding;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M8: the ledger authorizes suppression, so a tool-issued write must not be able
#     to forge it — exactly the reasoning behind every other session marker.
#     Registered in protected-basenames.js AND swept by cleanupZombies, so a
#     ledger from a dead session cannot mute reporting for a reused sid forever.
# ---------------------------------------------------------------------------
run_M8() {
    local out tmp wf tn problems=""
    out=$("$RWT" 20 node -e "
const p = require('$BASENAMES_NODE');
const problems = [];
if (!p.SESSION_MARKER_KINDS.includes('stall-reported')) problems.push('kind-not-listed');
if (!(p.PROTECTED_MARKER_SUFFIXES || []).includes('.stall-reported')) problems.push('suffix-not-protected');
if (p.classifyProtectedPath('/tmp/whatever/s1.stall-reported') !== 'marker') problems.push('path-not-classified');
if (p.classifyProtectedBashToken('\$WF/s1.stall-reported') !== 'marker') problems.push('bash-token-not-classified');
for (const k of ['workflow-off','next-step-paused']) {
  if (!p.SESSION_MARKER_KINDS.includes(k)) problems.push('sibling-kind-lost:' + k);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    [ "$out" = "OK" ] || problems="$problems [protected-basenames: ${out:-<err>}]"

    tmp="$(make_tmp)"; wf="$tmp/wf"; mkdir -p "$wf"; tn="$(node_path "$wf")"
    : > "$wf/m8-old.stall-reported"
    : > "$wf/m8-fresh.stall-reported"
    P="$(node_path "$wf/m8-old.stall-reported")" "$RWT" 15 node -e "
const fs = require('fs');
const t = new Date(Date.now() - 30 * 24 * 60 * 60 * 1000);
fs.utimesSync(process.env.P, t, t);" >/dev/null 2>&1
    CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
require('$STATEIO_NODE').cleanupZombies();" >/dev/null 2>&1
    [ ! -f "$wf/m8-old.stall-reported" ] || problems="$problems [aged stall-reported ledger survived the zombie sweep]"
    [ -f "$wf/m8-fresh.stall-reported" ] || problems="$problems [fresh stall-reported ledger was swept away]"
    rm -rf "$tmp" 2>/dev/null || true

    if [ -z "$problems" ]; then
        pass "M8: .stall-reported is a protected session-marker basename and is reclaimed by cleanupZombies when stale"
    else
        fail "M8: stall-reported registration incomplete;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M9: never-throw. The reporter runs inside a UserPromptSubmit hook; an
#     exception there costs the user their prompt. An unwritable ledger location
#     is the realistic trigger, and the answer must be a structured
#     {reported:false, reason} — with a reason, so the failure is diagnosable
#     rather than silently indistinguishable from "already reported".
# ---------------------------------------------------------------------------
run_M9() {
    local tmp tn out problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    # The ledger path is occupied by a DIRECTORY, so every write attempt fails.
    mkdir -p "$tmp/m9.stall-reported"
    out="$(report_once "$tn" m9 research in-flight-expired)"
    case "$out" in
        THREW\|*) problems="$problems [threw instead of returning: $out]" ;;
        false\|undefined|false\|null|false\|) problems="$problems [reported=false but no reason given: '$out']" ;;
        false\|?*) : ;;
        *) problems="$problems [expected reported=false with a reason, got '${out:-<module-load-error>}']" ;;
    esac
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "M9: an unwritable ledger yields {reported:false, reason} instead of an exception"
    else
        fail "M9: never-throw contract broken;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M10: where the report actually LANDS, on both destinations. #1997 is about a
#      failure leaving no trace, so "the ledger file exists" is the weakest
#      possible reading of it: the ledger only suppresses repeats, while the
#      SUPERVISOR state file is the trace a human or a later session reads.
#      The finding must therefore carry the step, the kind, severity=error (a
#      broken mechanism is not a notice) and the `workflow` category, which is
#      what cross-session pattern detection groups on.
# ---------------------------------------------------------------------------
run_M10() {
    local tmp tn out problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    report_once "$tn" m10 write_tests in-flight-expired >/dev/null
    if [ ! -f "$(sup_state_path "$tmp" m10)" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "M10: the report left no supervisor state file — the mechanism failure has no durable trace"
        return
    fi
    out=$(P="$(node_path "$(sup_state_path "$tmp" m10)")" "$RWT" 20 node -e "
const fs = require('fs');
let st;
try { st = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('BAD:unparseable'); process.exit(0); }
const findings = (st.alert && st.alert.findings) || st.findings || [];
if (!Array.isArray(findings) || findings.length === 0) { process.stdout.write('BAD:no-findings'); process.exit(0); }
const text = JSON.stringify(findings);
const problems = [];
if (!text.includes('write_tests')) problems.push('step-not-recorded');
if (!text.includes('in-flight-expired')) problems.push('kind-not-recorded');
const f = findings.find((x) => String(x.severity) === 'error');
if (!f) problems.push('no-error-severity(' + findings.map((x) => x.severity).join(',') + ')');
const cats = findings.reduce((a, x) => a.concat(x.categories || []), []);
if (!cats.includes('workflow')) problems.push('categories=' + cats.join(','));
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    [ "$out" = "OK" ] || problems="$problems [supervisor finding: ${out:-<err>}]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "M10: the supervisor findings log carries the finding with the step, the kind, severity=error and the workflow category"
    else
        fail "M10: the report did not land in the supervisor log correctly;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M11: the real fail-fast consumer. A recorded finding nobody reads is still the
#      #1997 silence, so the C4 Stop guard — the hook that decides whether the
#      turn ends quietly — must block on a stalled mechanism and SAY SO. The
#      wording matters: `mechanism-failure` in the reason is how the user (and
#      the next session) tells this block apart from an ordinary premature-stop
#      nudge, which asks for a completely different response.
# ---------------------------------------------------------------------------
run_M11() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_in_flight "$tmp" "$tn" m11 write_tests $((TTL_MS + 60000))
    run_c4 "$tn" m11
    [ "$C4_RC" -eq 2 ] ||
        problems="$problems [C4 rc=$C4_RC, expected 2 — a stalled mechanism must not end the turn quietly]"
    printf '%s' "$C4_OUT" | grep -q 'mechanism-failure' ||
        problems="$problems [the block reason does not say 'mechanism-failure': '${C4_OUT:-<empty>}']"
    printf '%s' "$C4_OUT" | grep -q 'write_tests' ||
        problems="$problems [the block reason does not name the stalled step]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "M11: the real C4 guard blocks on a stalled mechanism and names both 'mechanism-failure' and the stalled step in its reason"
    else
        fail "M11: the fail-fast consumer does not surface the mechanism failure;$problems"
    fi
}

# ---------------------------------------------------------------------------
# M12: ORDERING between the two side effects. The ledger's job is to suppress
#      repeats, so writing it before the supervisor report succeeds converts a
#      transient supervisor failure into permanent silence for that finding —
#      the report is suppressed forever by a record of a report that never
#      happened. Report first, record second. Driven by pointing the plans dir
#      at a regular FILE so every supervisor write fails, then restoring it.
# ---------------------------------------------------------------------------
run_M12() {
    local tmp wf bad good out problems=""
    tmp="$(make_tmp)"
    wf="$tmp/wf"; good="$tmp/plans"; bad="$tmp/blocked"
    mkdir -p "$wf" "$good"
    : > "$bad"   # a FILE where a directory is required: every write under it fails

    out="$(report_once_pd "$(node_path "$wf")" "$(node_path "$bad")" m12 write_tests in-flight-expired)"
    case "$out" in
        THREW\|*) problems="$problems [threw while the supervisor destination was unwritable: $out]" ;;
        false\|?*) : ;;
        *) problems="$problems [with the supervisor unwritable the call returned '$out', expected reported=false with a reason]" ;;
    esac
    [ ! -f "$wf/m12.stall-reported" ] ||
        problems="$problems [a ledger entry was written even though the report failed — the finding is now permanently suppressed]"

    out="$(report_once_pd "$(node_path "$wf")" "$(node_path "$good")" m12 write_tests in-flight-expired)"
    case "$out" in
        true\|*) : ;;
        *) problems="$problems [after restoring the supervisor destination the retry returned '$out', expected reported=true]" ;;
    esac
    [ -f "$wf/m12.stall-reported" ] ||
        problems="$problems [the successful retry recorded no ledger entry]"
    [ "$(reported_entries "$wf" m12)" = "1" ] ||
        problems="$problems [after the retry the ledger holds '$(reported_entries "$wf" m12)', expected 1]"

    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "M12: a failed supervisor report writes NO ledger entry, and the retry after the destination is restored both reports and records"
    else
        fail "M12: report/record ordering is wrong — a transient failure becomes permanent silence;$problems"
    fi
}
