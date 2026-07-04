#!/usr/bin/env bash
# Tests: hooks/enforce-worktree/shared-cmd-utils.js, hooks/lib/command-parser.js, hooks/lib/command-ir.js
# Tags: worktree, enforce, hook, shell-chaining, ir, scope:issue-specific
# L3 gap (what this test does NOT catch):
# - Real hook registration and firing in a live claude session (enforce-worktree.js wired to PreToolUse)
# - Behavioral change when command flows through the full allow-chain (standard.js → hasShellChaining → IR)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration
set -uo pipefail

PASS=0; FAIL=0

# Worktree root — all node require() targets resolve relative to this.
WORKTREE="C:/git/worktrees/1293-canary2-ir/agents"
[ -d "$WORKTREE" ] || WORKTREE="$(cd "$(dirname "$0")/.." && pwd)"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found — skipping tests"; exit 77; }

# ---------------------------------------------------------------------------
# assert_eq — table-driven assertion (inlined per test-design.md; no shared lib)
# ---------------------------------------------------------------------------
assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then
    echo "PASS: $name"; PASS=$((PASS + 1))
  else
    echo "FAIL: $name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; FAIL=$((FAIL + 1))
  fi
}

# ---------------------------------------------------------------------------
# JS bridges — each shells out to node once per case. The command string is
# passed as argv[1] (process.argv[2]) to avoid any quoting/escaping surprises
# from string-interpolating the command into the -e source.
# ---------------------------------------------------------------------------

# splitSegments(cmd).length
seg_count() {
  ( cd "$WORKTREE" && node -e '
    const {splitSegments} = require("./hooks/lib/command-parser");
    process.stdout.write(String(splitSegments(process.argv[1]).length));
  ' "$1" ) 2>/dev/null
}

# JSON.stringify(parse(cmd).separators)
ir_separators() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const ir = parse(process.argv[1]);
    process.stdout.write(JSON.stringify(ir.separators));
  ' "$1" ) 2>/dev/null
}

# hasShellChaining(cmd) → "true"/"false"
has_chaining() {
  ( cd "$WORKTREE" && node -e '
    const {hasShellChaining} = require("./hooks/enforce-worktree/shared-cmd-utils");
    process.stdout.write(String(hasShellChaining(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# rejectInterpreterAndChaining(cmd) → "true"/"false"
reject_interp() {
  ( cd "$WORKTREE" && node -e '
    const {rejectInterpreterAndChaining} = require("./hooks/enforce-worktree/shared-cmd-utils");
    process.stdout.write(String(rejectInterpreterAndChaining(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# hasCommandSequencing(cmd) → "true"/"false"
has_sequencing() {
  ( cd "$WORKTREE" && node -e '
    const {hasCommandSequencing} = require("./hooks/enforce-worktree/shared-cmd-utils");
    process.stdout.write(String(hasCommandSequencing(process.argv[1])));
  ' "$1" ) 2>/dev/null
}

# Does parse(cmd).separators contain a given operator token? → "true"/"false"
sep_contains() {
  ( cd "$WORKTREE" && node -e '
    const {parse} = require("./hooks/lib/command-ir");
    const seps = parse(process.argv[1]).separators || [];
    process.stdout.write(String(seps.includes(process.argv[2])));
  ' "$1" "$2" ) 2>/dev/null
}

echo "=== Section A: splitSegments fd-dup fix (segment count) ==="
# Regression pins from #982/#838/#959: fd-dup redirects must NOT split the command.
assert_eq "A1 fd-dup 2>&1 no split"     "1" "$(seg_count 'git merge 2>&1')"
assert_eq "A2 fd-dup 1>&2 no split"     "1" "$(seg_count 'git merge 1>&2')"
assert_eq "A3 fd-dup >&2 no split"      "1" "$(seg_count 'git merge >&2')"
assert_eq "A4 fd-dup 2>&- no split"     "1" "$(seg_count 'git merge 2>&-')"
assert_eq "A5 fd-dup >&- no split"      "1" "$(seg_count 'git merge >&-')"
assert_eq "A6 && still splits"          "2" "$(seg_count 'git merge && git push')"
assert_eq "A7 pipe still splits"        "2" "$(seg_count 'git merge | tee log.txt')"
assert_eq "A8 semicolon still splits"   "2" "$(seg_count 'git stash; git pull')"
assert_eq "A9 &> still splits"          "2" "$(seg_count 'git merge &> /tmp/log')"

echo "=== Section B: IR separators field ==="
assert_eq "B1 && separator"             '["&&"]'      "$(ir_separators 'git merge && git push')"
assert_eq "B2 semicolon separator"      '[";"]'       "$(ir_separators 'git stash; git pull')"
assert_eq "B3 OR separator"             '["||"]'      "$(ir_separators 'a || b')"
assert_eq "B4 pipe separator"           '["|"]'       "$(ir_separators 'cmd | tee file')"
assert_eq "B5 fd-dup no separator"      '[]'          "$(ir_separators 'git merge 2>&1')"
assert_eq "B6 multiple separators"      '["&&",";"]'  "$(ir_separators 'a && b; c')"
assert_eq "B7 simple no separator"      '[]'          "$(ir_separators 'git merge')"
assert_eq "B8 leading semicolon (C1)"   "true"        "$(sep_contains '; rm -rf /' ';')"
assert_eq "B9 trailing && (C1)"         "true"        "$(sep_contains 'git pull &&' '&&')"

echo "=== Section C: hasShellChaining IR migration ==="
assert_eq "C1 fd-dup 2>&1 no chaining"  "false" "$(has_chaining 'git merge 2>&1')"
assert_eq "C2 fd-dup 1>&2"              "false" "$(has_chaining 'git merge 1>&2')"
assert_eq "C3 fd-dup >&2"               "false" "$(has_chaining 'git merge >&2')"
assert_eq "C4 fd-dup 2>&-"              "false" "$(has_chaining 'git merge 2>&-')"
assert_eq "C5 && is chaining"           "true"  "$(has_chaining 'git merge && git push')"
assert_eq "C6 pipe is chaining"         "true"  "$(has_chaining 'git merge | tee log.txt')"
assert_eq "C7 command substitution"     "true"  "$(has_chaining 'cmd $(subshell)')"
assert_eq "C8 SQ literal \$(text) (C2)"  "false" "$(has_chaining "git commit -m '\$(text)'")"
assert_eq "C9 clean command"            "false" "$(has_chaining 'git merge')"
assert_eq "C10 &> redirect blocked"     "true"  "$(has_chaining 'git merge &> /tmp/log')"
assert_eq "C11 empty-string guard"      "false" "$(has_chaining '')"

echo "=== Section D: rejectInterpreterAndChaining IR migration ==="
assert_eq "D1 interpreter prefix"       "true"  "$(reject_interp "bash -c 'git stash'")"
assert_eq "D2 fd-dup no chaining"       "false" "$(reject_interp 'git merge 2>&1')"
assert_eq "D3 && chaining"              "true"  "$(reject_interp 'git merge && git push')"
assert_eq "D4 literal newline (I9)"     "true"  "$(reject_interp $'git stash\nrm -rf /')"
assert_eq "D5 process substitution"     "true"  "$(reject_interp 'git stash <(cat /etc/passwd)')"
assert_eq "D6 SQ literal <(text) (C2)"  "false" "$(reject_interp "git commit -m '<(text)'")"
assert_eq "D7 pipe (broad gate)"        "true"  "$(reject_interp 'git merge | tee log.txt')"
assert_eq "D8 clean command"            "false" "$(reject_interp 'git merge')"

echo "=== Section E: hasCommandSequencing IR migration ==="
assert_eq "E1 pipe alone NOT sequencing" "false" "$(has_sequencing 'git merge | tee log.txt')"
assert_eq "E2 semicolon is sequencing"   "true"  "$(has_sequencing 'git stash; git pull')"
assert_eq "E3 && is sequencing"          "true"  "$(has_sequencing 'git pull && git push')"
assert_eq "E4 || is sequencing"          "true"  "$(has_sequencing 'git pull || git pull')"
assert_eq "E5 leading ; fail-closed (C1)" "true"  "$(has_sequencing '; rm -rf /')"
assert_eq "E6 trailing && fail-closed (C1)" "true" "$(has_sequencing 'git pull &&')"
assert_eq "E7 fd-dup not sequencing"     "false" "$(has_sequencing 'git merge 2>&1')"
assert_eq "E8 clean command"             "false" "$(has_sequencing 'git merge')"
assert_eq "E9 empty-string guard"        "false" "$(has_sequencing '')"

echo "=== Section F: parseFailure fail-closed (unclosed quote) ==="
assert_eq "F1 hasShellChaining unclosed"           "true" "$(has_chaining "git merge 'unclosed")"
assert_eq "F2 rejectInterpreterAndChaining unclosed" "true" "$(reject_interp "git merge 'unclosed")"
assert_eq "F3 hasCommandSequencing unclosed"        "true" "$(has_sequencing "git merge 'unclosed")"

echo "=== Section G: Gap coverage (adjacent fd-dups, idempotency, chained-interpreter IR path) ==="
# G1: adjacent fd-dup redirects produce no separators
assert_eq "G1 adjacent fd-dups seps=[]"    '[]'    "$(ir_separators 'git merge main 2>&1 1>&2')"
# G2: adjacent fd-dups → hasShellChaining returns false (separators=[])
assert_eq "G2 adjacent fd-dups no chaining" "false" "$(has_chaining 'git merge main 2>&1 1>&2')"
# G3: multiple redirects including fd-dup and file redirect → no chaining flag
assert_eq "G3 multi-redirect no chaining"  "false" "$(has_chaining 'git status 2>&1 1>&2 >/dev/null')"
# G4: parse() idempotency — calling twice on same input returns identical separators
assert_eq "G4 parse idempotency"           "$(ir_separators 'git status 2>&1')" "$(ir_separators 'git status 2>&1')"
# G5: interpreter after && — separator gate fires first → true
assert_eq "G5 chained bash via &&"         "true"  "$(reject_interp 'git pull && bash -c script.sh')"
# G6: interpreter after && (python3) — separator gate fires first → true
assert_eq "G6 chained python3 via &&"      "true"  "$(reject_interp 'git pull && python3 script.py')"

echo ""
echo "==================================================="
echo "TOTAL: PASS=$PASS FAIL=$FAIL"
echo "==================================================="
[ "$FAIL" -eq 0 ]
