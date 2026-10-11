# Part of tests/bin/feature-2544-worker-outcome-write.sh — sourced.
# Tests: bin/worker-dispatch.js
# Tags: worker-dispatch, outcome, fixture, TL2, scope:issue-specific
# Shared fixture: one main repo carrying a stub tests/run-all.sh, the pinned state and
# plans dirs (pinned by the entrypoint), and the dispatch / listing helpers.

DISPATCH_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch.js"
FSGUARD_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/fsguard.js"
SPAWN_JS="$SCRIPT_CHECKOUT_ROOT/bin/worker-dispatch/spawn.js"
REGISTRY_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/worker-dispatch-registry.js"
SETTLE_JS="$SCRIPT_CHECKOUT_ROOT/hooks/workflow-state/dispatch-settlement.js"
PRELOAD="$SCRIPT_CHECKOUT_ROOT/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
THROW_PRELOAD="$CASE_DIR/throw-stub.js"
NULL_PRELOAD="$CASE_DIR/null-module-stub.js"

WF_RAW="$TMPD/workflow-state"
PLANS_RAW="$TMPD/plans"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

PASS_CANNED='[{"status":0,"stdout":"Results: PASS=2 FAIL=0 SKIP=0\nRUN_CONTRACT: PASS=2 FAIL=0 SKIP=0 EXECUTED=2\n"}]'
FAIL_CANNED='[{"status":1,"stdout":"FAIL: tests/bin/a.sh (exit 1)\nResults: PASS=1 FAIL=1 SKIP=0\nRUN_CONTRACT: PASS=1 FAIL=1 SKIP=0 EXECUTED=2\n"}]'
FINALIZE_CANNED='[{"stdout":"STATUS=init_done\nOWNER_REPO=o/r\n"}]'

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
# assert_has <name> <needle> <haystack> — the haystack contains the needle.
assert_has() {
    case "$3" in
        *"$2"*) pass "$1" ;;
        *) fail "$1" "missing $(printf '%q' "$2") in $(printf '%.200q' "$3")" ;;
    esac
}
# kv <output> <key> — the value of one "<key>=<value>" line.
kv() { printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -1; }
count_lines() { if [ -z "$1" ]; then printf '0'; else printf '%s\n' "$1" | grep -c ''; fi; }

build_repo() {
    REPO_RAW="$TMPD/repo"; OUTSIDE_RAW="$TMPD/outside"
    mkdir -p "$REPO_RAW/tests" "$OUTSIDE_RAW"
    harness_git_init "$REPO_RAW"
    git -C "$REPO_RAW" checkout -q -b main 2>/dev/null
    git -C "$REPO_RAW" config user.email "test@example.com"
    git -C "$REPO_RAW" config user.name "Test"
    printf '#!/usr/bin/env bash\necho "Results: PASS=2 FAIL=0 SKIP=0"\n' > "$REPO_RAW/tests/run-all.sh"
    echo init > "$REPO_RAW/README.md"
    git -C "$REPO_RAW" add README.md tests/run-all.sh >/dev/null 2>&1
    git -C "$REPO_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
    MAIN="$(np "$REPO_RAW")"; OUTSIDE="$(np "$OUTSIDE_RAW")"
    git -C "$REPO_RAW" rev-parse -q --verify HEAD >/dev/null 2>&1
}

# tr_json [cwd] [tag] — a test-runner payload; the tag makes two payloads differ in bytes.
tr_json() { printf '{"cwd":"%s","test_args":["%s"],"timeout_seconds":60}' "${1:-$MAIN}" "${2:-tests/bin/a.sh}"; }
finalize_json() {
    printf '{"phase":"initial","issue_number":1,"root_issue_number":1,"owner_repo":"o/r","target_main_root":"%s","session_id":"%s","artifact_dir":"%s"}' "$MAIN" "$1" "$WORKFLOW_PLANS_DIR"
}

# seed_payload <sid> <stem> <json> — a payload already present in the control dir,
# standing for an earlier publication. Prints its node-style path.
seed_payload() {
    mkdir -p "$WF_RAW/$1.control"
    printf '%s' "$3" > "$WF_RAW/$1.control/$2.json"
    np "$WF_RAW/$1.control/$2.json"
}
set_canned() { printf '%s' "$1" > "$CANNED"; }

DOUT=""; DERR=""; DRC=0
# dispatch <worker> <payload-path> [extra-preload] — the real dispatcher over a canned spawn seam.
dispatch() {
    local extra=()
    if [ -n "${3:-}" ]; then extra=(-r "$(np "$3")"); fi
    : > "$CALLLOG"
    DRC=0
    DOUT="$(cd "$TMPD" && run_with_timeout 120 env "WD_SPAWN_MODULE=$(np "$SPAWN_JS")" "WD_CANNED=$(np "$CANNED")" \
        "WD_CALL_LOG=$(np "$CALLLOG")" node -r "$(np "$PRELOAD")" "${extra[@]}" "$(np "$DISPATCH_JS")" "$1" "$MAIN" "$2" \
        2>"$TMPD/dispatch.err")" || DRC=$?
    DERR="$(cat "$TMPD/dispatch.err" 2>/dev/null)"
}
# field_of <key> — one top-level key of the dispatcher's stdout, quotes dropped.
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"; v="${v%\'}"; v="${v#\'}"
    printf '%s' "$v"
}

# ctrl_ls <sid> — every entry of the session control dir, sorted, space-joined.
ctrl_ls() {
    [ -d "$WF_RAW/$1.control" ] || return 0
    (cd "$WF_RAW/$1.control" && find . -mindepth 1 | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
}
# outcomes_in <sid> — the outcome file names in the control dir, space-joined.
outcomes_in() {
    [ -d "$WF_RAW/$1.control" ] || return 0
    (cd "$WF_RAW/$1.control" && find . -mindepth 1 -name '*.outcome.json' | sed 's|^\./||' | LC_ALL=C sort | tr '\n' ' ')
}
has_file() { if [ -f "$WF_RAW/$1.control/$2" ]; then printf 'yes'; else printf 'no'; fi; }
sha_of() { if [ -f "$1" ]; then sha256sum "$1" | cut -d' ' -f1; else printf 'MISSING'; fi; }

# outcome_fields <sid> <stem> — one "<key>=<value>" line per outcome field under test.
# cwd is printed raw: the outcome must carry the payload's own bytes, never a normalised path.
outcome_fields() {
    node - "$(np "$WF_RAW/$1.control/$2.outcome.json")" 2>&1 <<'JS'
const fs = require("fs");
const file = process.argv[process.argv.length - 1];
const say = (k, v) => console.log(k + "=" + v);
let o = null;
try { o = JSON.parse(fs.readFileSync(file, "utf8")); } catch (e) { say("parse", "failed:" + e.code); process.exit(0); }
say("parse", "ok");
for (const k of ["schema_version", "worker", "stem", "session_id", "payload_sha256", "status", "exit_code"]) say(k, o[k]);
say("cwd_type", typeof o.cwd);
say("cwd", JSON.stringify(o.cwd));
say("duration_ms_type", typeof o.duration_ms);
const wr = o.worker_result && typeof o.worker_result === "object" ? o.worker_result : {};
say("run_contract", wr.run_contract === null || wr.run_contract === undefined ? "none" : JSON.stringify(wr.run_contract));
say("failing_tests", JSON.stringify(wr.failing_tests));
say("log_tail_present", wr.log_tail === undefined ? "no" : "yes");
say("summary_type", typeof wr.summary);
say("summary", typeof wr.summary === "string" ? wr.summary.split("\n")[0] : "");
JS
}
