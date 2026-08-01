#!/bin/bash
# tests/fix-1569-quote-span-regression.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/arg-tail-guard.js, hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree/arg-value-guard.js, hooks/enforce-worktree/main-worktree-allows/standard.js, hooks/lib/quote-spans.js
# Tags: worktree, enforce, hook, quote-spans, arg-tail, security, classifier, scope:issue-specific
#
# STATUS: partially RED until C3 lands (hooks/enforce-worktree/arg-tail-guard.js
# + rejectsUnsafeArgTail wiring). Verified against the pre-C3 tree:
#
# Expected to FAIL today (15 rows, all in the direct-module ARG-* / RISK10-*
# section — tests/fix-1569-quote-span-regression/arg-tail-module.sh):
#   - ARG-accept dq pipe / sq pipe / dq semicolon / dq ampersand /
#     mixed foo"|"bar / escaped \$( in dq — rule 5, the deliberate relaxation
#     that IS the #1569 fix; today the flat metachar regex in worker-script.js
#     rejects them.
#   - ARG-reject bare subshell — today `(` / `)` are absent from that flat
#     regex, so an unquoted subshell in the arg tail is accepted; rule 3 (SET-A
#     includes parens) must start rejecting it.
#   - RISK10-{341,399}-rule5 compose/clarify dq pipe, sq semicolon, dq
#     ampersand — the same rule-5 relaxation reaching the sanctioned-bin
#     profile (rule 5 lives in rejectsUnsafeToken, not in the profile table).
#   - RISK10-{341,399}-rule2 ansic rejected — `$'...'` is invisible to today's
#     flat regex (it only looks for `$(`), so an ANSI-C word is accepted;
#     rule 2 must start rejecting it.
#
# Expected to PASS today and STAY green:
#   - FP1..FP6 ALLOW cases (the 6 false positives fixed in PR #1577) and every
#     paired *-attack BLOCK case
#   - the R5-* / RISK2A-* hook-level ALLOW rows: at the hook boundary these are
#     already allowed (the standard classifier sees no repo write), which is why
#     the relaxation itself is pinned in the direct-module ARG-* section
#     (tests/fix-1569-quote-span-regression/arg-tail-module.sh)
#   - every other BLOCK row (rules 1-4 are fail-closed today)
#   - the remaining RISK10-* rows (sanctioned-bin profile: plain `>` / `2>&1` /
#     `&>` all rejected under allowRedirectAmpersand:false, contrasted with the
#     ARG-accept '&>' / '&>>' / plain '>' rows on the worker-script profile,
#     which keep the documented redirect exception)
#
# Decision rules under test (top-down, first match wins) for rejectsUnsafeToken:
#   1. scan.ok===false | pieces coverage gap | tokenize ok:false   -> REJECT
#   2. any `ansic` piece                                            -> REJECT
#   3. `unquoted` piece text contains SET-A [|&;<>()]               -> REJECT
#   4. `unquoted`/`dq` piece text contains SET-B ($( or backtick),
#      excluding \$ / \` escapes inside dq                          -> REJECT
#   5. SET-A inside dq/sq pieces                                    -> ALLOW
#   6. otherwise                                                    -> ALLOW
#
# Classifier both-direction coverage (test-design.md): every ALLOW case below is
# paired with an attack variant that must BLOCK.
#
# TL3 gap (what this TL2 test does NOT catch):
# - a real Claude Code session issuing these commands through the PreToolUse
#   registration in settings.json (the hook is spawned directly here)
# - real shell expansion of the command once the hook has allowed it
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

# ── Fixtures: one main worktree (+ one linked worktree), one fake ACD, plans ──
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

ACD_RAW="$TMPDIR_BASE/acd"
mkdir -p "$ACD_RAW/bin/github-issues" "$ACD_RAW/skills/issue-create/scripts" \
         "$ACD_RAW/skills/review-code-security/scripts" \
         "$ACD_RAW/skills/issue-close-finalize/scripts" \
         "$ACD_RAW/hooks"
# Both trust markers (hooks/lib/agents-config-dir.js: hooks/enforce-worktree.js
# AND bin/). This stub stands in for a LEGITIMATE agents checkout, and a real one
# always carries the guard itself — a marker-less stub is not a faithful config
# dir, it is the hostile case, which tests/fix-1630-*.sh own (T4a-attack et al.).
touch "$ACD_RAW/hooks/enforce-worktree.js"
touch "$ACD_RAW/bin/github-issues/issue-create-dispatch.sh" \
      "$ACD_RAW/bin/check-unstaged-tracked.sh" \
      "$ACD_RAW/skills/review-code-security/scripts/run-quality-gates.sh" \
      "$ACD_RAW/skills/issue-close-finalize/scripts/run-loop-step.js"
ACD="$(norm "$ACD_RAW")"
DISPATCH="$ACD/bin/github-issues/issue-create-dispatch.sh"
QGATES="$ACD/skills/review-code-security/scripts/run-quality-gates.sh"
FSD="$ACD/skills/issue-close-finalize/scripts"

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
        env -u CLAUDE_ENV_FILE \
        "ENFORCE_WORKTREE=on" \
        "ENFORCE_WORKTREE_ADDITIONAL_REPOS=$MAIN_WT" \
        "AGENTS_CONFIG_DIR=$ACD" \
        "WORKFLOW_PLANS_DIR=$PLANS" \
        "$@" \
        node "$GUARD_JS" 2>&1)" || rc=$?
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
#
# #1673 deleted finalize-worker-overlay.js and the Bash-tool `eval` path for the
# finalize scripts, so the clean row is no longer the ALLOW half of a pair: both
# rows now BLOCK, the first because the capability is retired and the second
# because it always was an injection. The clean row is kept as a
# retired-capability pin — its BLOCK is the assertion that the shape a
# legitimate caller once used stays shut too.
#
# The pairing this section provided (clean ALLOW vs. dirty BLOCK, so that
# "reject everything" cannot pass) is not lost: it moved to the value-token
# level, where the enum/plans-dir predicate still ships. It is asserted in
# tests/fix-1630-overlay-cross-validation/metachar-args.sh (ARG-tok-* rejected
# rows against their ARG-tok-plain/real/nested/dashes accepted controls), and at
# hook level by the LIVE1679-* ALLOW rows in
# tests/fix-1679-finalize-overlay-arg-contract.sh.
# ============================================================================
assert_block "PR1612 finalize loop-step with clean enum decision — eval path retired (#1673)" \
    "eval \"\$(AGENTS_CONFIG_DIR=\"$ACD\" FINALIZE_SCRIPTS_DIR=\"$FSD\" node \"$FSD/run-loop-step.js\" \"$STATE\" \"accept\")\""
assert_block "PR1612-attack finalize loop-step with decision 'accept|evil'" \
    "eval \"\$(AGENTS_CONFIG_DIR=\"$ACD\" FINALIZE_SCRIPTS_DIR=\"$FSD\" node \"$FSD/run-loop-step.js\" \"$STATE\" \"accept|evil\")\""

# shellcheck source=tests/fix-1569-quote-span-regression/rules-hook.sh
. "$AGENTS_DIR/tests/fix-1569-quote-span-regression/rules-hook.sh"
run_rule_hook_cases

# shellcheck source=tests/fix-1569-quote-span-regression/arg-tail-module.sh
. "$AGENTS_DIR/tests/fix-1569-quote-span-regression/arg-tail-module.sh"
run_arg_tail_module_cases

# shellcheck source=tests/fix-1569-quote-span-regression/case-pattern.sh
. "$AGENTS_DIR/tests/fix-1569-quote-span-regression/case-pattern.sh"
run_case_pattern_cases

# shellcheck source=tests/fix-1569-quote-span-regression/fold-ok-gate.sh
. "$AGENTS_DIR/tests/fix-1569-quote-span-regression/fold-ok-gate.sh"
run_fold_ok_gate_cases

# shellcheck source=tests/fix-1569-quote-span-regression/canary.sh
. "$AGENTS_DIR/tests/fix-1569-quote-span-regression/canary.sh"
run_canary_cases

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
