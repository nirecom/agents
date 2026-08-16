# c-scope.sh — C1-C10: the v2 marker shape, for_step scoping, expiry, the real
# sentinel handler, the real next-step consumer, and the audit trail (#1624).
# Sourced by tests/feature-1624-next-step-pause-scope.sh.
# Tests: hooks/lib/next-step-pause-marker.js, hooks/workflow-mark/enforce-override-handlers/next-step-pause.js, bin/workflow/lib/next-step/verdict.js
# Tags: next-step-pause, marker-v2, for-step, ttl, audit, regression-1624, scope:issue-specific, pwsh-not-required, TL1, TL2

# ---------------------------------------------------------------------------
# C1: the v2 shape. Each field is one of the three missing properties from
#     #1624, so all three are asserted together: version+for_step (scope),
#     expires_at at the 4h TTL (expiry), audit (who paused, when, and why).
#     The TTL window is asserted as an ABSOLUTE +/-60s band rather than a
#     percentage: a percentage band scales with the TTL, so a module that
#     widened its own TTL would keep passing while the tolerance grew with it.
# ---------------------------------------------------------------------------
run_C1() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_pause "$tn" c1 "[for=write_tests] waiting on the test subagent"
    out=$(P="$(node_path "$(marker_path "$tmp" c1)")" "$RWT" 20 node -e "
const fs = require('fs');
let m;
try { m = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('BAD:marker-unreadable(' + e.message + ')'); process.exit(0); }
const problems = [];
if (m.version !== 2) problems.push('version=' + m.version);
if (m.for_step !== 'write_tests') problems.push('for_step=' + m.for_step);
if (typeof m.expires_at !== 'string') problems.push('expires_at-missing');
else {
  const dt = Date.parse(m.expires_at) - Date.now();
  if (Number.isNaN(dt)) problems.push('expires_at-unparseable');
  else if (Math.abs(dt - $PAUSE_TTL_MS) > 60000) problems.push('ttl-off-by-ms=' + (dt - $PAUSE_TTL_MS));
}
if (!m.audit || typeof m.audit !== 'object' || Object.keys(m.audit).length === 0) problems.push('audit-missing');
if (typeof m.reason !== 'string' || m.reason.length === 0) problems.push('reason-not-retained');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "C1: writePauseMarker emits a v2 marker carrying for_step, an expires_at within 60s of the 4h TTL, an audit record and the reason"
    else
        fail "C1: v2 marker shape wrong; got '${out:-<err>}'"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# C2/C3: the bug and its fix, as a pair on ONE marker. Scoped to write_tests, the
#        pause holds at write_tests (C2) and must NOT leak into review_tests
#        (C3) — the cross-step leak is exactly what #1624 reports.
# ---------------------------------------------------------------------------
run_C2() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_pause "$tn" c2 "[for=write_tests] waiting on the test subagent"
    assert_active C2 "a pause scoped to write_tests is active AT write_tests" true "$tn" c2 write_tests
    rm -rf "$tmp" 2>/dev/null || true
}

run_C3() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_pause "$tn" c3 "[for=write_tests] waiting on the test subagent"
    assert_active C3 "the same pause is NOT active at review_tests (no cross-step leak)" false "$tn" c3 review_tests
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# C4: the escape hatch stays available. A session-wide pause is still expressible
#     and must hold at every step, so scoping narrows the DEFAULT rather than
#     removing the capability.
# ---------------------------------------------------------------------------
run_C4() {
    local tmp tn step problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_pause "$tn" c4 "[for=any] out-of-workflow maintenance for the whole session"
    for step in research write_tests review_tests docs; do
        [ "$(pause_active "$tn" c4 "$step")" = "true/true" ] ||
            problems="$problems [not active at $step: $(pause_active "$tn" c4 "$step")]"
    done
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C4: for_step=any is active at every step (the session-wide pause survives the scoping change)"
    else
        fail "C4: session-wide pause broken;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C5: backward compatibility for the CALLER. Existing prompts emit a bare reason
#     with no [for=...] tag; those must keep meaning "the whole session", so the
#     change is additive and no documented usage silently narrows.
# ---------------------------------------------------------------------------
run_C5() {
    local tmp tn for_step problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_pause "$tn" c5 "waiting on a monitored subagent dispatch"
    for_step=$(P="$(node_path "$(marker_path "$tmp" c5)")" "$RWT" 15 node -e "
const fs = require('fs');
try { process.stdout.write(String(JSON.parse(fs.readFileSync(process.env.P, 'utf8')).for_step)); }
catch (e) { process.stdout.write('<unreadable>'); }" 2>/dev/null)
    [ "$for_step" = "any" ] || problems="$problems [for_step='$for_step', expected 'any' for an untagged reason]"
    [ "$(pause_active "$tn" c5 review_tests)" = "true/true" ] ||
        problems="$problems [an untagged pause is not active at review_tests]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C5: a reason without [for=...] defaults to for_step=any (untagged callers keep session-wide behaviour)"
    else
        fail "C5: untagged-reason default wrong;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C6: expiry. A pause whose expires_at has passed is over — this is the property
#     that ends the "forgot to resume, silent forever" failure mode.
# ---------------------------------------------------------------------------
run_C6() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_pause "$tn" c6 "[for=any] long maintenance"
    expire_marker "$tmp" c6 60000
    assert_active C6 "a marker whose expires_at has passed is no longer active" false "$tn" c6 research
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# C7: fail-CLOSED on a v1 legacy marker. Left over from a pre-v2 session, it has
#     no expires_at and no scope, so it cannot prove it is still live — and the
#     direction of the doubt matters: honouring it would resurrect the unbounded
#     silence, ignoring it merely makes next-step speak again.
# ---------------------------------------------------------------------------
run_C7() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    printf '{"reason":"legacy v1 pause","set_at":"%s"}' "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
        > "$(marker_path "$tmp" c7)"
    assert_active C7 "a v1 legacy marker (no expires_at) is treated as inactive" false "$tn" c7 research
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# C8 (TL2): the real sentinel handler writes v2. If the handler still wrote v1,
#           every C1-C7 property would hold in the library and none of them would
#           ever be reached in production.
# ---------------------------------------------------------------------------
run_C8() {
    local tmp tn out v problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(CMD='echo "<<WORKFLOW_NEXT_STEP_PAUSE: [for=research] waiting on a survey subagent>>"' "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Bash', session_id: 'c8', transcript_path: '',
  tool_input: { command: process.env.CMD } }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
          "$RWT" 20 node "$(node_path "$MARK_HOOK")" 2>/dev/null)
    [ -f "$(marker_path "$tmp" c8)" ] || problems="$problems [handler wrote no marker]"
    if [ -f "$(marker_path "$tmp" c8)" ]; then
        v=$(P="$(node_path "$(marker_path "$tmp" c8)")" "$RWT" 15 node -e "
const fs = require('fs');
try { const m = JSON.parse(fs.readFileSync(process.env.P, 'utf8'));
  process.stdout.write(String(m.version) + ':' + String(m.for_step) + ':' + (typeof m.expires_at)); }
catch (e) { process.stdout.write('<unreadable>'); }" 2>/dev/null)
        [ "$v" = "2:research:string" ] ||
            problems="$problems [marker is '$v', expected '2:research:string']"
    fi
    [ -f "$(marker_path "$tmp" c8).tmp" ] && problems="$problems [write-then-rename left a .tmp behind]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C8: the real NEXT_STEP_PAUSE sentinel handler writes a v2, step-scoped, expiring marker"
    else
        fail "C8: sentinel handler still writes the old marker;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C8-audit: the same real sentinel handler as C8, but checking the audit
#     object C10 only pins for the library-level write_pause() helper. Without
#     this row, the handler could satisfy C8's version/for_step/expires_at
#     checks while still writing an audit object with the wrong session_id or
#     a stale/non-ISO8601 set_at, and nothing at the handler level would catch it.
# ---------------------------------------------------------------------------
run_C8_audit() {
    local tmp tn out problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    CMD='echo "<<WORKFLOW_NEXT_STEP_PAUSE: [for=research] waiting on a survey subagent>>"' "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Bash', session_id: 'c8audit', transcript_path: '',
  tool_input: { command: process.env.CMD } }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
          "$RWT" 20 node "$(node_path "$MARK_HOOK")" >/dev/null 2>&1
    out=$(P="$(node_path "$(marker_path "$tmp" c8audit)")" "$RWT" 20 node -e "
const fs = require('fs');
let m;
try { m = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('BAD:marker-unreadable'); process.exit(0); }
const a = m.audit;
const problems = [];
if (!a || typeof a !== 'object') { process.stdout.write('BAD:audit-missing'); process.exit(0); }
if (typeof a.sentinel !== 'string' || !a.sentinel.includes('NEXT_STEP_PAUSE')) problems.push('sentinel=' + a.sentinel);
if (a.session_id !== 'c8audit') problems.push('session_id=' + a.session_id);
if (typeof a.set_at !== 'string' || Number.isNaN(Date.parse(a.set_at))) problems.push('set_at=' + a.set_at);
if (a.for_step !== 'research') problems.push('for_step=' + a.for_step);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    [ "$out" = "OK" ] || problems="$problems [handler-written audit object: ${out:-<err>}]"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C8-audit: the real sentinel handler's marker carries a correct audit object (sentinel, session_id, set_at, for_step)"
    else
        fail "C8-audit: handler-written audit object wrong;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C8-resume: the RESUME half of the real handler. A pause with no TTL escape
#     hatch other than an explicit resume must actually remove the marker —
#     and doing it twice (marker already gone the second time) must stay a
#     clean no-op: no error, no stray .tmp file from a half-finished rename.
# ---------------------------------------------------------------------------
run_C8_resume() {
    local tmp tn rc1 rc2 problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    CMD='echo "<<WORKFLOW_NEXT_STEP_PAUSE: [for=research] waiting on a survey subagent>>"' "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Bash', session_id: 'c8resume', transcript_path: '',
  tool_input: { command: process.env.CMD } }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
          "$RWT" 20 node "$(node_path "$MARK_HOOK")" >/dev/null 2>&1
    [ -f "$(marker_path "$tmp" c8resume)" ] || problems="$problems [setup: pause marker never appeared]"

    CMD='echo "<<WORKFLOW_NEXT_STEP_RESUME: done>>"' "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Bash', session_id: 'c8resume', transcript_path: '',
  tool_input: { command: process.env.CMD } }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
          "$RWT" 20 node "$(node_path "$MARK_HOOK")" >/dev/null 2>&1
    rc1=$?
    [ "$rc1" -eq 0 ] || problems="$problems [1st RESUME: handler exited $rc1]"
    [ ! -f "$(marker_path "$tmp" c8resume)" ] || problems="$problems [1st RESUME: marker still present]"
    [ ! -f "$(marker_path "$tmp" c8resume).tmp" ] || problems="$problems [1st RESUME: stray .tmp left behind]"

    CMD='echo "<<WORKFLOW_NEXT_STEP_RESUME: done-again>>"' "$RWT" 15 node -e "
process.stdout.write(JSON.stringify({ tool_name: 'Bash', session_id: 'c8resume', transcript_path: '',
  tool_input: { command: process.env.CMD } }));" \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" \
          "$RWT" 20 node "$(node_path "$MARK_HOOK")" >/dev/null 2>&1
    rc2=$?
    [ "$rc2" -eq 0 ] || problems="$problems [2nd RESUME (already-gone marker): handler exited $rc2]"
    [ ! -f "$(marker_path "$tmp" c8resume)" ] || problems="$problems [2nd RESUME: marker reappeared]"
    [ ! -f "$(marker_path "$tmp" c8resume).tmp" ] || problems="$problems [2nd RESUME: stray .tmp left behind]"

    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C8-resume: RESUME removes the marker and repeating it is a clean no-op (no error, no stray .tmp)"
    else
        fail "C8-resume: resume path broken;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C9 (TL2): the real consumer honours the scope. Session current step is
#           `research`; a pause scoped to write_tests must leave next-step
#           recommending research, while a pause scoped to research quiets it.
#           Both halves in one case so "always paused" and "never paused" each
#           fail.
# ---------------------------------------------------------------------------
run_C9() {
    local tmp tn problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" c9

    write_pause "$tn" c9 "[for=write_tests] waiting on the test subagent"
    # Anchor: without a marker on disk, "next-step is not paused" is vacuous —
    # it would hold for a writer that produced nothing at all.
    [ -f "$(marker_path "$tmp" c9)" ] ||
        problems="$problems [no marker on disk — the ACTION=invoke below proves nothing]"
    run_next_step "$tn" c9
    echo "$NS_OUT" | grep -q '^ACTION=invoke$' ||
        problems="$problems [a write_tests-scoped pause quieted next-step at research: $(echo "$NS_OUT" | tr '\n' ' ')]"

    write_pause "$tn" c9 "[for=research] waiting on a survey subagent"
    run_next_step "$tn" c9
    echo "$NS_OUT" | grep -q '^ACTION=paused$' ||
        problems="$problems [a research-scoped pause did NOT quiet next-step at research: $(echo "$NS_OUT" | tr '\n' ' ')]"
    echo "$NS_OUT" | grep -q "^REASON='next-step-paused'$" ||
        problems="$problems [paused without the next-step-paused reason]"

    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C9: next-step pauses only when the marker's for_step matches the session's current step"
    else
        fail "C9: next-step ignores the pause scope;$problems"
    fi
}

# ---------------------------------------------------------------------------
# C10: the audit trail, field by field. #1624's third missing property was "no
#      record of who paused, when, and why", and a pause that silences the
#      workflow guards is precisely the kind of act that must be reconstructable
#      afterwards. Two destinations are asserted, because they answer different
#      questions: the MARKER answers "what is suppressing me right now", and the
#      SUPERVISOR findings log answers "what happened in this session" — a
#      marker-only audit is deleted by the resume and leaves no history at all.
# ---------------------------------------------------------------------------
run_C10() {
    local tmp tn out sup problems=""
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" c10
    write_pause "$tn" c10 "[for=research] waiting on a survey subagent"

    out=$(P="$(node_path "$(marker_path "$tmp" c10)")" "$RWT" 20 node -e "
const fs = require('fs');
let m;
try { m = JSON.parse(fs.readFileSync(process.env.P, 'utf8')); } catch (e) { process.stdout.write('BAD:marker-unreadable'); process.exit(0); }
const a = m.audit;
const problems = [];
if (!a || typeof a !== 'object') { process.stdout.write('BAD:audit-missing'); process.exit(0); }
if (typeof a.sentinel !== 'string' || !a.sentinel.includes('NEXT_STEP_PAUSE')) problems.push('sentinel=' + a.sentinel);
if (a.session_id !== 'c10') problems.push('session_id=' + a.session_id);
if (typeof a.set_at !== 'string' || Number.isNaN(Date.parse(a.set_at))) problems.push('set_at=' + a.set_at);
else if (a.set_at !== new Date(a.set_at).toISOString()) problems.push('set_at-not-ISO8601=' + a.set_at);
if (a.for_step !== 'research') problems.push('for_step=' + a.for_step);
if (typeof a.reason !== 'string' || a.reason.length === 0) problems.push('reason=' + a.reason);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    [ "$out" = "OK" ] || problems="$problems [marker audit object: ${out:-<err>}]"

    sup="$(sup_findings_text "$tmp" c10)"
    case "$sup" in
        '<absent>') problems="$problems [no supervisor state file — the pause left no session history]" ;;
        *NEXT_STEP_PAUSE*|*next-step-paused*) : ;;
        *) problems="$problems [supervisor state carries no next-step-paused audit entry]" ;;
    esac

    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "C10: the pause records a full audit object (sentinel, session_id, ISO8601 set_at, for_step, reason) in the marker AND an entry in the supervisor findings log"
    else
        fail "C10: audit trail incomplete;$problems"
    fi
}
