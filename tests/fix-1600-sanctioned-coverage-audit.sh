#!/bin/bash
# tests/fix-1600-sanctioned-coverage-audit.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js
# Tags: worktree, enforce, hook, security, scope:issue-specific
#
# Issue #1600 coverage audit: verifies the finalize-worker overlay (a) accepts the
# 3 live command shapes with no gaps, (b) does not over-accept a non-registry
# sibling script, (c) has a well-formed FINALIZE_OVERLAY_REGISTRY / G5_DECISION_VALUES,
# (d) enforces interpreter binding, and (e) still defers to write-scope governance.
# The registry-integrity assertions inspect the REAL finalize-worker-overlay.js in
# the repo (not the fake ACD) — they fail-with-require-error until the module exists.
#
# TL3 gap: same as fix-1600-finalize-worker-overlay.sh — a full /issue-close-finalize
# chain from a real main worktree is only exercised at TL3 (RUN_TL3).

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
OVERLAY_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js"
WORKER_SCRIPT_JS="${AGENTS_DIR}/hooks/enforce-worktree/main-worktree-allows/worker-script.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'fix1600audit-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

if [ ! -f "$GUARD_JS" ]; then
    echo "FAIL: precondition missing — hooks/enforce-worktree.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_bash_payload() {
    local cmd="$1"
    local q; q="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$q"
}

GUARD_OUT=""
GUARD_RC=0
run_guard() {
    local payload="$1"; shift
    local main_wt="$1"; shift
    GUARD_RC=0
    GUARD_OUT="$(printf '%s' "$payload" | run_with_timeout 30 \
        env -u CLAUDE_ENV_FILE \
        -C "$main_wt" \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
    if [ "$GUARD_RC" -ne 0 ]; then
        return 2
    fi
    if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
        return 1
    fi
    return 0
}

if ! env -C "$TMPDIR_BASE" true 2>/dev/null; then
    run_guard() {
        local payload="$1"; shift
        local main_wt="$1"; shift
        GUARD_RC=0
        GUARD_OUT="$(cd "$main_wt" && printf '%s' "$payload" | run_with_timeout 30 \
            env -u CLAUDE_ENV_FILE \
            "ENFORCE_WORKTREE=on" \
            "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$main_wt" \
            "$@" \
            node "$GUARD_JS" 2>&1)" || GUARD_RC=$?
        if [ "$GUARD_RC" -ne 0 ]; then
            return 2
        fi
        if echo "$GUARD_OUT" | grep -q '"decision":"block"'; then
            return 1
        fi
        return 0
    }
fi

assert_allow() {
    local label="$1" rc="$2"
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (BLOCK — expected ALLOW; out: $GUARD_OUT)" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

assert_block() {
    local label="$1" rc="$2"
    case "$rc" in
        0) fail "$label (ALLOW — expected BLOCK; out: $GUARD_OUT)" ;;
        1) pass "$label" ;;
        2) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
        *) fail "$label (unexpected rc=$rc; out: $GUARD_OUT)" ;;
    esac
}

# ----------------------------------------------------------------------------
# Fixtures
# ----------------------------------------------------------------------------

setup_main_worktree() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

add_linked_worktree() {
    local main_wt="$1" name="$2" branch="$3"
    local wt_path="$main_wt/.wt/$name"
    git -C "$main_wt" worktree add -q -b "$branch" "$wt_path" >/dev/null
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$wt_path"
    else
        echo "$wt_path"
    fi
}

setup_fake_acd() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-$name"
    mkdir -p "$d/bin/github-issues"
    touch "$d/bin/check-unstaged-tracked.sh"
    mkdir -p "$d/skills/issue-close-finalize/scripts"
    touch "$d/skills/issue-close-finalize/scripts/pre-flight.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-initial.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-loop-step.js"
    touch "$d/skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
    touch "$d/skills/issue-close-finalize/scripts/step-g5-loop.sh"
    # Non-registry sibling script used for the over-acceptance probe.
    touch "$d/skills/issue-close-finalize/scripts/evil.sh"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

setup_plans_dir() {
    local name="$1"
    local d="$TMPDIR_BASE/plans-$name"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$d"
    else
        echo "$d"
    fi
}

# ============================================================================
# 1. No gaps — the 3 live shapes from a registered main worktree all ALLOW.
# ============================================================================

test_no_gaps_all_three_shapes() {
    local repo; repo="$(setup_main_worktree "audit-nogap")"
    add_linked_worktree "$repo" "wt1" "feat/audit-nogap" >/dev/null
    local acd; acd="$(setup_fake_acd "audit-nogap")"
    local plans; plans="$(setup_plans_dir "audit-nogap")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local outcome="$plans/sid-issue-close-outcome.json"

    local cmd_initial cmd_loop cmd_term rc
    cmd_initial="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' "$acd" "$scripts" "$repo" "$scripts")"
    rc=0; run_guard "$(build_bash_payload "$cmd_initial")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_allow "no-gaps: initial shape → ALLOW (RED before fix)" "$rc"

    cmd_loop="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s" "accept")"' "$acd" "$scripts" "$scripts" "$statefile")"
    rc=0; run_guard "$(build_bash_payload "$cmd_loop")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_allow "no-gaps: loop_step shape → ALLOW (RED before fix)" "$rc"

    cmd_term="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" bash "%s/run-finalize-terminal.sh" "%s" "sid" "%s")"' "$acd" "$scripts" "$statefile" "$outcome")"
    rc=0; run_guard "$(build_bash_payload "$cmd_term")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_allow "no-gaps: finalize_terminal shape → ALLOW (RED before fix)" "$rc"
}

# ============================================================================
# 2. No over-acceptance — non-registry sibling script (evil.sh) → BLOCK.
# ============================================================================

test_no_over_acceptance_sibling() {
    local repo; repo="$(setup_main_worktree "audit-sibling")"
    add_linked_worktree "$repo" "wt1" "feat/audit-sibling" >/dev/null
    local acd; acd="$(setup_fake_acd "audit-sibling")"
    local plans; plans="$(setup_plans_dir "audit-sibling")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/evil.sh" "1234" "1234" "")"' "$acd" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "no-over-acceptance: non-registry sibling evil.sh → BLOCK" "$rc"
}

# ============================================================================
# 3. Registry integrity — inspect the REAL finalize-worker-overlay.js.
# ============================================================================

test_registry_integrity() {
    local result
    result="$(run_with_timeout 30 node -e '
        const p = process.argv[1];
        let mod;
        try { mod = require(p); } catch (e) { console.log("REQUIRE_FAIL: " + e.message); process.exit(0); }
        const reg = mod.FINALIZE_OVERLAY_REGISTRY;
        const g5 = mod.G5_DECISION_VALUES;
        const errs = [];
        if (!Array.isArray(reg)) { errs.push("FINALIZE_OVERLAY_REGISTRY not an array"); }
        else {
            const rels = reg.map(e => e && e.rel).sort();
            const expected = [
                "skills/issue-close-finalize/scripts/run-finalize-terminal.sh",
                "skills/issue-close-finalize/scripts/run-initial.sh",
                "skills/issue-close-finalize/scripts/run-loop-step.js",
                "skills/issue-close-finalize/scripts/step-g5-loop.sh",
            ].sort();
            if (JSON.stringify(rels) !== JSON.stringify(expected)) {
                errs.push("rel set mismatch: " + JSON.stringify(rels));
            }
            const byRel = {};
            for (const e of reg) { if (e && e.rel) byRel[e.rel] = e; }
            const g5entry = byRel["skills/issue-close-finalize/scripts/step-g5-loop.sh"];
            if (!g5entry || g5entry.matchable !== false) errs.push("step-g5-loop.sh must be matchable:false");
            for (const rel of ["run-initial.sh","run-loop-step.js","run-finalize-terminal.sh"]) {
                const e = byRel["skills/issue-close-finalize/scripts/"+rel];
                if (!e || e.matchable !== true) errs.push(rel+" must be matchable:true");
            }
            const loop = byRel["skills/issue-close-finalize/scripts/run-loop-step.js"];
            if (!loop || !Array.isArray(loop.argSpec) || loop.argSpec[1] !== "enum-g5") {
                errs.push("run-loop-step.js argSpec[1] must be enum-g5 (got: " + JSON.stringify(loop && loop.argSpec) + ")");
            }
        }
        const expectedG5 = ["accept","decline","llm_declined","recurse_done"];
        if (JSON.stringify(g5) !== JSON.stringify(expectedG5)) {
            errs.push("G5_DECISION_VALUES mismatch (order+case): " + JSON.stringify(g5));
        }
        if (errs.length) { console.log("INTEGRITY_FAIL: " + errs.join(" | ")); }
        else { console.log("ok"); }
    ' "$OVERLAY_JS" 2>&1)"
    if [ "$result" = "ok" ]; then
        pass "registry-integrity: rels/matchable/argSpec/G5_DECISION_VALUES all correct"
    else
        fail "registry-integrity: $result"
    fi
}

# Legacy SANCTIONED array still holds pre-flight.sh + run-quality-gates.sh but
# NONE of the 4 overlay scripts (overlay owns those now).
test_legacy_sanctioned_disjoint() {
    local errs=""
    grep -qF "skills/issue-close-finalize/scripts/pre-flight.sh" "$WORKER_SCRIPT_JS" \
        || errs="$errs;pre-flight.sh missing from SANCTIONED"
    grep -qF "skills/review-code-security/scripts/run-quality-gates.sh" "$WORKER_SCRIPT_JS" \
        || errs="$errs;run-quality-gates.sh missing from SANCTIONED"
    for s in run-initial.sh run-loop-step.js run-finalize-terminal.sh step-g5-loop.sh; do
        if grep -qF "issue-close-finalize/scripts/$s" "$WORKER_SCRIPT_JS"; then
            errs="$errs;overlay script $s leaked into worker-script.js SANCTIONED"
        fi
    done
    if [ -z "$errs" ]; then
        pass "legacy-sanctioned-disjoint: SANCTIONED keeps pre-flight/quality-gates, excludes 4 overlay scripts"
    else
        fail "legacy-sanctioned-disjoint:$errs"
    fi
}

# ============================================================================
# 4. Interpreter binding — node/bash mismatches → BLOCK.
# ============================================================================

test_interp_binding_node_on_bash() {
    local repo; repo="$(setup_main_worktree "audit-nodebash")"
    add_linked_worktree "$repo" "wt1" "feat/audit-nodebash" >/dev/null
    local acd; acd="$(setup_fake_acd "audit-nodebash")"
    local plans; plans="$(setup_plans_dir "audit-nodebash")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" node "%s/run-initial.sh" "1234" "1234" "")"' "$acd" "$scripts" "$repo" "$scripts")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "interp-binding: node run-initial.sh (bash script) → BLOCK" "$rc"
}

test_interp_binding_bash_on_node() {
    local repo; repo="$(setup_main_worktree "audit-bashnode")"
    add_linked_worktree "$repo" "wt1" "feat/audit-bashnode" >/dev/null
    local acd; acd="$(setup_fake_acd "audit-bashnode")"
    local plans; plans="$(setup_plans_dir "audit-bashnode")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    local statefile="$plans/sid-finalize-state-1234.json"
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" bash "%s/run-loop-step.js" "%s" "accept")"' "$acd" "$scripts" "$scripts" "$statefile")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "interp-binding: bash run-loop-step.js (node script) → BLOCK" "$rc"
}

# ============================================================================
# 5. Write-scope still governs — outer redirect into main worktree → BLOCK.
# ============================================================================

test_write_scope_outer_redirect() {
    local repo; repo="$(setup_main_worktree "audit-redir")"
    add_linked_worktree "$repo" "wt1" "feat/audit-redir" >/dev/null
    local acd; acd="$(setup_fake_acd "audit-redir")"
    local plans; plans="$(setup_plans_dir "audit-redir")"
    local scripts="$acd/skills/issue-close-finalize/scripts"
    # Otherwise-valid overlay shape with an added outer redirect into the main worktree.
    local cmd
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")" > "%s/pwned.txt"' "$acd" "$scripts" "$repo" "$scripts" "$repo")"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$repo" "AGENTS_CONFIG_DIR=$acd" "WORKFLOW_PLANS_DIR=$plans" || rc=$?
    assert_block "write-scope: overlay shape + outer redirect into main worktree → BLOCK" "$rc"
}

# ============================================================================
# Run all
# ============================================================================

run_all() {
    test_no_gaps_all_three_shapes
    test_no_over_acceptance_sibling
    test_registry_integrity
    test_legacy_sanctioned_disjoint
    test_interp_binding_node_on_bash
    test_interp_binding_bash_on_node
    test_write_scope_outer_redirect
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
