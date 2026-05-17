#!/bin/bash
# tests/fix-296-hook-cwd-drift-parse-cd.sh
#
# Tests for hooks/lib/parse-git-args.js — exports parseCdCommand(str)
# which extracts the absolute path from a leading "cd <path> && ..."
# (or "cd <path> ; ...") in a command string. Returns null when:
#   - command does not start with cd (whitespace allowed)
#   - cd argument is relative
#   - cd argument contains an environment variable ($VAR / ${VAR})
#   - cd argument contains tilde expansion
#   - quote is unterminated
#   - input is null/empty
#
# TDD: written before parseCdCommand is implemented. Pre-impl, every case
# below fails with NOT_EXPORTED. Post-impl, every case should PASS.

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

echo ""
echo "─────────────────────────────────────────"
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
