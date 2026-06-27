#!/bin/bash
# tests/fix-1109-heredoc-plans-dir.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/universal-target-allow.js, hooks/enforce-worktree/shared-cmd-utils.js, hooks/lib/bash-write-targets/cp-mv.js, hooks/lib/bash-write-targets/redirect.js
# Tags: worktree, enforce, hook, heredoc, plans-dir, shell-expansion, fix-1109, fix-983, fix-1025, fix-1040, scope:issue-specific
#
# Unit + integration tests for issue #1109 (+ #983/#1025/#1040): enforce-worktree
# must ALLOW heredoc writes whose redirect/mv targets all resolve under
# WORKFLOW_PLANS_DIR, even when the heredoc BODY contains ; / && / || sequencing.
#
# Two source fixes are under test:
#   Gap 2 (resolver): areAllBashTargetsUnderPlansDir's isUnder closure must run
#     expandStaticShellTokens; extractCpMvDestination must resolve $VAR via
#     process.env constrained to plans-dir (tryResolveEnvUnderPlansDir).
#   Gap 1 (heredoc parallel allow): a new hasCommandSequencingOutsideHeredoc()
#     helper + a parallel plans-dir allow path in bash-write-scope.js /
#     universal-target-allow.js fire only when sequencing lives ONLY inside the
#     heredoc body AND every target is under plans-dir.
#
# RED before the fix, GREEN after. Cases that pin existing behavior (regression
# guards) are GREEN both before and after.
#
# IMPORTANT — heredoc form. stripHeredocBody (hooks/lib/strip-quoted-args.js)
# only strips bodies for the `cat <<TAG ... > target` shape (redirect AFTER the
# opener). The `cat > target <<TAG` shape is NOT stripped, so its body-internal
# `;` would still trip sequencing. The fix therefore allows the canonical
# `cat <<'EOF' > "$WORKFLOW_PLANS_DIR/x"` form; all heredoc cases below use it.
#
# L3 gap (what this test does NOT catch):
# - Hook registration: these tests call enforce-worktree.js directly as a Node.js process,
#   not via the real Claude Code PreToolUse hook chain. L3 would verify the hook actually
#   fires and returns the correct verdict when claude -p executes a Bash command from the
#   main worktree.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
BWS="${_AGENTS_DIR_NODE}/hooks/enforce-worktree/bash-write-scope.js"
CPMV="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-targets/cp-mv.js"
SCU="${_AGENTS_DIR_NODE}/hooks/enforce-worktree/shared-cmd-utils.js"
SHB="${_AGENTS_DIR_NODE}/hooks/lib/strip-quoted-args.js"
HOOK="${_AGENTS_DIR_NODE}/hooks/enforce-worktree.js"

# Deterministic plans-dir: a real temp directory (getWorkflowPlansDir requires an
# absolute path). Node form normalized for Windows require()/path.resolve.
TMPPLANS="$(mktemp -d)"
if command -v cygpath >/dev/null 2>&1; then
    TMPPLANS_NODE="$(cygpath -m "$TMPPLANS")"
else
    TMPPLANS_NODE="$TMPPLANS"
fi

# Main worktree path (CWD for git-rooted integration cases). First porcelain entry.
MAIN_WT="$(git worktree list --porcelain 2>/dev/null | awk '/^worktree /{sub(/^worktree[[:space:]]+/, ""); print; exit}')"
if [ -n "$MAIN_WT" ] && command -v cygpath >/dev/null 2>&1; then
    MAIN_WT="$(cygpath -u "$MAIN_WT" 2>/dev/null || echo "$MAIN_WT")"
fi

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

cleanup() { rm -rf "$TMPPLANS" 2>/dev/null || true; }
trap cleanup EXIT

assert_eq() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Node helpers — call exported module functions with WORKFLOW_PLANS_DIR + extras
# set in the child's environment. MSYS_NO_PATHCONV=1 stops Git-Bash from
# mangling the POSIX-looking paths passed as values.
# ─────────────────────────────────────────────────────────────────────────────

# areAllBashTargetsUnderPlansDir(targetsJson) — targetsJson is a JSON array string.
call_under_plans() {
    local targets_json="$1"
    MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" run_with_timeout 30 node -e "
      try {
        const m = require('$BWS');
        const t = JSON.parse(process.argv[1]);
        console.log(JSON.stringify(m.areAllBashTargetsUnderPlansDir(t)));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$targets_json" 2>/dev/null
}

# extractCpMvDestination(cmd) with PLANS_DIR set as an env var (so $PLANS_DIR in
# the command resolves via process.env, constrained to plans-dir).
call_cpmv() {
    local cmd="$1"
    MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" PLANS_DIR="$TMPPLANS_NODE" run_with_timeout 30 node -e "
      try {
        const m = require('$CPMV');
        console.log(JSON.stringify(m.extractCpMvDestination(process.argv[1])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$cmd" 2>/dev/null
}

# hasCommandSequencingOutsideHeredoc(cmd) — new helper from shared-cmd-utils.js.
# Falls back to a friendly sentinel string if the export is missing (RED before fix).
call_seq_outside_heredoc() {
    local cmd="$1"
    MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" run_with_timeout 30 node -e "
      try {
        const m = require('$SCU');
        if (typeof m.hasCommandSequencingOutsideHeredoc !== 'function') {
          console.log('MISSING_EXPORT');
        } else {
          console.log(JSON.stringify(m.hasCommandSequencingOutsideHeredoc(process.argv[1])));
        }
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$cmd" 2>/dev/null
}

# Run the enforce-worktree.js hook with a Bash command payload from a given CWD.
# Echoes the hook's JSON stdout ({} = allow, {"decision":"block",...} = block).
run_hook() {
    local cwd="$1" cmd="$2"
    local payload
    payload="$(WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" node -e '
      const o = { tool_name: "Bash", tool_input: { command: process.argv[1] }, session_id: "test-1109" };
      process.stdout.write(JSON.stringify(o));
    ' -- "$cmd")"
    printf '%s' "$payload" | (
        cd "$cwd" || exit 1
        MSYS_NO_PATHCONV=1 ENFORCE_WORKTREE=on WORKFLOW_PLANS_DIR="$TMPPLANS_NODE" \
            CLAUDE_SESSION_ID=test-1109 run_with_timeout 30 node "$HOOK" 2>/dev/null
    )
}

is_allow()  { [ "$1" = "{}" ]; }
is_block()  { echo "$1" | grep -q '"decision":"block"'; }

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — areAllBashTargetsUnderPlansDir resolver (Gap 2 / #983)
# RED before fix: isUnder does not call expandStaticShellTokens, so raw
# $WORKFLOW_PLANS_DIR / $HOME tokens fail to resolve → false.
# ─────────────────────────────────────────────────────────────────────────────

test_case1_wpd_token() {
    # Case 1: raw "$WORKFLOW_PLANS_DIR/foo.tmp" token → true (resolver expands it).
    # RED before fix (returns false), GREEN after.
    assert_eq 'C1: ["$WORKFLOW_PLANS_DIR/foo.tmp"] → true' \
        "$(call_under_plans '["$WORKFLOW_PLANS_DIR/foo.tmp"]')" 'true'
}

test_case2_home_token() {
    # Case 2: "$HOME/.workflow-plans/foo.tmp" with WORKFLOW_PLANS_DIR set to the
    # default $HOME/.workflow-plans. We compute the path under HOME and set
    # WORKFLOW_PLANS_DIR to it, then assert the raw $HOME token resolves under it.
    # RED before fix (no expandStaticShellTokens), GREEN after.
    local home_node wpd
    # MSYS_NO_PATHCONV=1 prevents Git Bash from mangling /g in the regex literal.
    home_node="$(MSYS_NO_PATHCONV=1 node -e 'process.stdout.write(require("os").homedir().replace(/\\/g,"/"))')"
    wpd="$home_node/.workflow-plans"
    local got
    got="$(MSYS_NO_PATHCONV=1 WORKFLOW_PLANS_DIR="$wpd" run_with_timeout 30 node -e "
      try {
        const m = require('$BWS');
        console.log(JSON.stringify(m.areAllBashTargetsUnderPlansDir(['\$HOME/.workflow-plans/foo.tmp'])));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " 2>/dev/null)"
    assert_eq 'C2: ["$HOME/.workflow-plans/foo.tmp"] under default plans-dir → true' \
        "$got" 'true'
}

test_case3_unknown_var() {
    # Case 3: "$UNKNOWN_VAR/foo" → false (fail-closed: unresolvable env).
    # GREEN before and after (resolver fails closed both ways).
    assert_eq 'C3: ["$UNKNOWN_VAR_1109/foo"] → false (fail-closed)' \
        "$(call_under_plans '["$UNKNOWN_VAR_1109/foo"]')" 'false'
}

test_case4_external_abs() {
    # Case 4: "/tmp/external" absolute path outside plans-dir → false.
    # GREEN before and after (regression pin: external stays blocked).
    assert_eq 'C4: ["/tmp/external"] → false (external stays out)' \
        "$(call_under_plans '["/tmp/external"]')" 'false'
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 1 — extractCpMvDestination $VAR resolution (Gap 2 / #1025)
# RED before fix: cp-mv does not consult process.env, so $PLANS_DIR source token
# is unresolvable → null (parseFailure) → fail-closed.
# ─────────────────────────────────────────────────────────────────────────────

test_case5_mv_plans_to_plans() {
    # Case 5: mv "$PLANS_DIR/a.tmp" "$PLANS_DIR/a" → dest = resolved plans path (non-null).
    # RED before fix (null), GREEN after (resolves to TMPPLANS_NODE/a).
    assert_eq 'C5: mv $PLANS_DIR→$PLANS_DIR dest resolves' \
        "$(call_cpmv 'mv "$PLANS_DIR/a.tmp" "$PLANS_DIR/a"')" \
        "\"$TMPPLANS_NODE/a\""
}

test_case6_mv_plans_to_etc() {
    # Case 6: mv "$PLANS_DIR/a.tmp" /etc/passwd → dest = /etc/passwd.
    # Source resolves (under plans-dir) so cp-mv no longer fails closed; the
    # external dest is returned and later rejected by areAllBashTargetsUnderPlansDir.
    # RED before fix (null because source unresolvable), GREEN after (/etc/passwd).
    assert_eq 'C6: mv $PLANS_DIR→/etc/passwd dest = /etc/passwd (external pin)' \
        "$(call_cpmv 'mv "$PLANS_DIR/a.tmp" /etc/passwd')" \
        '"/etc/passwd"'
}

test_case7_mv_unresolved() {
    # Case 7: mv "$UNRESOLVED/a.tmp" "$UNRESOLVED/a" → null (fail-closed).
    # GREEN before and after (unknown env stays fail-closed).
    assert_eq 'C7: mv $UNRESOLVED→$UNRESOLVED → null' \
        "$(call_cpmv 'mv "$UNRESOLVED_1109/a.tmp" "$UNRESOLVED_1109/a"')" 'null'
}

test_case8_mv_singlequoted() {
    # Case 8: single-quoted 'mv "$PLANS_DIR/a.tmp" "$PLANS_DIR/a"' → null.
    # Single quotes are never expanded by POSIX; cp-mv fails closed. GREEN both ways.
    assert_eq 'C8: mv with single-quoted $PLANS_DIR → null (no expansion)' \
        "$(call_cpmv "mv '\$PLANS_DIR/a.tmp' '\$PLANS_DIR/a'")" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — hasCommandSequencingOutsideHeredoc (Gap 1 / new helper)
# RED before fix: function does not exist (MISSING_EXPORT).
# ─────────────────────────────────────────────────────────────────────────────

test_case9_body_only_seq() {
    # Case 9: cat <<'EOF' > x \n a; b \n EOF — semicolon only inside heredoc body
    # → false (no real sequencing outside the heredoc).
    assert_eq 'C9: heredoc body-only `;` → false' \
        "$(call_seq_outside_heredoc "cat <<'EOF' > x"$'\n'"a; b"$'\n'"EOF"$'\n')" 'false'
}

test_case10_real_seq() {
    # Case 10: echo a && echo b — real sequencing, no heredoc → true.
    assert_eq 'C10: `echo a && echo b` → true (real sequencing)' \
        "$(call_seq_outside_heredoc 'echo a && echo b')" 'true'
}

test_case11_quoted_semicolon() {
    # Case 11: echo "hello; world" — semicolon inside a quoted string → false
    # (stripQuotedArgs removes the quoted body before the sequencing test).
    assert_eq 'C11: `echo "hello; world"` → false (quoted ;)' \
        "$(call_seq_outside_heredoc 'echo "hello; world"')" 'false'
}

test_case12_dollar_sub_body() {
    # Case 12: unquoted heredoc opener with $(...) in the body → stripHeredocBody
    # refuses to strip (shell would execute the substitution), so the body-internal
    # `;` is still visible → true (fail-safe).
    assert_eq 'C12: unquoted opener + $() body → true (not stripped, fail-safe)' \
        "$(call_seq_outside_heredoc "cat <<EOF > x"$'\n'"\$(echo hi); bar"$'\n'"EOF"$'\n')" 'true'
}

# ─────────────────────────────────────────────────────────────────────────────
# Step 2 — integration: enforce-worktree.js hook (Gap 1)
# ─────────────────────────────────────────────────────────────────────────────

test_case13_integration_allow() {
    # Case 13: heredoc body-only sequencing, target under plans-dir, run from the
    # MAIN worktree → ALLOW ({}). RED before fix (block), GREEN after.
    if [ -z "$MAIN_WT" ] || [ ! -d "$MAIN_WT" ]; then
        pass "C13: skipped (main worktree path not resolvable)"
        return
    fi
    local cmd got
    cmd="cat <<'EOF' > \"\$WORKFLOW_PLANS_DIR/x.md\""$'\n'"a; b && c"$'\n'"EOF"$'\n'
    got="$(run_hook "$MAIN_WT" "$cmd")"
    if is_allow "$got"; then
        pass "C13: heredoc body-only seq + plans-dir target from main worktree → allow"
    else
        fail "C13: expected allow '{}', got '$got'"
    fi
}

test_case14_integration_real_seq_block() {
    # Case 14: real sequencing AFTER the heredoc delimiter (`; touch README.md`)
    # → BLOCK (heredoc-strip does not hide the trailing real sequence; README.md
    # is an in-scope write). BLOCK before and after — regression pin for C1.
    if [ -z "$MAIN_WT" ] || [ ! -d "$MAIN_WT" ]; then
        pass "C14: skipped (main worktree path not resolvable)"
        return
    fi
    local cmd got
    cmd="cat <<EOF > \"\$WORKFLOW_PLANS_DIR/x.md\""$'\n'"foo"$'\n'"EOF"$'\n'"; touch README.md"
    got="$(run_hook "$MAIN_WT" "$cmd")"
    if is_block "$got"; then
        pass "C14: real sequencing after delimiter → block"
    else
        fail "C14: expected block, got '$got'"
    fi
}

test_case15_integration_external_block() {
    # Case 15: heredoc body-only sequencing BUT target outside plans-dir
    # (/tmp/external.md) → BLOCK. The plans-dir constraint must not be bypassed
    # by the heredoc relaxation. BLOCK before and after — regression pin for C1.
    if [ -z "$MAIN_WT" ] || [ ! -d "$MAIN_WT" ]; then
        pass "C15: skipped (main worktree path not resolvable)"
        return
    fi
    local cmd got
    cmd="cat <<'EOF' > /tmp/external-1109.md"$'\n'"a;"$'\n'"EOF"$'\n'
    got="$(run_hook "$MAIN_WT" "$cmd")"
    if is_block "$got"; then
        pass "C15: heredoc body-only seq + external target → block"
    else
        fail "C15: expected block, got '$got'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# C3 coverage — exercise the bash-write-scope.js parallel allow path directly,
# bypassing universal-target-allow.js (which intercepts first on git-rooted CWD).
# ─────────────────────────────────────────────────────────────────────────────

test_case16_nongit_cwd_allow() {
    # Case 16: run the hook from a NON-git CWD. On non-git CWD universal-target-
    # allow.js abstains (sessionRoots empty / repoRoot null), so the
    # bash-write-scope.js parallel plans-dir allow (Step 2a) is the deciding path.
    # → ALLOW. RED before fix (block: "cannot determine repo root"), GREEN after.
    local nongit got cmd
    nongit="$(mktemp -d)"
    cmd="cat <<'EOF' > \"\$WORKFLOW_PLANS_DIR/x.md\""$'\n'"a; b && c"$'\n'"EOF"$'\n'
    got="$(run_hook "$nongit" "$cmd")"
    rmdir "$nongit" 2>/dev/null || true
    if is_allow "$got"; then
        pass "C16: non-git CWD heredoc plans-dir write → allow (2a parallel path)"
    else
        fail "C16: expected allow '{}', got '$got'"
    fi
}

# Cases 17/18 validate the decision COMPONENTS of the Step 2a parallel allow
# directly against bash-write-scope.js, since the 2a allow itself is inlined in
# enforce-worktree.js rather than exposed as a single scope-decision entry point.
# The two predicates that gate 2a are:
#   - hasCommandSequencingOutsideHeredoc(cmd) === false  (sequencing only in body)
#   - areAllBashTargetsUnderPlansDir(targets) === true    (all targets under plans-dir)
# NOTE: if the fix later exposes a single scope-decision entry (e.g.
# checkBashWriteScope) from bash-write-scope.js, prefer asserting its verdict
# directly. Until then, these assert the conjunction the inline path evaluates.

test_case17_parallel_allow_components_true() {
    # Case 17: heredoc body-only sequencing + all targets under plans-dir →
    # both gating predicates satisfied → 2a would ALLOW.
    # RED before fix (seqOutsideHeredoc MISSING_EXPORT; under-plans false for raw token).
    local seq under
    seq="$(call_seq_outside_heredoc "cat <<'EOF' > \"\$WORKFLOW_PLANS_DIR/x.md\""$'\n'"a; b"$'\n'"EOF"$'\n')"
    under="$(call_under_plans '["$WORKFLOW_PLANS_DIR/x.md"]')"
    if [ "$seq" = "false" ] && [ "$under" = "true" ]; then
        pass "C17: 2a components (seqOutsideHeredoc=false, underPlans=true) → allow"
    else
        fail "C17: expected seqOutsideHeredoc=false & underPlans=true, got seq='$seq' under='$under'"
    fi
}

test_case18_parallel_allow_external_denied() {
    # Case 18: heredoc body-only sequencing BUT target outside plans-dir →
    # underPlans=false → 2a must NOT fire (validates C2: repoRoot does not bypass
    # the plans-dir check). seqOutsideHeredoc is false, but areAllBashTargetsUnderPlansDir
    # is false, so the conjunction is false → not allowed.
    # RED before fix on the seq predicate (MISSING_EXPORT); the under-plans
    # predicate is GREEN both ways (external stays out).
    local seq under
    seq="$(call_seq_outside_heredoc "cat <<'EOF' > /tmp/external-1109.md"$'\n'"a;"$'\n'"EOF"$'\n')"
    under="$(call_under_plans '["/tmp/external-1109.md"]')"
    # Expected post-fix: seq=false, under=false → conjunction false → 2a does not allow.
    if [ "$under" = "false" ] && [ "$seq" = "false" ]; then
        pass "C18: 2a denied for external target (underPlans=false) — C2 invariant"
    else
        fail "C18: expected underPlans=false & seqOutsideHeredoc=false, got seq='$seq' under='$under'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_case1_wpd_token
test_case2_home_token
test_case3_unknown_var
test_case4_external_abs
test_case5_mv_plans_to_plans
test_case6_mv_plans_to_etc
test_case7_mv_unresolved
test_case8_mv_singlequoted
test_case9_body_only_seq
test_case10_real_seq
test_case11_quoted_semicolon
test_case12_dollar_sub_body
test_case13_integration_allow
test_case14_integration_real_seq_block
test_case15_integration_external_block
test_case16_nongit_cwd_allow
test_case17_parallel_allow_components_true
test_case18_parallel_allow_external_denied

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ "$FAIL" -eq 0 ]; then exit 0; else exit 1; fi
