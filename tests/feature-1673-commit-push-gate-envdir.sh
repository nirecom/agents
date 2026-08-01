#!/usr/bin/env bash
# tests/feature-1673-commit-push-gate-envdir.sh
# Tests: hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch/spawn.js, hooks/workflow-gate.js, hooks/workflow-state/state-io/core.js, bin/worker-dispatch/workers/commit-push.js
# Tags: worker-dispatch, commit-push, workflow-gate, env-propagation, state-dir, fail-quiet, TL2, scope:issue-specific
#
# Issue #1673 Risk 3 — the quiet failure.
#
# getWorkflowDir() reads exactly one variable, CLAUDE_WORKFLOW_DIR, and falls
# back to <HOME>/.claude/projects/workflow. spawn.js's buildEnv hands a child
# only CHILD_ENV_ALLOWLIST plus the entry's envPassthrough, and CLAUDE_WORKFLOW_DIR
# is in neither by default. A worker that forgets it does not crash: the gate
# child looks in the wrong directory, finds no state for the session, and answers
# whatever an absent state implies. That verdict is then reported as if the gate
# had been consulted.
#
# So the propagation is pinned from both ends:
#   Group 1 — the declaration exists, and buildEnv actually carries the variable
#             into the child env (with the negative: an undeclared name is
#             refused, so the declaration is what makes it possible).
#   Group 2 — the REAL gate binary changes its verdict based on the directory it
#             is pointed at. The negative case runs the identical payload with
#             the variable stripped and asserts the verdict differs — if it did
#             not, this whole file would be measuring nothing.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - The commit-push worker actually assembling the value (the worker module is
#     scanned here, not run against a real session state directory).
#     tests/TL3-worker-dispatch-commit-push.sh covers the real seam.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_CP1673_ENVDIR_INNER:-}" ]; then
    _CP1673_ENVDIR_INNER=1 timeout 240 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REGISTRY_JS="$AGENTS_DIR/hooks/lib/worker-dispatch-registry.js"
SPAWN_JS="$AGENTS_DIR/bin/worker-dispatch/spawn.js"
ANCHOR_JS="$AGENTS_DIR/bin/worker-dispatch/anchor.js"
GATE_JS="$AGENTS_DIR/hooks/workflow-gate.js"
WORKER_JS="$AGENTS_DIR/bin/worker-dispatch/workers/commit-push.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_ne() {
    local name="$1" unwanted="$2" got="$3"
    if [ "$unwanted" != "$got" ]; then pass "$name"
    else fail "$name" "value must differ from $(printf '%q' "$unwanted")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

for f in "$REGISTRY_JS" "$SPAWN_JS" "$ANCHOR_JS" "$GATE_JS"; do
    if [ ! -f "$f" ]; then
        fail "0/prerequisite" "missing $f"
        echo ""
        echo "Total: PASS=$PASS FAIL=$FAIL"
        exit 1
    fi
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/cp1673-envdir-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

REPO_RAW="$TMPD/repo"
mkdir -p "$REPO_RAW"
git -C "$REPO_RAW" init -q -b main >/dev/null 2>&1
git -C "$REPO_RAW" config user.email "test@example.com"
git -C "$REPO_RAW" config user.name "Test"
git -C "$REPO_RAW" config core.hooksPath /dev/null
echo init > "$REPO_RAW/README.md"
git -C "$REPO_RAW" add README.md >/dev/null 2>&1
git -C "$REPO_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
STATE_RAW="$TMPD/wfstate"; mkdir -p "$STATE_RAW"

REPO="$(nodepath "$REPO_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
STATE_DIR="$(nodepath "$STATE_RAW")"
# Random-ish and never used elsewhere: the default state directory must not
# happen to contain a file for it, or Group 2's negative case is meaningless.
SID="cp1673-envdir-$$-probe"

# ===========================================================================
# Group 1 — the declaration, and buildEnv carrying it through
# ===========================================================================
group_declaration() {
    local out
    out="$(run_with_timeout 60 env "WORKFLOW_PLANS_DIR=$PLANS" node -e '
      const reg = require(process.argv[1]);
      const spawn = require(process.argv[2]);
      const anchorMod = require(process.argv[3]);
      const p = (k, v) => process.stdout.write(k + "=" + String(v) + "\n");
      const entry = (reg.workers || {})["commit-push"];
      // Report the absence on EVERY key: "no var missing from the child env" is
      // trivially true when there is no entry to build an env from.
      if (!entry) {
        for (const k of ["entry","build","missing_in_child","undeclared_refused"]) p(k, "ENTRY_MISSING");
        process.exit(0);
      }
      p("entry", "present");
      const anchors = anchorMod.resolveAnchors(process.argv[4]);
      if (anchors.error) { p("anchors", anchors.error); process.exit(0); }
      const D1 = {
        CLAUDE_WORKFLOW_DIR: process.argv[5],
        WORKFLOW_PLANS_DIR: process.argv[6],
        WORKFLOW_SESSION_ID: "sid-probe",
        CLAUDE_PROJECT_DIR: process.argv[4],
        DEFAULT_BRANCHES: "main,master",
      };
      let env = null;
      try { env = spawn.buildEnv(entry, anchors, D1); }
      catch (e) { p("build", "THREW:" + e.message); process.exit(0); }
      p("build", "ok");
      p("missing_in_child", Object.keys(D1).filter((k) => env[k] !== D1[k]).sort().join(","));
      // Negative control: buildEnv must REFUSE a name the entry never declared,
      // which is precisely why the declaration is load-bearing.
      let refused = 0;
      try { spawn.buildEnv(entry, anchors, { NOT_DECLARED_BY_ANY_WORKER: "x" }); }
      catch (_e) { refused = 1; }
      p("undeclared_refused", refused);
    ' "$(nodepath "$REGISTRY_JS")" "$(nodepath "$SPAWN_JS")" "$(nodepath "$ANCHOR_JS")" \
      "$REPO" "$STATE_DIR" "$PLANS" 2>&1)" || out="entry=PROBE_CRASHED"
    ev() { printf '%s\n' "$out" | sed -n "s/^$1=//p" | head -1; }

    assert_eq "declaration/entry-present" "present" "$(ev entry)"
    assert_eq "declaration/buildenv-accepts-d1-vars" "ok" "$(ev build)"
    assert_eq "declaration/all-d1-vars-reach-child-env" "" "$(ev missing_in_child)"
    assert_eq "declaration/undeclared-name-refused" "1" "$(ev undeclared_refused)"
}

# ===========================================================================
# Group 2 — the real gate reads the directory it is pointed at
#
# `git push origin main` hits the MERGE GATE, which runs unconditionally and
# reads user_verification straight out of the session state file. That makes it
# the shortest path from "which directory did the child look in" to an
# observable verdict.
# ===========================================================================
# gate_decision <scenario> <user_verification-status> <propagate:1|0>
#   → prints approve | block | (unknown)
#
# Each scenario gets its own state AND plans directory. A gate block writes a
# supervisor finding, and a later run in the same directories is then blocked by
# the pre-merge warning flush instead of by the step status under test — an
# order dependency that would silently invert the meaning of these rows.
gate_decision() {
    local scenario="$1" status="$2" propagate="$3" out rc=0 payload
    local sdir="$TMPD/sc-$scenario/state" pdir="$TMPD/sc-$scenario/plans"
    mkdir -p "$sdir" "$pdir"
    node -e '
      const fs = require("fs");
      const [, file, status] = process.argv;
      fs.writeFileSync(file, JSON.stringify({
        steps: {
          workflow_init: { status: "complete" },
          run_tests: { status: "complete" },
          review_security: { status: "complete" },
          docs: { status: "complete" },
          user_verification: { status: status },
        },
      }, null, 2));
    ' "$sdir/$SID.json" "$status"
    payload="$(node -e '
      const [, cwd, sid] = process.argv;
      process.stdout.write(JSON.stringify({
        tool_name: "Bash",
        tool_input: { command: "git push origin main", cwd: cwd },
        session_id: sid,
      }));
    ' "$REPO" "$SID")"
    if [ "$propagate" = "1" ]; then
        out="$(printf '%s' "$payload" | run_with_timeout 60 env \
            "CLAUDE_WORKFLOW_DIR=$(nodepath "$sdir")" "WORKFLOW_PLANS_DIR=$(nodepath "$pdir")" \
            "DEFAULT_BRANCHES=main,master" \
            node "$(nodepath "$GATE_JS")" 2>/dev/null)" || rc=$?
    else
        out="$(printf '%s' "$payload" | run_with_timeout 60 env -u CLAUDE_WORKFLOW_DIR \
            "WORKFLOW_PLANS_DIR=$(nodepath "$pdir")" "DEFAULT_BRANCHES=main,master" \
            node "$(nodepath "$GATE_JS")" 2>/dev/null)" || rc=$?
    fi
    case "$out" in
        *'"block"'*) printf 'block' ;;
        *'"approve"'*) printf 'approve' ;;
        *) printf '(unknown:rc=%s)' "$rc" ;;
    esac
}

group_real_gate() {
    # Positive: the state this test wrote is the state the gate acted on.
    assert_eq "real-gate/pending-blocks-when-propagated" "block" "$(gate_decision pending pending 1)"
    assert_eq "real-gate/complete-approves-when-propagated" "approve" "$(gate_decision complete complete 1)"

    # Negative: identical bytes on stdin, identical state file on disk, only the
    # variable removed. A verdict equal to the propagated one would mean the gate
    # never consulted CLAUDE_WORKFLOW_DIR and this file proves nothing.
    assert_ne "real-gate/verdict-depends-on-the-variable" "approve" "$(gate_decision unpropagated complete 0)"
}

# ===========================================================================
# Group 3 — the worker resolves the value instead of relying on inheritance
# ===========================================================================
group_worker_source() {
    if [ ! -f "$WORKER_JS" ]; then
        fail "worker/sets-claude-workflow-dir" "implementation missing: bin/worker-dispatch/workers/commit-push.js"
        fail "worker/computes-default-state-dir" "implementation missing: bin/worker-dispatch/workers/commit-push.js"
        return
    fi
    if grep -qF 'CLAUDE_WORKFLOW_DIR' "$WORKER_JS"; then
        pass "worker/sets-claude-workflow-dir"
    else
        fail "worker/sets-claude-workflow-dir" "the worker never names CLAUDE_WORKFLOW_DIR"
    fi
    # envPassthrough also permits inheritance; the plan requires the worker to
    # compute the documented default when the parent env has nothing.
    if grep -qE 'projects.{1,4}workflow' "$WORKER_JS"; then
        pass "worker/computes-default-state-dir"
    else
        fail "worker/computes-default-state-dir" \
            "no <HOME>/.claude/projects/workflow fallback found — inheritance-only resolution"
    fi
}

group_declaration
group_real_gate
group_worker_source

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
