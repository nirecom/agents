#!/usr/bin/env bash
# tests/fix-1273-round3-provenance-identity.sh
# Tests: hooks/workflow-run-tests/provenance-identity.js, hooks/workflow-run-tests/exec-model.js, hooks/workflow-run-tests.js
# Tags: workflow, tests, runner, hook, classifier, provenance, security, TL1, TL2, scope:common
#
# WHY (CPR-WPH): round 2 of the #1273 hardening added a filesystem identity check
# so that a file merely NAMED `tests/run-all.sh` no longer inherits the emitter's
# authority. The post-fix security review found that the identity check itself
# carries two holes — both of them places where the check answers "trusted"
# without ever having authenticated anything.
#
# Two boundaries are separated here (CPR-SC), never treated as one tangle:
#
#   NEW-H2  A path that does NOT resolve on disk is trusted outright
#           (`if (real === null) return true;`, provenance-identity.js ~L118).
#           The stated rationale — "a file that does not exist cannot have
#           executed" — is false for this hook: the hook never executes anything.
#           It reads a command STRING and a stdout STRING that the same author
#           supplied. So `echo 'RUN_CONTRACT: …'; bash /nowhere/tests/run-all.sh`
#           hands over a forged contract with full emitter authority, because the
#           unverifiable path is scored as verified.
#
#   NEW-M1  findRepoRoot() accepts ANY ancestor holding a `.git` entry as "a
#           valid repo root" (provenance-identity.js ~L67-80). It answers "is
#           there a repo here?", not "is this THIS repo?". A throwaway
#           `git init` directory with a `tests/run-all.sh` inside it therefore
#           becomes a fully authorised emitter, and the cwd it is judged against
#           is an ordinary field of the tool call.
#
# Layering: NEW-H2 / NEW-M1 are TL1 (exec-model.js required directly, real
# fixture directories on disk) plus one TL2 row each read through the real hook
# process and the real workflow-state file.
#
# RED-FIRST: every `*-must-not-be-trusted` row asserts the SAFE outcome, so it
# reports FAIL against today's code and turns green when the fix lands. That now
# includes the H2b legacy-synthetic-fixture rows: they were briefly pinned at
# today's (buggy) verdict to make the fix's collateral visible, and are now
# pinned at the post-fix verdict together with their one-layer-up counterparts
# QA-ABS / QA-ABS-TO / QA-ABS-WIN in
# tests/main-workflow-run-tests/quoted-arg-and-provenance.sh.
#
# TL3 gap (what this test does NOT catch):
#   - Whether a REAL `claude -p` Bash tool call delivers `tool_input.cwd` in the
#     spelling these fixtures assume. tests/TL3-worker-dispatch-run-tests.sh is
#     the gated tier for the real-invocation shape.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }
AGENTS_WIN="$(nodepath "$AGENTS_DIR")"
RUN_TESTS_HOOK="$AGENTS_DIR/hooks/workflow-run-tests.js"
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

if [ ! -f "$RUN_TESTS_HOOK" ] || [ ! -f "$AGENTS_DIR/hooks/workflow-run-tests/provenance-identity.js" ]; then
    fail "0/prerequisites" "hook=$RUN_TESTS_HOOK model=$EXEC_MODEL_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/rt-prov3-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

# Fixture isolation (rules/test/fixture-isolation.md): dual-pin the workflow dir
# and the plans dir, and clear the inherited live session ids so the hook can
# never resolve — and mutate — the session running this suite.
export CLAUDE_WORKFLOW_DIR="$TMPD/workflow-state"
export WORKFLOW_PLANS_DIR="$TMPD/workflow-plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

# --- drivers ---------------------------------------------------------------

# provenance <command> <cwd> → run-all | worker-dispatch | (none) | ERR
# The cwd is passed EXPLICITLY (unlike the round-2 suite's helper), because the
# repo-root walk under test starts from exactly that value.
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

# ===========================================================================
# NEW-H2 — an unresolvable path is scored as VERIFIED
#
# `realpathOrNull()` returning null means "I could not check this". The module
# converts that into `return true` — "I checked it and it is ours". Those are
# different answers, and only the second one may unlock a completion.
#
# The attack shape is a single Bash tool call whose stdout the attacker also
# authors:
#
#   echo 'RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1'; \
#     bash /tmp/forge-XXXX/tests/run-all.sh 2>/dev/null; true
#
# Nothing at that path ever ran — that is precisely why the check passes.
#
# SHAPE CHOICE (deliberate, do not "simplify"): the paths below use a
# `/tmp/forge-<pid>` root that is guaranteed NOT to exist and has no relationship
# to any checkout. They deliberately avoid the `/srv/checkout/agents/...` and
# `C:/git/checkout/agents/...` spellings that
# tests/main-workflow-run-tests/quoted-arg-and-provenance.sh already uses as
# legitimate synthetic fixtures, so a fix can be evaluated against the two
# shapes independently. See H2b below for that collision, spelled out.
# ===========================================================================
FORGE_ROOT="/tmp/forge-$$-$RANDOM"   # guaranteed absent on every platform
[ -e "$FORGE_ROOT" ] && FORGE_ROOT="/tmp/forge-$$-$RANDOM-2"

assert_eq "H2a/unresolvable-absolute-outside-any-repo-must-not-be-trusted" "(none)" \
    "$(provenance "bash $FORGE_ROOT/tests/run-all.sh" "$AGENTS_WIN")"

# CPR-ORTH: the same hole is reachable through the OTHER authorised emitter.
# A fix that patches only the run-all branch leaves the dispatcher branch open.
assert_eq "H2a/unresolvable-dispatcher-outside-any-repo-must-not-be-trusted" "(none)" \
    "$(provenance "node $FORGE_ROOT/bin/worker-dispatch.js test-runner $FORGE_ROOT $FORGE_ROOT/s.json" "$AGENTS_WIN")"

# Same hole behind a prefix runner: the identity check is reached through the
# resolved execution position, so wrapper spelling must not change the verdict.
assert_eq "H2a/unresolvable-absolute-behind-timeout-must-not-be-trusted" "(none)" \
    "$(provenance "timeout 300 bash $FORGE_ROOT/tests/run-all.sh" "$AGENTS_WIN")"

# TL2 — the same boundary read through the real hook. This is the complete
# exploit: a forged contract line plus a path that never existed marks
# run_tests complete.
SID="h2ghost-$$-$RANDOM"
seed_step "$SID" "write_tests" "complete"
drive_hook "bash $FORGE_ROOT/tests/run-all.sh" 0 "$SID" \
    "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1" "$AGENTS_WIN"
assert_eq "H2a/unresolvable-emitter-must-not-complete-run-tests" "pending" "$(run_tests_status "$SID")"

# CONTROL, opposite verdict (CPR-ORTH): the REAL emitter in the REAL repo must
# keep its authority. Without this row, "return null always" passes every H2 row.
assert_eq "H2a/control-real-run-all-still-trusted" "run-all" \
    "$(provenance "bash $AGENTS_WIN/tests/run-all.sh" "$AGENTS_WIN")"

# ===========================================================================
# H2b — the legacy synthetic fixtures, resolved
#
# tests/main-workflow-run-tests/quoted-arg-and-provenance.sh rows QA-ABS,
# QA-ABS-TO and QA-ABS-WIN drive the hook with SYNTHETIC absolute paths that do
# not exist on the running machine —
#     bash /srv/checkout/agents/tests/run-all.sh
#     bash C:/git/checkout/agents/tests/run-all.sh
# — and used to require them to COMPLETE. They were green for exactly the reason
# NEW-H2 is a vulnerability: `real === null → true`.
#
# There is no property of the STRING that separates those fixtures from the H2a
# forgery above; both are absolute, both are absent from disk, neither is inside
# any checkout. A predicate that rejects the forgery therefore MUST reject these
# too — the tension is resolved in favour of the trust boundary, and the legacy
# fixtures are reclassified as what they structurally are: unauthenticated
# emitters. QA-ABS / QA-ABS-TO / QA-ABS-WIN now expect the pending demotion, and
# these rows are their classifier-level counterpart (same assertion, one layer
# down). The two spellings stay pinned separately so a fix that closes only the
# POSIX shape is still caught.
# ===========================================================================
assert_eq "H2b/legacy-synthetic-posix-fixture-must-not-be-trusted" "(none)" \
    "$(provenance "bash /srv/checkout/agents/tests/run-all.sh" "$AGENTS_WIN")"
assert_eq "H2b/legacy-synthetic-drive-letter-fixture-must-not-be-trusted" "(none)" \
    "$(provenance "bash C:/git/checkout/agents/tests/run-all.sh" "$AGENTS_WIN")"

# ===========================================================================
# NEW-M1 — findRepoRoot() authenticates "a repo", not "this repo"
#
# The walk stops at the nearest ancestor holding a `.git` entry and hands that
# directory to the canonical-path comparison as an accepted root. Every property
# it verifies afterwards is then satisfied trivially, because the attacker owns
# the whole tree: `<throwaway>/tests/run-all.sh` really does realpath-match
# `path.join(<throwaway>, "tests/run-all.sh")`.
#
# `git init` in a temp directory is a two-second, unprivileged operation, and the
# cwd the walk starts from is an ordinary field of the tool call — so this is not
# a theoretical root. The invariant the fix must assert is repo IDENTITY
# (MODULE_REPO_ROOT, or a worktree demonstrably belonging to the same repository),
# not repo EXISTENCE.
#
# Per rules/test/fixture-isolation.md the fixture repo disables its hooks path
# immediately after `git init`.
# ===========================================================================
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
        # The file EXISTS and realpath-matches its own repo's canonical location,
        # so nothing but repo identity can distinguish it from the real emitter.
        assert_eq "M1/unrelated-throwaway-repo-run-all-must-not-be-trusted" "(none)" \
            "$(provenance "bash $THROWAWAY_WIN/tests/run-all.sh" "$THROWAWAY_WIN")"

        # CPR-ORTH: same hole via the dispatcher emitter.
        assert_eq "M1/unrelated-throwaway-repo-dispatcher-must-not-be-trusted" "(none)" \
            "$(provenance "node $THROWAWAY_WIN/bin/worker-dispatch.js test-runner $THROWAWAY_WIN $THROWAWAY_WIN/s.json" "$THROWAWAY_WIN")"

        # Relative spelling from inside the throwaway repo: non-climbing, so the
        # `../` guard never fires and only repo identity can reject it.
        assert_eq "M1/unrelated-throwaway-repo-relative-must-not-be-trusted" "(none)" \
            "$(provenance "bash tests/run-all.sh" "$THROWAWAY_WIN")"

        # TL2 — end to end through the hook: throwaway repo + hand-written
        # contract completes run_tests today.
        SID="m1throw-$$-$RANDOM"
        seed_step "$SID" "write_tests" "complete"
        drive_hook "bash $THROWAWAY_WIN/tests/run-all.sh" 0 "$SID" \
            "RUN_CONTRACT: PASS=1 FAIL=0 SKIP=0 EXECUTED=1" "$THROWAWAY_WIN"
        assert_eq "M1/unrelated-throwaway-repo-must-not-complete-run-tests" "pending" \
            "$(run_tests_status "$SID")"

        # CONTROL, opposite verdict: the real repo judged from its own cwd stays
        # trusted. A fix that pins MODULE_REPO_ROOT only must still satisfy this.
        assert_eq "M1/control-real-repo-relative-still-trusted" "run-all" \
            "$(provenance "bash tests/run-all.sh" "$AGENTS_WIN")"

        # DESIGN TENSION (comment only, no row — the fixture cannot be built
        # cheaply here): provenance-identity.js accepts the cwd's repo root
        # precisely so that a DIFFERENT legitimate checkout / linked worktree of
        # THIS repository keeps its authority. Whatever identity predicate the fix
        # chooses must still admit a linked worktree of the agents repo (where
        # `.git` is a FILE, not a directory) — the everyday case for this repo, and
        # the case an over-tight `resolved === MODULE_REPO_ROOT` check would break.
    fi
else
    echo "SKIP: git not found — M1 throwaway-repo rows not run"
fi

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
