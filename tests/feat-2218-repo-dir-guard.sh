#!/usr/bin/env bash
# tests/feat-2218-repo-dir-guard.sh
# Tests: bin/workflow/lib/next-step/repo-dir-guard.js, bin/workflow/lib/next-step/verdict.js, bin/workflow/next-step
# Tags: next-step, repo-dir, fail-fast, cross-session, worktree-identity, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 9 — next-step's repoDir is resolved from the CALLING process, so a cross-session `--session <other-sid>` invocation would otherwise evaluate another session's workflow against this worktree's evidence. The guard decides, per verdict, whether that is silently fine (`same`), provably fine (`sibling-worktree` + identical content), or must stop the evaluation outright.

# TL3 gap: a real Claude Code session where session-start passes `--session <own-sid>` on a machine whose git is broken is not exercised; nor is a junction/8.3-name worktree pair, which needs a Windows host with those features enabled. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): every case is expected to FAIL with "MODULE NOT FOUND: bin/workflow/lib/next-step/repo-dir-guard.js".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

TARGET="bin/workflow/lib/next-step/repo-dir-guard.js"

# RED gate: the module under test does not exist yet. Name the expected path
# instead of skipping — a silent skip would read as green.
require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 9, not yet implemented (write_code has not run)"
    return 1
}

# Shared preamble for the node snippets. `verdictOf` tolerates either a bare
# verdict string or a {verdict} wrapper; `outcome` reduces the guard's two
# possible refusal shapes (throw, or a falsy/ok:false return) to one word, so a
# case asserts the DECISION rather than the implementation's error style.
PRELUDE="
const guard = require('$AGENTS_DIR_NODE/$TARGET');
function verdictOf(v) { return (v && typeof v === 'object') ? (v.verdict || v.result || JSON.stringify(v)) : String(v); }
function outcome(fn) {
  try { const r = fn(); if (r && r.ok === false) return 'fail-fast'; return 'continue'; }
  catch (e) { return 'fail-fast'; }
}
"

run_node() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" \
        HOME="$tn/home" USERPROFILE="$tn/home" \
        "$RWT" 60 node -e "$1" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    printf '%s' "$out"
}

init_repo() {
    git init -q "$1" 2>/dev/null
    git -C "$1" config core.hooksPath /dev/null
    git -C "$1" config user.email 't@example.com'
    git -C "$1" config user.name 'fixture'
    git -C "$1" config commit.gpgsign false
    printf 'seed\n' > "$1/f.txt"
    git -C "$1" add -A
    # Pinned author/committer date: two independent init_repo calls with
    # identical tree content must produce a byte-identical commit hash
    # deterministically. Without this, R6's HEAD-equality-dependent cases
    # (both the 'true' pairs and the untracked-axis 'false' pairs, which all
    # need HEAD to match before the intended branch runs) pass or fail based
    # on whether both commits land in the same wall-clock second.
    GIT_AUTHOR_DATE='2020-01-01T00:00:00Z' GIT_COMMITTER_DATE='2020-01-01T00:00:00Z' \
        git -C "$1" commit -q -m init
}

# R1 — lexical normalization (algorithm step 2). The drive-letter forms are the
# hole `inheritance/context-match.js` samePath() has today: a session that
# recorded `/c/git/agents` must still match a repoDir of `C:\git\agents`.
run_R1() {
    require_module "$TARGET" || return 0
    case "${OSTYPE:-unknown}" in
        msys*|cygwin*|win32*) : ;;
        *)
        skip "R1: drive-letter normalization is win32-only (OSTYPE=${OSTYPE:-unknown})"
        return 0
        ;;
    esac
    local out
    out="$(run_node "
$PRELUDE
const problems = [];
const target = 'C:' + String.fromCharCode(92) + 'git' + String.fromCharCode(92) + 'agents';
const forms = ['/c/git/agents', 'c:/git/agents', 'C:/git/agents', target, target + String.fromCharCode(92), 'c:/GIT/agents/'];
for (const f of forms) {
  const v = verdictOf(guard.compareRepoIdentity(f, target));
  if (v !== 'same') problems.push(JSON.stringify(f) + ':' + v);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "R1: POSIX drive-letter forms, trailing separator and case differences all normalize to 'same'"
    else
        fail "R1: expected 'OK', got '${out:-<err>}'"
    fi
}

# R2 — git identity (algorithm step 3): a linked worktree shares
# --git-common-dir but not --show-toplevel, and an unrelated repo shares
# neither. Lexically all three pairs are simply "different strings".
run_R2() {
    require_module "$TARGET" || return 0
    local tmp main wt other out
    tmp="$(make_tmp)"
    main="$tmp/main"; wt="$tmp/linked"; other="$tmp/other"
    init_repo "$main"
    init_repo "$other"
    git -C "$main" worktree add -q -b feature/wt "$wt" 2>/dev/null
    if [ ! -d "$wt" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "R2: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node -e "
$PRELUDE
const problems = [];
const main = '$(node_path "$main")';
const wt = '$(node_path "$wt")';
const other = '$(node_path "$other")';
const cases = [[main, main, 'same'], [main, wt, 'sibling-worktree'], [wt, main, 'sibling-worktree'], [main, other, 'different-repo']];
for (const c of cases) {
  const v = verdictOf(guard.compareRepoIdentity(c[0], c[1]));
  if (v !== c[2]) problems.push(c[0] + ' vs ' + c[1] + ':want=' + c[2] + ',got=' + v);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "R2: linked worktree is 'sibling-worktree', unrelated repo is 'different-repo', same path is 'same'"
    else
        fail "R2: expected 'OK', got '${out:-<err>}'"
    fi
}

# R3 — `unknown` (no recorded cwd). Always fails open regardless of
# isExplicitSessionOverride: unknown means no recorded cwd exists to compare
# against at all, never evidence of a cross-session call. Both paths warn.
run_R3() {
    require_module "$TARGET" || return 0
    local out
    out="$(run_node "
$PRELUDE
const { writeState, createInitialState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const problems = [];
writeState('sid-r3', createInitialState('sid-r3', {}));
const v = verdictOf(guard.compareRepoIdentity(null, '/anywhere'));
if (v !== 'unknown') problems.push('verdict:' + v);
const self = outcome(() => guard.assertRepoDirMatchesSession('sid-r3', '/anywhere', { isExplicitSessionOverride: false }));
if (self !== 'continue') problems.push('self-call-not-fail-open:' + self);
const cross = outcome(() => guard.assertRepoDirMatchesSession('sid-r3', '/anywhere', { isExplicitSessionOverride: true }));
if (cross !== 'continue') problems.push('cross-session-not-fail-open:' + cross);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    # Both calls fail-open through the warning-writing UNKNOWN branch, so stderr
    # carries two 'repo-context-unverified' lines ahead of the stdout verdict
    # (run_node merges 2>&1) — match on the trailing marker, not exact equality.
    case "$out" in
        *BAD:*|"") fail "R3: expected 'OK', got '${out:-<err>}'" ;;
        *OK) pass "R3: unknown fails open regardless of isExplicitSessionOverride" ;;
        *) fail "R3: expected 'OK', got '${out:-<err>}'" ;;
    esac
    local warn
    warn="$(run_node "
$PRELUDE
const { writeState, createInitialState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
writeState('sid-r3w', createInitialState('sid-r3w', {}));
try { guard.assertRepoDirMatchesSession('sid-r3w', '/anywhere', { isExplicitSessionOverride: false }); } catch (e) {}
")"
    case "$warn" in
        *repo-context-unverified*) pass "R3b: unknown warns 'repo-context-unverified' on the fail-open path" ;;
        *) fail "R3b: expected a 'repo-context-unverified' warning, got '${warn:-<empty>}'" ;;
    esac
}

# R4 — `indeterminate` (the comparison itself failed). Distinct from `unknown`:
# here there IS a recorded cwd, but git could not speak for it. Always
# fail-fast, self-call included — round1-fix C3 closed exactly this
# "reintroduce the bug through a broken-git edge case" path.
run_R4() {
    require_module "$TARGET" || return 0
    local tmp out
    tmp="$(make_tmp)"
    mkdir -p "$tmp/plain-a" "$tmp/plain-b"
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 node -e "
$PRELUDE
const { writeState, createInitialState } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const problems = [];
const a = '$(node_path "$tmp/plain-a")';
const b = '$(node_path "$tmp/plain-b")';
const v = verdictOf(guard.compareRepoIdentity(a, b));
if (v !== 'indeterminate') problems.push('verdict:' + v);
writeState('sid-r4', createInitialState('sid-r4', { cwd: a }));
for (const override of [false, true]) {
  const o = outcome(() => guard.assertRepoDirMatchesSession('sid-r4', b, { isExplicitSessionOverride: override }));
  if (o !== 'fail-fast') problems.push('override=' + override + ':' + o);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "R4: indeterminate fails fast regardless of call shape, and is not conflated with unknown"
    else
        fail "R4: expected 'OK', got '${out:-<err>}'"
    fi
}

# R5 — how isExplicitSessionOverride is COMPUTED (round3-fix C3). A presence
# check ("was --session passed?") mislabels the self-call at
# hooks/session-start.js:225, which passes --session <own-sid> explicitly. Only
# a VALUE comparison against resolveSessionId({}) separates the two.
run_R5_static() {
    require_module "$TARGET" || return 0
    local vfile out
    vfile="$AGENTS_DIR/bin/workflow/lib/next-step/verdict.js"
    if [ ! -f "$vfile" ]; then
        fail "R5-static: bin/workflow/lib/next-step/verdict.js not found"
        return 0
    fi
    out="$(run_node "
const fs = require('fs');
const src = fs.readFileSync('$(node_path "$vfile")', 'utf8');
const problems = [];
if (src.indexOf('assertRepoDirMatchesSession') === -1) problems.push('guard-not-called-from-verdict');
if (!/resolveSessionId\(\s*\{\s*\}\s*\)/.test(src)) problems.push('ownSid-not-resolved-via-resolveSessionId({})');
const line = src.split(String.fromCharCode(10)).find((l) => /isExplicitSessionOverride\s*=/.test(l)) || '';
if (!line) problems.push('isExplicitSessionOverride-not-assigned');
else {
  if (line.indexOf('!==') === -1) problems.push('not-a-value-comparison:' + line.trim());
  if (/!==\s*(undefined|null)|!=\s*null|Boolean\(|!!|typeof/.test(line)) problems.push('presence-check-detected:' + line.trim());
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
")"
    if [ "$out" = "OK" ]; then
        pass "R5-static: verdict.js derives isExplicitSessionOverride by comparing sid against resolveSessionId({})"
    else
        fail "R5-static: expected 'OK', got '${out:-<err>}'"
    fi
}

# R5-behavioral — the same rule observed end to end through the CLI, on all
# three call shapes. Case (ii) is the regression round3 found: omitting it
# leaves the presence-check bug invisible.
run_R5_cli() {
    require_module "$TARGET" || return 0
    local tmp own other repo main rc out result
    tmp="$(make_tmp)"
    # repo (== the linked worktree) is what CLAUDE_PROJECT_DIR points at for
    # every probe below — i.e. what next-step resolves as its OWN repoDir.
    # `own`'s recorded cwd is set to this same dir (verdict SAME, continues
    # regardless of override). `other`'s recorded cwd is the sibling main
    # checkout, and repo is made to diverge from it (an extra commit) so the
    # SIBLING verdict's content-equivalence check fails for a genuine
    # cross-session call — this is what actually exercises the
    # isExplicitSessionOverride axis, rather than an unrelated empty
    # closes_issues gate uniformly blocking all three probes.
    main="$tmp/main"; repo="$tmp/wt"
    init_repo "$main"
    git -C "$main" worktree add -q -b feature/r5 "$repo" 2>/dev/null
    if [ ! -d "$repo" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "R5-cli: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    printf 'ahead\n' > "$repo/ahead.txt"
    git -C "$repo" add -A
    git -C "$repo" commit -q -m ahead
    own="own-sid-r5"; other="other-sid-r5"; ownmain="own-main-sid-r5"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { writeState, createInitialState, markStep } = require('$AGENTS_DIR_NODE/hooks/workflow-state/state-io');
const own = createInitialState('$own', { cwd: '$(node_path "$repo")' });
own.closes_issues = [2218];
writeState('$own', own);
markStep('$own', 'workflow_init', 'complete');
const other = createInitialState('$other', { cwd: '$(node_path "$main")' });
other.closes_issues = [2218];
writeState('$other', other);
markStep('$other', 'workflow_init', 'complete');
const ownmain = createInitialState('$ownmain', { cwd: '$(node_path "$main")' });
ownmain.closes_issues = [2218];
writeState('$ownmain', ownmain);
markStep('$ownmain', 'workflow_init', 'complete');
" >/dev/null 2>&1
    # "fail-fast observed" := non-zero exit, or an abort/blocked ACTION line.
    probe() {
        local env_sid="$1" args_sid="$2" o r
        if [ -z "$args_sid" ]; then
            o=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$env_sid" \
                CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
                CLAUDE_PROJECT_DIR="$repo" HOME="$tmp/home" USERPROFILE="$tmp/home" \
                "$RWT" 60 node "$AGENTS_DIR/bin/workflow/next-step" 2>&1)
            r=$?
        else
            o=$(env -u CLAUDE_CODE_SESSION_ID CLAUDE_SESSION_ID="$env_sid" \
                CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
                CLAUDE_PROJECT_DIR="$repo" HOME="$tmp/home" USERPROFILE="$tmp/home" \
                "$RWT" 60 node "$AGENTS_DIR/bin/workflow/next-step" --session "$args_sid" 2>&1)
            r=$?
        fi
        if [ "$r" -ne 0 ]; then printf 'fail-fast'; return 0; fi
        case "$o" in
            *ACTION=abort*|*ACTION=blocked*) printf 'fail-fast' ;;
            *) printf 'continue' ;;
        esac
    }
    result=""
    out="$(probe "$own" "")"
    [ "$out" = "continue" ] || result="$result omitted-session:$out"
    out="$(probe "$own" "$own")"
    [ "$out" = "continue" ] || result="$result explicit-own-sid:$out"
    out="$(probe "$own" "$other")"
    [ "$out" = "fail-fast" ] || result="$result explicit-other-sid:$out"
    # SIBLING-self-call: recorded cwd is $main (a real sibling of $repo, not
    # $repo itself), so the SAME-verdict short-circuit above does NOT apply —
    # the guard must reach the SIBLING branch's content-equivalence check.
    # $repo has an extra "ahead" commit vs $main, so content is NOT
    # equivalent; only the self-call fail-open path (repo-dir-guard.js
    # SIBLING branch, isExplicitSessionOverride=false) can still let this
    # continue. Exercised both via omitted --session and an explicit
    # self-referencing --session, since either shape must compute
    # isExplicitSessionOverride=false for the same env/args sid.
    out="$(probe "$ownmain" "")"
    [ "$out" = "continue" ] || result="$result sibling-self-omitted-session:$out"
    out="$(probe "$ownmain" "$ownmain")"
    [ "$out" = "continue" ] || result="$result sibling-self-explicit-own-sid:$out"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$result" ]; then
        pass "R5-cli: --session omitted and --session <own-sid> both continue (SAME and content-divergent SIBLING-self); --session <other-sid> fails fast"
    else
        fail "R5-cli: unexpected outcomes —$result"
    fi
}

# R6 — compareRepoContentEquivalence, every branch. "Different worktree path"
# is not "different content", so a sibling pair gets one more chance before the
# guard stops the run; branch (4) folds spawn failure into not-equivalent so
# there is no undocumented third outcome, and branch (5) covers the untracked
# axis, where anything the guard cannot prove equal is reported as unequal.
run_R6() {
    require_module "$TARGET" || return 0
    local tmp out
    tmp="$(make_tmp)"
    init_repo "$tmp/base"
    git -C "$tmp/base" worktree add -q -b feature/eq "$tmp/eq" 2>/dev/null
    if [ ! -d "$tmp/eq" ]; then
        rm -rf "$tmp" 2>/dev/null || true
        fail "R6: fixture setup failed — could not create a linked worktree"
        return 0
    fi
    # (1) HEAD mismatch: the linked worktree gains a commit the base lacks.
    printf 'ahead\n' > "$tmp/eq/ahead.txt"
    git -C "$tmp/eq" add -A
    git -C "$tmp/eq" commit -q -m ahead
    # (3)/(4) dirty pair: identical edit on both sides, then a divergent one.
    init_repo "$tmp/d1"
    init_repo "$tmp/d2"
    printf 'seed\nedit\n' > "$tmp/d1/f.txt"
    printf 'seed\nedit\n' > "$tmp/d2/f.txt"
    init_repo "$tmp/x1"
    init_repo "$tmp/x2"
    printf 'seed\nleft\n' > "$tmp/x1/f.txt"
    printf 'seed\nright\n' > "$tmp/x2/f.txt"
    mkdir -p "$tmp/nogit"
    # (5) untracked axis. `git diff HEAD` is blind to untracked files, so every
    # pair below leaves the tracked tree pristine and varies only what is
    # untracked — a tracked-diff-only guard would call all of them equivalent.
    init_repo "$tmp/u1"
    init_repo "$tmp/u2"
    printf 'same\n' > "$tmp/u1/extra.txt"
    printf 'same\n' > "$tmp/u2/extra.txt"
    init_repo "$tmp/p1"
    init_repo "$tmp/p2"
    printf 'same\n' > "$tmp/p1/extra.txt"
    init_repo "$tmp/c1"
    init_repo "$tmp/c2"
    printf 'aaaa\n' > "$tmp/c1/extra.txt"
    printf 'bbbb\n' > "$tmp/c2/extra.txt"
    # Oversize pair: byte-identical, but past MAX_UNTRACKED_COMPARE_BYTES the
    # guard refuses to read them into memory to prove it, so equivalence is
    # denied rather than downgraded to a size-only match.
    init_repo "$tmp/b1"
    init_repo "$tmp/b2"
    node -e "require('fs').writeFileSync(process.argv[1], Buffer.alloc(1024*1024+16, 97))" "$tmp/b1/big.bin"
    node -e "require('fs').writeFileSync(process.argv[1], Buffer.alloc(1024*1024+16, 97))" "$tmp/b2/big.bin"
    # Symlink pair with the same target on both sides. The guard lstats rather
    # than stats, so it sees a link — not a regular file — and refuses; it never
    # follows the link into a target that could be anything. Windows without
    # developer mode turns `symlink` into a copy, which would silently test a
    # regular file instead, so drop the row unless real links were created.
    init_repo "$tmp/s1"
    init_repo "$tmp/s2"
    node -e "try{require('fs').symlinkSync('f.txt',process.argv[1])}catch(e){}" "$tmp/s1/link"
    node -e "try{require('fs').symlinkSync('f.txt',process.argv[1])}catch(e){}" "$tmp/s2/link"
    local symlink_row="" symlink_note=" (symlink row skipped — host cannot create symlinks)"
    if [ -L "$tmp/s1/link" ] && [ -L "$tmp/s2/link" ]; then
        symlink_row="['untracked-symlink-same-target', '$(node_path "$tmp/s1")', '$(node_path "$tmp/s2")', false],"
        symlink_note=""
    fi
    out=$(env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_PROJECT_DIR \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 90 node -e "
$PRELUDE
const problems = [];
function eq(a, b) {
  const r = guard.compareRepoContentEquivalence(a, b);
  if (typeof r === 'boolean') return r;
  if (r && typeof r === 'object') return r.equivalent === true;
  return null;
}
const base = '$(node_path "$tmp/base")';
const ahead = '$(node_path "$tmp/eq")';
const clean1 = '$(node_path "$tmp/d1")';
const cases = [
  ['head-mismatch', base, ahead, false],
  ['both-clean-head-match', base, base, true],
  ['dirty-diff-identical', '$(node_path "$tmp/d1")', '$(node_path "$tmp/d2")', true],
  ['dirty-diff-different', '$(node_path "$tmp/x1")', '$(node_path "$tmp/x2")', false],
  ['spawn-failure', clean1, '$(node_path "$tmp/nogit")', false],
  ['untracked-identical', '$(node_path "$tmp/u1")', '$(node_path "$tmp/u2")', true],
  ['untracked-path-set-mismatch', '$(node_path "$tmp/p1")', '$(node_path "$tmp/p2")', false],
  ['untracked-content-mismatch-equal-size', '$(node_path "$tmp/c1")', '$(node_path "$tmp/c2")', false],
  ['untracked-oversize-byte-identical', '$(node_path "$tmp/b1")', '$(node_path "$tmp/b2")', false],
  $symlink_row
];
for (const c of cases) {
  const got = eq(c[1], c[2]);
  if (got === null) problems.push(c[0] + ':unreadable-return');
  else if (got !== c[3]) problems.push(c[0] + ':want=' + c[3] + ',got=' + got);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "R6: content equivalence is 2-valued — HEAD mismatch, dirty-diff mismatch, spawn failure and every unprovable untracked pair (path-set, content, oversize, symlink) land on not-equivalent$symlink_note"
    else
        fail "R6: expected 'OK', got '${out:-<err>}'"
    fi
}

run_R1
run_R2
run_R3
run_R4
run_R5_static
run_R5_cli
run_R6

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
