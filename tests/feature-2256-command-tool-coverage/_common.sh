#!/usr/bin/env bash
# tests/feature-2256-command-tool-coverage/_common.sh
# Tests: hooks/lib/tool-command-text.js
# Tags: test-infrastructure, fixture, shared-lib, scope:issue-specific
# Shared fixture, payload builder and assertion preamble for the
# feature-2256-command-tool-coverage sections.

# Sourced by each section, never run as one: the parent lists sections explicitly.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || printf '%s' "$1"; }
AGENTS_NODE="$(nrm "$AGENTS_DIR")"
HOOKS_NODE="$AGENTS_NODE/hooks"
TCT_NODE="$HOOKS_NODE/lib/tool-command-text.js"
FP_NODE="$HOOKS_NODE/lib/diff-fingerprint.js"
WRITER_NODE="$HOOKS_NODE/lib/supervisor-state-writer.js"
SCHEMA_NODE="$HOOKS_NODE/lib/supervisor-state-schema.js"
WFSTATE_MODULE="$HOOKS_NODE/workflow-state"
export WFSTATE_MODULE
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
MKPAYLOAD="$AGENTS_DIR/tests/feature-2256-command-tool-coverage/mkpayload.js"
PROBE="$AGENTS_NODE/tests/feature-1644-advance-transaction/state-probe.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_eq() { if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi; }
assert_ne() { if [ "$2" != "$3" ]; then pass "$1"; else fail "$1" "both sides are '$2'"; fi; }
assert_match() {
    if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "'$2' does not match /$3/"; fi
}
assert_nomatch() {
    if printf '%s' "$2" | grep -Eq "$3"; then fail "$1" "'$2' unexpectedly matches /$3/"; else pass "$1"; fi
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256ct)"
trap 'rm -rf "$WORK"' EXIT
WORK_NODE="$(nrm "$WORK")"

mkdir -p "$WORK/plans" "$WORK/wf" "$WORK/transcripts" "$WORK/cfg"
: > "$WORK/cfg/.env"
export CLAUDE_WORKFLOW_DIR="$WORK_NODE/wf"
export WORKFLOW_PLANS_DIR="$WORK_NODE/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WORK_NODE/transcripts"
export AGENTS_CONFIG_DIR="$WORK_NODE/cfg"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
cd "$WORK" || exit 1

# The four command-tool shapes every sentinel path must treat identically.
# rc1 is the load-bearing one: `^...$` never matches a joined two-element list.
SHAPES="bash runInTerminal rc0 rc1"
SENTINEL_UV='echo "<<WORKFLOW_USER_VERIFIED: the change was verified in the running app>>"'

# payload <shape> <command> [cwd] [session-id] [exit-code] [lead-command]
payload() {
    SHAPE="$1" CMD="$2" PCWD="${3:-}" SID="${4:-}" EXITCODE="${5:-}" LEAD="${6:-git status --short}" \
        node "$MKPAYLOAD"
}

# run_hook <hook-relative-path> <payload-json> — stdout of the hook, stderr dropped.
run_hook() {
    printf '%s' "$2" | bash "$RWT" 60 node "$AGENTS_DIR/hooks/$1" 2>/dev/null
}

# jfield <json> <dotted-path> — the field's value, or 'none' when absent.
jfield() {
    JBODY="$1" JPATH="$2" node -e "
const o = (() => { try { return JSON.parse(process.env.JBODY); } catch (e) { return null; } })();
if (o === null) { process.stdout.write('parse-error'); process.exit(0); }
let v = o;
for (const k of process.env.JPATH.split('.')) v = v === null || v === undefined ? undefined : v[k];
process.stdout.write(v === undefined ? 'none' : String(v));
"
}

# mk_repo <name> — a git fixture with hooks disabled and deterministic line endings.
mk_repo() {
    local dir="$WORK/$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    git -C "$dir" config commit.gpgsign false
    git -C "$dir" config user.email t@example.invalid
    git -C "$dir" config user.name tester
    printf 'seed\n' > "$dir/seed.txt"
    git -C "$dir" add -A
    git -C "$dir" commit -q -m seed
    nrm "$dir"
}
