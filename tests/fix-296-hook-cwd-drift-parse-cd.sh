#!/bin/bash
# tests/fix-296-hook-cwd-drift-parse-cd.sh
# Tests: hooks/lib/parse-git-args.js
# Tags: hook, bin, git, tests, scope:common
# parseCdCommand(str): extracts the absolute path from a leading "cd <path> && ..."/";",
# null for non-cd / relative / env-var / tilde / unterminated-quote / null/empty input.
# parseGitCArg(str): extracts the `git -C <path>` argument; null on absence/unterminated
# quote and (post-#2319 CPR-ORTH null guard, detail plan Step 2 / T2) null/non-string
# input rather than throwing — the symmetric guard parseCdCommand already carries.
# TDD: pre-impl the parseCdCommand cases fail NOT_EXPORTED; the parseGitCArg null-guard
# cases fail (throw) until Step 2 lands. Do not weaken.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/parse-git-args.js"

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

if [ ! -f "$AGENTS_DIR/hooks/lib/parse-git-args.js" ]; then
    echo "FAIL: hooks/lib/parse-git-args.js not found"
    echo ""
    echo "Results: 0 passed, 1 failed"
    exit 1
fi

# call_parse_cd <command-string>
# Emits the JSON-encoded return value of parseCdCommand(arg),
# or one of: "NOT_EXPORTED", "ERROR: <msg>".
call_parse_cd() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.parseCdCommand;
        if (typeof fn !== 'function') { console.log('NOT_EXPORTED'); process.exit(2); }
        const r = fn(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch(e) { console.log('ERROR: '+e.message); }
    " -- "$1" 2>/dev/null
}

# Same as call_parse_cd but passes JS null as the first arg (cannot do
# that via process.argv[1] because argv values are always strings).
call_parse_cd_null() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.parseCdCommand;
        if (typeof fn !== 'function') { console.log('NOT_EXPORTED'); process.exit(2); }
        const r = fn(null);
        console.log(JSON.stringify(r));
      } catch(e) { console.log('ERROR: '+e.message); }
    " 2>/dev/null
}

# assert_eq <id> <input> <expected-json>
assert_eq() {
    local id="$1"
    local input="$2"
    local expected="$3"
    local r
    r="$(call_parse_cd "$input")"
    if [ "$r" = "$expected" ]; then
        pass "$id: parseCdCommand -> $expected"
    else
        fail "$id: input=<<<$input>>> expected=$expected got=$r"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Cases
# ─────────────────────────────────────────────────────────────────────────────

# P1: unquoted absolute path
assert_eq "P1" 'cd /tmp/foo && git commit -m x' '"/tmp/foo"'

# P2: double-quoted path containing a space
assert_eq "P2" 'cd "/path with space" && git status' '"/path with space"'

# P3: single-quoted path containing a space
assert_eq "P3" "cd '/single quoted' && echo ok" '"/single quoted"'

# P4: literal Windows path with backslashes inside double quotes.
# Bash leaves backslashes intact inside double quotes, so the JS string is
# literally  C:\path\to\dir  — which JSON-encodes with escaped backslashes.
assert_eq "P4" 'cd "C:\path\to\dir" && git commit' '"C:\\path\\to\\dir"'

# P5: semicolon separator (instead of &&) is also accepted
assert_eq "P5" 'cd "C:\path" ; git commit' '"C:\\path"'

# P6: "cd" appears inside a quoted echo argument, not at the start
assert_eq "P6" 'echo "cd /tmp" | sh' 'null'

# P7: "cd" appears inside the commit message, not at the start
assert_eq "P7" 'git commit -m "cd /tmp foo"' 'null'

# P8: relative path rejected
assert_eq "P8" 'cd foo && git commit' 'null'

# P9: only the first cd is extracted (do not chain through multiple cds)
assert_eq "P9" 'cd "/a" && cd /b && git' '"/a"'

# P10: leading whitespace + multiple inner spaces tolerated
assert_eq "P10" '   cd   /spaced   &&  echo' '"/spaced"'

# P11: unterminated quote → null
assert_eq "P11" 'cd "/unterminated && git' 'null'

# P12: pushd is not cd
assert_eq "P12" 'pushd /tmp && git commit' 'null'

# P13: env-var $LINKED inside double quotes → rejected (literal $ in string)
assert_eq "P13" 'cd "$LINKED" && gh pr create' 'null'

# P14: braced env-var ${WT} inside double quotes → rejected
assert_eq "P14" 'cd "${WT}" && git' 'null'

# P15: tilde expansion rejected
assert_eq "P15" 'cd ~/git/foo && git' 'null'

# P16: empty string → null
assert_eq "P16" '' 'null'

# P17: null literal — must not throw, must return null
test_p17() {
    local r
    r="$(call_parse_cd_null)"
    case "$r" in
        ERROR*)
            fail "P17: parseCdCommand(null) threw: $r"
            ;;
        NOT_EXPORTED)
            fail "P17: parseCdCommand not exported"
            ;;
        null)
            pass "P17: parseCdCommand(null) -> null (no throw)"
            ;;
        *)
            fail "P17: parseCdCommand(null) expected 'null', got '$r'"
            ;;
    esac
}
test_p17

# ─────────────────────────────────────────────────────────────────────────────
# T2 — parseGitCArg null guard (#2319 Step 2, CPR-ORTH with parseCdCommand).
# parseGitCArg must return null (never throw) on null / non-string input, and
# still parse a valid `git -C <path>`. Without the guard `command.match(...)`
# throws, which propagates out of resolveRepoDir(null,null) and lands the
# pre-merge backstop in its fail-closed catch (#2319 symptom 2).
# ─────────────────────────────────────────────────────────────────────────────

RESOLVE_MODULE="${_AGENTS_DIR_NODE}/hooks/workflow-gate/repo-resolution.js"

# call_gitc <command-string> — JSON-encoded parseGitCArg(arg), or NOT_EXPORTED / ERROR.
call_gitc() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.parseGitCArg;
        if (typeof fn !== 'function') { console.log('NOT_EXPORTED'); process.exit(2); }
        console.log(JSON.stringify(fn(process.argv[1])));
      } catch(e) { console.log('ERROR: '+e.message); }
    " -- "$1" 2>/dev/null
}

# call_gitc_arg <js-literal> — parseGitCArg(<js-literal>) where the literal is a
# real JS value (null, 123, {}) that argv strings cannot express.
call_gitc_arg() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const fn = m.parseGitCArg;
        if (typeof fn !== 'function') { console.log('NOT_EXPORTED'); process.exit(2); }
        console.log(JSON.stringify(fn($1)));
      } catch(e) { console.log('ERROR: '+e.message); }
    " 2>/dev/null
}

# G1: a valid `git -C <path>` still parses (guard must not break the happy path).
r="$(call_gitc 'git -C /tmp/foo status')"
[ "$r" = '"/tmp/foo"' ] && pass "G1: parseGitCArg('git -C /tmp/foo status') -> /tmp/foo" \
    || fail "G1: expected \"/tmp/foo\", got $r"

# G2: null input must return null, not throw.
r="$(call_gitc_arg 'null')"
case "$r" in
    ERROR*) fail "G2: parseGitCArg(null) threw: $r" ;;
    NOT_EXPORTED) fail "G2: parseGitCArg not exported" ;;
    null) pass "G2: parseGitCArg(null) -> null (no throw)" ;;
    *) fail "G2: parseGitCArg(null) expected 'null', got '$r'" ;;
esac

# G3: non-string (number) input must return null, not throw.
r="$(call_gitc_arg '123')"
case "$r" in
    ERROR*) fail "G3: parseGitCArg(123) threw: $r" ;;
    NOT_EXPORTED) fail "G3: parseGitCArg not exported" ;;
    null) pass "G3: parseGitCArg(123) -> null (no throw)" ;;
    *) fail "G3: parseGitCArg(123) expected 'null', got '$r'" ;;
esac

# G4: resolveRepoDir(null, null) must reach the Tier4 fallback (a resolved repo
# dir) instead of throwing at parseGitCArg — the downstream consequence the guard
# unblocks (#2319 symptom 2). Asserted as "no throw + non-empty return", which is
# stable regardless of which Tier4 candidate (CLAUDE_PROJECT_DIR / process.cwd() /
# an additionalDirectory) actually wins.
if [ -f "$AGENTS_DIR/hooks/workflow-gate/repo-resolution.js" ]; then
    TIER4_DIR="$(mktemp -d 2>/dev/null || mktemp -d -t wf296t)"
    TIER4_NODE="$(if command -v cygpath >/dev/null 2>&1; then cygpath -m "$TIER4_DIR"; else printf '%s' "$TIER4_DIR"; fi)"
    r="$(
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
        export CLAUDE_PROJECT_DIR="$TIER4_NODE"
        run_with_timeout 30 node -e "
      try {
        const { resolveRepoDir } = require('$RESOLVE_MODULE');
        const out = resolveRepoDir(null, null);
        console.log(typeof out === 'string' && out.length ? 'RET:'+out : 'EMPTY:'+String(out));
      } catch(e) { console.log('THREW: '+e.message); }
    " 2>/dev/null
    )"
    rm -rf "$TIER4_DIR" 2>/dev/null || true
    case "$r" in
        RET:*) pass "G4: resolveRepoDir(null,null) reaches Tier4 and returns a repo dir (no throw)" ;;
        THREW*) fail "G4: resolveRepoDir(null,null) threw: $r" ;;
        *) fail "G4: resolveRepoDir(null,null) returned no dir: '$r'" ;;
    esac
else
    fail "G4: hooks/workflow-gate/repo-resolution.js not found"
fi

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
