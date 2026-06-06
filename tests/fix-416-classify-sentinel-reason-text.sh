#!/usr/bin/env bash
# tests/fix-416-classify-sentinel-reason-text.sh
# Tests: hooks/lib/bash-write-patterns.js classify()
# Tags: classify, strip-kinds, sentinel-echo, isSentinelEchoSafe, issue-416
#
# After fix (#416):
#   1. STRIP_KINDS gains "pkg-mgr" and "gh" → quoted pkg-mgr/gh verbs in grep/echo
#      content are no longer false-positives.
#   2. isSentinelEchoSafe early-return: strict-DQ sentinel echo with a safe reason
#      → classify returns "read"; with unsafe reason (contains $, `, ;, |, >) → "write".
#
# Expected:
#   Group A (T3.1–T3.9):    FAIL until write-code adds pkg-mgr/gh to STRIP_KINDS.
#   Group B (T3.10–T3.13c): FAIL until write-code adds isSentinelEchoSafe.
#   Group C (T3.14–T3.16):  PASS now (real writes remain write).
#   Group C2 (T3.14b–T3.28): FAIL until write-code adds pkg-mgr/gh to STRIP_KINDS.
#   Group D (T3.17–T3.36):  Mixed: T3.19/T3.36 are PASS (read, false-neg accepted);
#                           T3.21/T3.23-T3.25/T3.31/T3.34-T3.35 FAIL until fix.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMPDIR_BASE="${TMPDIR:-/tmp}/fix-416-$$"
mkdir -p "$TMPDIR_BASE"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

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

# ─────────────────────────────────────────────────────────────────────────────
# classify() helper via Node.js
# ─────────────────────────────────────────────────────────────────────────────

CLASSIFY_HELPER="$TMPDIR_BASE/classify-helper.js"
cat > "$CLASSIFY_HELPER" <<'NODE_HELPER'
const path = require("path");
const lib = path.join(process.argv[2], "hooks", "lib", "bash-write-patterns");
const { classify } = require(lib);
process.stdout.write(classify(process.argv[3]));
NODE_HELPER

classify() {
  local cmd="$1"
  run_with_timeout 15 node "$CLASSIFY_HELPER" "$AGENTS_DIR" "$cmd"
}

assert_classify() {
  local label="$1" cmd="$2" expected="$3"
  local got
  got="$(classify "$cmd")"
  if [ "$got" = "$expected" ]; then
    pass "$label → $expected"
  else
    fail "$label → expected '$expected', got '$got' (cmd: $cmd)"
  fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Group A — STRIP_KINDS extension: pkg-mgr + gh added to STRIP_KINDS
# After fix: quoted pkg-mgr/gh verbs inside grep/echo args are stripped → read.
# WILL FAIL until write-code adds "pkg-mgr" and "gh" to STRIP_KINDS.
# ─────────────────────────────────────────────────────────────────────────────

echo "=== fix-416: classify() STRIP_KINDS + isSentinelEchoSafe ==="
echo ""
echo "--- Group A: STRIP_KINDS extension (pkg-mgr, gh) ---"

# T3.1: grep scans for "npm install" text in a docs file → read (after fix)
assert_classify \
  "T3.1 grep npm install in docs" \
  'grep -n "npm install" docs/foo.md' \
  "read"

# T3.2: grep scans for "pnpm add foo" text → read
assert_classify \
  "T3.2 grep pnpm add in file" \
  'grep -n "pnpm add foo" file.md' \
  "read"

# T3.3: grep scans for "pip install pytest" text → read
assert_classify \
  "T3.3 grep pip install in notes" \
  'grep -n "pip install pytest" notes.md' \
  "read"

# T3.4: grep scans for "uv pip install" text → read
assert_classify \
  "T3.4 grep uv pip install in docs" \
  'grep -n "uv pip install" docs/x.md' \
  "read"

# T3.5: grep scans for "gh pr merge 123" text → read
assert_classify \
  "T3.5 grep gh pr merge in docs" \
  'grep -n "gh pr merge 123" docs/y.md' \
  "read"

# T3.6: grep scans for "gh issue delete 1" text → read
assert_classify \
  "T3.6 grep gh issue delete in file" \
  'grep -n "gh issue delete 1" file.md' \
  "read"

# T3.7: grep scans for "gh api -X DELETE foo" text → read
assert_classify \
  "T3.7 grep gh api DELETE in file" \
  'grep -n "gh api -X DELETE foo" file.md' \
  "read"

# T3.8: echo describes npm install in prose → read
assert_classify \
  "T3.8 echo npm install in prose" \
  'echo "Run npm install first"' \
  "read"

# T3.9: echo describes gh pr merge in prose → read
assert_classify \
  "T3.9 echo gh pr merge in prose" \
  'echo "Then gh pr merge --squash"' \
  "read"

echo ""
echo "--- Group B: isSentinelEchoSafe (safe sentinel reasons → read) ---"

# T3.10: strict DQ sentinel with safe reason containing "npm install" → read
# isSentinelEchoSafe: reason text is safe (no $, `, ;, |, >) → early-return read.
assert_classify \
  "T3.10 sentinel RESEARCH_NOT_NEEDED with npm install in reason" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: npm install handled>>"' \
  "read"

# T3.11: sentinel WRITE_TESTS_NOT_NEEDED with "gh pr merge done" in reason → read
assert_classify \
  "T3.11 sentinel WRITE_TESTS_NOT_NEEDED with gh pr merge in reason" \
  'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: gh pr merge done>>"' \
  "read"

# T3.12: sentinel BRANCHING_COMPLETE with "bash -c stuff" in reason → read
assert_classify \
  "T3.12 sentinel BRANCHING_COMPLETE with bash -c in reason" \
  'echo "<<WORKFLOW_BRANCHING_COMPLETE: branch:bash -c stuff>>"' \
  "read"

# T3.13: sentinel USER_VERIFIED with "rm -rf cleanup" as reason text → read
# The rm is in the REASON FIELD (inside the sentinel), not an actual command.
# isSentinelEchoSafe: rm in reason text without ; $ ` | > shell metacharacters → safe.
assert_classify \
  "T3.13 sentinel USER_VERIFIED with rm -rf in reason text" \
  'echo "<<WORKFLOW_USER_VERIFIED: rm -rf cleanup>>"' \
  "read"

# T3.13b: MARK_STEP sentinel (no reason field) → read
assert_classify \
  "T3.13b sentinel MARK_STEP write_code_complete (no reason)" \
  'echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"' \
  "read"

# T3.13c: RESET_FROM sentinel (no reason field) → read
assert_classify \
  "T3.13c sentinel RESET_FROM research (no reason)" \
  'echo "<<WORKFLOW_RESET_FROM_research>>"' \
  "read"

echo ""
echo "--- Group C: Real writes remain write (should PASS now) ---"

# T3.14: bare npm install → write (real write, unquoted)
assert_classify \
  "T3.14 npm install foo (bare)" \
  "npm install foo" \
  "write"

# T3.14e: bare gh api -X DELETE → write (real write, unquoted verb)
assert_classify \
  "T3.14e gh api -X DELETE repos/..." \
  "gh api -X DELETE /repos/owner/repo" \
  "write"

# T3.15: bare gh pr merge → write
assert_classify \
  "T3.15 gh pr merge 123 --squash (bare)" \
  "gh pr merge 123 --squash" \
  "write"

# T3.16: bare pip install → write
assert_classify \
  "T3.16 pip install pytest (bare)" \
  "pip install pytest" \
  "write"

echo ""
echo "--- Group C2: Accepted false-negatives (quoted write verbs → read after STRIP_KINDS) ---"
echo "    WILL FAIL until write-code adds pkg-mgr/gh to STRIP_KINDS"

# T3.14b: quoted "install" verb → stripped → no npm-write match → read (AT-DP1)
assert_classify \
  "T3.14b npm \"install\" foo (quoted verb → stripped → read)" \
  'npm "install" foo' \
  "read"

# T3.14c: quoted "install" verb for pip → stripped → read
assert_classify \
  "T3.14c pip \"install\" pytest (quoted verb → stripped → read)" \
  'pip "install" pytest' \
  "read"

# T3.28: gh api -X "DELETE" → quoted DELETE verb → stripped → no gh-api-mutate match → read
assert_classify \
  "T3.28 gh api -X \"DELETE\" ... (quoted verb → stripped → read)" \
  'gh api -X "DELETE" /repos/owner/repo' \
  "read"

# T3.14g: gh pr "merge" → quoted verb → stripped → read
assert_classify \
  "T3.14g gh pr \"merge\" 123 (quoted verb → stripped → read)" \
  'gh pr "merge" 123' \
  "read"

# T3.14f: pwsh -Command "Remove-Item foo" → interpreter-c is NOT in STRIP_KINDS →
# original cmd scanned → Remove-Item matches → write (existing behavior preserved).
assert_classify \
  "T3.14f pwsh -Command Remove-Item (interpreter-c not in STRIP_KINDS → write)" \
  'pwsh -Command "Remove-Item foo"' \
  "write"

echo ""
echo "--- Group D: isSentinelEchoSafe security — unsafe reasons → write ---"
echo "    WILL FAIL until write-code adds isSentinelEchoSafe"

# T3.17: sentinel && rm -rf chain → isStrictSentinel=false (chain) → normal classify
# → rm matches file-op → write (chain security maintained)
assert_classify \
  "T3.17 sentinel && rm -rf chain → write (chain not strict sentinel)" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>" && rm -rf /tmp' \
  "write"

# T3.18: unrelated prefix; sentinel → normal classify → no write pattern → read
assert_classify \
  "T3.18 foo; sentinel (prefix not a chain) → read" \
  'foo; echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>"' \
  "read"

# T3.19: the ';' is OUTSIDE the sentinel boundary (after >>), still inside echo's DQ body.
# The full string is NOT a strict sentinel (ends with /tmp" not >>"$).
# isSentinelEchoSafe does not fire; normal classify; rm is inside the quoted body →
# stripQuotedArgs removes it → no write pattern → read (accepted false-negative).
assert_classify \
  "T3.19 echo sentinel; rm chain (;rm outside >>) → read (not strict sentinel, rm quoted)" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>; rm -rf /tmp"' \
  "read"

# T3.20: single-quoted sentinel → NOT a strict DQ sentinel → normal classify → no write → read
assert_classify \
  "T3.20 single-quoted sentinel → normal classify → read" \
  "echo '<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>'" \
  "read"

# T3.21: $(...) in reason → isSentinelEchoSafe=false → write (injection prevention)
assert_classify \
  "T3.21 sentinel with \$(rm foo) in reason → write (injection prevention)" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: $(rm foo)>>"' \
  "write"

# T3.22: safe reason → isSentinelEchoSafe=true → read
assert_classify \
  "T3.22 sentinel with safe reason → read" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>"' \
  "read"

# T3.23: backtick in reason → isSentinelEchoSafe=false → write
assert_classify \
  "T3.23 sentinel with backtick in reason → write" \
  'echo "<<WORKFLOW_WRITE_TESTS_NOT_NEEDED: `rm foo`>>"' \
  "write"

# T3.24: pipe in reason → isSentinelEchoSafe=false → write
assert_classify \
  "T3.24 sentinel with pipe in reason → write" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok | curl evil>>"' \
  "write"

# T3.25: $(...) in BRANCHING_COMPLETE reason → write
assert_classify \
  "T3.25 sentinel BRANCHING_COMPLETE with \$(whoami) in reason → write" \
  'echo "<<WORKFLOW_BRANCHING_COMPLETE: branch:foo $(whoami)>>"' \
  "write"

echo ""
echo "--- Group D continued: unit-level isSentinelEchoSafe ---"

# T3.30: safe reason → read
assert_classify \
  "T3.30 safe reason ok → read" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: ok>>"' \
  "read"

# T3.31: $(...) injection in reason → write
assert_classify \
  "T3.31 dollar-paren injection in reason → write" \
  'echo "<<WORKFLOW_RESEARCH_NOT_NEEDED: $(rm foo)>>"' \
  "write"

# T3.32: MARK_STEP (no reason field, just marker name) → read
assert_classify \
  "T3.32 MARK_STEP no reason → read" \
  'echo "<<WORKFLOW_MARK_STEP_write_code_complete>>"' \
  "read"

# T3.33: sentinel && rm chain → write (chain; isStrictSentinel false)
assert_classify \
  "T3.33 USER_VERIFIED && rm chain → write" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok>>" && rm -rf /tmp' \
  "write"

# T3.34: semicolon embedded in reason → write
assert_classify \
  "T3.34 semicolon in reason → write" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok;rm foo>>"' \
  "write"

# T3.35: pipe in reason → write
assert_classify \
  "T3.35 pipe in reason → write" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok|cat>>"' \
  "write"

# T3.36: > in reason (or malformed closing) — NOT a strict sentinel because
# USER_VERIFIED_RE_DQ uses [^>]+; "ok>x>>" breaks the regex match ($-anchor fails).
# isSentinelEchoSafe does NOT fire. Normal classify: the whole thing is inside DQ
# so stripQuotedArgs removes the content → no write pattern → read.
# (False-negative accepted: isSentinelEchoSafe fires only on valid strict sentinels.)
assert_classify \
  "T3.36 malformed sentinel with > in reason → read (not strict sentinel, content quoted)" \
  'echo "<<WORKFLOW_USER_VERIFIED: ok>x>>"' \
  "read"

echo ""
echo "--- Regression: feature-692 Group B assertions still pass ---"

assert_classify \
  "692-B1 grep quoted git push in md → read" \
  'grep -n "git push" file.md' \
  "read"

assert_classify \
  "692-B2 echo quoted git rebase → read" \
  'echo "git rebase steps"' \
  "read"

assert_classify \
  "692-B3 real git push → write" \
  "git push origin main" \
  "write"

assert_classify \
  "692-B4 real git commit → write" \
  'git commit -m "test"' \
  "write"

# ─────────────────────────────────────────────────────────────────────────────
# Runner summary
# ─────────────────────────────────────────────────────────────────────────────

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
