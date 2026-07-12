#!/bin/bash
# tests/fix-bash-write-patterns-fd-redirect.sh
# Tests: hooks/lib/bash-write-patterns.js
# Tags: hook, bin, git, tests
# Tests for FD-to-FD redirect false positive fix (#243)
set -u
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
WP="${_A}/hooks/lib/bash-write-patterns.js"
PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}
classify() {
  run_with_timeout node -e "const {classify}=require('$WP');console.log(classify(process.argv[1]))" -- "$1" 2>/dev/null
}
assert_read()  { local got; got="$(classify "$1")"; [ "$got" = "read"  ] && pass "$2" || fail "$2 (got=$got)"; }
assert_write() { local got; got="$(classify "$1")"; [ "$got" != "read" ] && pass "$2" || fail "$2 (expected write, got=read)"; }

assert_read  "ls 2>&1"               "R1: 2>&1 → read"
assert_read  "echo err 1>&2"         "R2: 1>&2 → read"
assert_read  "ls 2>&1 | head"        "R3: 2>&1 in pipeline → read"
# Post-#1296: POSIX write redirects (>, 2>, &>) now classify() as "read" — their
# WRITE_PATTERNS entries were retired; write-detection moved to isPosixRedirWriteIR.
# In-scope BLOCKING of these redirect writes is enforced at the hook (IR fast-allow)
# and verified end-to-end by tests/feature-canary5-6git/commit2-green-retire.sh L2.
# These rows pin the new classify="read" contract; the FD-to-FD false-positive fix
# (#243, R1/R2/R3/R5b) is unaffected — those were already "read".
assert_read  "echo x > file.txt"     "R4: > file → read (write-detection moved to IR)"
assert_read  "make 2>err.log"        "R5: 2>file → read (write-detection moved to IR)"
assert_read  "git status 2>/dev/null" "R5b: 2>/dev/null → read"
assert_read  "make &> build.log"     "R5c: &> combined → read (write-detection moved to IR)"

echo ""; echo "Results: $PASS passed, $FAIL failed"; [ "$FAIL" -eq 0 ]
