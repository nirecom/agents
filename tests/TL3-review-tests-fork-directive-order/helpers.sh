# shellcheck shell=bash
# Tests: skills/review-tests/SKILL.md, rules/shell-commands.md
# Tags: rules, prompt, dispatch, fork, claude-e2e, TL3, scope:issue-specific
#
# Helpers for TL3-review-tests-fork-directive-order. Sourced by
# ../TL3-review-tests-fork-directive-order.sh (assumes AGENTS_DIR, pass()/fail()/skip() defined).

run_with_timeout() {
    local secs="$1"; shift
    "$AGENTS_DIR/bin/run-with-timeout.sh" "$secs" "$@"
}

node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# The exact same triple-predicate as directive_lineno() in
# tests/feature-2140-fork-dispatch-shell-commands.sh (CPR-SSOT would share the function, but
# that file defines it inline rather than in a sourced lib -- duplicated here at the predicate
# level only, not the fixture/assertion level).
rfdo_extract_directive() { # <skill-file> -> the directive line's text, or empty
    local f="$1" hit
    [ -f "$f" ] || return 0
    hit="$(grep -F -- 'rules/shell-commands.md' "$f" 2>/dev/null \
        | grep -F -- 'Read' \
        | grep -Ei -- 'before (the )?(first )?Bash command' \
        | grep -Ei -- 'before (writing|you write|it writes|any (file )?write|creating or writing)' \
        | head -n1)"
    printf '%s' "$hit"
}

# rfdo_build_repo <repo-dir> -- fixture project carrying only a copy of rules/shell-commands.md
# at the same relative path the directive names, so the Read tool can resolve it. No hooks
# registered (rules/test/claude-e2e.md: minimal settings.json, never the global one).
rfdo_build_repo() {
    local repo="$1"
    mkdir -p "$repo/rules" "$repo/.claude"
    git -C "$repo" init -q 2>/dev/null || { mkdir -p "$repo"; git -C "$repo" init -q; }
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    cp "$AGENTS_DIR/rules/shell-commands.md" "$repo/rules/shell-commands.md"
    printf '%s\n' '{ "hooks": {} }' > "$repo/.claude/settings.json"
}

# rfdo_run_claude <repo-dir> <session-id> <prompt> <out-file> -- one claude -p run.
# Echoes the exit code; stdout (the JSON transcript) lands in <out-file>.
rfdo_run_claude() {
    local repo="$1" sid="$2" prompt="$3" out="$4" rc=0
    (
        cd "$repo" || exit 90
        unset CLAUDECODE
        unset CLAUDE_SESSION_ID
        unset CLAUDE_CODE_SESSION_ID
        run_with_timeout 180 claude -p "$prompt" \
            --session-id "$sid" \
            --setting-sources project \
            --dangerously-skip-permissions \
            --output-format json \
            > "$out" 2>/dev/null
    ) || rc=$?
    echo "$rc"
}

# rfdo_tool_order <response-file> -- parses the ordered assistant tool_use sequence and prints
# "READ_IDX=<n> BASH_IDX=<n> TOTAL=<n>" (index -1 means "not seen"). Logic: tool-order.js.
rfdo_tool_order() {
    local out="$1"
    node "$(node_path "$(dirname "${BASH_SOURCE[0]}")/tool-order.js")" "$(node_path "$out")" 2>/dev/null
}
