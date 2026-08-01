#!/bin/bash
# tests/fix-1600-sanctioned-coverage-audit.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree/arg-value-guard.js
# Tags: worktree, enforce, hook, security, static, TL1, scope:issue-specific
#
# SANCTIONED coverage audit. Originally (#1600) this file audited the
# finalize-worker overlay's registry and command shapes. #1673 retires that
# overlay: the three finalize scripts are no longer invoked as a Bash-tool `eval`
# from the main worktree — they run as child processes of bin/worker-dispatch.js,
# behind worker-dispatch-overlay.js + the registry capability layer. What is left
# to audit is therefore the LEGACY SANCTIONED list itself:
#
#   (a) SANCTIONED holds exactly the 7 remaining entries — the 3 subprocess-only
#       scripts (bin/issue-close-gate.sh, bin/github-issues/issue-close-stage-triage.sh,
#       bin/github-issues/parent-body-update.sh) are gone, and nothing else was
#       dropped along with them.
#   (b) those 3 have no remaining Bash-TOOL call site: no prompt-facing `.md`
#       under skills/ or docs/ tells Claude to run them. They stay reachable only
#       as children of run-stage-chain.sh / run-initial.sh, which the guard never
#       sees. This is the invariant that makes removal safe (Risks 7).
#   (c) finalize-worker-overlay.js no longer exists — the shared helpers moved to
#       hooks/enforce-worktree/arg-value-guard.js and the match function retired
#       with the eval path it guarded.
#
# TL1 (static): the subject is a literal array in one source file plus a grep
# over prompt text. Guard BEHAVIOR for the surviving SANCTIONED entries is
# covered by tests/fix-959-enforce-worktree-worker-path-arg.sh, and for the
# dispatch path by tests/feature-1643-worker-dispatch-guard.sh.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
WORKER_SCRIPT_JS="${AGENTS_DIR}/hooks/enforce-worktree/main-worktree-allows/worker-script.js"
OVERLAY_JS="${AGENTS_DIR}/hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js"
ARG_VALUE_GUARD_JS="${AGENTS_DIR}/hooks/enforce-worktree/arg-value-guard.js"

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

if [ ! -f "$WORKER_SCRIPT_JS" ]; then
    echo "FAIL: precondition missing — worker-script.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

# The 3 entries #1673 removes. Subprocess-only: their sole callers are
# run-stage-chain.sh and run-initial.sh, both of which the dispatcher spawns.
REMOVED_ENTRIES='bin/issue-close-gate.sh
bin/github-issues/issue-close-stage-triage.sh
bin/github-issues/parent-body-update.sh'

# The 7 entries that MUST survive, each because a prompt-facing step runs it
# through the Bash tool from the main worktree:
#   check-unstaged-tracked.sh   /commit-push CP-1, /worktree-end WE-3
#   probe-remote-bootstrap.sh   /commit-push bootstrap probe
#   issue-create-dispatch.sh    /issue-create survey dispatch
#   run-bulk-dispatch.sh        /issue-create bulk phase
#   run-phase5-record.sh        /issue-create phase 5
#   pre-flight.sh               /issue-close-finalize pre-flight gate (main context)
#   run-quality-gates.sh        /review-code-security quality gates
KEPT_ENTRIES='bin/check-unstaged-tracked.sh
bin/probe-remote-bootstrap.sh
bin/github-issues/issue-create-dispatch.sh
skills/issue-create/scripts/run-bulk-dispatch.sh
skills/issue-create/scripts/run-phase5-record.sh
skills/issue-close-finalize/scripts/pre-flight.sh
skills/review-code-security/scripts/run-quality-gates.sh'

# ============================================================================
# (a) SANCTIONED is exactly the 7 kept entries.
#
# Read by parsing the literal array out of the source: worker-script.js is not
# require-able in isolation without its whole hook dependency tree, and the array
# is the thing under audit — a mocked stand-in would audit the mock.
# ============================================================================

extract_sanctioned() {
    run_with_timeout 30 node -e '
        const fs = require("fs");
        const src = fs.readFileSync(process.argv[1], "utf8");
        const m = src.match(/const\s+SANCTIONED\s*=\s*\[([\s\S]*?)\]\s*;/);
        if (!m) { console.log("PARSE_FAIL"); process.exit(0); }
        const out = [];
        const re = /"([^"]+)"/g;
        let x;
        while ((x = re.exec(m[1])) !== null) out.push(x[1]);
        process.stdout.write(out.join("\n"));
    ' "$(nodepath "$WORKER_SCRIPT_JS")" 2>&1
}

test_sanctioned_exact_set() {
    local actual expected count
    actual="$(extract_sanctioned)"
    if [ "$actual" = "PARSE_FAIL" ] || [ -z "$actual" ]; then
        fail "a1: could not extract the SANCTIONED array from worker-script.js" "$actual"
        return
    fi
    count="$(printf '%s\n' "$actual" | grep -c .)"
    if [ "$count" -eq 7 ]; then
        pass "a1: SANCTIONED holds exactly 7 entries"
    else
        fail "a1: SANCTIONED holds $count entries, expected 7 (RED until #1673 commit 5)" \
            "$(printf '%s' "$actual" | tr '\n' ' ')"
    fi

    expected="$(printf '%s\n' "$KEPT_ENTRIES" | sort)"
    actual="$(printf '%s\n' "$actual" | sort)"
    if [ "$actual" = "$expected" ]; then
        pass "a2: SANCTIONED set matches the 7 documented Bash-tool call sites exactly"
    else
        fail "a2: SANCTIONED set drift (RED until #1673 commit 5)" \
            "got: $(printf '%s' "$actual" | tr '\n' ' ')"
    fi
}

# Symmetric negative: each removed entry must be gone from worker-script.js.
test_removed_entries_absent_from_source() {
    local errs="" rel
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        if grep -qF "\"$rel\"" "$WORKER_SCRIPT_JS"; then
            errs="$errs $rel"
        fi
    done <<< "$REMOVED_ENTRIES"
    if [ -z "$errs" ]; then
        pass "a3: none of the 3 retired scripts is still listed in SANCTIONED"
    else
        fail "a3: retired script(s) still in SANCTIONED (RED until #1673 commit 5)" "$errs"
    fi
}

# ============================================================================
# (b) No prompt-facing Bash-tool call site remains for the 3 removed entries.
#
# Removing a SANCTIONED entry that a SKILL.md still tells Claude to run would
# false-block a legitimate main-worktree operation. `.sh` / `.js` references are
# expected and fine — those are subprocess call sites the PreToolUse hook never
# inspects (it sees the command HEAD only).
# ============================================================================

test_no_bash_tool_call_sites() {
    local errs="" rel hits
    while IFS= read -r rel; do
        [ -z "$rel" ] && continue
        # Invocation shape only: `bash "<...>/<rel>"` or `bash <...>/<rel>` inside
        # a prompt file. A prose mention in docs/history/*.md is a record of past
        # work, not an instruction, and must not trip the audit.
        hits="$(grep -rlnE "bash[[:space:]]+\"?[^\"[:space:]]*${rel//\//\\/}" \
            --include='*.md' "$AGENTS_DIR/skills" "$AGENTS_DIR/docs" 2>/dev/null)"
        if [ -n "$hits" ]; then
            errs="$errs $rel->$(printf '%s' "$hits" | tr '\n' ',')"
        fi
    done <<< "$REMOVED_ENTRIES"
    if [ -z "$errs" ]; then
        pass "b1: no skills/ or docs/ .md invokes any of the 3 retired scripts via the Bash tool"
    else
        fail "b1: Bash-tool call site(s) survive for a retired SANCTIONED entry" "$errs"
    fi
}

# Mutation probe: prove b1's detector can fire at all. A synthetic prompt file
# carrying the invocation shape must be matched by the same expression.
test_bash_tool_detector_probe() {
    local tmpd probe
    tmpd="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/fix1600audit-$$")"
    mkdir -p "$tmpd"
    probe="$tmpd/synthetic-skill.md"
    printf '%s\n' 'XX-1. Run `bash "$AGENTS_CONFIG_DIR/bin/issue-close-gate.sh" "$OWNER_REPO" "$N"`.' > "$probe"
    if grep -rqE 'bash[[:space:]]+"?[^"[:space:]]*bin\/issue-close-gate\.sh' --include='*.md' "$tmpd" 2>/dev/null; then
        pass "b2: the b1 detector fires on a synthetic prompt-file call site (mutation probe)"
    else
        fail "b2: the b1 detector does not fire — b1's green is meaningless"
    fi
    rm -rf "$tmpd"
}

# ============================================================================
# (c) finalize-worker-overlay.js is retired; arg-value-guard.js owns the shared
#     helpers it used to export.
# ============================================================================

test_overlay_file_absent() {
    if [ ! -e "$OVERLAY_JS" ]; then
        pass "c1: finalize-worker-overlay.js no longer exists"
    else
        fail "c1: finalize-worker-overlay.js still on disk (RED until #1673 commit 5)"
    fi
}

test_worker_script_does_not_require_overlay() {
    if grep -qF "finalize-worker-overlay" "$WORKER_SCRIPT_JS"; then
        fail "c2: worker-script.js still references finalize-worker-overlay (RED until #1673 commit 5)"
    else
        pass "c2: worker-script.js has no finalize-worker-overlay require or (a0) branch"
    fi
}

test_arg_value_guard_exports_shared_helpers() {
    if [ ! -f "$ARG_VALUE_GUARD_JS" ]; then
        fail "c3: hooks/enforce-worktree/arg-value-guard.js missing (RED until #1673 commit 1)"
        return
    fi
    local result
    result="$(run_with_timeout 30 node -e '
        let mod;
        try { mod = require(process.argv[1]); }
        catch (e) { console.log("REQUIRE_FAIL: " + String(e.message).split("\n")[0]); process.exit(0); }
        const missing = [];
        for (const fn of ["stripRelSuffix","isUnderPlansDir","hasControlChar","isSimpleArgValue"]) {
            if (typeof mod[fn] !== "function") missing.push(fn);
        }
        for (const re of ["UNSAFE_ARG_VALUE_RE","ID_VALUE_RE","REPO_SLUG_VALUE_RE"]) {
            if (!(mod[re] instanceof RegExp)) missing.push(re);
        }
        console.log(missing.length ? "MISSING: " + missing.join(",") : "ok");
    ' "$(nodepath "$ARG_VALUE_GUARD_JS")" 2>&1)"
    if [ "$result" = "ok" ]; then
        pass "c3: arg-value-guard.js exports all 7 shared helpers moved off the overlay"
    else
        fail "c3: arg-value-guard.js export set incomplete" "$result"
    fi
}

# ============================================================================
# Run all
# ============================================================================

run_all() {
    test_sanctioned_exact_set
    test_removed_entries_absent_from_source
    test_no_bash_tool_call_sites
    test_bash_tool_detector_probe
    test_overlay_file_absent
    test_worker_script_does_not_require_overlay
    test_arg_value_guard_exports_shared_helpers
}

if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX1600AUDIT_TEST_INNER:-}" ]; then
        _FIX1600AUDIT_TEST_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
