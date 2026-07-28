#!/bin/bash
# tests/fix-1630-overlay-cross-validation.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/finalize-worker-overlay.js, hooks/lib/agents-config-dir.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js
# Tags: worktree, enforce, hook, config-dir, overlay, security, scope:issue-specific
#
# STATUS: RED until C5 lands (stripRelSuffix + three-way candidate
# cross-validation in matchFinalizeWorkerOverlay, immediately after the
# `if (!entry) return null;` early return).
#
# What C5 changes: today the overlay identifies a finalize script by
# `path.join(acd, entry.rel)` string equality against a single acd value. With
# the #1630 resolver there is a CANDIDATE SET (env / module / realpath), so
# identification inverts: strip the registry's relative suffix off the invoked
# script path (stripRelSuffix) to derive the root it implies, then require that
# derived root to match a resolver candidate AND to agree with the inline
# AGENTS_CONFIG_DIR / FINALIZE_SCRIPTS_DIR / MAIN_WORKTREE_PATH values.
#
# Case groups live in tests/fix-1630-overlay-cross-validation/:
#   xv-families.sh — candidate-mismatch BLOCK families, VALUE-* pins, canaries
#   strip-units.sh — stripRelSuffix units + candidate acceptance
#   path-edges.sh  — path edge shapes for the segment-wise suffix strip
#   mutation.sh    — mutation-sensitive proof that each of the two equalities in
#                    the three-way comparison is individually load-bearing
#   metachar-args.sh — what the overlay accepts INSIDE an argument: shell
#                    metacharacters in a plans-dir / id token, and arguments
#                    past the end of the entry's argSpec
#
# Expected verdicts today:
#   RED   — every STRIP-* unit (stripRelSuffix does not exist yet)
#   RED   — CAND-accept-* (a script rooted at a non-env candidate is refused today)
#   GREEN — every XV-* BLOCK family and every VALUE-* pin (regression guards that
#           must survive C5 unchanged)
#   GREEN — the normal-path ALLOW regression sourced from
#           tests/fix-1600-finalize-worker-overlay/allow-cases.sh
#
# TL3 gap (what this TL2 test does NOT catch):
# - a real /issue-close-finalize chain emitting these evals from a genuine main
#   worktree through the PreToolUse registration in settings.json
# - a real symlinked checkout (~/.claude/* -> agents repo) where the module and
#   realpath candidates genuinely differ
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not found";  exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GUARD_JS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"
OVERLAY_PROBE="${_AGENTS_DIR_NODE}/tests/fixtures/finalize-overlay-probe.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

assert_eq() {
    local name="$1" got="$2" want="$3"
    if [ "$got" = "$want" ]; then pass "$name"
    else fail "$name (want=$want got=$got)"; fi
}

_trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t fix1630xv)"
trap 'rm -rf "$TMPDIR_BASE" 2>/dev/null' EXIT

for f in "$GUARD_JS" "$OVERLAY_PROBE"; do
    if [ ! -f "$f" ]; then
        echo "FAIL: precondition missing — $f"
        echo ""
        echo "Total: PASS=0 FAIL=1"
        exit 1
    fi
done

# ----------------------------------------------------------------------------
# Harness + fixture builders, kept name-compatible with
# tests/fix-1600-finalize-worker-overlay.sh so its allow-cases.sh can be sourced
# verbatim as the normal-path ALLOW regression (no case duplication).
# ----------------------------------------------------------------------------
json_quote() { node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"; }

build_bash_payload() {
    local cmd="$1" q
    q="$(json_quote "$cmd")"
    printf '{"tool_name":"Bash","tool_input":{"command":%s}}' "$q"
}

GUARD_OUT=""
GUARD_RC=0
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
    [ "$GUARD_RC" -ne 0 ] && return 2
    echo "$GUARD_OUT" | grep -q '"decision":"block"' && return 1
    return 0
}

assert_allow() {
    local label="$1" rc="$2"
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (BLOCK — expected ALLOW; out: $GUARD_OUT)" ;;
        *) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
    esac
}

assert_block() {
    local label="$1" rc="$2"
    case "$rc" in
        0) fail "$label (ALLOW — expected BLOCK; out: $GUARD_OUT)" ;;
        1) pass "$label" ;;
        *) fail "$label (CRASH rc=$GUARD_RC; out: $GUARD_OUT)" ;;
    esac
}

setup_main_worktree() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    mkdir -p "$repo/docs/history"
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q --no-verify -m "initial"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$repo"; else echo "$repo"; fi
}

setup_fake_acd() {
    local name="$1"
    local d="$TMPDIR_BASE/fake-acd-$name"
    mkdir -p "$d/bin/github-issues" "$d/hooks" "$d/skills/issue-close-finalize/scripts"
    touch "$d/bin/check-unstaged-tracked.sh" \
          "$d/bin/probe-remote-bootstrap.sh" \
          "$d/bin/issue-close-gate.sh" \
          "$d/bin/github-issues/issue-close-stage-triage.sh" \
          "$d/bin/github-issues/parent-body-update.sh" \
          "$d/hooks/enforce-worktree.js" \
          "$d/skills/issue-close-finalize/scripts/pre-flight.sh" \
          "$d/skills/issue-close-finalize/scripts/run-initial.sh" \
          "$d/skills/issue-close-finalize/scripts/run-loop-step.js" \
          "$d/skills/issue-close-finalize/scripts/run-finalize-terminal.sh"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

setup_plans_dir() {
    local name="$1"
    local d="$TMPDIR_BASE/plans-$name"
    mkdir -p "$d"
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$d"; else echo "$d"; fi
}

build_initial() {
    local acd_val="$1" fsd_val="$2" mwt_val="$3" scripts="$4"
    printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234" "")"' \
        "$acd_val" "$fsd_val" "$mwt_val" "$scripts"
}

build_loop_step() {
    local acd_val="$1" fsd_val="$2" scripts="$3" statefile="$4" decision="$5"
    printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" node "%s/run-loop-step.js" "%s" "%s")"' \
        "$acd_val" "$fsd_val" "$scripts" "$statefile" "$decision"
}

build_finalize_terminal() {
    local acd_val="$1" scripts="$2" statefile="$3" sid="$4" outcome="$5"
    printf 'eval "$(AGENTS_CONFIG_DIR="%s" bash "%s/run-finalize-terminal.sh" "%s" "%s" "%s")"' \
        "$acd_val" "$scripts" "$statefile" "$sid" "$outcome"
}

# ============================================================================
# Normal-path ALLOW regression — sourced verbatim from the #1600 suite.
# These must be unaffected by C5: a correctly-rooted finalize invocation keeps
# working when identification switches from join-equality to suffix-stripping.
# ============================================================================
# shellcheck source=./fix-1600-finalize-worker-overlay/allow-cases.sh
. "$AGENTS_DIR/tests/fix-1600-finalize-worker-overlay/allow-cases.sh"

test_allow_initial
test_allow_loop_step_enum "accept"
test_allow_loop_step_enum "recurse_done"
test_allow_finalize_terminal
test_allow_initial_env_order_swapped

# shellcheck source=./fix-1630-overlay-cross-validation/xv-families.sh
. "$AGENTS_DIR/tests/fix-1630-overlay-cross-validation/xv-families.sh"
run_xv_family_cases


# shellcheck source=./fix-1630-overlay-cross-validation/strip-units.sh
. "$AGENTS_DIR/tests/fix-1630-overlay-cross-validation/strip-units.sh"
# shellcheck source=./fix-1630-overlay-cross-validation/path-edges.sh
. "$AGENTS_DIR/tests/fix-1630-overlay-cross-validation/path-edges.sh"
# shellcheck source=./fix-1630-overlay-cross-validation/mutation.sh
. "$AGENTS_DIR/tests/fix-1630-overlay-cross-validation/mutation.sh"
# shellcheck source=./fix-1630-overlay-cross-validation/metachar-args.sh
. "$AGENTS_DIR/tests/fix-1630-overlay-cross-validation/metachar-args.sh"

run_strip_unit_cases
run_path_edge_cases
run_mutation_cases
run_overlay_metachar_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
