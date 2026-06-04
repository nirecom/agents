#!/bin/bash
# tests/fix-strip-quoted-args-lib.sh
# Tests: hooks/lib/strip-quoted-args.js, hooks/lib/bash-write-patterns.js
# Tags: hook, bin, tests, strip-shell-var, classify-detailed
#
# Tests for hooks/lib/strip-quoted-args.js — exports stripQuotedArgs(str)
# which strips content inside double-quoted ("..."), single-quoted ('...'),
# and ANSI-C ($'...') quotes, leaving empty quote markers in place.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/strip-quoted-args.js"

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

call_strip() {
    run_with_timeout 30 node -e "
      try {
        const { stripQuotedArgs } = require('$MODULE');
        console.log(JSON.stringify(stripQuotedArgs(process.argv[1])));
      } catch(e) { console.log('ERROR: '+e.message); }
    " -- "$1" 2>/dev/null
}

# ─────────────────────────────────────────────────────────────────────────────
# Tests
# ─────────────────────────────────────────────────────────────────────────────

test_no_quotes() {
    local r
    r="$(call_strip 'no quotes here')"
    if [ "$r" = '"no quotes here"' ]; then
        pass "no quotes — unchanged"
    else
        fail "no quotes: expected '\"no quotes here\"', got '$r'"
    fi
}

test_double_quoted_stripped() {
    local r
    r="$(call_strip 'git commit -m "branch -d"')"
    case "$r" in
        *'branch -d'*)
            fail "double-quoted: 'branch -d' still present in stripped result: $r"
            ;;
        *'git commit'*)
            pass "double-quoted content stripped (branch -d removed)"
            ;;
        *)
            fail "double-quoted: unexpected result: $r"
            ;;
    esac
}

test_single_quoted_stripped() {
    local r
    r="$(call_strip "echo 'branch -d'")"
    case "$r" in
        *"''\"")
            pass "single-quoted content stripped (ends with empty single quotes)"
            ;;
        *)
            fail "single-quoted: expected result to end with \"''\", got '$r'"
            ;;
    esac
}

test_ansi_c_quoted_stripped() {
    local r
    r="$(call_strip "echo \$'branch -d'")"
    case "$r" in
        *'branch -d'*)
            fail "ANSI-C quoted: 'branch -d' still present in stripped result: $r"
            ;;
        *echo*)
            pass "ANSI-C quoted content stripped (branch -d removed)"
            ;;
        *)
            fail "ANSI-C quoted: unexpected result: $r"
            ;;
    esac
}

test_fp_commit_message() {
    local r
    r="$(call_strip 'git commit -m "branch -d fix/foo"')"
    case "$r" in
        *"-d fix"*)
            fail "FP: stripped result must NOT contain '-d fix', got '$r'"
            ;;
        *)
            pass "no false positive: '-d fix' not in stripped result"
            ;;
    esac
}

test_empty_string() {
    local r
    r="$(call_strip '')"
    if [ "$r" = '""' ]; then
        pass "empty string -> empty JSON string"
    else
        fail "empty: expected '\"\"', got '$r'"
    fi
}

test_null_no_throw() {
    local r
    r="$(run_with_timeout 30 node -e "
      try {
        const { stripQuotedArgs } = require('$MODULE');
        const out = stripQuotedArgs(null);
        console.log(JSON.stringify({ok: true, falsy: !out, val: out === null ? 'null' : (out === undefined ? 'undefined' : String(out))}));
      } catch(e) { console.log('ERROR: '+e.message); }
    " 2>/dev/null)"
    case "$r" in
        *'"ok":true'*'"falsy":true'*)
            pass "stripQuotedArgs(null) does not throw, result is falsy"
            ;;
        *)
            fail "null handling: $r"
            ;;
    esac
}

test_escaped_quote_in_double() {
    local r
    r="$(call_strip 'echo "say \"hi\""')"
    if [ "$r" = '"echo \"\""' ]; then
        pass "escaped quote in double-quoted: 'echo \"\"'"
    else
        fail "escaped quote: expected '\"echo \\\"\\\"\"', got '$r'"
    fi
}

test_idempotency() {
    local a b
    a="$(call_strip 'git commit -m "branch -d"')"
    b="$(call_strip 'git commit -m "branch -d"')"
    if [ "$a" = "$b" ]; then
        pass "idempotent: two strips of same input match"
    else
        fail "not idempotent: a=$a b=$b"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# stripShellVarAssignment tests (#659)
# ─────────────────────────────────────────────────────────────────────────────

PATTERNS_MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-patterns.js"

# Helper: call stripShellVarAssignment from strip-quoted-args.js
# The function does NOT exist yet → all call_strip_shell_var tests are RED.
call_strip_shell_var() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        if (typeof m.stripShellVarAssignment !== 'function') {
          process.stdout.write('ERROR: stripShellVarAssignment not exported');
          process.exit(0);
        }
        console.log(JSON.stringify(m.stripShellVarAssignment(process.argv[1])));
      } catch(e) { console.log('ERROR: '+e.message); }
    " -- "$1" 2>/dev/null
}

test_shell_var_single() {
    local r
    r="$(call_strip_shell_var "BODY='rm -rf /'")"
    case "$r" in
        *"ERROR: stripShellVarAssignment not exported"*)
            fail "test_shell_var_single: stripShellVarAssignment not exported yet (#659 RED)"
            ;;
        *'rm -rf'*)
            fail "test_shell_var_single: 'rm -rf' still present after stripping: $r"
            ;;
        *)
            pass "test_shell_var_single: single-quoted shell var body stripped (rm -rf removed)"
            ;;
    esac
}

test_shell_var_double() {
    local r
    r="$(call_strip_shell_var 'BODY="rm -rf /"')"
    case "$r" in
        *"ERROR: stripShellVarAssignment not exported"*)
            fail "test_shell_var_double: stripShellVarAssignment not exported yet (#659 RED)"
            ;;
        *'rm -rf'*)
            fail "test_shell_var_double: 'rm -rf' still present after stripping: $r"
            ;;
        *)
            pass "test_shell_var_double: double-quoted shell var body stripped (rm -rf removed)"
            ;;
    esac
}

test_shell_var_multiline() {
    local r
    # Multiline body with embedded dangerous command on line 2
    r="$(call_strip_shell_var "BODY='line1
rm -rf /tmp
line3'")"
    case "$r" in
        *"ERROR: stripShellVarAssignment not exported"*)
            fail "test_shell_var_multiline: stripShellVarAssignment not exported yet (#659 RED)"
            ;;
        *'rm -rf'*)
            fail "test_shell_var_multiline: 'rm -rf' still present after stripping: $r"
            ;;
        *)
            pass "test_shell_var_multiline: multiline shell var body stripped (rm -rf removed)"
            ;;
    esac
}

test_shell_var_non_assignment() {
    local r
    # Input has no IDENT= prefix — should NOT over-strip; 'rm hi' must survive
    r="$(call_strip_shell_var "echo 'rm hi'")"
    case "$r" in
        *"ERROR: stripShellVarAssignment not exported"*)
            fail "test_shell_var_non_assignment: stripShellVarAssignment not exported yet (#659 RED)"
            ;;
        *'rm hi'*)
            pass "test_shell_var_non_assignment: non-assignment input not over-stripped (rm hi preserved)"
            ;;
        *)
            fail "test_shell_var_non_assignment: expected 'rm hi' preserved in output, got: $r"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# classifyDetailed tests (#659) — bash-write-patterns.js
# classifyDetailed does NOT exist yet → RED
# ─────────────────────────────────────────────────────────────────────────────

test_classify_with_body_var() {
    local r
    r="$(run_with_timeout 30 node -e "
      try {
        const m = require('$PATTERNS_MODULE');
        if (typeof m.classifyDetailed !== 'function') {
          process.stdout.write('ERROR: classifyDetailed not exported');
          process.exit(0);
        }
        const cmd = \"BODY='rm -rf /'; gh issue create --title 'fix' --body \\\"\\\$BODY\\\"\";
        const basic = m.classify(cmd);
        const detail = m.classifyDetailed(cmd);
        const names = detail.matchedNames || [];
        // gh issue create is a write — correct
        if (basic !== 'write') { process.stderr.write('classify should be write, got: ' + basic + '\n'); process.exit(1); }
        if (detail.kind !== 'write') { process.stderr.write('classifyDetailed.kind should be write, got: ' + detail.kind + '\n'); process.exit(1); }
        if (!names.includes('gh-issue-create')) { process.stderr.write('matchedNames should include gh-issue-create, got: ' + JSON.stringify(names) + '\n'); process.exit(1); }
        // Must NOT include file-op names (rm etc.) — shell var body must be stripped
        const fileOpNames = ['rm','mv','cp','sed-inplace','perl-inplace','patch','touch','chmod','dd','rsync','tar-extract','unzip','gunzip','bunzip2'];
        const badMatches = names.filter(n => fileOpNames.includes(n));
        if (badMatches.length > 0) { process.stderr.write('matchedNames must not include file-op names; got: ' + JSON.stringify(badMatches) + '\n'); process.exit(1); }
        process.stdout.write('ok');
      } catch(e) { process.stdout.write('ERROR: ' + e.message); }
    " 2>/dev/null)"
    case "$r" in
        "ERROR: classifyDetailed not exported")
            fail "test_classify_with_body_var: classifyDetailed not exported yet (#659 RED)"
            ;;
        "ok")
            pass "test_classify_with_body_var: classifyDetailed returns write+gh-issue-create, no file-op false-positive"
            ;;
        "ERROR: "*)
            fail "test_classify_with_body_var: $r"
            ;;
        *)
            fail "test_classify_with_body_var: unexpected output: $r"
            ;;
    esac
}

test_classify_clean_body() {
    local r
    r="$(run_with_timeout 30 node -e "
      try {
        const m = require('$PATTERNS_MODULE');
        if (typeof m.classifyDetailed !== 'function') {
          process.stdout.write('ERROR: classifyDetailed not exported');
          process.exit(0);
        }
        const cmd = \"gh issue create --title 'fix' --body 'normal body'\";
        const detail = m.classifyDetailed(cmd);
        const names = detail.matchedNames || [];
        if (!names.includes('gh-issue-create')) { process.stderr.write('should include gh-issue-create, got: ' + JSON.stringify(names) + '\n'); process.exit(1); }
        const nonGhCreate = names.filter(n => n !== 'gh-issue-create');
        if (nonGhCreate.length > 0) { process.stderr.write('expected only gh-issue-create, got extras: ' + JSON.stringify(nonGhCreate) + '\n'); process.exit(1); }
        process.stdout.write('ok');
      } catch(e) { process.stdout.write('ERROR: ' + e.message); }
    " 2>/dev/null)"
    case "$r" in
        "ERROR: classifyDetailed not exported")
            fail "test_classify_clean_body: classifyDetailed not exported yet (#659 RED)"
            ;;
        "ok")
            pass "test_classify_clean_body: clean body → matchedNames === [gh-issue-create]"
            ;;
        "ERROR: "*)
            fail "test_classify_clean_body: $r"
            ;;
        *)
            fail "test_classify_clean_body: unexpected output: $r"
            ;;
    esac
}

test_classify_non_group_a_scope() {
    local r
    r="$(run_with_timeout 30 node -e "
      try {
        const m = require('$PATTERNS_MODULE');
        if (typeof m.classifyDetailed !== 'function') {
          process.stdout.write('ERROR: classifyDetailed not exported');
          process.exit(0);
        }
        // BODY var assignment + a real rm outside any group-A context
        // classify() must still return 'write' (fail-safe — stripping shell vars
        // must not affect non-Group-A paths with dangerous commands)
        const cmd = \"BODY='rm -rf /'; rm -rf /tmp/test\";
        const basic = m.classify(cmd);
        if (basic !== 'write') { process.stderr.write('non-group-A rm must still classify as write, got: ' + basic + '\n'); process.exit(1); }
        process.stdout.write('ok');
      } catch(e) { process.stdout.write('ERROR: ' + e.message); }
    " 2>/dev/null)"
    case "$r" in
        "ERROR: classifyDetailed not exported")
            fail "test_classify_non_group_a_scope: classifyDetailed not exported yet (#659 RED)"
            ;;
        "ok")
            pass "test_classify_non_group_a_scope: non-Group-A rm still classified as write (fail-safe preserved)"
            ;;
        "ERROR: "*)
            fail "test_classify_non_group_a_scope: $r"
            ;;
        *)
            fail "test_classify_non_group_a_scope: unexpected output: $r"
            ;;
    esac
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all tests
# ─────────────────────────────────────────────────────────────────────────────

test_no_quotes
test_double_quoted_stripped
test_single_quoted_stripped
test_ansi_c_quoted_stripped
test_fp_commit_message
test_empty_string
test_null_no_throw
test_escaped_quote_in_double
test_idempotency

# stripShellVarAssignment tests (#659)
test_shell_var_single
test_shell_var_double
test_shell_var_multiline
test_shell_var_non_assignment

# classifyDetailed tests (#659)
test_classify_with_body_var
test_classify_clean_body
test_classify_non_group_a_scope

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
