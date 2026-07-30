#!/usr/bin/env bash
# tests/feature-1643-worker-dispatch-doc-append-behavior.sh
# Tests: bin/worker-dispatch/workers/doc-append.js, bin/worker-dispatch.js
# Tags: worker-dispatch, doc-append, argv-contract, idempotency, table-driven, TL2, scope:issue-specific
#
# Issue #1643 — doc-append is one CLI call in three shapes. The agent it replaced
# had its argv mangled by shell quoting; a table decides it here, and this file
# is what proves the table maps each mode to the right binary and the right
# flags. Nothing else covered which argv a mode produces.
#
# The process seam is canned via tests/feature-1643-worker-dispatch-lib/
# spawn-stub.js, so the exact argv the worker asked for is recorded and asserted
# instead of being inferred from a side effect. Everything up to the seam —
# per-mode required-field checks, script resolution under the ACD anchor,
# fsguard, emit — runs for real.
#
# TL3 gap (what this TL2 test does NOT catch):
#   - Whether bin/doc-append.py and bin/compose-doc-append-entry actually ACCEPT
#     the flags assembled here; only the real CLIs can answer that.
#     tests/TL3-worker-dispatch-run-tests.sh covers the real-runner tier.
#   - `uv` being absent from PATH on the host.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WD1643_DA_INNER:-}" ]; then
    _WD1643_DA_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
PRELOAD="$AGENTS_DIR/tests/feature-1643-worker-dispatch-lib/spawn-stub.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
assert_has() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) pass "$name" ;;
        *) fail "$name" "want substring '$needle' in '$hay'" ;;
    esac
}
assert_lacks() {
    local name="$1" needle="$2" hay="$3"
    case "$hay" in
        *"$needle"*) fail "$name" "unexpected substring '$needle' in '$hay'" ;;
        *) pass "$name" ;;
    esac
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$DISPATCH_JS" ] || [ ! -f "$PRELOAD" ]; then
    fail "0: fixture prerequisites missing" "dispatcher=$DISPATCH_JS stub=$PRELOAD"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-da-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT

MAIN_RAW="$TMPD/mainrepo"
mkdir -p "$MAIN_RAW"
git -C "$MAIN_RAW" init -q -b main
git -C "$MAIN_RAW" config user.email "test@example.com"
git -C "$MAIN_RAW" config user.name "Test"
git -C "$MAIN_RAW" config core.hooksPath /dev/null
echo init > "$MAIN_RAW/README.md"
git -C "$MAIN_RAW" add README.md >/dev/null 2>&1
git -C "$MAIN_RAW" commit -q --no-verify -m initial >/dev/null 2>&1
LINKED_RAW="$TMPD/linked-wt"
git -C "$MAIN_RAW" worktree add -q -b feature/da-probe "$LINKED_RAW" >/dev/null 2>&1
printf '## BugsFound\n- (none)\n' > "$LINKED_RAW/WORKTREE_NOTES.md"
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"

MAIN="$(nodepath "$MAIN_RAW")"
CWD="$(nodepath "$LINKED_RAW")"
NOTES="$(nodepath "$LINKED_RAW/WORKTREE_NOTES.md")"
PLANS="$(nodepath "$PLANS_RAW")"
CANNED="$TMPD/canned.json"
CALLLOG="$TMPD/calls.jsonl"

DOUT=""; DRC=0
write_payload() { printf '%s' "$2" > "$PLANS_RAW/$1.json"; nodepath "$PLANS_RAW/$1.json"; }
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}
dispatch_da() {
    printf '%s' "$1" > "$CANNED"
    : > "$CALLLOG"
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" \
        "WD_SPAWN_MODULE=$(nodepath "$AGENTS_DIR/bin/worker-dispatch/spawn.js")" \
        "WD_CANNED=$(nodepath "$CANNED")" \
        "WD_CALL_LOG=$(nodepath "$CALLLOG")" \
        node -r "$(nodepath "$PRELOAD")" "$(nodepath "$DISPATCH_JS")" doc-append "$MAIN" "$2" 2>/dev/null)" || DRC=$?
}
call_command() {
    node -e '
const fs=require("fs");
const t=fs.readFileSync(process.argv[1],"utf8").trim();
if(t===""){process.stdout.write("(no-call)");process.exit(0);}
process.stdout.write(JSON.parse(t.split("\n")[0]).command);
' "$(nodepath "$CALLLOG")"
}
call_args() {
    node -e '
const fs=require("fs");
const t=fs.readFileSync(process.argv[1],"utf8").trim();
if(t===""){process.stdout.write("(no-call)");process.exit(0);}
process.stdout.write(JSON.parse(t.split("\n")[0]).args.join(" "));
' "$(nodepath "$CALLLOG")"
}
call_count() { grep -c '' "$CALLLOG" 2>/dev/null | tr -d ' '; }

OK='[{"stdout":"appended"}]'
BASE_TEXT='"category":"FEATURE","subject":"dispatcher","background":"why","changes":"what"'

# ===========================================================================
# Group 1 — history mode
# ===========================================================================
group_history() {
    local p args
    p="$(write_payload da-hist "{\"mode\":\"history\",\"cwd\":\"$CWD\",$BASE_TEXT,\"commits\":\"abc1234\",\"date\":\"2026-07-28\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_da "$OK" "$p"
    assert_eq "history/exit0" "0" "$DRC"
    assert_eq "history/status" "appended" "$(field_of status)"
    assert_eq "history/summary" "history: appended to docs/history.md" "$(field_of summary)"
    assert_eq "history/command-is-uv" "uv" "$(call_command)"
    args="$(call_args)"
    assert_has "history/uv-run-form" "run " "$args"
    assert_has "history/target-doc" "docs/history.md" "$args"
    assert_has "history/commits-flag" "--commits abc1234" "$args"
    assert_has "history/date-passthrough" "--date 2026-07-28" "$args"
    assert_lacks "history/no-changelog-target" "CHANGELOG.md" "$args"
}

# ===========================================================================
# Group 2 — changelog mode (same binary, different target, no --commits)
# ===========================================================================
group_changelog() {
    local p args
    p="$(write_payload da-chlog "{\"mode\":\"changelog\",\"cwd\":\"$CWD\",$BASE_TEXT,\"date\":\"2026-07-28\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_da "$OK" "$p"
    assert_eq "changelog/status" "appended" "$(field_of status)"
    assert_eq "changelog/summary" "changelog: appended to CHANGELOG.md" "$(field_of summary)"
    assert_eq "changelog/command-is-uv" "uv" "$(call_command)"
    args="$(call_args)"
    assert_has "changelog/target-doc" "CHANGELOG.md" "$args"
    assert_lacks "changelog/no-commits-flag" "--commits" "$args"
}

# ===========================================================================
# Group 3 — compose mode (different binary entirely)
# ===========================================================================
group_compose() {
    local p args
    p="$(write_payload da-comp "{\"mode\":\"compose\",\"cwd\":\"$CWD\",\"notes_path\":\"$NOTES\",\"branch\":\"feature/da-probe\",\"pr_number\":\"1677\",\"merge_commit\":\"deadbee\",\"pr_title\":\"a title\",\"closes_issues_count\":3,\"artifact_dir\":\"$PLANS\"}")"
    dispatch_da "$OK" "$p"
    assert_eq "compose/status" "appended" "$(field_of status)"
    assert_eq "compose/summary" "compose: appended to docs/history.md + CHANGELOG.md" "$(field_of summary)"
    assert_eq "compose/command-is-bash" "bash" "$(call_command)"
    args="$(call_args)"
    assert_has "compose/script-is-compose-doc-append-entry" "compose-doc-append-entry" "$args"
    assert_has "compose/pr-number" "--pr 1677" "$args"
    assert_has "compose/merge-commit" "--merge-commit deadbee" "$args"
    assert_has "compose/closes-issues-count-passthrough" "--closes-issues-count 3" "$args"
    assert_lacks "compose/no-bootstrap-when-pr-given" "--bootstrap" "$args"

    p="$(write_payload da-boot "{\"mode\":\"compose\",\"cwd\":\"$CWD\",\"notes_path\":\"$NOTES\",\"branch\":\"feature/da-probe\",\"bootstrap\":true,\"merge_commit\":\"deadbee\",\"pr_title\":\"a title\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_da "$OK" "$p"
    assert_eq "compose/bootstrap-status" "appended" "$(field_of status)"
    args="$(call_args)"
    assert_has "compose/bootstrap-flag" "--bootstrap" "$args"
    assert_lacks "compose/bootstrap-has-no-pr-flag" "--pr " "$args"
    assert_has "compose/count-defaults-to-zero" "--closes-issues-count 0" "$args"
}

# ===========================================================================
# Group 4 — CLI failure surfaces, and the log survives it
# ===========================================================================
group_cli_failure() {
    local p log
    p="$(write_payload da-fail "{\"mode\":\"history\",\"cwd\":\"$CWD\",$BASE_TEXT,\"commits\":\"abc1234\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_da '[{"status":2,"stderr":"doc-append: category is not recognised\nsecond line"}]' "$p"
    assert_eq "clifail/exit0" "0" "$DRC"
    assert_eq "clifail/status" "failed" "$(field_of status)"
    assert_eq "clifail/summary-is-the-cli-first-line" "doc-append: category is not recognised" "$(field_of summary)"
    log="$(field_of artifact_path)"
    if [ -f "$log" ]; then pass "clifail/log-kept-on-failure"
    else fail "clifail/log-kept-on-failure" "artifact_path='$log'"; fi
    if grep -qF "second line" "$log" 2>/dev/null; then pass "clifail/log-carries-full-stderr"
    else fail "clifail/log-carries-full-stderr" "$(cat "$log" 2>/dev/null)"; fi
}

# ===========================================================================
# Group 5 — idempotency, asserted on the observable outcome
# ===========================================================================
group_idempotency() {
    local p
    p="$(write_payload da-idem "{\"mode\":\"history\",\"cwd\":\"$CWD\",$BASE_TEXT,\"commits\":\"abc1234\",\"artifact_dir\":\"$PLANS\"}")"
    dispatch_da "$OK" "$p"
    assert_eq "idem/first-run-appends" "appended" "$(field_of status)"
    # Same payload again; the CLI reports the entry is already present.
    dispatch_da '[{"stdout":"entry already exists for this date"}]' "$p"
    assert_eq "idem/second-run-is-noop-not-appended" "noop" "$(field_of status)"
    assert_eq "idem/noop-summary" "history: nothing to append (entry already present)" "$(field_of summary)"
    assert_eq "idem/second-run-still-exit0" "0" "$DRC"
}

# ===========================================================================
# Group 6 — per-mode required fields are refused BEFORE any process starts
# ===========================================================================
group_required_fields() {
    local name payload want_sub p
    while IFS='|' read -r name payload want_sub; do
        [ -z "${name// /}" ] && continue
        name="$(echo "$name" | xargs)"
        payload="${payload#"${payload%%[![:space:]]*}"}"; payload="${payload%"${payload##*[![:space:]]}"}"
        want_sub="${want_sub#"${want_sub%%[![:space:]]*}"}"; want_sub="${want_sub%"${want_sub##*[![:space:]]}"}"
        p="$(write_payload "da-req-$name" "$payload")"
        dispatch_da "$OK" "$p"
        assert_eq "required/$name/status" "failed" "$(field_of status)"
        assert_has "required/$name/summary" "$want_sub" "$(field_of summary)"
        assert_eq "required/$name/no-process-started" "0" "$(call_count)"
    done <<TABLE
history-missing-commits | {"mode":"history","cwd":"$CWD",$BASE_TEXT,"artifact_dir":"$PLANS"}                                              | commits
bugfix-missing-test-gap | {"mode":"history","cwd":"$CWD","category":"BUGFIX","subject":"s","background":"b","changes":"c","commits":"a1"}  | test_gap
incident-unsupported    | {"mode":"history","cwd":"$CWD","category":"INCIDENT","subject":"s","background":"b","changes":"c","commits":"a1"}| INCIDENT
compose-missing-pr      | {"mode":"compose","cwd":"$CWD","notes_path":"$NOTES","branch":"feature/da-probe","merge_commit":"deadbee"}       | pr_number
TABLE
}

group_history
group_changelog
group_compose
group_cli_failure
group_idempotency
group_required_fields

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
