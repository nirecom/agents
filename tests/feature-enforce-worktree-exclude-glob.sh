#!/bin/bash
# tests/feature-enforce-worktree-exclude-glob.sh
# Tests: hooks/lib/glob-match.js, hooks/lib/glob-match.js.
# Tags: worktree, enforce, hook, git, pre-commit
#
# Unit tests for hooks/lib/glob-match.js.
# Drives the module via `node -e` to verify pattern parsing, glob translation,
# and bulk matching helpers used by the pre-commit ENFORCE_WORKTREE_EXCLUDE
# bypass path.
#
# Skips gracefully when hooks/lib/glob-match.js is not yet implemented.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
GLOB_JS="${_AGENTS_DIR_NODE}/hooks/lib/glob-match.js"

if [ ! -f "$GLOB_JS" ]; then
    echo "SKIP: hooks/lib/glob-match.js not yet implemented"
    exit 0
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
        "$@"
    fi
}

# Run pathMatchesGlob(filePath, pattern) and echo "true"/"false"/"ERROR:..."
glob_match() {
    local file_path="$1"
    local pattern="$2"
    run_with_timeout 30 node -e "
      try {
        const m = require('$GLOB_JS');
        const r = m.pathMatchesGlob(process.argv[1], process.argv[2]);
        console.log(r ? 'true' : 'false');
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$file_path" "$pattern" 2>/dev/null
}

# Run parseExcludePatterns(input); print JSON array.
parse_patterns() {
    local input="$1"
    run_with_timeout 30 node -e "
      try {
        const m = require('$GLOB_JS');
        const r = m.parseExcludePatterns(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$input" 2>/dev/null
}

# Run matchesAnyExcludePattern(filePath, patternsJsonArray); echo "true"/"false".
matches_any() {
    local file_path="$1"
    local patterns_json="$2"
    run_with_timeout 30 node -e "
      try {
        const m = require('$GLOB_JS');
        const patterns = JSON.parse(process.argv[2]);
        const r = m.matchesAnyExcludePattern(process.argv[1], patterns);
        console.log(r ? 'true' : 'false');
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$file_path" "$patterns_json" 2>/dev/null
}

assert_match() {
    local desc="$1" file="$2" pattern="$3" expected="$4"
    local got; got="$(glob_match "$file" "$pattern")"
    if [ "$got" = "$expected" ]; then
        pass "$desc (file='$file' pat='$pattern' -> $expected)"
    else
        fail "$desc: expected '$expected', got '$got' (file='$file' pat='$pattern')"
    fi
}

assert_parse() {
    local desc="$1" input="$2" expected_json="$3"
    local got; got="$(parse_patterns "$input")"
    if [ "$got" = "$expected_json" ]; then
        pass "$desc -> $expected_json"
    else
        fail "$desc: expected '$expected_json', got '$got'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Normal: pathMatchesGlob basic semantics
# ─────────────────────────────────────────────────────────────────────────────

test_normal_globstar_matches_subdirs() {
    assert_match "**/ matches files in subdirectory" \
        "docs/sub/a.md" "**/*.md" "true"
    assert_match "** matches root-level file too" \
        "a.md" "**/*.md" "true"
    assert_match "**/ matches deep nested path" \
        "a/b/c/d/e.md" "**/*.md" "true"
}

test_normal_single_star_one_segment() {
    assert_match "*/x matches a/x" \
        "a/x" "*/x" "true"
    assert_match "*/x matches b/x" \
        "b/x" "*/x" "true"
}

test_normal_literal_match() {
    assert_match "literal exact match" \
        "docs/todo.md" "docs/todo.md" "true"
    assert_match "literal mismatch" \
        "docs/foo.md" "docs/todo.md" "false"
}

# ─────────────────────────────────────────────────────────────────────────────
# Normal: parseExcludePatterns
# ─────────────────────────────────────────────────────────────────────────────

test_parse_simple_split() {
    assert_parse "splits on semicolons" \
        "a;b;c" '["a","b","c"]'
}

test_parse_trims_whitespace() {
    assert_parse "trims whitespace around entries" \
        " a ; b ;  c  " '["a","b","c"]'
}

test_parse_drops_empty_entries() {
    assert_parse "drops empty entries between separators" \
        "a;;b;;;c" '["a","b","c"]'
}

test_parse_empty_string_input() {
    # "".split(";") yields [""] which must be filtered out.
    assert_parse "empty string input -> []" \
        "" '[]'
}

test_parse_only_separators() {
    assert_parse "string of only separators -> []" \
        ";;;" '[]'
}

# ─────────────────────────────────────────────────────────────────────────────
# Negative: single * does NOT cross path separators
# ─────────────────────────────────────────────────────────────────────────────

test_negative_single_star_not_cross_separator() {
    assert_match "docs/*.md does NOT match docs/sub/x.md" \
        "docs/sub/x.md" "docs/*.md" "false"
    assert_match "*.md does NOT match a/b.md" \
        "a/b.md" "*.md" "false"
}

# ─────────────────────────────────────────────────────────────────────────────
# Edge cases
# ─────────────────────────────────────────────────────────────────────────────

test_edge_empty_pattern_never_matches() {
    assert_match "empty pattern never matches arbitrary file" \
        "docs/todo.md" "" "false"
    assert_match "empty pattern does not match empty path" \
        "" "" "false"
}

test_edge_root_level_file() {
    assert_match "root-level file, literal" \
        "README.md" "README.md" "true"
    assert_match "root-level file via *.md" \
        "README.md" "*.md" "true"
}

test_edge_path_with_spaces() {
    assert_match "path with spaces matches literal" \
        "my docs/to do.md" "my docs/to do.md" "true"
    assert_match "path with spaces matches **/*.md" \
        "my docs/to do.md" "**/*.md" "true"
}

test_edge_dotfiles() {
    assert_match "dotfile matches via *.env literal" \
        ".env" ".env" "true"
    # Dotfile in subdir.
    assert_match "dotfile in subdir matches **/*" \
        "sub/.gitignore" "**/*" "true"
}

# ─────────────────────────────────────────────────────────────────────────────
# Security: regex meta chars treated literally
# ─────────────────────────────────────────────────────────────────────────────

test_security_regex_meta_chars_literal() {
    # '+' would mean "one or more" in regex; literal here.
    assert_match "+ literal: matches a+b literally" \
        "a+b" "a+b" "true"
    assert_match "+ literal: does NOT match aab" \
        "aab" "a+b" "false"

    # '.' would mean "any char" in regex; literal here.
    assert_match ". literal: a.b matches a.b" \
        "a.b" "a.b" "true"
    assert_match ". literal: a.b does NOT match aXb" \
        "aXb" "a.b" "false"

    # Parens / brackets must be escaped when translating to regex.
    assert_match "() literal" \
        "x(y)z" "x(y)z" "true"
    assert_match "[] literal" \
        "x[y]z" "x[y]z" "true"
}

test_security_repeated_globstar_no_catastrophic_backtracking() {
    # Use timeout to detect catastrophic backtracking. If the implementation
    # naively chains many `.*` greedy groups, this can blow up. Path is
    # crafted so naive backtracking would explode trying to match the
    # trailing 'X' that is not present.
    local long_path="a/b/c/d/e/f/g/h/i/j/k/l/m/n/o/p/q/r/s/t.md"
    local pattern="**/**/**/**/**/**/*.mdX"
    # Wrap with our own 10s timeout for the node call.
    local got
    got="$(run_with_timeout 10 node -e "
      try {
        const m = require('$GLOB_JS');
        const r = m.pathMatchesGlob(process.argv[1], process.argv[2]);
        console.log(r ? 'true' : 'false');
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " -- "$long_path" "$pattern" 2>/dev/null)"
    if [ "$got" = "false" ]; then
        pass "repeated ** does not cause catastrophic backtracking"
    else
        fail "repeated **: expected 'false' within 10s timeout, got '$got'"
    fi
}

# Run pathMatchesGlob and echo "<result> <elapsed-ms>"; pattern/target are built
# inside node so a multi-kilobyte pathological string never crosses the shell.
# Args: file-expr, pattern-expr — both are JS expressions eval'd by node.
glob_match_timed() {
    local file_expr="$1" pattern_expr="$2"
    run_with_timeout 30 node -e "
      try {
        const m = require('$GLOB_JS');
        const file = ($file_expr);
        const pattern = ($pattern_expr);
        const t0 = Date.now();
        const r = m.pathMatchesGlob(file, pattern);
        console.log((r ? 'true' : 'false') + ' ' + (Date.now() - t0));
      } catch (e) {
        console.log('ERROR: ' + e.message);
      }
    " 2>/dev/null
}

test_security_pattern_complexity_cap_stops_redos() {
    # ReDoS (CWE-1333) regression guard. A pattern alternating wildcards with
    # literals — "C:/git" + "**a" x20 + "z" — translates to 20 chained greedy
    # `.*` groups, each followed by a literal. Against a target that shares the
    # prefix but never supplies the trailing 'z', the engine must try every way
    # of splitting the run of 'a's between those groups: exponential in the
    # repeat count, and unreachable-in-practice at 20. The value is
    # user-controlled (CODE_LANG_EXCLUDE / ENFORCE_WORKTREE_EXCLUDE arrive from
    # .env or the environment), so the hang is reachable, not theoretical.
    #
    # The fix caps pattern complexity and treats an over-cap pattern as
    # NON-MATCHING. That direction matters: "no match" means the exclusion does
    # not apply and the language / worktree check still RUNS. A cap that instead
    # returned true would convert a malformed pattern into a silent bypass of
    # the very check the pattern gates.
    #
    # Both halves are asserted together. The wall-clock bound is what proves the
    # cap actually engaged: 'false' alone is also what a still-vulnerable build
    # produces — eventually. 2000ms is far above a capped run (sub-millisecond:
    # the pattern is rejected before any regex is built) and far below the
    # unbounded blow-up, so the threshold is not timing-sensitive on a loaded
    # machine.
    local out result elapsed
    out="$(glob_match_timed "'C:/git' + 'a'.repeat(60)" "'C:/git' + '**a'.repeat(20) + 'z'")"
    result="${out%% *}"
    elapsed="${out##* }"
    if [ "$result" != "false" ]; then
        fail "ReDoS cap: pathological pattern expected 'false' (non-matching → check still runs), got '$out'"
    elif ! [ "$elapsed" -lt 2000 ] 2>/dev/null; then
        fail "ReDoS cap: returned false but took ${elapsed}ms (>=2000ms) — complexity cap did not engage"
    else
        pass "ReDoS cap: 20x '**a' pattern returns false in ${elapsed}ms (no catastrophic backtracking)"
    fi

    # Over-long pattern: the second half of the cap (length, not wildcard count).
    # 4 wildcards only, so the wildcard limit cannot be what rejects it.
    out="$(glob_match_timed "'C:/git/x.md'" "'C:/git/' + 'a'.repeat(4000) + '**/**/*.md'")"
    result="${out%% *}"
    if [ "$result" = "false" ]; then
        pass "ReDoS cap: over-length pattern (>1KB) returns false"
    else
        fail "ReDoS cap: over-length pattern expected 'false', got '$out'"
    fi
}

test_security_complexity_cap_spares_realistic_globs() {
    # Counterpart to the cap test: the cap must not swallow ordinary patterns.
    # A cap that rejected real-world globs would silently stop excluding the
    # paths users configured — the same silent-bypass failure mode, arrived at
    # from the other side. These mirror the shapes actually written in
    # ENFORCE_WORKTREE_EXCLUDE / CODE_LANG_EXCLUDE.
    assert_match "cap spares Windows worktree-root glob" \
        'C:\git\worktrees\task\agents\hooks\lib\x.js' 'C:\git\worktrees\**' "true"
    assert_match "cap spares ordinary **/*.md" \
        "docs/sub/a.md" "**/*.md" "true"
    assert_match "cap spares multi-wildcard entry" \
        "src/a/b/test.spec.js" "src/**/*.spec.js" "true"

    # POSIX absolute worktree root — the shape WORKTREE_BASE_DIR takes on
    # macOS/Linux. Routed through glob_match_timed (which builds both strings
    # inside node) rather than assert_match: MSYS2 rewrites a leading-'/' argv
    # entry into a Windows path when handing it to node.exe, so on git-bash the
    # shell would mangle the file argument and the case would fail for a reason
    # that has nothing to do with the cap.
    local out
    out="$(glob_match_timed "'/home/u/git/worktrees/task/agents/x.js'" "'/home/u/git/worktrees/**'")"
    if [ "${out%% *}" = "true" ]; then
        pass "cap spares POSIX absolute worktree-root glob"
    else
        fail "cap spares POSIX absolute worktree-root glob: expected 'true', got '$out'"
    fi

    # Boundary pair around the 10-wildcard limit. Both sides are asserted so the
    # cap is pinned as inclusive-at-10: the pass side fails if an off-by-one
    # narrows what users can express, the reject side fails if the limit is
    # loosened. Star counts are 2x5 = 10 and 2x5+1 = 11 respectively.
    assert_match "cap boundary: exactly 10 wildcards still matches" \
        "a/b/c/d/e/x.md" "**/**/**/**/**/x.md" "true"
    assert_match "cap boundary: 11 wildcards is rejected (non-matching)" \
        "a/b/c/d/e/f.md" "**/**/**/**/**/*.md" "false"
}

# ─────────────────────────────────────────────────────────────────────────────
# Non-goal verification: '?' is NOT a wildcard
# ─────────────────────────────────────────────────────────────────────────────

test_nongoal_question_mark_literal() {
    assert_match "'?' is literal: pattern 'a?b' matches 'a?b'" \
        "a?b" "a?b" "true"
    assert_match "'?' is literal: pattern 'a?b' does NOT match 'aXb'" \
        "aXb" "a?b" "false"
}

# ─────────────────────────────────────────────────────────────────────────────
# Cross-platform: backslash normalization & Windows case-insensitive
# ─────────────────────────────────────────────────────────────────────────────

test_cross_platform_backslash_normalized() {
    # Backslash paths should normalize to forward slashes before matching.
    assert_match "windows-style backslash path matches **/*.md" \
        'docs\sub\a.md' "**/*.md" "true"
    assert_match "backslash path literal match against forward-slash pattern" \
        'docs\todo.md' "docs/todo.md" "true"
}

test_cross_platform_win32_case_insensitive() {
    local platform; platform="$(node -p 'process.platform' 2>/dev/null)"
    if [ "$platform" != "win32" ]; then
        pass "win32-only case-insensitive test skipped on $platform"
        return
    fi
    assert_match "win32: uppercase path matches lowercase pattern" \
        "DOCS/Todo.md" "docs/todo.md" "true"
    assert_match "win32: mixed-case extension matches via **/*.md" \
        "Docs/Sub/A.MD" "**/*.md" "true"
}

# ─────────────────────────────────────────────────────────────────────────────
# matchesAnyExcludePattern
# ─────────────────────────────────────────────────────────────────────────────

test_matches_any_returns_true_when_any_matches() {
    local got
    got="$(matches_any "docs/todo.md" '["src/**","docs/*.md"]')"
    if [ "$got" = "true" ]; then
        pass "matchesAny: docs/todo.md matches docs/*.md"
    else
        fail "matchesAny: expected 'true', got '$got'"
    fi
}

test_matches_any_returns_false_when_none_match() {
    local got
    got="$(matches_any "src/x.py" '["docs/*.md","**/*.txt"]')"
    if [ "$got" = "false" ]; then
        pass "matchesAny: src/x.py does not match any pattern -> false"
    else
        fail "matchesAny: expected 'false', got '$got'"
    fi
}

test_matches_any_empty_patterns_array() {
    local got
    got="$(matches_any "any/file.md" '[]')"
    if [ "$got" = "false" ]; then
        pass "matchesAny: empty patterns array -> false"
    else
        fail "matchesAny: empty array should return false, got '$got'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

# Normal
test_normal_globstar_matches_subdirs
test_normal_single_star_one_segment
test_normal_literal_match

# parseExcludePatterns
test_parse_simple_split
test_parse_trims_whitespace
test_parse_drops_empty_entries
test_parse_empty_string_input
test_parse_only_separators

# Negative
test_negative_single_star_not_cross_separator

# Edge
test_edge_empty_pattern_never_matches
test_edge_root_level_file
test_edge_path_with_spaces
test_edge_dotfiles

# Security
test_security_regex_meta_chars_literal
test_security_repeated_globstar_no_catastrophic_backtracking
test_security_pattern_complexity_cap_stops_redos
test_security_complexity_cap_spares_realistic_globs

# Non-goal
test_nongoal_question_mark_literal

# Cross-platform
test_cross_platform_backslash_normalized
test_cross_platform_win32_case_insensitive

# matchesAnyExcludePattern
test_matches_any_returns_true_when_any_matches
test_matches_any_returns_false_when_none_match
test_matches_any_empty_patterns_array

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
