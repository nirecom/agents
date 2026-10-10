#!/usr/bin/env bash
# tests/bin/feature-2561-worker-child-roots/stage-two.sh
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, child-env, root-names, real-git, security, scope:issue-specific, TL2
# Sourced by ../feature-2561-worker-child-roots.sh after its fixture is built. Each function
# sends one worker through the dispatcher of the checkout copy, for real, against the target
# repository, and judges the result, the effect, the stub hits and the recorded children.

readonly STAGE_TWO_BRANCH="target-fixture-linked"

# json_object <key> <value>... — a value starting with "json:" is taken as JSON, else as a string.
json_object() {
  node -e '
const o = {};
const a = process.argv.slice(1);
for (let i = 0; i + 1 < a.length; i += 2) o[a[i]] = a[i + 1].startsWith("json:") ? JSON.parse(a[i + 1].slice(5)) : a[i + 1];
process.stdout.write(JSON.stringify(o));
' "$@"
}

# dispatch <worker> <session id> <payload json> [hold] — sets DISPATCH_OUT / DISPATCH_RC / DISPATCH_REC.
dispatch() {
  local worker="$1" sid="$2" control="$WORKFLOW_STATE_DIR/$2.control"
  mkdir -p "$control"
  printf '%s\n' "$3" >"$control/worker-$worker-1.json"
  DISPATCH_REC="$TMP_ROOT/records-$worker.jsonl"
  : >"$DISPATCH_REC"
  rm -f "$AGENTS_MAIN_FIXTURE"/hits/*.hit "$LAUNCHER"/main/hits/*.hit "$LAUNCHER"/old/hits/*.hit
  DISPATCH_OUT="$(cd "$TMP_ROOT" && bash "$RWT" 150 env "HOME=$HOME_FIXTURE" "USERPROFILE=$HOME_FIXTURE" \
    "SPAWN_RECORD_OUT=$DISPATCH_REC" "SPAWN_RECORD_MODE=run-real" "SPAWN_RECORD_HOLD=${4:-}" \
    node -r "$PRELOAD" "$DISPATCH_FROM/bin/worker-dispatch.js" "$worker" "$TARGET_MAIN_ROOT" "$control/worker-$worker-1.json" 2>&1)"
  DISPATCH_RC=$?
}

dispatch_status() { printf '%s\n' "$DISPATCH_OUT" | sed -n 's/^status: *"\{0,1\}\([a-z_]*\).*/\1/p' | head -n 1; }
stub_hits() {
  printf '%s/%s/%s' "$(root_decoy_hit_count "$AGENTS_MAIN_FIXTURE")" "$(root_decoy_hit_count "$LAUNCHER/main")" "$(root_decoy_hit_count "$LAUNCHER/old")"
}

# judge <label> <wanted status> [check-records option...] — the part every worker shares.
judge() {
  local label="$1" want="$2"
  shift 2
  expect_eq "$label: dispatcher exit code" "$DISPATCH_RC" "0"
  if [[ "$(dispatch_status)" == "$want" ]]; then pass "$label: status is $want"
  else fail "$label: status is $want" "output: $(printf '%s' "$DISPATCH_OUT" | tr '\n' ' ' | cut -c1-400)"; fi
  expect_eq "$label: stub hits (agents main worktree / launcher main / launcher old)" "$(stub_hits)" "0/0/0"
  verdicts "$(records_check "$label" "$DISPATCH_REC" "$@")" "$label/"
}

worktree_copy_case() {
  rm -f "$TARGET_CHECKOUT_ROOT/WORKTREE_NOTES.md"
  dispatch worktree-copy childroots-copy "$(json_object worktree_path "$TARGET_CHECKOUT_ROOT" branch "$STAGE_TWO_BRANCH" session_id childroots-copy)"
  judge two-copy complete --scripts bin/worktree-copy-include.js,bin/parse-worktrees,bin/worktree-write-notes.js
  expect_eq "two-copy: the notes file lands in the target worktree" "$([[ -s "$TARGET_CHECKOUT_ROOT/WORKTREE_NOTES.md" ]] && echo written || echo missing)" "written"
  expect_eq "two-copy: nothing is written into the dispatcher checkout" "$([[ -e "$DISPATCH_COPY/WORKTREE_NOTES.md" ]] && echo present || echo absent)" "absent"
}

worktree_backup_case() {
  local backup="$TARGET_MAIN_ROOT/.worktree-backup/$STAGE_TWO_BRANCH"
  printf 'kept by the backup\n' >"$TARGET_CHECKOUT_ROOT/scratch note.txt"
  dispatch worktree-backup childroots-backup "$(json_object mode execute worktree_path "$TARGET_CHECKOUT_ROOT" branch "$STAGE_TWO_BRANCH" docker_check json:false session_id childroots-backup)"
  judge two-backup copied
  expect_eq "two-backup: the manifest lands under the target main worktree" "$([[ -s "$backup/manifest.json" ]] && echo written || echo missing)" "written"
  expect_eq "two-backup: the untracked file is copied" "$(cat "$backup/scratch note.txt" 2>/dev/null)" "kept by the backup"
  expect_eq "two-backup: no backup directory in the agents main worktree" "$([[ -e "$AGENTS_MAIN_FIXTURE/.worktree-backup" ]] && echo present || echo absent)" "absent"
  rm -f "$TARGET_CHECKOUT_ROOT/scratch note.txt"
}

test_runner_case() {
  local name
  dispatch test-runner childroots-runner "$(json_object cwd "$TARGET_CHECKOUT_ROOT" timeout_seconds json:60)"
  judge two-runner pass --family-scripts tests/run-all.sh
  if [[ "$DISPATCH_OUT" == *"child-roots-suite-ran"* ]]; then pass "two-runner: the suite of the target worktree really ran"
  else fail "two-runner: the suite of the target worktree really ran" "marker line missing from the output"; fi
  if [[ "$DISPATCH_OUT" == *"seen:AGENTS_MAIN_ROOT=set"* ]]; then pass "two-runner: the suite sees AGENTS_MAIN_ROOT"
  else fail "two-runner: the suite sees AGENTS_MAIN_ROOT" "the child reported it unset"; fi
  for name in SCRIPT_CHECKOUT_ROOT TARGET_MAIN_ROOT TARGET_CHECKOUT_ROOT; do
    if [[ "$DISPATCH_OUT" == *"seen:$name=unset"* ]]; then pass "two-runner: the suite sees no $name"
    else fail "two-runner: the suite sees no $name" "the child did not report it unset"; fi
  done
}

session_close_gate_case() {
  local sid="childroots-gate" control="$WORKFLOW_STATE_DIR/childroots-gate.control"
  mkdir -p "$control"
  printf '%s\n' '{"issues":[{"issueNumber":1,"state":"skipped"}]}' >"$control/issue-close-outcome.json"
  cat >"$control/supervisor-state.json" <<'STATE_JSON'
{"alert":{"alert_phase":"pending","alert_armed_at":"2020-01-01T00:00:00Z","last_run_at":"2020-01-01T00:01:00Z"},
 "audit":{"audit_phase":"pending","audit_armed_at":"2020-01-01T00:00:00Z","audit_last_run_at":"2020-01-01T00:01:00Z"}}
STATE_JSON
  dispatch session-close-gate "$sid" "$(json_object session_id "$sid")"
  judge two-gate complete --scripts bin/supervisor-report,bin/supervisor-write-alert,bin/supervisor-write-audit
  expect_eq "two-gate: the gate file says proceed" \
    "$(node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).gate_action' "$control/session-close-gate.json" 2>/dev/null)" "proceed"
}

commit_push_case() {
  local sid="childroots-commit" message="test: child roots commit" before after
  node -e '
const step = { status: "complete" };
const names = ["workflow_init", "clarify_intent", "make_outline_plan", "make_detail_plan", "write_tests",
  "review_tests", "write_code", "run_tests", "review_security", "docs", "user_verification"];
require("fs").writeFileSync(process.argv[1], JSON.stringify({ steps: Object.fromEntries(names.map((n) => [n, step])) }));
' "$WORKFLOW_STATE_DIR/$sid.json"
  printf 'a staged line\n' >>"$TARGET_CHECKOUT_ROOT/README.md"
  git -C "$TARGET_CHECKOUT_ROOT" add README.md
  before="$(git -C "$TARGET_CHECKOUT_ROOT" rev-parse HEAD)"
  dispatch commit-push "$sid" "$(json_object commit_message "$message" branch "$STAGE_TWO_BRANCH" worktree_path "$TARGET_CHECKOUT_ROOT" \
    session_id "$sid" enforce_worktree off closes_issues 'json:[]')" "probe-remote-bootstrap"
  judge two-commit pushed --scripts bin/check-unstaged-tracked.sh,hooks/workflow-gate.js \
    --gate-marker "$GATE_MARKER" --state-dir "$WORKFLOW_STATE_DIR" --held-git-verb push
  after="$(git -C "$TARGET_CHECKOUT_ROOT" rev-parse HEAD)"
  if [[ "$before" != "$after" ]]; then pass "two-commit: a commit lands in the target worktree"
  else fail "two-commit: a commit lands in the target worktree" "HEAD did not move"; fi
  expect_eq "two-commit: the commit carries the payload message" "$(git -C "$TARGET_CHECKOUT_ROOT" log -1 --pretty=%s)" "$message"
  expect_eq "two-commit: the target repository still has no remote" "$(git -C "$TARGET_MAIN_ROOT" remote)" ""
  expect_eq "two-commit: the agents main worktree gained no commit" "$(git -C "$AGENTS_MAIN_FIXTURE" rev-list --count HEAD)" "1"
}

# origin_repo <main dir> — a further repository with one commit and git hooks disabled.
origin_repo() {
  git init -q "$1" || return 1
  git -C "$1" config core.hooksPath /dev/null
  git -C "$1" config user.name "Child Roots Fixture"
  git -C "$1" config user.email "child-roots@example.com"
  git -C "$1" config commit.gpgsign false
  printf 'launch origin fixture\n' >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q -m "initial commit"
}

# origin_run <label> <dispatcher root> <expected agents main> <suite line> [check-records option...]
# Sends the test-runner through the dispatcher of <dispatcher root> and judges it like any other.
origin_run() {
  local label="$1" from="$2" main="$3" seen="$4"
  shift 4
  printf 'WORKFLOW_STATE_DIR=%s\n' "$WORKFLOW_STATE_DIR" >"$from/.env"
  DISPATCH_FROM="$from"
  EXPECTED_AGENTS_MAIN="$main"
  dispatch test-runner "childroots-$label" "$(json_object cwd "$TARGET_CHECKOUT_ROOT" timeout_seconds json:60)"
  judge "$label" pass --family-scripts tests/run-all.sh "$@"
  DISPATCH_FROM="$DISPATCH_COPY"
  EXPECTED_AGENTS_MAIN="$AGENTS_MAIN_FIXTURE"
  if [[ "$DISPATCH_OUT" == *"$seen"* ]]; then pass "$label: the suite reports $seen"
  else fail "$label: the suite reports $seen" "output: $(printf '%s' "$DISPATCH_OUT" | tr '\n' ' ' | cut -c1-400)"; fi
}

# A dispatcher in a linked worktree whose main worktree is no agents repository: nothing can be
# proven, so the key is left out, and the launcher's own value must not fill the gap.
origin_without_markers_case() {
  local main="$WORK/origin-plain/main" copy="$WORK/origin-plain/checkout"
  mkdir -p "$WORK/origin-plain"
  if ! { origin_repo "$main" && git -C "$main" worktree add -q -b origin-checkout "$copy" \
    && script_checkout_fixture_copy "$copy" bin hooks; }; then
    fail "two-plain: fixture" "the marker-less origin could not be built"
    return
  fi
  origin_run two-plain "$copy" "$main" "seen:AGENTS_MAIN_ROOT=unset" --agents-main-key absent
}

# A dispatcher in the main worktree of its own repository names that worktree.
origin_main_worktree_case() {
  local main="$WORK/origin-main/main"
  mkdir -p "$WORK/origin-main"
  if ! { origin_repo "$main" && script_checkout_fixture_copy "$main" bin hooks; }; then
    fail "two-main: fixture" "the main-worktree origin could not be built"
    return
  fi
  origin_run two-main "$main" "$main" "seen:AGENTS_MAIN_ROOT=set"
}
