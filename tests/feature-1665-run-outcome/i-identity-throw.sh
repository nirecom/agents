# shellcheck shell=bash
# tests/feature-1665-run-outcome/i-identity-throw.sh
# Tests: hooks/workflow-run-tests.js, hooks/workflow-run-tests/provenance-identity.js
# Tags: workflow, run-outcome, fail-safe, exception-path, local-catch, hook, TL2, scope:issue-specific
#
# TL2 — real hook process, with provenance-identity.js poisoned in the require cache.
#
# WHY (CPR-WPH): the fix (R2) lifts resolveTestProvenance() ABOVE the non-zero-exit
# fast path. That call is I/O-bearing — verifyEmitterIdentity() does realpath, stat
# and readFileSync on the emitter script — so it can throw where nothing threw
# before: a deleted worktree, a race with `git worktree remove`, an EACCES, a
# network path that vanished.
#
# Today the whole hook body sits inside one outer fail-open catch. If the lifted
# call throws, control jumps past BOTH writes and the non-zero exit is never
# recorded — run_tests silently stays `complete` on a run that crashed. That is a
# strictly WORSE regression than the bug being fixed, because it breaks the status
# axis that already worked.
#
# The requirement is therefore a LOCAL try/catch around the lifted call that falls
# back to contract-absent defaults (emitter null, ambiguous false, attributed false,
# contract null, vetoed false) and lets execution continue. Then:
#   status  axis -> still demoted to pending, exit code still recorded
#   outcome axis -> null: nothing was observed, so nothing may be claimed
#
# Injection method: a wrapper that require()s provenance-identity.js FIRST and
# overwrites verifyEmitterIdentity on the cached exports object, then require()s the
# hook. exec-model.js destructures that export at load time and has not been loaded
# yet, so it picks up the throwing version. This is portable — no chmod, no ACL
# games, works identically on Windows and POSIX (CPR-UNV).

_write_identity_poison() {
    cat > "$TMPD/poison-identity.js" <<'JS'
const path = require("path");
const root = process.env.F1665_AGENTS_ROOT;
const idMod = require(path.join(root, "hooks/workflow-run-tests/provenance-identity.js"));
idMod.verifyEmitterIdentity = function () {
  const err = new Error("EACCES: permission denied, open '<emitter>' (injected by i-identity-throw)");
  err.code = "EACCES";
  throw err;
};
require(path.join(root, "hooks/workflow-run-tests.js"));
JS
    printf '%s' "$(nodepath "$TMPD/poison-identity.js")"
}

run_i_identity_throw_cases() {
    echo ""
    echo "=== i-identity-throw (TL2: the lifted I/O must not swallow the demotion) ==="

    local poison
    poison="$(_write_identity_poison)"
    export F1665_AGENTS_ROOT="$AGENTS_WIN"

    # --- I0: the injection actually bites -----------------------------------
    # Without this the whole file is a tautology: a wrapper that silently failed to
    # poison anything would make every assertion below pass for the wrong reason.
    local probe_out
    probe_out="$(run_with_timeout 30 node -e '
const path = require("path");
const root = process.env.F1665_AGENTS_ROOT;
const idMod = require(path.join(root, "hooks/workflow-run-tests/provenance-identity.js"));
idMod.verifyEmitterIdentity = () => { throw new Error("boom"); };
const { resolveTestProvenance } = require(path.join(root, "hooks/workflow-run-tests/exec-model.js"));
try { resolveTestProvenance("bash " + root + "/tests/run-all.sh", root); process.stdout.write("no-throw"); }
catch (e) { process.stdout.write("threw"); }
' 2>/dev/null || echo "ERR")"
    assert_eq "I0/injection-reaches-resolveTestProvenance" "threw" "$probe_out"

    # --- I1: non-zero exit — the demotion survives the throw ----------------
    local sid="f1665-i1"
    seed_step "$sid" write_tests complete
    seed_step "$sid" run_tests complete
    drive_hook "$RUNALL_CMD" 1 "$sid" "RUN_CONTRACT: PASS=3 FAIL=2 SKIP=0 EXECUTED=5" "$poison" >/dev/null
    assert_eq "I1/status-demoted-to-pending" "pending" "$(step_field "$sid" run_tests status)"
    assert_eq "I1/last_exit_code-recorded" "1" "$(step_field "$sid" run_tests last_exit_code)"
    assert_eq "I1/last_run_failed-recorded" "true" "$(step_field "$sid" run_tests last_run_failed)"

    # The contract line is present and well-formed, but identity could not be
    # verified, so it is not attributable to a trusted emitter. Recording "fail"
    # from it would be claiming an observation the hook never actually made.
    assert_eq "I1/outcome-withheld" "(absent)" "$(step_field "$sid" run_tests run_outcome)"

    # --- I2: zero exit — the throw must not mint a completion ---------------
    # CPR-ORTH: the symmetric exit-code verdict. Falling back to contract-absent
    # means the green path cannot complete either; it takes the demotion route.
    local sid2="f1665-i2"
    seed_step "$sid2" write_tests complete
    seed_step "$sid2" run_tests complete
    drive_hook "$RUNALL_CMD" 0 "$sid2" "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$poison" >/dev/null
    assert_ne "I2/not-completed-on-unverifiable-identity" "complete" \
        "$(step_field "$sid2" run_tests status)"
    assert_eq "I2/outcome-withheld" "(absent)" "$(step_field "$sid2" run_tests run_outcome)"

    # --- I3: a stale outcome is cleared, not inherited ----------------------
    local sid3="f1665-i3"
    seed_step "$sid3" write_tests complete
    seed_step "$sid3" run_tests pending run_outcome pass
    drive_hook "$RUNALL_CMD" 1 "$sid3" "RUN_CONTRACT: PASS=5 FAIL=0 SKIP=0 EXECUTED=5" "$poison" >/dev/null
    assert_eq "I3/stale-outcome-cleared" "(absent)" "$(step_field "$sid3" run_tests run_outcome)"

    # --- I4: the hook still exits cleanly (fail-open preserved) -------------
    # A PostToolUse hook that dies takes the user's session with it. The local
    # catch must degrade, not escalate.
    local rc=0
    printf '%s' "$(hook_payload "$RUNALL_CMD" 1 "RUN_CONTRACT: PASS=1 FAIL=1 SKIP=0 EXECUTED=2" "f1665-i4" "$AGENTS_WIN")" \
        | run_with_timeout 30 node "$poison" >/dev/null 2>&1 || rc=$?
    assert_eq "I4/hook-exit-code-zero" "0" "$rc"

    unset F1665_AGENTS_ROOT
}
