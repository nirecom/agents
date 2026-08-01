#!/usr/bin/env bash
# tests/feature-1673-commit-push-gate.sh
# Tests: bin/worker-dispatch/workers/commit-push.js, bin/worker-dispatch.js, bin/worker-dispatch/spawn.js, hooks/workflow-gate.js
# Tags: worker-dispatch, commit-push, workflow-gate, merge-gate, fail-closed, TL2, scope:issue-specific
#
# Issue #1673 D1 — this file is the acceptance point for the whole decision.
#
# Moving `git commit` / `git push` from the Bash tool into a dispatcher child
# takes them out of PreToolUse, so hooks/workflow-gate.js stops firing. Two
# guards are lost with it: the commit-completion gate (run_tests / review_security
# / docs / user_verification) and the MERGE GATE, which hard-blocks a push to a
# protected branch until user_verification completes. `hooks/pre-commit` replaces
# neither. D1 reproduces both by driving the real gate binary twice — once before
# the commit, once before the push — with a synthetic PreToolUse payload on stdin.
#
# What is asserted:
#   (a) a blocking verdict before the commit leaves no commit call behind
#   (b) an approving verdict lets the commit through
#   (c) a blocking verdict before the push leaves no push call behind, AFTER the
#       commit already happened — the case the caller must be told about
#   (d) the gate's `tool_input.command` is byte-identical to the argv the worker
#       is about to spawn, and never the bare `git push` form the classifier
#       cannot decide on
#   (e) an abnormal gate exit still refuses a push to a protected branch
#
# The process boundary is canned through tests/feature-1673-commit-push-lib/
# gate-spawn-stub.js, which — unlike the #1643 stub — records `opts.input`. The
# gate contract lives entirely in those stdin bytes, so a stub that dropped them
# could not distinguish a correct payload from an empty one.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - Whether the REAL hooks/workflow-gate.js parses this synthetic payload and
#     returns the verdict expected here; only a real gate process can answer.
#     Covered by tests/TL3-worker-dispatch-commit-push.sh (RUN_TL3).
#   - Real `git push` reaching a real remote, and the retry/rebase ladder.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_CP1673_GATE_INNER:-}" ]; then
    _CP1673_GATE_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
SPAWN_JS="$AGENTS_DIR/bin/worker-dispatch/spawn.js"
PRELOAD="$AGENTS_DIR/tests/feature-1673-commit-push-lib/gate-spawn-stub.js"

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
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$SPAWN_JS" ] || [ ! -f "$PRELOAD" ]; then
    fail "0/prerequisite" "dispatcher=$DISPATCH_JS spawn=$SPAWN_JS stub=$PRELOAD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/cp1673-gate-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main >/dev/null 2>&1
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/1673-probe "$LINKED_RAW" >/dev/null 2>&1
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
CWD="$(nodepath "$LINKED_RAW")"
PLANS="$(nodepath "$PLANS_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"
SID="cp1673-gate-session"

DOUT=""; DRC=0
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }

# dispatch <canned-json> <payload-path>
dispatch() {
    printf '%s' "$1" > "$CANNED"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 120 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$SPAWN_JS")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" \
        commit-push "$MAIN" "$2" 2>/dev/null)" || DRC=$?
}
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}

# ---------------------------------------------------------------------------
# Call-log queries (node, so quoting in argv never reaches a shell)
# ---------------------------------------------------------------------------
LOGQ="$TMPD/logq.js"
cat > "$LOGQ" <<'LOGJS'
"use strict";
const fs = require("fs");
const [, , logFile, query] = process.argv;
let calls = [];
try {
  calls = fs.readFileSync(logFile, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
} catch (_e) { calls = []; }
const isGit = (c, verb) => c.command === "git" && (c.args || []).includes(verb);
const gitLine = (c) => ["git"].concat(c.args || []).join(" ");
const gateCalls = calls.filter((c) => c.script === "workflowGate");
const out = (s) => process.stdout.write(String(s));

switch (query) {
  case "count-commit": out(calls.filter((c) => isGit(c, "commit")).length); break;
  case "count-push": out(calls.filter((c) => isGit(c, "push")).length); break;
  case "count-gate": out(gateCalls.length); break;
  // Bare `git push` (no remote, no refspec) is prohibited: merge-detect.js
  // decides on explicit refspecs, so the bare form can slip past the classifier.
  case "bare-push": out(calls.filter((c) => c.command === "git" &&
    (c.args || []).length === 1 && (c.args || [])[0] === "push").length); break;
  case "gate-force-push": out(calls.filter((c) => c.command === "git" &&
    (c.args || []).some((a) => a === "--force" || a === "-f" ||
      String(a).startsWith("--force-with-lease"))).length); break;
  // Each gate call's declared command must equal the argv of the NEXT git call.
  case "gate-command-matches-argv": {
    const mismatches = [];
    for (const g of gateCalls) {
      let payload = null;
      try { payload = JSON.parse(g.input || ""); } catch (_e) { mismatches.push("UNPARSABLE_STDIN"); continue; }
      const declared = payload && payload.tool_input && payload.tool_input.command;
      const idx = calls.indexOf(g);
      const next = calls.slice(idx + 1).find((c) => c.command === "git" &&
        ((c.args || []).includes("commit") || (c.args || []).includes("push")));
      if (!next) continue; // gate blocked; nothing followed. Counted elsewhere.
      if (declared !== gitLine(next)) mismatches.push(String(declared) + " != " + gitLine(next));
    }
    out(mismatches.join(" ; "));
    break;
  }
  case "gate-stdin-shape": {
    const bad = [];
    gateCalls.forEach((g, i) => {
      let p = null;
      try { p = JSON.parse(g.input || ""); } catch (_e) { bad.push("call" + i + ":unparsable"); return; }
      if (p.tool_name !== "Bash") bad.push("call" + i + ":tool_name=" + p.tool_name);
      if (!p.tool_input || typeof p.tool_input.command !== "string") bad.push("call" + i + ":no-command");
      if (!p.tool_input || typeof p.tool_input.cwd !== "string") bad.push("call" + i + ":no-cwd");
      if (typeof p.session_id !== "string" || p.session_id === "") bad.push("call" + i + ":no-session_id");
    });
    out(bad.join(" ; "));
    break;
  }
  case "gate-session-id": {
    if (!gateCalls.length) { out("(no-gate-call)"); break; }
    let p = null;
    try { p = JSON.parse(gateCalls[0].input || ""); } catch (_e) { out("(unparsable)"); break; }
    out(String(p && p.session_id));
    break;
  }
  case "push-argv": {
    const c = calls.find((x) => x.command === "git" && (x.args || []).includes("push"));
    out(c ? gitLine(c) : "(no-push)");
    break;
  }
  default: out("(unknown-query)");
}
LOGJS
q() { node "$(nodepath "$LOGQ")" "$(nodepath "$CALLLOG")" "$1"; }

# ---------------------------------------------------------------------------
# Canned rule fragments. enforce_worktree=off keeps the run inside
# git+workflow-gate: step 8 skips the PR path entirely, so `gh` never appears
# and the assertions stay on the D1 seam.
# ---------------------------------------------------------------------------
STAGED='{"match":"diff","stdout":" README.md | 1 +\n 1 file changed"}'
UNSTAGED_CLEAN='{"match":"unstagedCheck","status":0}'
BOOTSTRAP_OK='{"match":"bootstrapProbe","stdout":"{\"preBootstrap\":false,\"classification\":\"normal\"}"}'
GIT_OK='{"match":"git","status":0,"stdout":""}'
CATCHALL='{"status":0,"stdout":""}'
# Step 0 branch verification (`git rev-parse --abbrev-ref HEAD`) must answer with
# the SAME branch the scenario's payload declares, or the worker stops at
# `branch_mismatch` before any of the behaviour under test runs. GIT_OK is a
# catch-all returning empty stdout, so these must precede it in every rule array,
# and each is paired with its own payload: HEAD_FEATURE with PAY_FEATURE,
# HEAD_MAIN with PAY_MAIN.
HEAD_FEATURE='{"match":"rev-parse --abbrev-ref HEAD","status":0,"stdout":"feature/1673-probe\n"}'
HEAD_MAIN='{"match":"rev-parse --abbrev-ref HEAD","status":0,"stdout":"main\n"}'
GATE_BLOCK_JSON='{\"decision\":\"block\",\"reason\":\"workflow-gate: run_tests is \\\"pending\\\"\"}'
GATE_ALLOW_JSON='{\"decision\":\"approve\"}'

PAY_FEATURE="$(write_payload cp-feature "{\"commit_message\":\"feat(#1673): probe\",\"branch\":\"feature/1673-probe\",\"worktree_path\":\"$CWD\",\"session_id\":\"$SID\",\"enforce_worktree\":\"off\",\"artifact_dir\":\"$PLANS\"}")"
PAY_MAIN="$(write_payload cp-main "{\"commit_message\":\"feat(#1673): probe\",\"branch\":\"main\",\"worktree_path\":\"$MAIN\",\"session_id\":\"$SID\",\"enforce_worktree\":\"off\",\"artifact_dir\":\"$PLANS\"}")"

# ===========================================================================
# (a) commit gate blocks → no commit call is ever made
# ===========================================================================
group_commit_block() {
    dispatch "[{\"match\":\"workflowGate\",\"stdout\":\"$GATE_BLOCK_JSON\"},$STAGED,$UNSTAGED_CLEAN,$BOOTSTRAP_OK,$HEAD_FEATURE,$GIT_OK,$CATCHALL]" "$PAY_FEATURE"
    assert_eq "commit-block/exit0" "0" "$DRC"
    assert_eq "commit-block/status" "gate_blocked" "$(field_of status)"
    assert_eq "commit-block/no-commit-spawned" "0" "$(q count-commit)"
    assert_eq "commit-block/no-push-spawned" "0" "$(q count-push)"
    assert_eq "commit-block/gate-called-once" "1" "$(q count-gate)"
    # The caller has to be able to tell WHY; the gate's reason must survive.
    case "$(field_of summary)" in
        *run_tests*) pass "commit-block/summary-carries-gate-reason" ;;
        *) fail "commit-block/summary-carries-gate-reason" "summary=$(field_of summary)" ;;
    esac
}

# ===========================================================================
# (b) both gates approve → commit AND push are spawned
# ===========================================================================
group_allow() {
    dispatch "[{\"match\":\"workflowGate\",\"stdout\":\"$GATE_ALLOW_JSON\"},$STAGED,$UNSTAGED_CLEAN,$BOOTSTRAP_OK,$HEAD_FEATURE,$GIT_OK,$CATCHALL]" "$PAY_FEATURE"
    assert_eq "allow/exit0" "0" "$DRC"
    assert_eq "allow/status" "pushed" "$(field_of status)"
    assert_eq "allow/commit-spawned-once" "1" "$(q count-commit)"
    assert_eq "allow/push-spawned-once" "1" "$(q count-push)"
    # D1-a and D1-b: the gate runs twice, not once.
    assert_eq "allow/gate-called-twice" "2" "$(q count-gate)"
}

# ===========================================================================
# (c) push gate blocks after an approved commit
# ===========================================================================
group_push_block() {
    dispatch "[{\"match\":\"workflowGate\",\"nth\":1,\"stdout\":\"$GATE_ALLOW_JSON\"},{\"match\":\"workflowGate\",\"nth\":2,\"stdout\":\"$GATE_BLOCK_JSON\"},$STAGED,$UNSTAGED_CLEAN,$BOOTSTRAP_OK,$HEAD_FEATURE,$GIT_OK,$CATCHALL]" "$PAY_FEATURE"
    assert_eq "push-block/exit0" "0" "$DRC"
    assert_eq "push-block/status" "gate_blocked" "$(field_of status)"
    assert_eq "push-block/commit-happened" "1" "$(q count-commit)"
    assert_eq "push-block/no-push-spawned" "0" "$(q count-push)"
    # Step 6: the commit is already in the tree — the caller must be told, or the
    # user is left believing nothing happened.
    case "$(field_of summary)" in
        *commit*|*Commit*) pass "push-block/summary-mentions-the-commit" ;;
        *) fail "push-block/summary-mentions-the-commit" "summary=$(field_of summary)" ;;
    esac
}

# ===========================================================================
# (d) the gate is asked about the command that is actually about to run
# ===========================================================================
group_command_fidelity() {
    dispatch "[{\"match\":\"workflowGate\",\"stdout\":\"$GATE_ALLOW_JSON\"},$STAGED,$UNSTAGED_CLEAN,$BOOTSTRAP_OK,$HEAD_FEATURE,$GIT_OK,$CATCHALL]" "$PAY_FEATURE"
    # Anchor first: the shape/fidelity assertions below are over the gate calls,
    # and every one of them is vacuously satisfied by an empty call log.
    assert_eq "fidelity/gate-called-twice" "2" "$(q count-gate)"
    assert_eq "fidelity/stdin-is-pretooluse-shaped" "" "$(q gate-stdin-shape)"
    assert_eq "fidelity/session-id-propagated" "$SID" "$(q gate-session-id)"
    assert_eq "fidelity/command-equals-next-argv" "" "$(q gate-command-matches-argv)"
    # codex C3: bare `git push` is prohibited — always the explicit form.
    assert_eq "fidelity/no-bare-push" "0" "$(q bare-push)"
    assert_eq "fidelity/no-force-push" "0" "$(q gate-force-push)"
    case "$(q push-argv)" in
        "git push"*"origin feature/1673-probe") pass "fidelity/push-names-remote-and-branch" ;;
        *) fail "fidelity/push-names-remote-and-branch" "argv=$(q push-argv)" ;;
    esac
}

# ===========================================================================
# (e) fail-closed: an abnormal gate exit before the push, on a protected branch
#
# The dangerous shape is a gate child that dies and a worker that reads "no
# block in stdout" as permission. D1 degrades to merge-detect.js: a protected
# target is refused rather than pushed.
# ===========================================================================
group_fail_closed() {
    local rules
    rules="[{\"match\":\"workflowGate\",\"nth\":1,\"stdout\":\"$GATE_ALLOW_JSON\"},{\"match\":\"workflowGate\",\"nth\":2,\"spawnError\":\"ENOENT\",\"status\":null},$STAGED,$UNSTAGED_CLEAN,$BOOTSTRAP_OK,$HEAD_MAIN,$GIT_OK,$CATCHALL]"
    dispatch "$rules" "$PAY_MAIN"
    assert_eq "fail-closed/exit0" "0" "$DRC"
    assert_eq "fail-closed/status" "gate_blocked" "$(field_of status)"
    assert_eq "fail-closed/no-push-to-protected" "0" "$(q count-push)"

    # Same degradation, but the gate returns bytes that are not JSON at all.
    rules="[{\"match\":\"workflowGate\",\"nth\":1,\"stdout\":\"$GATE_ALLOW_JSON\"},{\"match\":\"workflowGate\",\"nth\":2,\"stdout\":\"<html>proxy error</html>\"},$STAGED,$UNSTAGED_CLEAN,$BOOTSTRAP_OK,$HEAD_MAIN,$GIT_OK,$CATCHALL]"
    dispatch "$rules" "$PAY_MAIN"
    assert_eq "fail-closed/unparsable-verdict-status" "gate_blocked" "$(field_of status)"
    assert_eq "fail-closed/unparsable-verdict-no-push" "0" "$(q count-push)"

    # Non-vacuity: the same degradation on a NON-protected branch must still stop
    # (D1 forbids silently continuing), but the commit must have gone through —
    # proving the run reached the push stage rather than dying earlier.
    rules="[{\"match\":\"workflowGate\",\"nth\":1,\"stdout\":\"$GATE_ALLOW_JSON\"},{\"match\":\"workflowGate\",\"nth\":2,\"spawnError\":\"ENOENT\",\"status\":null},$STAGED,$UNSTAGED_CLEAN,$BOOTSTRAP_OK,$HEAD_FEATURE,$GIT_OK,$CATCHALL]"
    dispatch "$rules" "$PAY_FEATURE"
    assert_eq "fail-closed/feature-branch-status" "gate_blocked" "$(field_of status)"
    assert_eq "fail-closed/feature-branch-commit-happened" "1" "$(q count-commit)"
    assert_eq "fail-closed/feature-branch-no-push" "0" "$(q count-push)"
}

group_commit_block
group_allow
group_push_block
group_command_fidelity
group_fail_closed

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
