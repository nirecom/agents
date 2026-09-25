# a-predicate.sh — A1-A15: the isStepInFlight / anyStepInFlight predicates and
# the STEP_IN_FLIGHT_ALLOWLIST policy module they read (#2013).
# Sourced by tests/feature-2013-step-in-flight-automark.sh.
# Tests: hooks/lib/step-in-flight-policy.js, hooks/workflow-state/lifecycle.js, settings.json
# Tags: step-in-flight, predicate, allowlist, regression-2013, scope:issue-specific, pwsh-not-required, TL1

# ---------------------------------------------------------------------------
# A1-A4: every allowlisted step, in_progress and inside the TTL, IS in flight.
#        One case per member rather than a single loop assertion, so a partial
#        allowlist names the missing member instead of failing anonymously.
# ---------------------------------------------------------------------------
_run_allowlist_member() {
    local id="$1" step="$2" tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    in_flight_fixture "$tmp" "$tn" "a-$step" "$step" $((TTL_MS - 60000))
    # Anchor the fixture first: if markStep never landed, a `false` below would
    # be read as "not in flight" instead of "setup failed".
    if [ "$(step_status "$tmp" "a-$step" "$step")" != "in_progress" ]; then
        fail "$id: fixture failed — $step is not in_progress on disk"
        rm -rf "$tmp" 2>/dev/null || true
        return
    fi
    assert_pred "$id" "isStepInFlight(sid, '$step') is true at TTL-1min (allowlisted)" \
        "true" "$tn" "L.isStepInFlight('a-$step', '$step')"
    rm -rf "$tmp" 2>/dev/null || true
}

run_A1() { _run_allowlist_member A1 research; }
run_A2() { _run_allowlist_member A2 detail; }
run_A3() { _run_allowlist_member A3 write_tests; }
run_A4() { _run_allowlist_member A4 review_tests; }

# ---------------------------------------------------------------------------
# A5-A7: the non-targeted verdict (CPR-ORTH). `in_progress` alone must NOT buy
#        C4 silence — the exemption is scoped by ALLOWLIST, not by status, so a
#        long `docs` or `clarify_intent` turn stays nudgeable. A7 pins
#        write_code as deliberately outside this predicate: it keeps its own
#        isWriteCodeInFlight handler (A13), and a blanket "any in_progress step"
#        implementation would fail exactly here.
# ---------------------------------------------------------------------------
_run_non_allowlist_member() {
    local id="$1" step="$2" note="$3" tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    in_flight_fixture "$tmp" "$tn" "a-$step" "$step" $((TTL_MS - 60000))
    if [ "$(step_status "$tmp" "a-$step" "$step")" != "in_progress" ]; then
        fail "$id: fixture failed — $step is not in_progress on disk"
        rm -rf "$tmp" 2>/dev/null || true
        return
    fi
    assert_pred "$id" "isStepInFlight(sid, '$step') is false even at in_progress ($note)" \
        "false" "$tn" "L.isStepInFlight('a-$step', '$step')"
    rm -rf "$tmp" 2>/dev/null || true
}

run_A5() { _run_non_allowlist_member A5 docs "not in the allowlist"; }
run_A6() { _run_non_allowlist_member A6 clarify_intent "not in the allowlist"; }
run_A7() { _run_non_allowlist_member A7 write_code "separate isWriteCodeInFlight handler"; }

# ---------------------------------------------------------------------------
# A8: TTL boundary — one minute PAST the window is no longer in flight. This is
#     the row that keeps a forgotten in_progress record from silencing C4 for
#     the rest of the session (#1979's failure mode).
# ---------------------------------------------------------------------------
run_A8() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    in_flight_fixture "$tmp" "$tn" a8 research $((TTL_MS + 60000))
    assert_pred "A8" "isStepInFlight is false once the record is TTL+1min old" \
        "false" "$tn" "L.isStepInFlight('a8', 'research')"
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# A9: fail-CLOSED on a missing timestamp. A record that cannot prove how old it
#     is must not be treated as fresh — an unbounded quiet window would disable
#     C4 silently.
# ---------------------------------------------------------------------------
run_A9() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" a9
    seed_step "$tn" a9 research in_progress
    strip_updated_at "$tmp" a9 research
    assert_pred "A9" "isStepInFlight is false when updated_at is missing (fail-CLOSED)" \
        "false" "$tn" "L.isStepInFlight('a9', 'research')"
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# A10: fail-CLOSED with no state file at all, and the predicate is TOTAL — it
#      must return false rather than throw, because every consumer calls it in
#      the suppression direction.
# ---------------------------------------------------------------------------
run_A10() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out="$(pred_eval "$tn" "(() => { try { return L.isStepInFlight('a10-absent', 'research'); } catch (e) { return 'THREW:' + e.message; } })()")"
    if [ "$out" = "false" ]; then
        pass "A10: isStepInFlight is false (not a throw) when the state file is absent"
    else
        fail "A10: expected 'false' with no state file, got '${out:-<module-load-error>}'"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# A11: anyStepInFlight names the step it found. C4's message quality depends on
#      the NAME, not on a boolean — asserting the identity keeps an
#      implementation that returns `true` from passing.
# ---------------------------------------------------------------------------
run_A11() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    in_flight_fixture "$tmp" "$tn" a11 research $((TTL_MS - 60000))
    assert_pred "A11" "anyStepInFlight returns the step name 'research'" \
        "research" "$tn" "L.anyStepInFlight('a11')"
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# A12: the counter-anchor for A11 — with only NON-allowlisted steps in_progress
#      the answer is null. Deliberately seeds two in_progress steps so a
#      "returns the first in_progress step whatever it is" implementation is
#      caught here rather than shipping a blanket exemption.
# ---------------------------------------------------------------------------
run_A12() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" a12
    seed_step "$tn" a12 docs in_progress
    seed_step "$tn" a12 user_verification in_progress
    assert_pred "A12" "anyStepInFlight is null when only non-allowlisted steps are in_progress" \
        "null" "$tn" "L.anyStepInFlight('a12')"
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# A13: isWriteCodeInFlight survives the refactor UNCHANGED. It is the sibling
#      predicate, not an alias: for the same fixture it says true while the
#      allowlist-scoped isStepInFlight says false (A7). Both halves are asserted
#      in one run so an implementation that collapses the two into one function
#      cannot satisfy them simultaneously.
# ---------------------------------------------------------------------------
run_A13() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    in_flight_fixture "$tmp" "$tn" a13 write_code $((TTL_MS - 60000))
    out="$(pred_eval "$tn" "[L.isWriteCodeInFlight('a13'), L.isStepInFlight('a13','write_code')].join('/')")"
    if [ "$out" = "true/false" ]; then
        pass "A13: isWriteCodeInFlight stays true for an in-flight write_code while isStepInFlight (allowlist-scoped) says false"
    else
        fail "A13: expected 'true/false' (writeCode/stepInFlight), got '${out:-<module-load-error>}'"
    fi
    rm -rf "$tmp" 2>/dev/null || true
}

# ---------------------------------------------------------------------------
# A14: registration. A perfectly correct hook that settings.json never invokes
#      fixes nothing, and #2013 is precisely a dispatch-path bug — so the
#      PostToolUse matcher must name all three dispatch tools, and the entry
#      must point at the auto-mark hook. The UserPromptSubmit registration for
#      the #1979 stall check is asserted in its own file.
# ---------------------------------------------------------------------------
run_A14() {
    local out
    out=$("$RWT" 20 node -e "
const s = require('$_AGENTS_DIR_NODE/settings.json');
const problems = [];
const groups = (s.hooks && s.hooks.PostToolUse) || [];
const entry = groups.find((g) => (g.hooks || []).some((h) =>
  typeof h.command === 'string' && h.command.includes('postuse-step-in-flight-mark.js')));
if (!entry) {
  problems.push('no-PostToolUse-entry-for-postuse-step-in-flight-mark.js');
} else {
  const m = String(entry.matcher || '');
  for (const tool of ['Agent', 'Task', 'Skill']) {
    if (m.split('|').indexOf(tool) === -1) problems.push('matcher-missing:' + tool);
  }
  const hook = (entry.hooks || []).find((h) => String(h.command).includes('postuse-step-in-flight-mark.js'));
  if (!String(hook.command).includes('\$AGENTS_CONFIG_DIR')) problems.push('command-not-AGENTS_CONFIG_DIR-relative');
  if (typeof hook.timeout !== 'number') problems.push('no-timeout');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "A14: settings.json registers postuse-step-in-flight-mark.js on a PostToolUse matcher naming Agent, Task and Skill"
    else
        fail "A14: PostToolUse registration wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# A15: the policy module is the SSOT (CPR-SSOT). Exactly the four steps, frozen,
#      and the TTL this suite backdates against. An allowlist that quietly grew
#      a fifth member changes C4's silence surface and must be a deliberate,
#      test-visible edit.
# ---------------------------------------------------------------------------
run_A15() {
    local out
    out=$("$RWT" 20 node -e "
const p = require('$POLICY_NODE');
const problems = [];
const want = ['research', 'detail', 'write_tests', 'review_tests'];
const got = p.STEP_IN_FLIGHT_ALLOWLIST;
if (!Array.isArray(got)) {
  problems.push('allowlist-not-an-array');
} else {
  if (got.slice().sort().join(',') !== want.slice().sort().join(',')) problems.push('allowlist=' + got.join(','));
  if (!Object.isFrozen(got)) problems.push('allowlist-not-frozen');
}
if (p.STEP_IN_FLIGHT_TTL_MS !== $TTL_MS) problems.push('ttl=' + p.STEP_IN_FLIGHT_TTL_MS);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "A15: STEP_IN_FLIGHT_ALLOWLIST is exactly {research,detail,write_tests,review_tests} (frozen) and the TTL is 4h"
    else
        fail "A15: step-in-flight-policy.js contract wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# A16: membership as a table, one row per step, MUST-be-in beside MUST-NOT-be-in.
#      A15 pins the list's exact contents; this asserts the boundary from the
#      other side, naming the steps whose exclusion is a deliberate decision
#      rather than an oversight — write_code (own predicate), user_verification
#      and run_tests (long but interactive), docs and clarify_intent.
# ---------------------------------------------------------------------------

# The rows are checked in ONE node process against the policy module directly,
# because the point here is the list itself; A1-A7 already drive the predicate
# with real fixtures for the interesting members of each side.
run_A16() {
    local step want rows="" problems=""
    while IFS='|' read -r step want; do
        step="$(trim "$step")"; want="$(trim "$want")"
        case "$step" in ''|'#'*) continue ;; esac
        rows="$rows$step:$want "
    done <<'EOF'
# step               | in the allowlist?
research             | yes
detail               | yes
write_tests          | yes
review_tests         | yes
workflow_init        | no
clarify_intent       | no
outline              | no
branching_complete   | no
write_code           | no
run_tests            | no
review_security      | no
docs                 | no
user_verification    | no
EOF
    problems=$(ROWS="$rows" "$RWT" 20 node -e "
let list;
try { list = require('$POLICY_NODE').STEP_IN_FLIGHT_ALLOWLIST; }
catch (e) { process.stdout.write('module-load-error'); process.exit(0); }
if (!Array.isArray(list)) { process.stdout.write('allowlist-not-an-array'); process.exit(0); }
const bad = [];
for (const row of process.env.ROWS.trim().split(/\s+/)) {
  const [step, want] = row.split(':');
  const got = list.includes(step);
  if (got !== (want === 'yes')) bad.push(step + '=' + got + '(want ' + (want === 'yes') + ')');
}
process.stdout.write(bad.join(' '));" 2>/dev/null)
    if [ -z "$problems" ]; then
        pass "A16: allowlist membership matches the table for all 13 steps — 4 members in, 9 deliberate non-members out"
    else
        fail "A16: allowlist membership disagrees with the table; $problems"
    fi
}
