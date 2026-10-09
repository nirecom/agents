#!/usr/bin/env bash
# tests/skills/feature-1673-finalize-script-contract.sh
# Tests: skills/issue-close-finalize/scripts/run-loop-step.js, skills/issue-close-finalize/scripts/run-initial.sh, skills/issue-close-finalize/scripts/run-finalize-terminal.sh
# Tags: worker-dispatch, issue-close-finalize, kv-contract, argv-contract, idempotency, atomic-write, TL2, scope:issue-specific, direct-launch, root-names, security, gh-stub
# Issue #1673 — pins the three finalize scripts' side of the worker seam (argv arity,
# required env, KEY=VALUE stdout, state transitions, the g5_3a_completed idempotency
# guard) against the real scripts. Worker-free on purpose: a worker refactor that changes
# what it passes surfaces here, not as a silent no-op at close time.
# `step-g5-loop.sh` is a recording stub via FINALIZE_SCRIPTS_DIR (the real one talks to gh).
# TL3 gap: the real step-g5-loop.sh / pre-flight.sh / gh behind the stub; run-initial.sh's
# real merged-PR path. Checked at WORKFLOW_USER_VERIFIED preflight (skill-orchestration).

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_F1673_SCRIPT_INNER:-}" ]; then
    _F1673_SCRIPT_INNER=1 timeout 300 bash "$0" "$@"
    exit $?
fi

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SCRIPTS_DIR="$SCRIPT_CHECKOUT_ROOT/skills/issue-close-finalize/scripts"
LOOP_STEP="$SCRIPTS_DIR/run-loop-step.js"
RUN_INITIAL="$SCRIPTS_DIR/run-initial.sh"
RUN_TERMINAL="$SCRIPTS_DIR/run-finalize-terminal.sh"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

for f in "$LOOP_STEP" "$RUN_INITIAL" "$RUN_TERMINAL"; do
    [ -f "$f" ] || { fail "fixtures" "missing script: $f"; echo ""; echo "Total: PASS=$PASS FAIL=$FAIL"; exit 1; }
done

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/f1673-script-$$")"
mkdir -p "$TMPD"
trap 'cd /; rm -rf "$TMPD"' EXIT
# isolation: pin state and plans dirs once for this file
dl_np() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s\n' "$1"; fi; }
DL_TMP="$(dl_np "$TMPD")/direct-launch"
mkdir -p "$DL_TMP/iso/workflow-state" "$DL_TMP/iso/plans"
export WORKFLOW_STATE_DIR="$DL_TMP/iso/workflow-state" WORKFLOW_PLANS_DIR="$DL_TMP/iso/plans"
# Every case runs from a throwaway repository with the home directory and AGENTS_MAIN_ROOT
# pinned inside the temp dir, so nothing is answered from the caller's checkout or home.
CHECKOUT_N="$(dl_np "$SCRIPT_CHECKOUT_ROOT")"
CWD_REPO="$DL_TMP/cwd-repo"
mkdir -p "$CWD_REPO" "$DL_TMP/home" "$DL_TMP/agents-main-root-fixture"
PIN_ENV=("AGENTS_MAIN_ROOT=$DL_TMP/agents-main-root-fixture" "HOME=$DL_TMP/home" "USERPROFILE=$DL_TMP/home")
# The helpers that read and write the fixture state start node outside PIN_ENV: same home for them.
export HOME="$DL_TMP/home" USERPROFILE="$DL_TMP/home"
git init -q "$CWD_REPO" && git -C "$CWD_REPO" config core.hooksPath /dev/null &&
    git -C "$CWD_REPO" -c user.name=t -c user.email=t@example.com commit -q --allow-empty -m init
cd "$CWD_REPO" || { echo "FAIL: fixtures: cannot enter the fixture cwd"; exit 1; }

STUB_DIR="$TMPD/finalize-scripts"
mkdir -p "$STUB_DIR"
G5LOG="$TMPD/g5-calls.log"
cat > "$STUB_DIR/step-g5-loop.sh" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$G5_CALL_LOG"
if [ "${1:-}" = "prepare" ]; then
    printf 'PROPOSAL_STATUS=ok\nPROPOSAL_PARENT=1500\n'
fi
exit 0
STUB
chmod +x "$STUB_DIR/step-g5-loop.sh"

STATE="$TMPD/state.json"
MKSTATE="$TMPD/mkstate.js"
cat > "$MKSTATE" <<'MKJS'
"use strict";
// Writes a state of the shape the worker's initial pass writes, then prints what the writer's
// own validator says about it: "ok" or the refusal.
const fs = require("fs");
const path = require("path");
const [, , outFile, mutation, checkout, targetMain] = process.argv;
const lib = path.join(checkout, "bin", "worker-dispatch");
const stateLib = require(path.join(lib, "workers", "issue-close-finalize", "state.js"));
const anchors = require(path.join(lib, "anchor.js")).resolveAnchors(targetMain);
const state = {
  schema_version: stateLib.SCHEMA_VERSION,
  root_issue_number: 1673,
  current_issue_number: 1673,
  owner_repo: "nirecom/agents",
  script_checkout_root: anchors.scriptCheckoutRoot,
  target_main_root: anchors.targetMainRoot,
  merge_commit: "",
  phase: "init_done",
  triage_action: "resume_e",
  g5_loop_iteration: 0,
  g5_history: [
    { iteration: 1, issue_number: "1673", proposal_status: "ok", proposal_parent: 1600,
      user_decision: null, g5_3a_completed: false, recursion_completed: false },
  ],
  proposal_counters: { accepted: 0, declined: 0, skipped: 0 },
};
if (mutation && mutation !== "-") new Function("s", mutation)(state);
fs.writeFileSync(outFile, JSON.stringify(state, null, 2));
process.stdout.write(anchors.error === null ? String(stateLib.validateState(state, anchors) || "ok") : "anchors: " + anchors.error);
MKJS

MK_VERDICT=""
write_state() { MK_VERDICT="$(node "$MKSTATE" "$STATE" "$1" "$CHECKOUT_N" "$CWD_REPO" 2>&1)"; }
state_field() { node -e 'const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=new Function("s","return "+process.argv[2])(s);process.stdout.write(String(v));' "$STATE" "$1"; }

LOUT=""
loop_step() {
    : > "$G5LOG"
    LOUT="$(run_with_timeout 60 env "${PIN_ENV[@]}" \
        "FINALIZE_SCRIPTS_DIR=$STUB_DIR" \
        "G5_CALL_LOG=$G5LOG" \
        node "$LOOP_STEP" "$STATE" "$1" 2>&1)"
}
kv_of() { printf '%s\n' "$LOUT" | sed -n "s/^$1=//p" | head -1; }
g5_calls() { grep -c '' "$G5LOG" 2>/dev/null | tr -d ' '; }

# ===========================================================================
# Group 1 — decline / llm_declined go straight to terminal, no child work
# ===========================================================================
group_decline() {
    write_state "-"
    assert_eq "fixture/the state is one the writer's validator accepts" "ok" "$MK_VERDICT"
    loop_step decline
    assert_eq "decline/status" "terminal" "$(kv_of STATUS)"
    assert_eq "decline/phase" "terminal" "$(state_field 's.phase')"
    assert_eq "decline/counter" "1" "$(state_field 's.proposal_counters.declined')"
    assert_eq "decline/user-decision" "decline" "$(state_field 's.g5_history[0].user_decision')"
    assert_eq "decline/no-g5-execute" "0" "$(g5_calls)"

    write_state "-"
    loop_step llm_declined
    assert_eq "llm-declined/status" "terminal" "$(kv_of STATUS)"
    assert_eq "llm-declined/user-decision" "llm_declined" "$(state_field 's.g5_history[0].user_decision')"
}

# ===========================================================================
# Group 2 — accept runs G.5-3a once, and the flag makes the rerun a no-op
# ===========================================================================
group_accept_idempotency() {
    write_state "-"
    loop_step accept
    assert_eq "accept/status" "awaiting_recursion" "$(kv_of STATUS)"
    assert_eq "accept/phase" "awaiting_recursion" "$(state_field 's.phase')"
    assert_eq "accept/g5-3a-completed" "true" "$(state_field 's.g5_history[0].g5_3a_completed')"
    assert_eq "accept/g5-called-once" "1" "$(g5_calls)"
    assert_eq "accept/g5-argv" "execute 1600 accept" "$(head -1 "$G5LOG")"

    # Second accept on the same state: the guard must suppress the child call.
    loop_step accept
    assert_eq "accept-again/status" "awaiting_recursion" "$(kv_of STATUS)"
    assert_eq "accept-again/no-second-g5-call" "0" "$(g5_calls)"
    assert_eq "accept-again/g5-3a-still-completed" "true" "$(state_field 's.g5_history[0].g5_3a_completed')"
}

# ===========================================================================
# Group 3 — recurse_done grows g5_history monotonically
# ===========================================================================
group_recurse() {
    write_state 's.g5_history[0].g5_3a_completed = true; s.phase = "awaiting_recursion";'
    loop_step recurse_done
    assert_eq "recurse/status" "init_done" "$(kv_of STATUS)"
    assert_eq "recurse/history-length" "2" "$(state_field 's.g5_history.length')"
    assert_eq "recurse/iteration" "1" "$(state_field 's.g5_loop_iteration')"
    assert_eq "recurse/new-entry-iteration" "1" "$(state_field 's.g5_history[1].iteration')"
    assert_eq "recurse/current-issue-advanced" "1600" "$(state_field 's.current_issue_number')"
    assert_eq "recurse/accepted-counter" "1" "$(state_field 's.proposal_counters.accepted')"
    assert_eq "recurse/recursion-completed" "true" "$(state_field 's.g5_history[0].recursion_completed')"
    # The new entry is seeded from the prepare stub's KV stdout, not from eval.
    assert_eq "recurse/new-proposal-parent" "1500" "$(state_field 's.g5_history[1].proposal_parent')"
    assert_eq "recurse/g5-prepare-argv" "prepare 1600" "$(head -1 "$G5LOG")"

    loop_step recurse_done
    assert_eq "recurse-twice/history-length" "3" "$(state_field 's.g5_history.length')"
    assert_eq "recurse-twice/iteration" "2" "$(state_field 's.g5_loop_iteration')"
}

# ===========================================================================
# Group 4 — rejects, and the atomic-write contract
# ===========================================================================
group_rejects() {
    write_state "-"
    loop_step not_a_decision
    assert_eq "unknown-decision/status" "failed" "$(kv_of STATUS)"
    assert_eq "unknown-decision/state-untouched" "init_done" "$(state_field 's.phase')"

    # One below and one above the version the writer writes; neither may be acted on.
    write_state 's.schema_version -= 1;'
    loop_step accept
    assert_eq "schema-previous/status" "failed" "$(kv_of STATUS)"
    assert_eq "schema-previous/no-g5-call" "0" "$(g5_calls)"
    write_state 's.schema_version += 1;'
    loop_step accept
    assert_eq "schema-next/status" "failed" "$(kv_of STATUS)"
    assert_eq "schema-next/no-g5-call" "0" "$(g5_calls)"

    write_state 's.g5_history = [];'
    loop_step accept
    assert_eq "empty-history/status" "failed" "$(kv_of STATUS)"

    rm -f "$STATE"
    loop_step accept
    assert_eq "missing-state/status" "failed" "$(kv_of STATUS)"

    write_state "-"
    loop_step decline
    assert_eq "decline-for-atomic-write/status" "terminal" "$(kv_of STATUS)"
    # The writer's temp file is <state>.<pid>.<random>.tmp and its lock <state>.lock.
    assert_eq "atomic-write/no-tmp-or-lock-left-behind" "" "$(compgen -G "$STATE.*" || true)"
    # Exactly the two-line KV contract the worker parses.
    assert_eq "kv/line-count" "2" "$(printf '%s\n' "$LOUT" | grep -c '^[A-Z_][A-Z0-9_]*=')"
    assert_eq "kv/has-summary" "1" "$([ -n "$(kv_of SUMMARY)" ] && echo 1 || echo 0)"
    assert_eq "kv/exit0" "0" "$(run_with_timeout 60 env "${PIN_ENV[@]}" FINALIZE_SCRIPTS_DIR="$STUB_DIR" G5_CALL_LOG="$G5LOG" node "$LOOP_STEP" "$STATE" decline >/dev/null 2>&1; echo $?)"
}

# ===========================================================================
# Group 5 — argv / env arity of the two bash scripts (fail-closed, non-zero)
# ===========================================================================
# argv_refused <name> <wanted refusal text> <command...> — refused by the named check itself:
# exit code 1 and that check's own message, so a timeout or an unrelated crash does not pass.
argv_refused() {
    local name="$1" want="$2" out rc=0
    shift 2
    out="$(run_with_timeout 30 "$@" 2>&1)" || rc=$?
    assert_eq "$name: exit code" "1" "$rc"
    case "$out" in
        *"$want"*) pass "$name: names the missing input" ;;
        *) fail "$name: names the missing input" "want '$want' in: $(printf '%s' "$out" | tr '\n' ' ' | cut -c1-300)" ;;
    esac
}

group_argv() {
    argv_refused "run-initial/no-args-rejected" "issue_number required" env "${PIN_ENV[@]}" bash "$RUN_INITIAL"
    argv_refused "run-initial/missing-root-issue-rejected" "root_issue_number required" env "${PIN_ENV[@]}" bash "$RUN_INITIAL" 1673

    argv_refused "run-initial/missing-env-rejected" "FINALIZE_SCRIPTS_DIR not set" \
        env -u FINALIZE_SCRIPTS_DIR "${PIN_ENV[@]}" bash "$RUN_INITIAL" 1673 1673
    # The scripts dir is the stub dir here: it holds no pre-flight, so nothing reaches a forge.
    argv_refused "run-initial/missing-target-main-root-flag-rejected" "--target-main-root <dir> required" \
        env "${PIN_ENV[@]}" "FINALIZE_SCRIPTS_DIR=$STUB_DIR" bash "$RUN_INITIAL" 1673 1673
    # The flag with the positionals missing is still refused by the positional checks.
    argv_refused "run-initial/flag-then-no-args-rejected" "issue_number required" \
        env "${PIN_ENV[@]}" bash "$RUN_INITIAL" --target-main-root "$CWD_REPO"
    argv_refused "run-initial/flag-then-missing-root-issue-rejected" "root_issue_number required" \
        env "${PIN_ENV[@]}" bash "$RUN_INITIAL" --target-main-root "$CWD_REPO" 1673
    argv_refused "run-initial/empty-flag-value-rejected" "--target-main-root <dir> required" \
        env "${PIN_ENV[@]}" "FINALIZE_SCRIPTS_DIR=$STUB_DIR" bash "$RUN_INITIAL" --target-main-root "" 1673 1673
    argv_refused "run-initial/flag-without-value-rejected" "--target-main-root <dir> required" \
        env "${PIN_ENV[@]}" "FINALIZE_SCRIPTS_DIR=$STUB_DIR" bash "$RUN_INITIAL" --target-main-root
    # The flag is read in first place only: after the positionals it names no root.
    argv_refused "run-initial/flag-after-positionals-rejected" "--target-main-root <dir> required" \
        env "${PIN_ENV[@]}" "FINALIZE_SCRIPTS_DIR=$STUB_DIR" bash "$RUN_INITIAL" 1673 1673 --target-main-root "$CWD_REPO"

    argv_refused "run-terminal/no-args-rejected" "state_file_path required" env "${PIN_ENV[@]}" bash "$RUN_TERMINAL"
    argv_refused "run-terminal/missing-session-id-rejected" "session_id required" env "${PIN_ENV[@]}" bash "$RUN_TERMINAL" "$STATE"
    # Two of three arguments: refused at the argument check, before the state file is read.
    argv_refused "run-terminal/missing-outcome-path-rejected" "outcome_file_path required" \
        env "${PIN_ENV[@]}" bash "$RUN_TERMINAL" "$STATE" sid

    # run-finalize-terminal.sh exports ISSUE_CLOSE_SKILL itself — the dispatcher
    # must not have to (and must not) pass it through.
    if grep -q 'export ISSUE_CLOSE_SKILL=1' "$RUN_TERMINAL"; then
        pass "run-terminal/self-exports-issue-close-skill"
    else
        fail "run-terminal/self-exports-issue-close-skill" "export missing from run-finalize-terminal.sh"
    fi
}

# ===========================================================================
# Group 6 — direct launch (#2561): run-initial.sh / run-finalize-terminal.sh run
# their own checkout's helpers whether the root names point at stub trees or are
# absent. gh is a fixed-output stub; git stays real (the origin is read locally).
# TL3 gap: the real gh answers; the same scripts through the dispatcher's child
# environment (tests/bin/TL3-worker-dispatch-issue-close-finalize.sh).
# ===========================================================================
DL_ROOT="$(cd "$SCRIPTS_DIR/../../.." && pwd)"
# shellcheck source=tests/lib/root-decoy.sh
. "$DL_ROOT/tests/lib/root-decoy.sh"
# shellcheck source=tests/lib/cli-stub.sh
. "$DL_ROOT/tests/lib/cli-stub.sh"
# shellcheck source=tests/lib/target-repo-fixture.sh
. "$DL_ROOT/tests/lib/target-repo-fixture.sh"

DL_RWT="$DL_ROOT/bin/run-with-timeout.sh"
DL_BUILDER="$DL_ROOT/tests/lib/root-decoy-build.js"
DL_ISSUE=4242
DL_SLUG="example-owner/example-repo"
# A directory name with a space and shell metacharacters: every path below runs through it.
DL_WORK="$DL_TMP/fin & \$x dir"
DL_DECOY="$DL_TMP/decoy"
DL_GH_LOG="$DL_TMP/gh-calls.log"
DL_OUT="$DL_TMP/launch.out"
DL_STATE="$DL_WORK/state.json"
DL_OUTCOME="$DL_WORK/outcome.json"
DL_RETIRED=()
DL_GITHUB_TARGET=""
DL_OTHER_TARGET=""
DL_WHY=""
DL_RC=0

# dl_setup: returns 1 with the reason in DL_WHY when a fixture cannot be built.
dl_setup() {
    local name seen
    unset CLAUDE_CODE_SESSION_ID ROOT_DECOY_TEST_ID GH_REPO GH_TOKEN
    mkdir -p "$DL_WORK/github" "$DL_WORK/other"
    while IFS= read -r name; do
        name="${name%$'\r'}"
        [ -n "$name" ] && DL_RETIRED+=("$name")
    done < <(node "$DL_BUILDER" --print-retired-env-names)
    DL_WHY="the root decoy could not be built"
    [ "${#DL_RETIRED[@]}" -gt 0 ] || return 1
    node "$DL_BUILDER" --out "$DL_DECOY" || return 1
    # The stub dir carries gh only; git stays real so the origin remote is read locally.
    DL_WHY="gh stub"
    cli_stub_make "$DL_TMP/stub-bin" gh || return 1
    seen="$(PATH="$CLI_STUB_DIR:$PATH" command -v gh)"
    DL_WHY="the gh stub is not first on PATH ($seen)"
    [ "${seen%/*}" = "$CLI_STUB_DIR" ] || return 1
    DL_WHY="target repo"
    target_repo_fixture_create "$DL_WORK/github" || return 1
    DL_GITHUB_TARGET="$TARGET_MAIN_ROOT"
    git -C "$DL_GITHUB_TARGET" remote add origin "https://github.com/$DL_SLUG.git"
    DL_WHY="second target repo"
    target_repo_fixture_create "$DL_WORK/other" || return 1
    DL_OTHER_TARGET="$TARGET_MAIN_ROOT"
    git -C "$DL_OTHER_TARGET" remote add origin "https://git.example.com/$DL_SLUG.git"
    DL_WHY=""
}

dl_kv() { sed -n "s/^$1=//p" "$DL_OUT" | head -n 1; }
dl_reset_probes() {
    : > "$DL_GH_LOG"
    rm -f "$DL_DECOY"/main/hits/*.hit "$DL_DECOY"/old/hits/*.hit
}
dl_decoy_hits() { printf '%s/%s' "$(root_decoy_hit_count "$DL_DECOY/main")" "$(root_decoy_hit_count "$DL_DECOY/old")"; }
dl_gh_calls() { grep -c -- "^gh $1" "$DL_GH_LOG" 2>/dev/null || true; }
dl_asked_gh() { # <name>
    if [ "$(dl_gh_calls "issue view $DL_ISSUE")" -ge 1 ]; then pass "$1"
    else fail "$1" "no 'gh issue view $DL_ISSUE' call recorded"; fi
}

dl_write_state() { # <triage_action> — the full state the initial pass writes, for this target.
    MK_VERDICT="$(node "$MKSTATE" "$DL_STATE" "s.root_issue_number = s.current_issue_number = $DL_ISSUE;
s.owner_repo = '$DL_SLUG'; s.triage_action = '$1'; s.g5_history[0].issue_number = '$DL_ISSUE';" \
        "$CHECKOUT_N" "$DL_GITHUB_TARGET" 2>&1)"
}
dl_state_phase() { node -p 'JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")).phase' "$DL_STATE" 2>/dev/null; }
dl_outcome() { # <js expression over bag b>
    node -e '
let b = { issues: [] };
try { b = JSON.parse(require("fs").readFileSync(process.argv[1], "utf8")); } catch (_) {}
process.stdout.write(String(new Function("b", "return " + process.argv[2])(b)));
' "$DL_OUTCOME" "$1"
}

# dl_launch <decoy|bare> <target main root> <command...>
# decoy: the agents root name and every retired name point at stub trees.
# bare:  none of those names is set at all.
dl_launch() {
    local mode="$1" target="$2" name
    shift 2
    (
        cd "$target" || exit 98
        export HOME="$DL_TMP/home" USERPROFILE="$DL_TMP/home"
        unset AGENTS_MAIN_ROOT
        for name in "${DL_RETIRED[@]}"; do unset "$name"; done
        if [ "$mode" = "decoy" ]; then
            export AGENTS_MAIN_ROOT="$DL_DECOY/main"
            for name in "${DL_RETIRED[@]}"; do export "$name=$DL_DECOY/old"; done
        fi
        FINALIZE_SCRIPTS_DIR="$SCRIPTS_DIR" CLI_STUB_OUT="CLOSED" CLI_STUB_LOG="$DL_GH_LOG" \
            cli_stub_run bash "$DL_RWT" 90 "$@"
    ) > "$DL_OUT" 2> "$DL_OUT.err"
    DL_RC=$?
}

dl_initial_cases() {
    dl_reset_probes
    dl_launch decoy "$DL_GITHUB_TARGET" bash "$RUN_INITIAL" --target-main-root "$DL_GITHUB_TARGET" "$DL_ISSUE" "$DL_ISSUE"
    assert_eq "initial/decoy: exit code" "0" "$DL_RC"
    assert_eq "initial/decoy: STATUS" "init_done" "$(dl_kv STATUS)"
    assert_eq "initial/decoy: OWNER_REPO comes from the target origin" "$DL_SLUG" "$(dl_kv OWNER_REPO)"
    assert_eq "initial/decoy: TRIAGE_ACTION" "auto_close_path" "$(dl_kv TRIAGE_ACTION)"
    assert_eq "initial/decoy: NEXT_STEPS" "G,J,K" "$(dl_kv NEXT_STEPS)"
    dl_asked_gh "initial/decoy: the triage of this checkout asked gh"
    assert_eq "initial/decoy: stub hits (main/old)" "0/0" "$(dl_decoy_hits)"

    dl_reset_probes
    dl_launch bare "$DL_GITHUB_TARGET" bash "$RUN_INITIAL" --target-main-root "$DL_GITHUB_TARGET" "$DL_ISSUE" "$DL_ISSUE"
    assert_eq "initial/bare: exit code" "0" "$DL_RC"
    assert_eq "initial/bare: STATUS" "init_done" "$(dl_kv STATUS)"
    assert_eq "initial/bare: OWNER_REPO" "$DL_SLUG" "$(dl_kv OWNER_REPO)"

    dl_reset_probes
    dl_launch decoy "$DL_OTHER_TARGET" bash "$RUN_INITIAL" --target-main-root "$DL_OTHER_TARGET" "$DL_ISSUE" "$DL_ISSUE"
    assert_eq "initial/non-github: exit code" "0" "$DL_RC"
    assert_eq "initial/non-github: STATUS" "failed" "$(dl_kv STATUS)"
    assert_eq "initial/non-github: SUMMARY names the pre-flight" "pre-flight failed" "$(dl_kv SUMMARY)"
    assert_eq "initial/non-github: no OWNER_REPO line" "" "$(dl_kv OWNER_REPO)"
    assert_eq "initial/non-github: gh never asked" "0" "$(dl_gh_calls "")"
    assert_eq "initial/non-github: stub hits (main/old)" "0/0" "$(dl_decoy_hits)"
}

dl_terminal_cases() {
    dl_reset_probes
    rm -f "$DL_OUTCOME"
    dl_write_state resume_j
    assert_eq "terminal/fixture: the state is one the writer's validator accepts" "ok" "$MK_VERDICT"
    dl_launch decoy "$DL_GITHUB_TARGET" bash "$RUN_TERMINAL" "$DL_STATE" "sid-2561" "$DL_OUTCOME"
    assert_eq "terminal/decoy: exit code" "0" "$DL_RC"
    assert_eq "terminal/decoy: STATUS" "terminal" "$(dl_kv STATUS)"
    assert_eq "terminal/decoy: state phase" "terminal" "$(dl_state_phase)"
    assert_eq "terminal/decoy: outcome entry written by this checkout" "1" \
        "$(dl_outcome "b.issues.filter((e) => e.issueNumber === $DL_ISSUE && e.sentinelsPosted === 'succeeded').length")"
    dl_asked_gh "terminal/decoy: the sentinel step of this checkout asked gh"
    assert_eq "terminal/decoy: resume_j never closes" "0" "$(dl_gh_calls "issue close")"
    assert_eq "terminal/decoy: stub hits (main/old)" "0/0" "$(dl_decoy_hits)"
    # Idempotency: a second pass over the terminal state file keeps one entry.
    dl_launch decoy "$DL_GITHUB_TARGET" bash "$RUN_TERMINAL" "$DL_STATE" "sid-2561" "$DL_OUTCOME"
    assert_eq "terminal/decoy: second pass STATUS" "terminal" "$(dl_kv STATUS)"
    assert_eq "terminal/decoy: second pass keeps one entry" "1" "$(dl_outcome "b.issues.length")"
    assert_eq "terminal/decoy: second pass stub hits (main/old)" "0/0" "$(dl_decoy_hits)"

    dl_reset_probes
    rm -f "$DL_OUTCOME"
    dl_write_state resume_j
    dl_launch bare "$DL_GITHUB_TARGET" bash "$RUN_TERMINAL" "$DL_STATE" "sid-2561" "$DL_OUTCOME"
    assert_eq "terminal/bare: exit code" "0" "$DL_RC"
    assert_eq "terminal/bare: STATUS" "terminal" "$(dl_kv STATUS)"
    assert_eq "terminal/bare: outcome entry" "1" "$(dl_outcome "b.issues.length")"

    dl_reset_probes
    rm -f "$DL_OUTCOME"
    dl_write_state resume_j
    dl_launch decoy "$DL_GITHUB_TARGET" bash "$RUN_TERMINAL" "$DL_STATE" "sid-2561" "$DL_OUTCOME" "0000"
    assert_eq "terminal/conflict: exit code" "0" "$DL_RC"
    assert_eq "terminal/conflict: STATUS" "failed" "$(dl_kv STATUS)"
    assert_eq "terminal/conflict: state phase untouched" "init_done" "$(dl_state_phase)"
    assert_eq "terminal/conflict: no outcome file" "absent" "$([ -e "$DL_OUTCOME" ] && echo present || echo absent)"
    assert_eq "terminal/conflict: gh never asked" "0" "$(dl_gh_calls "")"
    assert_eq "terminal/conflict: stub hits (main/old)" "0/0" "$(dl_decoy_hits)"
}

# run-loop-step.js under the same two environments. The G.5 step is the recording stub it is
# handed, so a pass that looked for its helper under a root name shows up as a missing call.
dl_loop_prepare() { dl_reset_probes; : > "$G5LOG"; dl_write_state resume_e; }
dl_loop_checks() { # <mode>
    assert_eq "loop-step/$1: exit code" "0" "$DL_RC"
    assert_eq "loop-step/$1: STATUS" "awaiting_recursion" "$(dl_kv STATUS)"
    assert_eq "loop-step/$1: state phase" "awaiting_recursion" "$(dl_state_phase)"
    assert_eq "loop-step/$1: the handed-over G.5 step ran once" "1" "$(g5_calls)"
    assert_eq "loop-step/$1: stub hits (main/old)" "0/0" "$(dl_decoy_hits)"
}
dl_loop_cases() {
    dl_loop_prepare
    dl_launch decoy "$DL_GITHUB_TARGET" env "FINALIZE_SCRIPTS_DIR=$STUB_DIR" "G5_CALL_LOG=$G5LOG" node "$LOOP_STEP" "$DL_STATE" accept
    dl_loop_checks decoy
    dl_loop_prepare
    dl_launch bare "$DL_GITHUB_TARGET" env "FINALIZE_SCRIPTS_DIR=$STUB_DIR" "G5_CALL_LOG=$G5LOG" node "$LOOP_STEP" "$DL_STATE" accept
    dl_loop_checks bare
}

group_direct_launch() {
    if ! dl_setup; then
        fail "direct-launch/setup" "$DL_WHY"
        return
    fi
    dl_initial_cases
    dl_loop_cases
    dl_terminal_cases
}

group_decline
group_accept_idempotency
group_recurse
group_rejects
group_argv
group_direct_launch

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
