#!/usr/bin/env bash
# Tests: hooks/scan-outbound.js, hooks/workflow-gate.js
# Tags: TL3, run-e2e, hooks, pretooluse, allow-deny-hook, permission-decision, settings-registration, scan-outbound, workflow-gate, scope:issue-specific, dup-group-keep:size-hard-limit
# #2676: with the registration settings.json really deploys for scan-outbound and workflow-gate
# (matcher, command, timeout copied verbatim, not a stub), a deny from either hook keeps a
# protected `git commit` from running in a real permission flow, even with a permissions.allow
# rule matching it. A control turn without those hooks shows the same commit does run.
# Not appended to feature-2676-hook-classification.js: rules/test.md "Test file naming by layer"
# keeps TL3 cases in a TL3- file without an issue number, and 472 lines + these cases exceed 500.

set -uo pipefail

# TL3 gap (what even this file does NOT catch): the decision-time-limit ask at the real
# registration (a shrunken limit needs the test preload; the day-to-day runner is
# tests/hooks/feature-2676-hook-classification.js) and an interactive dialog.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
if [ ! -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ]; then
    echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off; then
    echo "SKIP: requires RUN_TL3=on in .env" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
    echo "SKIP: claude CLI not found" >&2; exit 77
fi
# shellcheck source=tests/lib/session-repo-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/session-repo-fixture.sh"

readonly BASE="$(mktemp -d)"
trap 'rm -rf "$BASE"' EXIT
export WORKFLOW_STATE_DIR="$BASE/workflow" WORKFLOW_PLANS_DIR="$BASE/plans"
mkdir -p "$WORKFLOW_STATE_DIR" "$WORKFLOW_PLANS_DIR" "$BASE/bin"

expect() { # <name> <want> <got> <why>
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want [$2] got [$3] -- $4"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else "$@"; fi
}
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

WRITER="$SCRIPT_CHECKOUT_ROOT/tests/hooks/TL3-hook-registered-deny/write-settings.js"
PROBE="$SCRIPT_CHECKOUT_ROOT/tests/lib/tl3-turn-transcript.js"
# The hooks run from a copy of this checkout attached to each fixture repo, so each hook treats
# the fixture as its own repo and reads the private-info lists from the fixture's main worktree.
CHECKOUT="$BASE/checkout"
session_repo_fixture_create "$CHECKOUT" hooks bin || { echo "FAIL: checkout copy" >&2; exit 1; }

# SAFETY: shadow `gh` so no turn can reach a remote.
printf '%s\n' '#!/usr/bin/env bash' 'echo "gh is disabled in this TL3 fixture" >&2' 'exit 1' > "$BASE/bin/gh"
chmod +x "$BASE/bin/gh"

# make_repo <name> <staged-content> -> a no-remote repo with one commit and notes.txt staged.
make_repo() {
    local repo="$BASE/$1"
    mkdir -p "$repo/.claude"
    git -C "$repo" init -q -b main
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config user.email "fixture@example.com"
    git -C "$repo" config user.name "Fixture"
    git -C "$repo" commit -q --allow-empty -m init
    printf 'forbiddenword[0-9]+\n' > "$repo/.private-info-blocklist"
    : > "$repo/.private-info-allowlist"
    printf '.private-info-*\n.claude/\n' >> "$repo/.git/info/exclude"
    printf '%s\n' "$2" > "$repo/notes.txt"
    git -C "$repo" add notes.txt
    printf '%s' "$repo"
}
# settings_for <repo> [hookName...]: only those real registrations, commit allow-listed.
settings_for() {
    local repo="$1"; shift
    node "$(node_path "$WRITER")" "$(node_path "$SCRIPT_CHECKOUT_ROOT/settings.json")" \
        "$(node_path "$repo/.claude/settings.json")" '["Bash(git commit:*)"]' "$@"
}
# write_begun_state <sid>: workflow_init complete, every other step pending (a premature commit).
write_begun_state() {
    node -e '
const fs = require("fs"), path = require("path");
const { VALID_STEPS } = require(process.argv[1] + "/hooks/workflow-state.js");
const now = new Date().toISOString();
const steps = Object.fromEntries(VALID_STEPS.map((step) => [step, { status: "pending", updated_at: null }]));
steps.workflow_init = { status: "complete", updated_at: now };
fs.writeFileSync(path.join(process.argv[3], process.argv[2] + ".json"), JSON.stringify({ version: 1, session_id: process.argv[2], created_at: now, steps }, null, 2));
' "$(node_path "$SCRIPT_CHECKOUT_ROOT")" "$1" "$(node_path "$WORKFLOW_STATE_DIR")"
}

unset CLAUDECODE

declare -A TURN_RC=()
run_turn() { # <repo> <session-uuid>; no --dangerously-skip-permissions: the decision is measured
    local rc=0
    session_repo_fixture_attach "$CHECKOUT" "$1" || return 1
    ( cd "$1" && \
      unset CLAUDE_CODE_SESSION_ID; \
      PATH="$BASE/bin:$PATH" AGENTS_MAIN_ROOT="$(node_path "$CHECKOUT")" \
      run_with_timeout 180 claude -p "$PROMPT" \
        --session-id "$2" \
        --setting-sources project \
        --output-format stream-json --verbose \
      >"$BASE/$2.out" 2>&1 ) || rc=$?
    TURN_RC["$2"]=$rc
}
transcript_of() { find "$HOME/.claude/projects" -name "$1.jsonl" -type f 2>/dev/null | head -n 1; }
outcome() { # <session> -> executed | refused | not-attempted | unobserved
    local out att err tr
    tr="$(transcript_of "$1")"
    out="$(node "$PROBE" --probe --needle "git commit" "$(node_path "$BASE/$1.out")" ${tr:+"$(node_path "$tr")"} 2>/dev/null)"
    att="$(printf '%s\n' "$out" | sed -n 's/^attempted=//p')"
    err="$(printf '%s\n' "$out" | sed -n 's/^result_error=//p')"
    [ "$att" = "true" ] || { printf 'not-attempted'; return; }
    case "$err" in false) printf 'executed' ;; true) printf 'refused' ;; *) printf 'unobserved' ;; esac
}
# refused_by <session> <marker> -> true | false | unknown: whether the commit's refused result
# carries that hook's own wording, so each refusal is attributed to the hook under test.
refused_by() {
    local out tr
    tr="$(transcript_of "$1")"
    out="$(node "$PROBE" --probe --needle "git commit" --marker "$2" "$(node_path "$BASE/$1.out")" ${tr:+"$(node_path "$tr")"} 2>/dev/null)"
    printf '%s\n' "$out" | sed -n 's/^marker=//p'
}
# Each hook's own deny wording (hooks/scan-outbound.js staged scan; hooks/workflow-gate.js incomplete
# steps). Not the bare "workflow-gate:" prefix: its decision-time-limit ask carries that prefix too.
SO_MARKER="information detected in staged files"
WG_MARKER="workflow-gate: the following workflow steps are not complete"
commits() { git -C "$1" rev-list --count HEAD; }

PROMPT='Using the Bash tool, run exactly this one command and report verbatim what happened: git commit -m "test". Do not rewrite it, do not use any other form, and do not retry with a different command if it is refused.'
SO="bbbbbbbb-2676-4000-8000-0000000000b1"; WG="bbbbbbbb-2676-4000-8000-0000000000b2"
CONTROL="bbbbbbbb-2676-4000-8000-0000000000b3"

echo "=== scan-outbound: real registration denies a commit of private content ==="
case_begin "registered-scan-outbound-deny" "hooks/scan-outbound.js"
SO_REPO="$(make_repo so 'Internal gateway at 10.20.30.40 is offline.')"
settings_for "$SO_REPO" scan-outbound
run_turn "$SO_REPO" "$SO"
expect "SO-cli-exited-zero" "0" "${TURN_RC[$SO]}" "a timeout (124) or CLI crash leaves the same trace as a refusal"
# Attempted first: a model that never ran the command would also leave the commit count alone.
expect "SO-commit-attempted-and-refused" "refused" "$(outcome "$SO")" "the deny did not reach the permission flow"
expect "SO-refusal-is-scan-outbounds" "true" "$(refused_by "$SO" "$SO_MARKER")" "the refusal does not carry scan-outbound's wording"
expect "SO-commit-not-made" "1" "$(commits "$SO_REPO")" "a scan-outbound deny let the protected commit run"
case_end

echo "=== workflow-gate: real registration denies a premature commit ==="
case_begin "registered-workflow-gate-deny" "hooks/workflow-gate.js"
WG_REPO="$(make_repo wg 'Just an ordinary log line with nothing sensitive.')"
settings_for "$WG_REPO" workflow-gate
write_begun_state "$WG"
run_turn "$WG_REPO" "$WG"
expect "WG-cli-exited-zero" "0" "${TURN_RC[$WG]}" "a timeout (124) or CLI crash leaves the same trace as a refusal"
expect "WG-commit-attempted-and-refused" "refused" "$(outcome "$WG")" "the deny did not reach the permission flow"
expect "WG-refusal-is-workflow-gates" "true" "$(refused_by "$WG" "$WG_MARKER")" "the refusal does not carry workflow-gate's wording"
expect "WG-commit-not-made" "1" "$(commits "$WG_REPO")" "a workflow-gate deny let the protected commit run"

# Control: the same allow-listed commit with neither hook registered does run, so the two
# refusals above come from the hooks, not from the permission rule or the model.
CONTROL_REPO="$(make_repo control 'Just an ordinary log line with nothing sensitive.')"
settings_for "$CONTROL_REPO"
run_turn "$CONTROL_REPO" "$CONTROL"
expect "control-cli-exited-zero" "0" "${TURN_RC[$CONTROL]}" "a timeout (124) or CLI crash"
expect "control-commit-executed" "executed" "$(outcome "$CONTROL")" "the allow rule alone did not let the commit run"
expect "control-commit-made" "2" "$(commits "$CONTROL_REPO")" "the allow-listed commit did not land"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
