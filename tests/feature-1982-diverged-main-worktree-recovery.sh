#!/bin/bash
# tests/feature-1982-diverged-main-worktree-recovery.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/main-worktree-allows/standard.js
# Tags: enforce-worktree, main-worktree-cleanup, merge-recovery, feature-1982, scope:issue-specific
# TL3 gap (what this test does NOT catch):
#   - Whether enforce-worktree.js correctly routes the isAllowedMainWorktreeCleanup
#     merge branch via the real Claude Code PreToolUse dispatch chain in a live session
#   - Whether the upstream mismatch block (C1) triggers correctly when git config
#     is modified live during a session
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _A="$(cygpath -m "$AGENTS_DIR")"; else _A="$AGENTS_DIR"; fi
GUARD_JS="${_A}/hooks/enforce-worktree.js"
HOOK="${_A}/hooks/enforce-worktree.js"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS+1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL+1)); }

run_with_timeout() {
  local secs="$1"; shift
  if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
  else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

TMPBASE="$(mktemp -d 2>/dev/null || mktemp -d -t feat1982)"
trap 'rm -rf "$TMPBASE" 2>/dev/null' EXIT

# --- direct-predicate helpers ------------------------------------------------
check_mc() {
  run_with_timeout 15 node -e "
    const {isAllowedMainWorktreeCleanup}=require('$GUARD_JS');
    console.log(isAllowedMainWorktreeCleanup(process.argv[1],process.argv[2])?'allow':'reject');
  " -- "$1" "$2" 2>/dev/null
}
assert_allow() { local got; got="$(check_mc "$1" "$2")"; [ "$got" = "allow"  ] && pass "$3" || fail "$3 (got=$got)"; }
assert_block() { local got; got="$(check_mc "$1" "$2")"; [ "$got" = "reject" ] && pass "$3" || fail "$3 (got=$got)"; }

check_ff() {
  run_with_timeout 15 node -e "
    const {isAllowedFastForwardMerge}=require('$GUARD_JS');
    console.log(isAllowedFastForwardMerge(process.argv[1])?'allow':'reject');
  " -- "$1" 2>/dev/null
}
assert_ff_allow() { local got; got="$(check_ff "$1")"; [ "$got" = "allow"  ] && pass "$2" || fail "$2 (got=$got)"; }
assert_ff_block() { local got; got="$(check_ff "$1")"; [ "$got" = "reject" ] && pass "$2" || fail "$2 (got=$got)"; }

# --- enforcement-route helpers ----------------------------------------------
build_json_file() {
  local json_file="$1" cmd="$2" cwd="$3" sid="$4"
  node -e "
var fs = require('fs');
var obj = {tool_name:'Bash',tool_input:{command:process.argv[2],cwd:process.argv[3]},session_id:process.argv[4]};
fs.writeFileSync(process.argv[1], JSON.stringify(obj));
" "$json_file" "$cmd" "$cwd" "$sid"
}

# run_hook <json_file> <tmpdir_node> <main_cwd>
# CRITICAL: hook is launched FROM the fixture main CWD so that process.cwd()
# lands inside the fixture repo → session scope includes it → the allowlist
# is actually exercised (rather than short-circuiting as out-of-scope).
# Sets HOOK_RC so an allow (empty stdout) can be told apart from a crash.
HOOK_RC=0
run_hook() {
  local json_file="$1" tmpdir_node="$2" main_cwd="$3" out
  out=$(WORKFLOW_PLANS_DIR="$tmpdir_node" ENFORCE_WORKTREE=on \
    run_with_timeout 15 bash -c "cd '$main_cwd' && cat '$json_file' | node '$HOOK'" 2>/dev/null)
  HOOK_RC=$?
  printf '%s' "$out"
}

# assert_hook_allowed <label> <hook_stdout> <hook_rc>
# Empty stdout counts as "allowed" only when the hook exited 0 — a crash or
# timeout also yields empty stdout and must not read as an allow.
assert_hook_allowed() {
  local label="$1" out="$2" rc="$3" result
  if [ -z "$out" ]; then
    [ "$rc" = "0" ] && result="OK" || result="NO_OUTPUT_RC=$rc"
  else
    result=$(node -e "
try { var r=JSON.parse(process.argv[1]);
  console.log((r.decision&&r.decision==='block')?'BLOCKED:'+String(r.reason).substring(0,80):'OK');
} catch(e) { console.log('PARSE_ERR:'+String(process.argv[1]).substring(0,60)); }
" "$out" 2>/dev/null)
  fi
  [ "$result" = "OK" ] && pass "$label: hook allowed" || fail "$label: expected allow — got: $result"
}

assert_hook_blocked() {
  local label="$1" out="$2" result
  result=$(node -e "
try { var r=JSON.parse(process.argv[1]);
  console.log((r.decision&&r.decision==='block')?'OK':'NOT_BLOCKED');
} catch(e) { console.log('PARSE_ERR:'+String(process.argv[1]).substring(0,60)); }
" "$out" 2>/dev/null)
  [ "$result" = "OK" ] && pass "$label: hook blocked" || fail "$label: expected block — got: $result"
}

norm() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# ============================================================================
# Fixture: bare remote + main clone in a 1-ahead / 1-behind diverged state
# ============================================================================
REMOTE_BARE="$TMPBASE/remote.git"
git init --bare -q -b main "$REMOTE_BARE" 2>/dev/null || git init --bare -q "$REMOTE_BARE"

INIT_CLONE="$TMPBASE/init-clone"
git clone -q "$REMOTE_BARE" "$INIT_CLONE" 2>/dev/null
git -C "$INIT_CLONE" checkout -q -b main 2>/dev/null
git -C "$INIT_CLONE" config user.email "test@example.com"
git -C "$INIT_CLONE" config user.name "Test"
git -C "$INIT_CLONE" config core.hooksPath /dev/null
git -C "$INIT_CLONE" config core.autocrlf false
echo "init" > "$INIT_CLONE/README.md"
git -C "$INIT_CLONE" add README.md
git -C "$INIT_CLONE" commit --no-verify -q -m "init"
git -C "$INIT_CLONE" push -q origin main

# make_main_clone <dest> — clone of the bare remote with one local commit ahead
make_main_clone() {
  local dest="$1"
  git clone -q "$REMOTE_BARE" "$dest" 2>/dev/null
  git -C "$dest" config user.email "test@example.com"
  git -C "$dest" config user.name "Test"
  git -C "$dest" config core.hooksPath /dev/null
  git -C "$dest" config core.autocrlf false
  echo "local" > "$dest/local.txt"
  git -C "$dest" add local.txt
  git -C "$dest" commit --no-verify -q -m "local commit (ahead)"
}

MAIN_CLONE="$TMPBASE/main"
MAIN_WITH_WT="$TMPBASE/main-with-wt"
make_main_clone "$MAIN_CLONE"
make_main_clone "$MAIN_WITH_WT"

# Advance the remote so both clones become 1-behind as well as 1-ahead.
echo "remote" > "$INIT_CLONE/remote.txt"
git -C "$INIT_CLONE" add remote.txt
git -C "$INIT_CLONE" commit --no-verify -q -m "remote commit (behind)"
git -C "$INIT_CLONE" push -q origin main

git -C "$MAIN_CLONE" fetch -q origin
git -C "$MAIN_WITH_WT" fetch -q origin

# Linked worktree on the second fixture (exercises the worktree-count gate).
git -C "$MAIN_WITH_WT" worktree add -q -b feature/wt "$TMPBASE/wt-linked" HEAD 2>/dev/null

WT_COUNT=$(git -C "$MAIN_WITH_WT" worktree list --porcelain 2>/dev/null | grep -c '^worktree ')
if [ "$WT_COUNT" != "2" ]; then
  echo "SETUP_ERROR: MAIN_WITH_WT expected 2 worktrees, got $WT_COUNT"
  exit 1
fi

AHEAD=$(git -C "$MAIN_CLONE" rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
BEHIND=$(git -C "$MAIN_CLONE" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
if [ "$AHEAD" != "1" ] || [ "$BEHIND" != "1" ]; then
  echo "SETUP_ERROR: expected 1 ahead 1 behind, got ahead=$AHEAD behind=$BEHIND"
  exit 1
fi

MAIN_N="$(norm "$MAIN_CLONE")"
MAIN_WITH_WT_N="$(norm "$MAIN_WITH_WT")"
TMP_N="$(norm "$TMPBASE")"

echo "=== Section A: isAllowedFastForwardMerge boundary (CPR-ORTH) ==="
assert_ff_allow "git pull --ff-only origin/main"  "FF-1: ff-only pull allowed by ff predicate"
assert_ff_allow "git merge --ff-only origin/main" "FF-2: ff-only merge allowed by ff predicate"
assert_ff_block "git merge --no-edit origin/main" "FF-3: --no-edit merge NOT in ff predicate (the gap)"
assert_ff_block "git merge origin/main"           "FF-4: flagless merge NOT in ff predicate"

echo "=== Section B: C1 upstream-boundary edge cases ==="
# B1: resolveUpstream returns null when no upstream tracking is configured.
# The !upstream branch of the C1 guard must reject — distinct from ADV-1
# (wrong-branch mismatch) which exercises upstream !== "origin/"+branch.
NO_UP="$TMPBASE/no-upstream"
git clone -q "$REMOTE_BARE" "$NO_UP" 2>/dev/null
git -C "$NO_UP" config user.email "test@example.com"
git -C "$NO_UP" config user.name "Test"
git -C "$NO_UP" config core.hooksPath /dev/null
git -C "$NO_UP" config core.autocrlf false
git -C "$NO_UP" branch --unset-upstream main 2>/dev/null || true
NO_UP_N="$(norm "$NO_UP")"
assert_block "git merge --no-edit origin/main" "$NO_UP_N" \
  "B1: no upstream tracking → merge rejected (C1: !upstream)"

echo "=== Section D: real git execution (gap confirmation) ==="
git -C "$MAIN_CLONE" fetch -q origin 2>/dev/null
AHEAD2=$(git -C "$MAIN_CLONE" rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
BEHIND2=$(git -C "$MAIN_CLONE" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
{ [ "$AHEAD2" = "1" ] && [ "$BEHIND2" = "1" ]; } \
  && pass "RED-D1: fetch does not resolve divergence (still 1/1)" \
  || fail "RED-D1: unexpected state (ahead=$AHEAD2 behind=$BEHIND2)"

if ! run_with_timeout 10 git -C "$MAIN_CLONE" pull --ff-only origin main >/dev/null 2>&1; then
  pass "RED-D2: git pull --ff-only fails on diverged graph (expected)"
else
  fail "RED-D2: git pull --ff-only unexpectedly succeeded (fixture divergence broken)"
fi

# Sanctioned cleanup commands run, but leave the divergence untouched.
echo "dirty" >> "$MAIN_CLONE/local.txt"
run_with_timeout 10 git -C "$MAIN_CLONE" stash push -q >/dev/null 2>&1
run_with_timeout 10 git -C "$MAIN_CLONE" restore local.txt >/dev/null 2>&1
run_with_timeout 10 git -C "$MAIN_CLONE" checkout -- local.txt >/dev/null 2>&1
AHEAD3=$(git -C "$MAIN_CLONE" rev-list --count origin/main..HEAD 2>/dev/null || echo "0")
BEHIND3=$(git -C "$MAIN_CLONE" rev-list --count HEAD..origin/main 2>/dev/null || echo "0")
{ [ "$AHEAD3" = "1" ] && [ "$BEHIND3" = "1" ]; } \
  && pass "RED-D3: stash/restore/checkout leave divergence at 1/1 (no recovery path)" \
  || fail "RED-D3: unexpected state (ahead=$AHEAD3 behind=$BEHIND3)"

echo "=== Section E: sanctioned merge recovery (post-fix) ==="
# Pin the target behaviour: `git merge --no-edit origin/main` is the
# sanctioned main-worktree recovery command.
assert_allow "git merge --no-edit origin/main" "$MAIN_N" \
  "GREEN-E1: merge allowed post-fix (isAllowedMainWorktreeCleanup)"

JSON_GREEN="$TMPBASE/green.json"
build_json_file "$JSON_GREEN" "git merge --no-edit origin/main" "$MAIN_N" "sess-1982-green"
OUT_GREEN="$(run_hook "$JSON_GREEN" "$TMP_N" "$MAIN_CLONE"; echo "|rc=$HOOK_RC")"
GREEN_RC="${OUT_GREEN##*|rc=}"; OUT_GREEN="${OUT_GREEN%|rc=*}"
assert_hook_allowed "GREEN-E2" "$OUT_GREEN" "$GREEN_RC"

# No linked-worktree count gate on the merge branch: allowed even with a
# linked worktree present (unlike stash/restore/checkout).
assert_allow "git merge --no-edit origin/main" "$MAIN_WITH_WT_N" \
  "GREEN-E3: allow with linked worktree present (no count gate for merge)"

echo "=== Section F: boundary / adversarial (all must stay blocked) ==="
while IFS='|' read -r name cmd; do
  [ -z "${name// /}" ] && continue
  case "$name" in \#*) continue ;; esac
  name="${name//[[:space:]]/}"
  # trim leading/trailing whitespace from cmd
  cmd="${cmd#"${cmd%%[![:space:]]*}"}"
  cmd="${cmd%"${cmd##*[![:space:]]}"}"
  got="$(check_mc "$cmd" "$MAIN_N")"
  [ "$got" = "reject" ] && pass "$name: blocked ($cmd)" || fail "$name: expected block ($cmd) (got=$got)"
done <<'TABLE'
ADV-1  | git merge --no-edit origin/feature
ADV-2  | git merge --no-edit
ADV-3  | git merge --no-edit origin/main -s recursive
ADV-4  | git merge --no-edit origin/main -m msg
ADV-5  | git merge --abort --no-edit origin/main
ADV-6  | git merge --ff-only --no-edit origin/main
ADV-7  | git merge --no-ff --no-edit origin/main
ADV-8  | git merge -e --no-edit origin/main
ADV-9  | git merge --no-edit origin/main:other
ADV-10 | git merge --no-edit +origin/main
ADV-11 | git merge --no-edit refs/remotes/origin/main
ADV-12 | git -c core.sshCommand=curl merge --no-edit origin/main
ADV-13 | git --upload-pack=cmd merge --no-edit origin/main
ADV-14 | git --git-dir=/tmp/x merge --no-edit origin/main
ADV-15 | git --work-tree=/tmp/x merge --no-edit origin/main
ADV-16 | git --exec-path=/tmp/x merge --no-edit origin/main
ADV-17 | git --config-env=GIT_CONFIG=/tmp/x merge --no-edit origin/main
ADV-18 | sudo git merge --no-edit origin/main
ADV-19 | env git merge --no-edit origin/main
ADV-20 | exec git merge --no-edit origin/main
ADV-21 | command git merge --no-edit origin/main
ADV-22 | GIT_EDITOR=/tmp/payload git merge --no-edit origin/main
ADV-23 | VISUAL=evil git merge --no-edit origin/main
ADV-24 | EDITOR=evil git merge --no-edit origin/main
ADV-25 | my_var=foo git merge --no-edit origin/main
ADV-26 | echo git merge --no-edit origin/main
ADV-27 | git merge --no-edit origin/main && git push
ADV-28 | bash -c 'git merge --no-edit origin/main'
TABLE

echo ""
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
