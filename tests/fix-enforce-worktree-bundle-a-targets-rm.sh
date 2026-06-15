#!/bin/bash
# tests/fix-enforce-worktree-bundle-a-targets-rm.sh
# Tests: hooks/lib/bash-write-targets.js (extractRmTargets)
# Tags: worktree, enforce, hook, rm, bash-write-targets

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-targets.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

assert_fn_result() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

call_rm() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractRmTargets(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# extractRmTargets — quote-aware tokenizer (issue #573)
# ─────────────────────────────────────────────────────────────────────────────
#
# After the quote-aware tokenizer lands in hooks/lib/bash-write-targets.js,
# extractRmTargets must handle double- and single-quoted paths instead of
# fail-closing on ANY quote character.
# Accepted constraints (must still fail-closed):
#   - "a;b.md"  — outer regex truncates at `;` before the tokenizer sees it
#   - "foo\"bar.md" — backslash escape inside double quotes is not supported

test_rm_targets() {
    # Basic non-repo path (unquoted) — already supported, regression guard.
    assert_fn_result "rm: basic non-repo path" \
        "$(call_rm 'rm /non/repo/path')" '["/non/repo/path"]'

    # Double-quoted path with space — must tokenize as one path.
    assert_fn_result "rm: double-quoted path with space" \
        "$(call_rm 'rm "/non/repo/path with spaces"')" \
        '["/non/repo/path with spaces"]'

    # Single-quoted path — must tokenize as one path.
    assert_fn_result "rm: single-quoted path" \
        "$(call_rm "rm '/non/repo/path'")" \
        '["/non/repo/path"]'

    # $VAR token — unresolvable → null (fail-closed).
    assert_fn_result "rm: \$VAR token → null" \
        "$(call_rm 'rm $VAR')" 'null'

    # Empty quote rm "" → [] (empty token filtered out, no positionals).
    assert_fn_result 'rm: empty quote "" → []' \
        "$(call_rm 'rm ""')" '[]'

    # Accepted constraint: rm "a;b.md" — outer regex truncates at `;` so
    # the tokenizer sees an unbalanced quote → null (fail-closed).
    assert_fn_result 'rm: "a;b.md" → null (outer regex truncates at ;)' \
        "$(call_rm 'rm "a;b.md"')" 'null'

    # Empty string input guard.
    assert_fn_result "rm: empty string → null" \
        "$(call_rm '')" 'null'

    # Command substitution $(...) → null (isUnresolvableToken).
    assert_fn_result 'rm: $(echo /tmp/foo) → null' \
        "$(call_rm 'rm $(echo /tmp/foo)')" 'null'

    # Backtick substitution → null (isUnresolvableToken).
    assert_fn_result 'rm: backtick → null' \
        "$(call_rm 'rm `echo /tmp/foo`')" 'null'

    # Double-dash end-of-flags; positional after -- extracted.
    assert_fn_result 'rm: -- /tmp/path → ["/tmp/path"]' \
        "$(call_rm 'rm -- /tmp/path')" '["/tmp/path"]'

    # Mixed unquoted + quoted targets.
    assert_fn_result 'rm: mixed unquoted+quoted → ["/tmp/a", "/tmp/b c"]' \
        "$(call_rm 'rm /tmp/a "/tmp/b c"')" '["/tmp/a","/tmp/b c"]'

    # Command substitution inside double-quotes → null ($ makes token unresolvable).
    assert_fn_result 'rm: "$(pwd)/file" → null' \
        "$(call_rm 'rm "$(pwd)/file"')" 'null'

    # $HOME inside double-quotes → null ($HOME token unresolvable).
    assert_fn_result 'rm: "$HOME/.config/foo" → null' \
        "$(call_rm 'rm "$HOME/.config/foo"')" 'null'

    # Double-dash end-of-flags combined with quoted path.
    assert_fn_result 'rm: -- "path with spaces" → ["path with spaces"]' \
        "$(call_rm 'rm -- "path with spaces"')" '["path with spaces"]'
}

test_rm_idempotency() {
    local first second
    first=$(call_rm 'rm /tmp/a "/tmp/b c"')
    second=$(call_rm 'rm /tmp/a "/tmp/b c"')
    assert_fn_result "rm: idempotency (pure function)" "$second" "$first"
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_rm_targets
test_rm_idempotency

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
