#!/bin/bash
# tests/hooks/fix-1569-quote-span-regression.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/arg-tail-guard.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree/arg-value-guard.js, hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/lib/quote-spans.js
# Tags: worktree, enforce, hook, quote-spans, arg-tail, security, classifier, scope:issue-specific
# Decision rules under test for rejectsUnsafeToken (first match wins): 1 scan or
# tokenize failure -> REJECT; 2 any `ansic` piece -> REJECT; 3 unquoted SET-A
# [|&;<>()] -> REJECT; 4 unquoted/dq SET-B ($( or backtick, minus dq escapes) ->
# REJECT; 5 SET-A inside dq/sq -> ALLOW; 6 otherwise ALLOW. Every ALLOW case is
# paired with an attack variant that must BLOCK (test-design.md); per-row status
# notes live in the part files under tests/hooks/fix-1569-quote-span-regression/.
# TL3 gap (what this TL2 test does NOT catch): a real session issuing these through the PreToolUse registration; checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration.

set -u

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not found";  exit 77; }

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _SCRIPT_CHECKOUT_ROOT_NODE="$(cygpath -m "$SCRIPT_CHECKOUT_ROOT")"
else
    _SCRIPT_CHECKOUT_ROOT_NODE="$SCRIPT_CHECKOUT_ROOT"
fi
GUARD_JS="${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/enforce-worktree.js"
# shellcheck source=../lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPDIR_BASE="$(mktemp -d 2>/dev/null || mktemp -d -t fix1569)"
trap 'rm -rf "$TMPDIR_BASE" 2>/dev/null' EXIT

if [ ! -f "$GUARD_JS" ]; then
    echo "FAIL: precondition missing — hooks/enforce-worktree.js"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi

norm() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

json_payload() {
    node -e 'process.stdout.write(JSON.stringify({tool_name:"Bash",tool_input:{command:process.argv[1]}}))' "$1"
}

# ── Fixtures: one main worktree (+ one linked worktree), one fake script checkout root, plans ──
MAIN_WT_RAW="$TMPDIR_BASE/repo"
mkdir -p "$MAIN_WT_RAW"
git -C "$MAIN_WT_RAW" init -q -b main
git -C "$MAIN_WT_RAW" config user.email "test@example.com"
git -C "$MAIN_WT_RAW" config user.name "Test"
git -C "$MAIN_WT_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_WT_RAW/README.md"
git -C "$MAIN_WT_RAW" add README.md
git -C "$MAIN_WT_RAW" commit -q --no-verify -m initial
git -C "$MAIN_WT_RAW" worktree add -q -b feature/x "$MAIN_WT_RAW/.wt/x" >/dev/null
MAIN_WT="$(norm "$MAIN_WT_RAW")"

FAKE_SCRIPT_CHECKOUT_ROOT_RAW="$TMPDIR_BASE/script_checkout_root"
mkdir -p "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/bin/github-issues" "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/skills/issue-create/scripts" \
         "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/skills/review-code-security/scripts" \
         "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/skills/issue-close-finalize/scripts" \
         "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/hooks"
# The guard and its modules find the checkout from their own location, so this
# stand-in for a LEGITIMATE agents checkout carries a real copy of hooks/ and
# every case runs that copy. The copy also supplies one trust marker
# (hooks/lib/script-checkout-root.js: hooks/enforce-worktree.js AND bin/); the
# marker-less hostile case is owned by tests/fix-1630-*.sh (T4a-attack et al.).
if ! script_checkout_fixture_copy "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW" hooks; then
    echo "FAIL: precondition — hooks fixture copy failed"
    echo ""
    echo "Total: PASS=0 FAIL=1"
    exit 1
fi
touch "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/bin/github-issues/issue-create-dispatch.sh" \
      "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/bin/check-unstaged-tracked.sh" \
      "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/skills/review-code-security/scripts/run-quality-gates.sh" \
      "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW/skills/issue-close-finalize/scripts/run-loop-step.js"
FAKE_SCRIPT_CHECKOUT_ROOT="$(norm "$FAKE_SCRIPT_CHECKOUT_ROOT_RAW")"
FAKE_GUARD_JS="$FAKE_SCRIPT_CHECKOUT_ROOT/hooks/enforce-worktree.js"
DISPATCH="$FAKE_SCRIPT_CHECKOUT_ROOT/bin/github-issues/issue-create-dispatch.sh"
QGATES="$FAKE_SCRIPT_CHECKOUT_ROOT/skills/review-code-security/scripts/run-quality-gates.sh"
FSD="$FAKE_SCRIPT_CHECKOUT_ROOT/skills/issue-close-finalize/scripts"

PLANS_RAW="$TMPDIR_BASE/plans"
mkdir -p "$PLANS_RAW"
PLANS="$(norm "$PLANS_RAW")"
STATE="$PLANS/sid-finalize.json"

EVIL_RAW="$TMPDIR_BASE/evil"
mkdir -p "$EVIL_RAW"
touch "$EVIL_RAW/issue-create-dispatch.sh"
EVIL="$(norm "$EVIL_RAW")"

# Run the guard from the MAIN worktree. rc: 0 = ALLOW, 1 = BLOCK, 2 = CRASH.
GUARD_OUT=""
run_guard() {
    local cmd="$1"; shift
    local payload rc=0
    payload="$(json_payload "$cmd")"
    GUARD_OUT="$(cd "$MAIN_WT_RAW" && printf '%s' "$payload" | run_with_timeout 30 \
        env \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$MAIN_WT" \
        "AGENTS_MAIN_ROOT=$FAKE_SCRIPT_CHECKOUT_ROOT" \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        "$@" \
        node "$FAKE_GUARD_JS" 2>&1)" || rc=$?
    [ "$rc" -ne 0 ] && return 2
    echo "$GUARD_OUT" | grep -q '"decision":"block"' && return 1
    return 0
}

assert_allow() {
    local label="$1" cmd="$2"; local rc=0
    run_guard "$cmd" || rc=$?
    case "$rc" in
        0) pass "$label" ;;
        1) fail "$label (BLOCK — expected ALLOW; cmd=$cmd)" ;;
        *) fail "$label (CRASH; out=$GUARD_OUT)" ;;
    esac
}

assert_block() {
    local label="$1" cmd="$2"; local rc=0
    run_guard "$cmd" || rc=$?
    case "$rc" in
        0) fail "$label (ALLOW — expected BLOCK; cmd=$cmd)" ;;
        1) pass "$label" ;;
        *) fail "$label (CRASH; out=$GUARD_OUT)" ;;
    esac
}

LF=$'\n'

# ============================================================================
# 1-6: the 6 false positives fixed in PR #1577 — must STAY allowed, each paired
#      with the attack variant that must stay blocked.
# ============================================================================

# Attack variants inject a write that targets the REPO (relative to the main
# worktree cwd) — enforce-worktree only blocks repo writes, so an injection
# aimed at /tmp would be allowed for reasons unrelated to quote spans and would
# make the pairing vacuous.

# 1 — #1568: gh issue create with literal newlines inside the DQ --body.
assert_allow "FP1 #1568 gh --body with literal newlines inside DQ" \
    "ISSUE_CREATE_SKILL=1 gh issue create --title T --body \"line1${LF}line2${LF}line3\""
assert_block "FP1-attack #1568 newline injection on a non-sanctioned gh command" \
    "gh issue view 1${LF}rm -rf README.md"
assert_block "FP1-attack #1568 bare gh issue create without the skill marker (#713)" \
    "gh issue create --title T --body \"line1${LF}line2\""
# NOTE (out of scope for #1569): a sanctioned `ISSUE_CREATE_SKILL=1 gh issue
# create ...` short-circuits in the isGhWriteCommand branch of
# hooks/enforce-worktree.js (~line 265) and never reaches the standard write
# classifier, so an injected write appended to it is allowed. That branch is not
# touched by the quote-span refactor; pinning it here would produce a
# permanently-RED assertion, so the two pins above use the paths #1569 governs.

# 2 — #1533: sanctioned dispatch.sh with a multiline DQ --body arg.
assert_allow "FP2 #1533 sanctioned dispatch.sh with multiline DQ body" \
    "ISSUE_CREATE_SKILL=1 bash \"$DISPATCH\" --body \"line1${LF}line2\""
assert_block "FP2-attack #1533 newline outside the DQ body injects a repo write" \
    "ISSUE_CREATE_SKILL=1 bash \"$DISPATCH\" --body \"line1\"${LF}rm -rf README.md"

# 3 — #1457: ANSI-C quoting in a gh --body argument.
assert_allow "FP3 #1457 gh --body with ANSI-C \$'...' quoting" \
    "ISSUE_CREATE_SKILL=1 gh issue create --body \$'it'\\''s fine'"
assert_block "FP3-attack #1457 ANSI-C body followed by an injected repo write" \
    "bash \"$DISPATCH\" --body \$'it' ; rm -rf README.md"

# 4 — #1449: run-quality-gates.sh is a sanctioned worker script.
assert_allow "FP4 #1449 bash run-quality-gates.sh from main" \
    "bash \"$QGATES\""
assert_block "FP4-attack #1449 same script with a chained repo rm" \
    "bash \"$QGATES\" ; rm -rf README.md"

# 5 — #1385: read-only workflow CLI via bash -c.
assert_allow "FP5 #1385 bash -c read-only workflow CLI" \
    "bash -c 'node bin/workflow/read-complexity-evaluation --session sid'"
assert_block "FP5-attack #1385 bash -c with a chained repo write" \
    "bash -c 'node bin/workflow/read-complexity-evaluation --session sid && rm -rf README.md'"

# 6 — #1191: VAR=val env prefix before a sanctioned bash invocation.
assert_allow "FP6 #1191 VAR=val prefix before sanctioned bash script" \
    "ISSUE_CREATE_SKILL=1 bash \"$DISPATCH\""
assert_block "FP6-attack #1191 same prefix, injected repo write after the script" \
    "ISSUE_CREATE_SKILL=1 bash \"$DISPATCH\" ; rm -rf README.md"
# 6b — #1191 `2>&1 | tee <linked-wt>/log` form, pinned at the CURRENT verdict in
# BOTH layers (this is the "do not loosen, do not tighten" pin):
#   hook   -> ALLOW, but NOT via the sanctioned fast path: the bare `|` makes
#             worker-script reject, and the command survives only because the
#             standard classifier finds every write target inside a registered
#             linked worktree. Tightening the arg-tail guard must not change it.
#   module -> false. The bare `|` is an unquoted SET-A metacharacter (rule 3);
#             C3 must not let the tee-into-a-linked-worktree shape relax it.
# The module half is asserted in the ARG-* section below (ARG-reject #1191 tee).
assert_allow "FP6b #1191 '2>&1 | tee <linked-wt>/log' stays allowed via the write-scope path" \
    "ISSUE_CREATE_SKILL=1 bash \"$DISPATCH\" 2>&1 | tee \"$MAIN_WT/.wt/x/build.log\""
assert_block "FP6b-attack #1191 same form, tee target moved into the MAIN worktree" \
    "ISSUE_CREATE_SKILL=1 bash \"$DISPATCH\" 2>&1 | tee \"$MAIN_WT/build.log\""

# ============================================================================
# 7: PR #1612 — enum-g5 decision value carrying a pipe.
# #1673 deleted finalize-worker-overlay.js and the Bash-tool `eval` path, so
# both rows now BLOCK: the clean row is kept as a retired-capability pin, the
# second always was an injection. The clean-ALLOW vs dirty-BLOCK pairing moved
# to the value-token level: ARG-tok-* rows in
# tests/hooks/fix-1630-overlay-cross-validation/metachar-args.sh, and at hook
# level the LIVE1679-* ALLOW rows in
# tests/hooks/fix-1679-finalize-overlay-arg-contract.sh.
# ============================================================================
assert_block "PR1612 finalize loop-step with clean enum decision — eval path retired (#1673)" \
    "eval \"\$(AGENTS_MAIN_ROOT=\"$FAKE_SCRIPT_CHECKOUT_ROOT\" FINALIZE_SCRIPTS_DIR=\"$FSD\" node \"$FSD/run-loop-step.js\" \"$STATE\" \"accept\")\""
assert_block "PR1612-attack finalize loop-step with decision 'accept|evil'" \
    "eval \"\$(AGENTS_MAIN_ROOT=\"$FAKE_SCRIPT_CHECKOUT_ROOT\" FINALIZE_SCRIPTS_DIR=\"$FSD\" node \"$FSD/run-loop-step.js\" \"$STATE\" \"accept|evil\")\""

# shellcheck source=tests/hooks/fix-1569-quote-span-regression/rules-hook.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1569-quote-span-regression/rules-hook.sh"
run_rule_hook_cases

# shellcheck source=tests/hooks/fix-1569-quote-span-regression/arg-tail-module.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1569-quote-span-regression/arg-tail-module.sh"
run_arg_tail_module_cases

# shellcheck source=tests/hooks/fix-1569-quote-span-regression/case-pattern.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1569-quote-span-regression/case-pattern.sh"
run_case_pattern_cases

# shellcheck source=tests/hooks/fix-1569-quote-span-regression/fold-ok-gate.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1569-quote-span-regression/fold-ok-gate.sh"
run_fold_ok_gate_cases

# shellcheck source=tests/hooks/fix-1569-quote-span-regression/canary.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/fix-1569-quote-span-regression/canary.sh"
run_canary_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
