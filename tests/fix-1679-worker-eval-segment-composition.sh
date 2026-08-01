#!/bin/bash
# tests/fix-1679-worker-eval-segment-composition.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js, skills/issue-close-finalize/SKILL.md
# Tags: enforce-worktree, allowlist, security, TL1, TL2, pwsh-not-required, scope:issue-specific
#
# Issue #1679 (S-8) — isAllowedWorkerScriptInvocation's eval-unwrap regex is
# END-ANCHORED:
#   /^\s*eval\s+"\$\(bash\s+"([^"]+)"\s*\)"\s*(?:\|\|\s*exit\s+0\s*)?$/
# so a sanctioned pre-flight.sh eval stops matching the moment ANY benign
# companion segment is present — a leading `cd "<repo>" &&`, a trailing
# `; echo "OWNER_REPO=$OWNER_REPO"`, or a `2>&1` fd-dup. That single anchor is
# the root cause of the large majority of the logged blocked incidents, all of
# which are the documented /issue-close-finalize pre-flight shape.
#
# The fix replaces the anchor with a segment-composition rule: exactly ONE
# sanctioned segment, and every companion segment must be write=null AND
# non-env-mutating (new ENV_MUTATION_RE / ASSIGN_RE guards). The env-mutation
# guards close the confused-deputy hole that a naive composition rule would open
# together with the S-7 $AGENTS_CONFIG_DIR prefix resolution: detectWritePredicate
# classifies `export VAR=val`, `VAR=val`, `unset VAR` and `source f` as read
# (null), so without them an attacker could repoint AGENTS_CONFIG_DIR in a
# companion segment and have the sanctioned segment resolve against it.
#
# IN1679-*  real logged blocked command strings — RED before the fix, GREEN after
#           (IN1679-6 is the already-working bare shape: GREEN before AND after).
#           IN1679-5 is the exception: #1673 deleted finalize-worker-overlay.js,
#           the only matcher for a literal eval-wrapped run-initial.sh Bash-tool
#           string, so that shape now BLOCKs at every segment composition —
#           retired-capability pin, not a live ALLOW row.
# AD1679-*  adversarial compositions — BLOCK before AND after the fix. These are
#           the security boundary the S-8 widening must not breach.
# E2E1679-* end-to-end decision + block-reason assertions on the same surface.
#           E2E1679-5 mirrors IN1679-5's retirement — see the note there.
# MU1679-*  TL1 unit rows calling isAllowedWorkerScriptInvocation() directly, so
#           the predicate is isolated from every other branch of the hook.
#
# Drive surface (full hook, TL2):
#   echo '{"tool_name":"Bash","tool_input":{"command":"<cmd>"}}' | \
#     (cd <main-worktree> && ENFORCE_WORKTREE=on AGENTS_CONFIG_DIR=<fake-acd> \
#      WORKFLOW_PLANS_DIR=<plans> node hooks/enforce-worktree.js)
#
# TL3 gap (what this TL2 test does NOT catch):
#   - A real /session-close → /issue-close-finalize chain issuing the eval from a
#     genuine main worktree with a live AGENTS_CONFIG_DIR and real finalize scripts.
#   - Whether the hook is actually registered as PreToolUse in settings.json, so a
#     real Claude Code session routes the Bash command through it at all.
#   - Real shell expansion of $AGENTS_CONFIG_DIR inside the eval sub-shell.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration

set -u

# Self-re-exec under a hard timeout BEFORE any fixture is built, so the outer
# process never pays for the git init / worktree add it is about to discard.
if command -v timeout >/dev/null 2>&1; then
    if [ -z "${_FIX1679_SEG_INNER:-}" ]; then
        _FIX1679_SEG_INNER=1 timeout 180 bash "$0" "$@"
        exit $?
    fi
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

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
const d=path.join(os.tmpdir(),'fix1679-seg-'+process.pid).replace(/\\\\/g,'/');
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

# Run the guard with cwd set to <main-worktree>.
# Returns: 0 = ALLOW, 1 = BLOCK, 2 = CRASH.
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

# `env -C` is a GNU coreutils extension (>=8.28). Fallback: subshell `cd` + env.
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
# Fixtures — one shared main worktree + linked worktree + fake acd + plans dir.
# No case mutates fixture state, so a single build keeps the 25+ guard spawns
# inside the 120s budget. Pattern lifted from tests/fix-1600-finalize-worker-overlay.sh.
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
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$repo"; else echo "$repo"; fi
}

add_linked_worktree() {
    local main_wt="$1" name="$2" branch="$3"
    local wt_path="$main_wt/.wt/$name"
    git -C "$main_wt" worktree add -q -b "$branch" "$wt_path" >/dev/null
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$wt_path"; else echo "$wt_path"; fi
}

# Fake AGENTS_CONFIG_DIR carrying BOTH trust markers (hooks/enforce-worktree.js
# and bin/) so hooks/lib/agents-config-dir.js accepts it as a legitimate agents
# checkout — the hostile marker-less case is owned by tests/fix-1630-*.sh.
setup_fake_acd() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-$name"
    mkdir -p "$d/bin/github-issues" "$d/hooks"
    touch "$d/hooks/enforce-worktree.js"
    touch "$d/bin/check-unstaged-tracked.sh"
    touch "$d/bin/issue-close-gate.sh"
    # AD1679-7 target: present on disk but deliberately NOT in SANCTIONED.
    touch "$d/bin/evil.sh"
    mkdir -p "$d/skills/issue-close-finalize/scripts"
    touch "$d/skills/issue-close-finalize/scripts/pre-flight.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-initial.sh"
    touch "$d/skills/issue-close-finalize/scripts/run-loop-step.js"
    touch "$d/skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

setup_plans_dir() {
    local d="$TMPDIR_BASE/plans-$1"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

REPO="$(setup_main_worktree "repo")"
LINKED="$(add_linked_worktree "$REPO" "wt1" "feat/x")"
ACD="$(setup_fake_acd "main")"
PLANS="$(setup_plans_dir "main")"
SCRIPTS="$ACD/skills/issue-close-finalize/scripts"

# The literal (unexpanded) prefix is what PreToolUse actually receives, because
# the hook fires BEFORE the shell expands the command.
PF_LITERAL='$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/pre-flight.sh'
PF_RESOLVED="$SCRIPTS/pre-flight.sh"

# eval-wrapped sanctioned segment. $1 = script path literal.
pf_eval() { printf 'eval "$(bash "%s")"' "$1"; }

# Convenience: run one command through the guard against the shared fixture.
guard() {
    local cmd="$1"
    local rc=0
    run_guard "$(build_bash_payload "$cmd")" "$REPO" \
        "AGENTS_CONFIG_DIR=$ACD" "WORKFLOW_PLANS_DIR=$PLANS" || rc=$?
    return $rc
}

# ----------------------------------------------------------------------------
# Test groups (sourced — share the harness/fixtures/builders defined above).
# ----------------------------------------------------------------------------

SCRIPT_DIR_1679="$(dirname "${BASH_SOURCE[0]}")/fix-1679-worker-eval-segment-composition"

# shellcheck source=./fix-1679-worker-eval-segment-composition/in-ad-cases.sh
. "$SCRIPT_DIR_1679/in-ad-cases.sh"
# shellcheck source=./fix-1679-worker-eval-segment-composition/e2e-tl1-cases.sh
. "$SCRIPT_DIR_1679/e2e-tl1-cases.sh"

# ============================================================================
# Run all
# ============================================================================

test_in_cases
test_ad_cases
test_e2e_cases
test_tl1_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $FAIL
