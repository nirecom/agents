#!/usr/bin/env bash
# tests/bin/feature-2757-merge-base-advance.sh
# Tests: bin/resolve-merge-base.sh, bin/lib/resolve-merge-base-advance.sh
# Tags: merge-base, baseline, merge-in-progress, base-advance, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - a real origin remote and fetch; origin/main is a local remote-tracking ref and every run is --no-fetch
# Closest-to-action mitigation: bin/check-verification-gate.sh category: merge-base-suspect.
#
# #2757 — layer 1 follows a merge of main: the recorded base advances to the newest candidate
# merge-base(X, M), X in {HEAD, MERGE_HEAD...}, M in {origin/main, main}, that descends from the
# recorded base and is comparable with every other candidate; otherwise it stays (fail-safe).
set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMPROOT="$(make_tmp)"
readonly TMPROOT
trap 'rm -rf "$TMPROOT"' EXIT
harness_isolate "$TMPROOT/iso"
export HOME="$TMPROOT/home"
mkdir -p "$HOME" "$TMPROOT/cwd"
cd "$TMPROOT/cwd" || exit 1

command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }
command -v node >/dev/null 2>&1 || { echo "SKIP: node not available (layer 1 reads the record through node)"; exit 77; }

HELPER="$SCRIPT_CHECKOUT_ROOT/bin/resolve-merge-base.sh"
WS_DIR="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state"
if command -v cygpath >/dev/null 2>&1; then WS_DIR="$(cygpath -m "$WS_DIR")"; fi

new_repo() { # <dir>
  harness_git_init "$1"
  git -C "$1" checkout -q -b main 2>/dev/null || git -C "$1" symbolic-ref HEAD refs/heads/main
  git -C "$1" config user.email test@example.com
  git -C "$1" config user.name test
  git -C "$1" config commit.gpgsign false
}
commit_on() { # <repo> <file> <message> ; prints the new sha
  printf '%s\n' "$3" >"$1/$2"
  git -C "$1" add -A >/dev/null 2>&1
  git -C "$1" commit -q -m "$3" >/dev/null 2>&1
  git -C "$1" rev-parse HEAD
}

# put_record <sid> <repo> <base> <branch_head> — a layer-1 record for branch `work`.
put_record() {
  local sid="$1" root="$2"
  if command -v cygpath >/dev/null 2>&1; then root="$(cygpath -m "$root")"; fi
  node -e '
const path = require("path"), fs = require("fs");
const [wsDir, sid, cwd, base, head] = process.argv.slice(1);
const ws = require(wsDir);
const st = ws.createInitialState(sid, { cwd, git_branch: "work" });
ws.writeState(sid, st);
const file = path.join(process.env.WORKFLOW_STATE_DIR, sid + ".json");
const cur = JSON.parse(fs.readFileSync(file, "utf8"));
cur.merge_base_baseline = { base, branch: "work", branch_head: head, repo_root: cwd, source: "recorded-baseline", post_session_head: false, alt_base: null };
fs.writeFileSync(file, JSON.stringify(cur, null, 2), "utf8");
' "$WS_DIR" "$sid" "$root" "$3" "$4" >/dev/null 2>&1 || fail "fixture" "could not write the layer-1 record for $sid"
}

OUT=""
run_resolver() { # <repo> <sid> [extra args]
  local repo="$1" sid="$2"
  shift 2
  OUT="$(run_with_timeout 60 bash "$HELPER" -C "$repo" --no-fetch --session "$sid" "$@" 2>/dev/null)"
}
kv() { printf '%s\n' "$OUT" | sed -n "s/^$1=//p" | head -1; }
check() { # <desc> <want> <got>
  if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "want [$2] got [$3]"; fi
}

# Shared topology: main c0 -> m1 -> m2 (origin/main = m2); work = c0 -> w1 (recorded base c0).
# Prints "<repo> <c0> <m1> <m2> <w1>".
base_topology() { # <dir>
  local r="$1" c0 m1 m2 w1
  new_repo "$r"
  c0="$(commit_on "$r" seed.txt seed)"
  m1="$(commit_on "$r" main1.txt main-one)"
  m2="$(commit_on "$r" main2.txt main-two)"
  git -C "$r" update-ref refs/remotes/origin/main "$m2"
  git -C "$r" checkout -q -b work "$c0"
  w1="$(commit_on "$r" work.txt work-one)"
  printf '%s %s %s %s %s' "$r" "$c0" "$m1" "$m2" "$w1"
}

case_begin "merge-in-progress-advances-to-merged-main" "bin/lib/resolve-merge-base-advance.sh"
read -r R c0 m1 m2 w1 <<<"$(base_topology "$TMPROOT/a")"
git -C "$R" merge -q --no-commit --no-ff main >/dev/null 2>&1
if [ ! -f "$R/.git/MERGE_HEAD" ]; then
  fail "advance-a-fixture" "git merge --no-commit main left no MERGE_HEAD"
else
  put_record sid-a "$R" "$c0" "$w1"
  run_resolver "$R" sid-a
  check "advance-a-state: layer 1 still answers" "RECORDED" "$(kv state)"
  check "advance-a-base: base moves to the merged main tip before the merge is committed" "$m2" "$(kv base)"
  check "advance-a-recorded: recorded_base keeps the recorded value" "$c0" "$(kv recorded_base)"
  check "advance-a-flag: base_advanced=1" "1" "$(kv base_advanced)"
  run_resolver "$R" sid-a --format base
  check "advance-a-format-base: --format base prints the advanced base" "$m2" "$OUT"
fi
case_end

case_begin "merge-commit-keeps-the-advanced-base" "bin/lib/resolve-merge-base-advance.sh"
git -C "$R" commit -q --no-edit >/dev/null 2>&1
if [ -f "$R/.git/MERGE_HEAD" ]; then
  fail "advance-b-fixture" "the merge commit was not made"
else
  run_resolver "$R" sid-a
  check "advance-b-base: after the merge commit the base is the same main tip" "$m2" "$(kv base)"
  check "advance-b-flag: base_advanced=1" "1" "$(kv base_advanced)"
  check "advance-b-recorded: recorded_base unchanged" "$c0" "$(kv recorded_base)"
fi
case_end

case_begin "non-main-branch-advances-only-to-its-main" "bin/lib/resolve-merge-base-advance.sh"
read -r R c0 m1 m2 w1 <<<"$(base_topology "$TMPROOT/c")"
git -C "$R" checkout -q -b side "$m1"
commit_on "$R" side.txt side-one >/dev/null
git -C "$R" checkout -q work
git -C "$R" merge -q --no-commit --no-ff side >/dev/null 2>&1
put_record sid-c "$R" "$c0" "$w1"
run_resolver "$R" sid-c
check "advance-c-base: merging a branch cut at m1 advances to m1, not to main's tip" "$m1" "$(kv base)"
check "advance-c-flag: base_advanced=1" "1" "$(kv base_advanced)"
case_end

case_begin "branch-without-main-content-does-not-advance" "bin/lib/resolve-merge-base-advance.sh"
read -r R c0 m1 m2 w1 <<<"$(base_topology "$TMPROOT/d")"
git -C "$R" checkout -q -b side "$c0"
commit_on "$R" side.txt side-one >/dev/null
git -C "$R" checkout -q work
git -C "$R" merge -q --no-commit --no-ff side >/dev/null 2>&1
put_record sid-d "$R" "$c0" "$w1"
run_resolver "$R" sid-d
check "advance-d-base: a merged branch that carries no newer main keeps the recorded base" "$c0" "$(kv base)"
check "advance-d-flag: base_advanced=0" "0" "$(kv base_advanced)"
check "advance-d-recorded: recorded_base equals base" "$c0" "$(kv recorded_base)"
case_end

case_begin "main-advanced-without-merge-does-not-advance" "bin/lib/resolve-merge-base-advance.sh"
read -r R c0 m1 m2 w1 <<<"$(base_topology "$TMPROOT/e")"
put_record sid-e "$R" "$c0" "$w1"
run_resolver "$R" sid-e
check "advance-e-base: main moved on but was not merged, so the base stays" "$c0" "$(kv base)"
check "advance-e-flag: base_advanced=0" "0" "$(kv base_advanced)"
case_end

case_begin "incomparable-candidates-do-not-advance" "bin/lib/resolve-merge-base-advance.sh"
read -r R c0 m1 m2 w1 <<<"$(base_topology "$TMPROOT/f")"
git -C "$R" checkout -q -b fork "$m1"
o1="$(commit_on "$R" fork.txt fork-one)"
git -C "$R" update-ref refs/remotes/origin/main "$o1"
git -C "$R" checkout -q work
git -C "$R" merge -q --no-commit --no-ff main >/dev/null 2>&1
printf '%s\n' "$o1" >>"$R/.git/MERGE_HEAD"
if git -C "$R" merge-base --is-ancestor "$m2" "$o1" || git -C "$R" merge-base --is-ancestor "$o1" "$m2"; then
  fail "advance-f-fixture" "m2 and o1 are comparable; the row would not isolate the fail-safe"
else
  put_record sid-f "$R" "$c0" "$w1"
  run_resolver "$R" sid-f
  check "advance-f-state: layer 1 still answers" "RECORDED" "$(kv state)"
  check "advance-f-base: two incomparable candidates (m2, o1) keep the recorded base" "$c0" "$(kv base)"
  check "advance-f-flag: base_advanced=0" "0" "$(kv base_advanced)"
fi
case_end

case_begin "no-descendant-candidate-does-not-advance" "bin/lib/resolve-merge-base-advance.sh"
read -r R c0 m1 m2 w1 <<<"$(base_topology "$TMPROOT/g")"
w2="$(commit_on "$R" work.txt work-two)"
put_record sid-g "$R" "$w1" "$w2"
run_resolver "$R" sid-g
check "advance-g-base: no candidate descends from a recorded base on the branch itself" "$w1" "$(kv base)"
check "advance-g-flag: base_advanced=0" "0" "$(kv base_advanced)"
check "advance-g-recorded: recorded_base equals the record" "$w1" "$(kv recorded_base)"
case_end

case_begin "kv-carries-the-new-keys" "bin/resolve-merge-base.sh"
run_resolver "$R" sid-g
for k in recorded_base base_advanced; do
  if printf '%s\n' "$OUT" | grep -q "^$k="; then pass "kv-$k: the kv block carries $k="; else fail "kv-$k" "no $k= line in the kv block"; fi
done
check "kv-keeps-existing: state= is still emitted" "RECORDED" "$(kv state)"
case_end

echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
