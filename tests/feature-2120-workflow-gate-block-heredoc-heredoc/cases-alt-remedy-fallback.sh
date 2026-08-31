# Tests: hooks/lib/alt-target-remedy.js, hooks/lib/workflow-plans-dir.js, hooks/lib/claude-scratchpad-base.js
# Tags: enforce-worktree, block-message, error-injection, scope:issue-specific
# M14 — error-injection for buildAltTargetRemedy()'s two resolver catch arms.
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

run_M14() {
    # M14 (C6, test-review round 3) — error-injection unit tests for
    # buildAltTargetRemedy()'s two fallback branches (hooks/lib/alt-target-remedy.js).
    # Both resolvers are wrapped in try/catch with a hardcoded fallback string;
    # neither catch arm had coverage, so a fallback that produced "undefined" would
    # ship silently. getWorkflowPlansDir() really throws on a relative
    # WORKFLOW_PLANS_DIR (real-env case); getClaudeBaseNorm() cannot be made to throw
    # through env alone, so both branches are also forced by stubbing the resolver
    # module in require.cache.
    local got
    # Real-env failure: WORKFLOW_PLANS_DIR set to a RELATIVE path makes
    # getWorkflowPlansDir() throw (hooks/lib/workflow-plans-dir.js:15).
    got="$(WORKFLOW_PLANS_DIR=relative/not/absolute run_with_timeout 30 node -e '
const {buildAltTargetRemedy}=require(process.argv[1]);
process.stdout.write(buildAltTargetRemedy());
' "$ALT_REMEDY" 2>/dev/null)"
    if [ -z "$got" ]; then fail "M14 real-env plans throw: produced no remedy string"
    else
        pass "M14 real-env plans throw: buildAltTargetRemedy still returns a remedy"
        has   "M14 real-env plans throw: falls back to the ~/.workflow-plans name" "~/.workflow-plans" "$got"
        lacks "M14 real-env plans throw: no literal 'undefined' in the wording" "undefined" "$got"
        alt_target_wording "M14 real-env plans throw" "$got"
    fi

    # Forced failure of EITHER/BOTH resolvers via require.cache stubs.
    local mode
    for mode in plans scratch both; do
        got="$(run_with_timeout 30 node -e '
const [remedy, mode] = process.argv.slice(1);
const path = require("path");
const libDir = path.dirname(remedy);
const boom = (name) => { const f = require.resolve(path.join(libDir, name)); require.cache[f] = { id: f, filename: f, loaded: true, exports: new Proxy({}, { get(){ return () => { throw new Error("injected resolver failure"); }; } }) }; };
if (mode === "plans" || mode === "both") boom("workflow-plans-dir.js");
if (mode === "scratch" || mode === "both") boom("claude-scratchpad-base.js");
process.stdout.write(require(remedy).buildAltTargetRemedy());
' "$ALT_REMEDY" "$mode" 2>/dev/null)"
        if [ -z "$got" ]; then fail "M14 forced-throw/$mode: produced no remedy string (the catch arm did not hold)"; continue; fi
        pass "M14 forced-throw/$mode: buildAltTargetRemedy still returns a remedy"
        lacks "M14 forced-throw/$mode: no literal 'undefined' in the wording" "undefined" "$got"
        lacks "M14 forced-throw/$mode: no empty target parens '()'" "()" "$got"
        alt_target_wording "M14 forced-throw/$mode" "$got"
        case "$mode" in
            (plans)   has "M14 forced-throw/plans: plans fallback name is present" "~/.workflow-plans" "$got" ;;
            (scratch) has "M14 forced-throw/scratch: scratchpad fallback name is present" "<os-tmpdir>/claude" "$got" ;;
            (both)    has "M14 forced-throw/both: plans fallback name is present" "~/.workflow-plans" "$got"
                      has "M14 forced-throw/both: scratchpad fallback name is present" "<os-tmpdir>/claude" "$got" ;;
        esac
    done
}
