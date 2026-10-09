#!/usr/bin/env bash
# tests/hooks/fix-1273-round3-provenance-identity.sh
# Tests: hooks/workflow-run-tests/provenance-identity.js, hooks/workflow-run-tests/exec-model.js, hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, classifier, provenance, security, TL1, TL2, scope:common
#
# The emitter identity check must not answer "trusted" without authenticating (#1273 round 3):
# NEW-H2 an unresolvable path, NEW-M1 an unrelated repo. Contract: the header of provenance-identity.js.
# TL3 gap: the spelling of a real `claude -p` tool_input.cwd (tests/bin/TL3-worker-dispatch-run-tests.sh);
# mitigated at WORKFLOW_USER_VERIFIED preflight, bin/check-verification-gate.sh category hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$SCRIPT_CHECKOUT_ROOT")"
RUN_TESTS_HOOK="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-run-tests.js"
EXEC_MODEL_JS="$AGENTS_WIN/hooks/workflow-run-tests/exec-model.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$RUN_TESTS_HOOK" ] || [ ! -f "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-run-tests/provenance-identity.js" ]; then
    fail "0/prerequisites" "hook=$RUN_TESTS_HOOK model=$EXEC_MODEL_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rt-prov3-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixture isolation: rules/test/fixture-isolation.md (dual pin, no inherited session id).
export WORKFLOW_STATE_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_CODE_SESSION_ID

# provenance <command> <cwd> → run-all | worker-dispatch | (none) | ERR (the cwd starts the repo-root walk).
provenance() {
    run_with_timeout 30 node -e '
try {
  const m = require(process.argv[1]);
  if (typeof m.resolveTestProvenance !== "function") { process.stdout.write("ERR"); process.exit(0); }
  const r = m.resolveTestProvenance(process.argv[2], process.argv[3]);
  process.stdout.write(r === null ? "(none)" : String(r.emitter));
} catch (e) { process.stdout.write("ERR"); }
' "$EXEC_MODEL_JS" "$1" "$2" 2>/dev/null
}

# seed_step <sid> <step> <status>
seed_step() {
    run_with_timeout 30 node -e "
      require('$AGENTS_WIN/hooks/workflow-state').markStep(process.argv[1], process.argv[2], process.argv[3]);
    " "$1" "$2" "$3" >/dev/null 2>&1 || true
}

# drive_hook <command> <exit_code> <sid> <stdout_content> <cwd>
drive_hook() {
    local json
    json=$(run_with_timeout 30 node -e "
const payload = {
  tool_name: 'Bash',
  tool_input: { command: process.argv[1], cwd: process.argv[5] },
  tool_response: { exit_code: parseInt(process.argv[2], 10), stdout: process.argv[3] },
  session_id: process.argv[4]
};
process.stdout.write(JSON.stringify(payload));
" "$1" "$2" "$4" "$3" "$5" 2>/dev/null)
    printf '%s' "$json" | run_with_timeout 30 node "$RUN_TESTS_HOOK" >/dev/null 2>&1 || true
}

# run_tests_status <sid> → complete | pending | absent
run_tests_status() {
    run_with_timeout 30 node -e "
try {
  const s = require('$AGENTS_WIN/hooks/workflow-state').readState(process.argv[1]);
  console.log(s && s.steps && s.steps.run_tests ? s.steps.run_tests.status : 'absent');
} catch (e) { console.log('absent'); }
" "$1" 2>/dev/null || echo "absent"
}

# NEW-H2 — an unresolvable path must not be scored as verified. The root below is absent on
# every platform and shares no spelling with the legacy synthetic fixtures of H2b.
FORGE_ROOT="/tmp/forge-$$-$RANDOM"
[ -e "$FORGE_ROOT" ] && FORGE_ROOT="/tmp/forge-$$-$RANDOM-2"

assert_eq "H2a/unresolvable-absolute-outside-any-repo-must-not-be-trusted" "(none)" \
    "$(provenance "bash $FORGE_ROOT/tests/run-all.sh" "$AGENTS_WIN")"

# CPR-ORTH: the same hole through the other authorised emitter.
assert_eq "H2a/unresolvable-dispatcher-outside-any-repo-must-not-be-trusted" "(none)" \
    "$(provenance "node $FORGE_ROOT/bin/worker-dispatch.js test-runner $FORGE_ROOT $FORGE_ROOT/s.json" "$AGENTS_WIN")"

# A prefix runner must not change the verdict.
assert_eq "H2a/unresolvable-absolute-behind-timeout-must-not-be-trusted" "(none)" \
    "$(provenance "timeout 300 bash $FORGE_ROOT/tests/run-all.sh" "$AGENTS_WIN")"

# TL2 — the complete exploit through the real hook: forged contract line + a path that never existed.
SID="h2ghost-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "bash $FORGE_ROOT/tests/run-all.sh" 0 "$SID" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1" "$AGENTS_WIN"
assert_eq "H2a/unresolvable-emitter-must-not-complete-run-tests" "pending" "$(run_tests_status "$SID")"

# CONTROL, opposite verdict: without it "return null always" passes every H2 row.
assert_eq "H2a/control-real-run-all-still-trusted" "run-all" \
    "$(provenance "bash $AGENTS_WIN/tests/run-all.sh" "$AGENTS_WIN")"

# H2b — the legacy synthetic absolute paths are unauthenticated emitters too; the classifier-level
# counterpart of QA-ABS* in tests/hooks/main-workflow-run-tests/quoted-arg-and-provenance.sh.
assert_eq "H2b/legacy-synthetic-posix-fixture-must-not-be-trusted" "(none)" \
    "$(provenance "bash /srv/checkout/agents/tests/run-all.sh" "$AGENTS_WIN")"
assert_eq "H2b/legacy-synthetic-drive-letter-fixture-must-not-be-trusted" "(none)" \
    "$(provenance "bash C:/git/checkout/agents/tests/run-all.sh" "$AGENTS_WIN")"

# NEW-M1 — the root must be THIS repository (SCRIPT_CHECKOUT_ROOT or a worktree of the same
# repository), not any directory holding a `.git` entry.
if command -v git >/dev/null 2>&1; then
    THROWAWAY="$TMPD/throwaway-repo"
    mkdir -p "$THROWAWAY/tests" "$THROWAWAY/bin"
    git -C "$THROWAWAY" init -q >/dev/null 2>&1 || git init -q "$THROWAWAY" >/dev/null 2>&1
    git -C "$THROWAWAY" config core.hooksPath /dev/null >/dev/null 2>&1 || true
    printf '#!/usr/bin/env bash\necho "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1"\n' \
        > "$THROWAWAY/tests/run-all.sh"
    printf 'process.stdout.write("RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1\\n");\n' \
        > "$THROWAWAY/bin/worker-dispatch.js"
    THROWAWAY_WIN="$(nodepath "$THROWAWAY")"

    if [ ! -e "$THROWAWAY/.git" ]; then
        fail "M1/fixture-git-init" "no .git created at $THROWAWAY"
    else
        # The file exists and matches its own repo's canonical location: only repo identity rejects it.
        assert_eq "M1/unrelated-throwaway-repo-run-all-must-not-be-trusted" "(none)" \
            "$(provenance "bash $THROWAWAY_WIN/tests/run-all.sh" "$THROWAWAY_WIN")"

        # CPR-ORTH: same hole via the dispatcher emitter.
        assert_eq "M1/unrelated-throwaway-repo-dispatcher-must-not-be-trusted" "(none)" \
            "$(provenance "node $THROWAWAY_WIN/bin/worker-dispatch.js test-runner $THROWAWAY_WIN $THROWAWAY_WIN/s.json" "$THROWAWAY_WIN")"

        # Relative and non-climbing, so the `../` guard never fires.
        assert_eq "M1/unrelated-throwaway-repo-relative-must-not-be-trusted" "(none)" \
            "$(provenance "bash tests/run-all.sh" "$THROWAWAY_WIN")"

        # TL2 — end to end through the hook.
        SID="m1throw-$$-$RANDOM"
        seed_step "$SID" "write_tests" "complete"
        drive_hook "bash $THROWAWAY_WIN/tests/run-all.sh" 0 "$SID" \
            "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1" "$THROWAWAY_WIN"
        assert_eq "M1/unrelated-throwaway-repo-must-not-complete-run-tests" "pending" \
            "$(run_tests_status "$SID")"

        # CONTROL, opposite verdict: a fix that pins SCRIPT_CHECKOUT_ROOT only must still satisfy this.
        assert_eq "M1/control-real-repo-relative-still-trusted" "run-all" \
            "$(provenance "bash tests/run-all.sh" "$AGENTS_WIN")"

        # No row for a linked worktree (`.git` is a file): an over-tight
        # `resolved === SCRIPT_CHECKOUT_ROOT` check would break that everyday case.
    fi
else
    echo "SKIP: git not found — M1 throwaway-repo rows not run"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
