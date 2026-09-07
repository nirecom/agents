#!/bin/bash
# tests/feature-2125-merge-detect-ir.sh
# Tests: hooks/lib/merge-detect.js, hooks/lib/command-ir.js, hooks/lib/shell-segments.js
# Tags: hook, merge-detect, command-ir, canary, enforce-worktree, table-driven, TL1, pwsh-not-required, scope:issue-specific

set -u

# #2125 Step 4 (detail.md S4) — merge-detect is canary-1 for the shell-segments
# -> IR migration. shell-segments.js splits only on `;` `&&` `||`, so `|` and `&`
# hide a protected-branch push. Sections are labelled RED (post-migration,
# failing today) or GREEN (behavior the migration must not disturb or RELAX).

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# TL3 gap: whether workflow-gate.js blocks the live Bash call is out of scope —
# this file drives the classifier directly. Closest-to-action mitigation: the
# registration is checked at WORKFLOW_USER_VERIFIED preflight by
# bin/check-verification-gate.sh, category hook-registration.

if command -v cygpath >/dev/null 2>&1; then AN="$(cygpath -m "$AGENTS_DIR")"; else AN="$AGENTS_DIR"; fi
MD="$AN/hooks/lib/merge-detect.js"
CIR="$AN/hooks/lib/command-ir.js"

# Fixture isolation (rules/test/fixture-isolation.md): the parent session's ids
# must never reach the child node processes, and DEFAULT_BRANCHES drives
# getProtectedBranches() — pin it so an ambient value cannot flip every verdict.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
export DEFAULT_BRANCHES="main,master"

PASS=0; FAIL=0; ROWS=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want='$want' got='$got'"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if [ -x "$AGENTS_DIR/bin/run-with-timeout.sh" ]; then "$AGENTS_DIR/bin/run-with-timeout.sh" "$secs" "$@"
    elif command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

abort_vacuous() {
    fail "M0: $1 — every case below would be vacuous"
    echo ""
    echo "Results: $PASS passed, $FAIL failed"
    exit 1
}

# M0 availability guards — without them every case scores an empty string.
command -v node >/dev/null 2>&1 || abort_vacuous "node unavailable"
[ -f "$MD" ] || abort_vacuous "hooks/lib/merge-detect.js missing"
[ -f "$CIR" ] || abort_vacuous "hooks/lib/command-ir.js missing"
M0_SANITY="$(run_with_timeout 30 node -e 'process.stdout.write(typeof require(process.argv[1]).isMergeToProtectedCommand + "/" + typeof require(process.argv[2]).parse)' "$MD" "$CIR" 2>/dev/null)"
assert_eq "M0: both modules load and export their entry points" "function/function" "$M0_SANITY"

# verdict <cmd> -> "<hit>:<kind>", e.g. "true:git-push-protected" / "false:null".
# "ERROR" on throw, so a crash can never be scored as an expected value.
verdict() {
    run_with_timeout 30 node -e '
try {
  const {isMergeToProtectedCommand}=require(process.argv[1]);
  const r=isMergeToProtectedCommand(process.argv[2], null);
  process.stdout.write(String(r.hit)+":"+String(r.kind));
} catch (e) { process.stdout.write("ERROR"); }
' "$MD" "$1" 2>/dev/null
}

# pf <cmd> -> "true"/"false": does parse() report parseFailure for this input?
pf() {
    run_with_timeout 30 node -e '
try {
  const {parse}=require(process.argv[1]);
  process.stdout.write(String(parse(process.argv[2]).parseFailure));
} catch (e) { process.stdout.write("ERROR"); }
' "$CIR" "$1" 2>/dev/null
}

# M1 (GREEN today, must stay green) — the `;` / `&&` / `||` rows are exactly what
# shell-segments.js already splits, so they are the direct non-regression pins
# for swapping in parse().
while IFS='|' read -r label want cmd; do
    [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
    label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
    ROWS=$((ROWS + 1))
    assert_eq "M1 $label" "$want" "$(verdict "$cmd")"
done <<'TABLE'
push-main            | true:git-push-protected  | git push origin main
push-master          | true:git-push-protected  | git push origin master
push-refs-heads-main | true:git-push-protected  | git push origin refs/heads/main
push-all             | true:git-push-protected  | git push --all origin
gh-pr-merge          | true:gh-pr-merge         | gh pr merge 123
gh-pr-merge-auto     | true:gh-pr-merge         | gh pr merge --auto --squash
semicolon-then-push  | true:git-push-protected  | cd /x; git push origin main
and-then-push        | true:git-push-protected  | cd /x && git push origin main
or-then-push         | true:git-push-protected  | false || git push origin main
push-feature         | false:null               | git push origin feature/x
push-feature-colon   | false:null               | git push origin HEAD:feature/x
quoted-push          | false:null               | echo "git push origin main"
plain-status         | false:null               | git status --short
empty                | false:null               |
TABLE

# ROW BUDGET (mirrors feature-2134-bash-guard.sh's ROWS_EXPECTED): a drifted heredoc delimiter
# or an early exit ahead of the loop would otherwise execute zero M1 rows and still report green.
M1_ROWS_EXPECTED=14
assert_eq "M1 BUDGET: every M1 row executed" "$M1_ROWS_EXPECTED" "$ROWS"

# M2 (RED until S4 lands) — the #2125 divergence. `|` and `&` are not split by
# shell-segments.js, so today the push in the right-hand segment is invisible.
# parse() splits on both: the fail-CLOSED direction #2125 requires.
assert_eq "M2 pipe-into-gh-merge" "true:gh-pr-merge" "$(verdict 'echo a | gh pr merge')"
assert_eq "M2 pipe-into-push" "true:git-push-protected" "$(verdict 'echo a | git push origin main')"
assert_eq "M2 amp-then-push" "true:git-push-protected" "$(verdict 'echo a & git push origin main')"
assert_eq "M2 amp-then-gh-merge" "true:gh-pr-merge" "$(verdict 'sleep 1 & gh pr merge 123')"
assert_eq "M2 pipe-chain-into-push" "true:git-push-protected" "$(verdict 'echo a | tee log | git push origin main')"

# M2 symmetric counterpart (CPR-ORTH): widening the split set must not make every
# piped/backgrounded line a hit. Without these, M2 passes on a blanket true.
assert_eq "M2 negative: pipe with no protected target stays a miss" "false:null" \
    "$(verdict 'echo a | git push origin feature/x')"
assert_eq "M2 negative: background with no merge command stays a miss" "false:null" \
    "$(verdict 'sleep 1 & echo done')"

# M3 (GREEN today, must stay green) — the current lexer shreds a `VAR=$(...)`
# assignment across segments while the new parser keeps it intact. The verdict is
# pinned either way, so the segmentation change cannot leak into the answer.
assert_eq "M3 substitution then protected push stays a hit" "true:git-push-protected" \
    "$(verdict 'VAR=$(echo x) && git push origin main')"
assert_eq "M3 substitution with no push stays a miss" "false:null" \
    "$(verdict 'VAR=$(echo x) && echo $VAR')"
# Measured (re-measured post-S4): parse() splits on `(` / `)`, so the substitution BODY
# becomes its own segment and the push inside it IS seen. Pinned exactly in both
# directions — an accept-either check would score a regression here as green.
assert_eq "M3 substitution-body protected push is a hit" "true:git-push-protected" \
    "$(verdict 'echo $(git push origin main)')"
assert_eq "M3 substitution-body feature push stays a miss" "false:null" \
    "$(verdict 'echo $(git push origin feature/x)')"

# M3-ESC (CPR-ORTH counterpart): an ESCAPED separator is a literal argument, not a split
# point, so the `git push` text belongs to the echo. The IR flags the link; merge-detect
# must honour that flag or every documented `\;` example reads as a protected push.
assert_eq "M3-ESC escaped semicolon before a protected push is not a hit" "false:null" \
    "$(verdict 'echo x \; git push origin main')"
assert_eq "M3-ESC fully-escaped && before a protected push is not a hit" "false:null" \
    "$(verdict 'echo a \&\& git push origin main')"
assert_eq "M3-ESC an unescaped semicolon still splits and still hits" "true:git-push-protected" \
    "$(verdict 'echo x ; git push origin main')"
# Verified against real bash (`bash -c 'echo a \&& echoB push origin main'` actually runs
# echoB as a separate command): `\&&` escapes ONLY the first `&`. Bash's tokenizer does not
# treat a partially-escaped compound operator as one unit — the escaped `&` becomes a literal
# word character and the second, unescaped `&` is a REAL background-operator split, so the
# push after it executes for real. The prior pin here (`false:null`) was wrong; this is the
# fail-CLOSED direction: a real protected-branch push must not slip past the guard.
assert_eq "M3-ESC partially-escaped && (only the first &) still splits on the live second & and still hits" \
    "true:git-push-protected" "$(verdict 'echo a \&& git push origin main')"
assert_eq "M3-ESC partially-escaped || (only the first |) still splits on the live second | and still hits" \
    "true:git-push-protected" "$(verdict 'echo a \|| git push origin main')"

# M4 (GREEN today; the pin a naive migration BREAKS) — detail.md S4-2.
# splitShellCommands never throws, so an unclosed quote still yields segments and
# still hits. parse() returns parseFailure:true with segments: [], so iterating
# ir.segments alone would answer false — a RELAXATION #2125 forbids. The
# migration therefore owes a whole-command fallback on parseFailure.
assert_eq "M4 precondition: unclosed dq is a parse failure" "true" "$(pf 'git push origin main "')"
assert_eq "M4 precondition: unclosed sq is a parse failure" "true" "$(pf "gh pr merge 123 'oops")"
assert_eq "M4 precondition: a well-formed command is not a parse failure" "false" "$(pf 'git push origin main')"
assert_eq "M4 unclosed dq around a protected push still hits" "true:git-push-protected" \
    "$(verdict 'git push origin main "')"
assert_eq "M4 unclosed sq around gh pr merge still hits" "true:gh-pr-merge" \
    "$(verdict "gh pr merge 123 'oops")"
assert_eq "M4 unclosed quote with no merge command stays a miss" "false:null" \
    "$(verdict 'echo "hello')"
assert_eq "M4 unclosed quote on a feature-branch push stays a miss" "false:null" \
    "$(verdict 'git push origin feature/x "')"

# M5 (RED until S4 lands) — the SSOT decoupling itself (#2125's headline).
# merge-detect must stop requiring shell-segments.js and read the IR instead;
# shell-segments.js survives (2 consumers remain) but drops its SSOT self-claim.
if grep -q 'require("\./shell-segments")' "$AGENTS_DIR/hooks/lib/merge-detect.js"; then
    fail "M5: merge-detect.js still requires ./shell-segments — canary-1 not migrated"
else
    pass "M5: merge-detect.js no longer requires ./shell-segments"
fi
if grep -q 'require("\./command-ir")' "$AGENTS_DIR/hooks/lib/merge-detect.js"; then
    pass "M5: merge-detect.js consumes ./command-ir"
else
    fail "M5: merge-detect.js does not consume ./command-ir — canary-1 not migrated"
fi
if grep -qi '^// SSOT for ' "$AGENTS_DIR/hooks/lib/shell-segments.js"; then
    fail "M5: shell-segments.js still claims to be the SSOT for shell segmentation"
else
    pass "M5: shell-segments.js dropped its SSOT self-claim"
fi
if [ -f "$AGENTS_DIR/hooks/lib/shell-segments.js" ]; then
    pass "M5: shell-segments.js is retained (deletion is out of this PR's scope)"
else
    fail "M5: shell-segments.js was deleted — out of scope (detail.md S4-4)"
fi

# M6 (GREEN today, must stay green) — the canary's blast radius. merge-detect
# backs workflow-gate.js (hard gate) AND workflow-mark.js (post-push reset); a
# migration that only kept the gate honest would still break the mark path.
for consumer in workflow-gate workflow-mark; do
    if grep -rq 'merge-detect' "$AGENTS_DIR/hooks/$consumer.js" "$AGENTS_DIR/hooks/$consumer" 2>/dev/null; then
        pass "M6: $consumer still consumes merge-detect"
    else
        fail "M6: $consumer lost its merge-detect consumption"
    fi
done
M6_BRANCHES="$(DEFAULT_BRANCHES=release run_with_timeout 30 node -e '
try {
  const {getProtectedBranches}=require(process.argv[1]);
  process.stdout.write(getProtectedBranches().join(","));
} catch (e) { process.stdout.write("ERROR"); }
' "$MD" 2>/dev/null)"
assert_eq "M6 getProtectedBranches still honours DEFAULT_BRANCHES" "release" "$M6_BRANCHES"
M6_NULL="$(run_with_timeout 30 node -e '
try {
  const {isMergeToProtectedCommand}=require(process.argv[1]);
  const r=isMergeToProtectedCommand(null, null);
  process.stdout.write(String(r.hit)+":"+String(r.kind));
} catch (e) { process.stdout.write("ERROR"); }
' "$MD" 2>/dev/null)"
assert_eq "M6 a non-string input is still handled without throwing" "false:null" "$M6_NULL"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
