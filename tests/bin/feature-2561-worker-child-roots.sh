#!/usr/bin/env bash
# tests/bin/feature-2561-worker-child-roots.sh
# Tests: bin/worker-dispatch/spawn.js, hooks/lib/worker-dispatch-registry.js, bin/worker-dispatch.js, bin/worker-dispatch/workers/commit-push/gate.js, tests/fixtures/spawn-record-preload.js
# Tags: worker-dispatch, spawn, child-env, root-names, real-git, security, scope:issue-specific, TL2
# TL3 gap (what this test does NOT catch):
# - a real push, pull request, gh, glab or docker call: those are recorded and answered, never run
# - children of children: only the dispatcher's own spawn calls are recorded
# - the four workers that need a forge or uv are covered record-only (stage one), not for real
# Closest-to-action mitigation: tests/bin/TL3-worker-dispatch-commit-push.sh.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
# shellcheck source=tests/lib/harness.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/root-decoy.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
# shellcheck source=tests/lib/target-repo-fixture.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/target-repo-fixture.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }
command -v git >/dev/null 2>&1 || { echo "SKIP: git not available"; exit 77; }

TMP_ROOT="$(np "$(make_tmp)")"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/iso"
unset CLAUDE_CODE_SESSION_ID ROOT_DECOY_TEST_ID GH_REPO GH_TOKEN GITHUB_TOKEN GITLAB_TOKEN GITLAB_HOST SSH_AUTH_SOCK
unset WORKTREE_BASE_DIR ENFORCE_WORKTREE DEFAULT_BRANCHES FINALIZE_SCRIPTS_DIR

readonly HELPERS="$(np "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-worker-child-roots")"
readonly PRELOAD="$(np "$SCRIPT_CHECKOUT_ROOT/tests/fixtures/spawn-record-preload.js")"
readonly BUILDER="$(np "$SCRIPT_CHECKOUT_ROOT/tests/lib/root-decoy-build.js")"
# A directory name with a space and shell metacharacters: every fixture path runs through it.
readonly WORK="$TMP_ROOT/kid & \$x dir"
readonly AGENTS_MAIN_FIXTURE="$WORK/agents-repo/main"
readonly DISPATCH_COPY="$WORK/agents-repo/checkout"
readonly LAUNCHER="$TMP_ROOT/launcher-decoy"
readonly HOME_FIXTURE="$TMP_ROOT/home"
readonly GATE_MARKER="branch-list-of-the-dispatcher-checkout"
mkdir -p "$WORK/agents-repo" "$WORK/target" "$HOME_FIXTURE" "$TMP_ROOT/self"
# Every process started from here on reads its home directory from the fixture.
export HOME="$HOME_FIXTURE" USERPROFILE="$HOME_FIXTURE"

setup_fail() { echo "FAIL: setup: $1"; exit 1; }

# A forge or container CLI reached by a child of a child finds a stub that forwards nowhere.
# shellcheck source=tests/lib/cli-stub.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/cli-stub.sh"
cli_stub_make "$TMP_ROOT/stubs" gh glab docker uv || setup_fail "the CLI stubs could not be built"
export PATH="$CLI_STUB_DIR:$PATH"
expect_eq() { if [[ "$2" == "$3" ]]; then pass "$1"; else fail "$1" "want=$3 got=$2"; fi; }

RETIRED=()
while IFS= read -r _name; do
  _name="${_name%$'\r'}"
  [[ -n "$_name" ]] && RETIRED+=("$_name")
done < <(node "$BUILDER" --print-retired-env-names)
[[ "${#RETIRED[@]}" -gt 0 ]] || setup_fail "the retired environment names are unavailable"
RETIRED_CSV="$(IFS=,; printf '%s' "${RETIRED[*]}")"
readonly RETIRED_CSV

# The launcher environment: the agents root name and every retired name point at stub trees.
node "$BUILDER" --out "$LAUNCHER" || setup_fail "the launcher decoy could not be built"
export AGENTS_MAIN_ROOT="$LAUNCHER/main"
for _name in "${RETIRED[@]}"; do export "$_name=$LAUNCHER/old"; done

# A second agents repository: its main worktree holds stubs only, its linked worktree holds
# the dispatcher under test. The two carry different .env values.
git init -q "$AGENTS_MAIN_FIXTURE" || setup_fail "git init"
git -C "$AGENTS_MAIN_FIXTURE" config core.hooksPath /dev/null
git -C "$AGENTS_MAIN_FIXTURE" config user.name "Child Roots Fixture"
git -C "$AGENTS_MAIN_FIXTURE" config user.email "child-roots@example.com"
git -C "$AGENTS_MAIN_FIXTURE" config commit.gpgsign false
printf 'agents repository fixture\n' >"$AGENTS_MAIN_FIXTURE/README.md"
git -C "$AGENTS_MAIN_FIXTURE" add README.md
git -C "$AGENTS_MAIN_FIXTURE" commit -q -m "initial commit" || setup_fail "fixture commit"
git -C "$AGENTS_MAIN_FIXTURE" worktree add -q -b dispatcher-checkout "$DISPATCH_COPY" || setup_fail "git worktree add"
node "$BUILDER" --single "$AGENTS_MAIN_FIXTURE" --marker agents-main-worktree || setup_fail "the agents main worktree stubs"
printf 'DEFAULT_BRANCHES=branch-list-of-the-agents-main-worktree\n' >>"$AGENTS_MAIN_FIXTURE/.env"
script_checkout_fixture_copy "$DISPATCH_COPY" bin hooks skills || setup_fail "the dispatcher checkout copy"
printf 'DEFAULT_BRANCHES=%s\nWORKFLOW_STATE_DIR=%s\n' "$GATE_MARKER" "$WORKFLOW_STATE_DIR" >"$DISPATCH_COPY/.env"

target_repo_fixture_create "$WORK/target" || setup_fail "the target repository"
mkdir -p "$TARGET_CHECKOUT_ROOT/tests"
cat >"$TARGET_CHECKOUT_ROOT/tests/run-all.sh" <<'SUITE'
#!/usr/bin/env bash
echo "child-roots-suite-ran"
for name in AGENTS_MAIN_ROOT SCRIPT_CHECKOUT_ROOT TARGET_MAIN_ROOT TARGET_CHECKOUT_ROOT; do
  if [[ -n "${!name+x}" ]]; then echo "seen:$name=set"; else echo "seen:$name=unset"; fi
done
exit 0
SUITE
git -C "$TARGET_CHECKOUT_ROOT" add tests/run-all.sh
git -C "$TARGET_CHECKOUT_ROOT" commit -q -m "add a suite stub" || setup_fail "the target suite commit"

# Which dispatcher is launched and which agents main worktree the analyser expects. The two
# launch-origin cases of stage two re-point both for one dispatch and put them back.
DISPATCH_FROM="$DISPATCH_COPY"
EXPECTED_AGENTS_MAIN="$AGENTS_MAIN_FIXTURE"

# records_check <label> <records file> [check-records option...]
records_check() {
  local label="$1" file="$2"
  shift 2
  node "$HELPERS/check-records.js" --label "$label" --records "$file" --agents-main "$EXPECTED_AGENTS_MAIN" \
    --checkout "$DISPATCH_FROM" --target-main "$TARGET_MAIN_ROOT" --target-linked "$TARGET_CHECKOUT_ROOT" \
    --launcher "$LAUNCHER" --retired "$RETIRED_CSV" "$@" | tr -d '\r'
}

# verdicts <analyser output> <name prefix> — one result per line of that group; none is a failure.
verdicts() {
  local kind name detail saw=0
  while IFS=$'\t' read -r kind name detail; do
    [[ "$name" == "$2"* ]] || continue
    saw=1
    if [[ "$kind" == "ok" ]]; then pass "$name"; else fail "$name" "$detail"; fi
  done <<<"$1"
  if [[ "$saw" -eq 0 ]]; then fail "$2" "the analyser printed no verdict for this group"; fi
}

# shellcheck source=tests/bin/feature-2561-worker-child-roots/stage-two.sh
source "$SCRIPT_CHECKOUT_ROOT/tests/bin/feature-2561-worker-child-roots/stage-two.sh"

SELF_OUT="$(cd "$TMP_ROOT" && bash "$RWT" 60 env "SPAWN_RECORD_OUT=$TMP_ROOT/self.jsonl" \
  node -r "$PRELOAD" "$HELPERS/selfcheck.js" "$TMP_ROOT/self" "$RETIRED_CSV" 2>&1 | tr -d '\r')"
readonly SELF_OUT

# Stage one: every script and every external command of all nine workers, started record-only.
(cd "$TMP_ROOT" && bash "$RWT" 120 env "HOME=$HOME_FIXTURE" "USERPROFILE=$HOME_FIXTURE" \
  "SPAWN_RECORD_OUT=$TMP_ROOT/stage-one.jsonl" "SPAWN_RECORD_MODE=run-real" \
  node -r "$PRELOAD" "$HELPERS/stage-one.js" "$DISPATCH_COPY" "$TARGET_MAIN_ROOT" "$TARGET_CHECKOUT_ROOT") \
  >"$TMP_ROOT/stage-one.json" 2>"$TMP_ROOT/stage-one.err"
STAGE_ONE="$(records_check one "$TMP_ROOT/stage-one.jsonl" --report "$TMP_ROOT/stage-one.json")"
readonly STAGE_ONE

# Stage one starts nothing, so a hit count taken there proves nothing. What is shown instead is
# that the counter stage two reads does move when a stub of each tree is really reached.
(cd "$TMP_ROOT" && node "$AGENTS_MAIN_FIXTURE/hooks/enforce-worktree.js") >/dev/null 2>&1
(cd "$TMP_ROOT" && node "$LAUNCHER/main/hooks/enforce-worktree.js") >/dev/null 2>&1
(cd "$TMP_ROOT" && node "$LAUNCHER/old/hooks/enforce-worktree.js") >/dev/null 2>&1
STUB_COUNTER_LIVE="$(stub_hits)"
readonly STUB_COUNTER_LIVE
rm -f "$AGENTS_MAIN_FIXTURE"/hits/*.hit "$LAUNCHER"/main/hits/*.hit "$LAUNCHER"/old/hits/*.hit

case_begin "recorder-holds-and-runs-as-asked" "tests/fixtures/spawn-record-preload.js"
verdicts "$SELF_OUT" "self/preload:"
verdicts "$SELF_OUT" "self/analyser:"
expect_eq "self: a reached stub of each tree moves the hit counter" "$STUB_COUNTER_LIVE" "1/1/1"
expect_eq "self: the hit counter reads zero once cleared" "$(stub_hits)" "0/0/0"
case_end

case_begin "all-declared-children-start-exactly-once" "hooks/lib/worker-dispatch-registry.js"
verdicts "$STAGE_ONE" "one/setup:"
verdicts "$STAGE_ONE" "one/count:"
case_end

case_begin "all-children-get-the-agents-main-worktree-as-AGENTS_MAIN_ROOT" "bin/worker-dispatch/spawn.js"
verdicts "$STAGE_ONE" "one/env:"
case_end

case_begin "all-declared-scripts-resolve-under-their-own-root" "hooks/lib/worker-dispatch-registry.js"
verdicts "$STAGE_ONE" "one/path:"
case_end

# Stage two: five workers through the dispatcher for real, against the target repository.
case_begin "worktree-copy-runs-from-the-dispatcher-checkout" "bin/worker-dispatch.js"
worktree_copy_case
case_end

case_begin "worktree-backup-runs-inside-the-target-repository" "bin/worker-dispatch.js"
worktree_backup_case
case_end

case_begin "test-runner-runs-the-suite-of-the-target-worktree" "bin/worker-dispatch.js"
test_runner_case
case_end

case_begin "session-close-gate-runs-from-the-dispatcher-checkout" "bin/worker-dispatch.js"
session_close_gate_case
case_end

case_begin "commit-push-gate-reads-the-dispatcher-checkout-env-file" "bin/worker-dispatch/workers/commit-push/gate.js"
commit_push_case
case_end

case_begin "launch-from-a-checkout-whose-main-worktree-lacks-the-markers-hands-down-no-AGENTS_MAIN_ROOT" "bin/worker-dispatch/spawn.js"
origin_without_markers_case
case_end

case_begin "launch-from-a-main-worktree-hands-down-that-worktree-as-AGENTS_MAIN_ROOT" "bin/worker-dispatch/spawn.js"
origin_main_worktree_case
case_end

echo ""
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
