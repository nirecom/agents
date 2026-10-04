#!/bin/bash
# tests/hooks/feature-2326-hook-mechanism.sh
# Tests: hooks/rtk-rewrite.js
# Tags: rtk, hook, pretooluse, scope:issue-specific
#
# T-M gate: end-to-end mechanism check for the rtk-rewrite PreToolUse hook.
# The hook delegates to `rtk hook claude` via spawnSync, feeding the PreToolUse
# payload on stdin and passing through the RTK's hookSpecificOutput. This test
# injects a fake rtk (via RTK_BIN) that speaks that delegation protocol: on
# `hook claude` it reads the payload from stdin and returns an allow decision
# whose updatedInput command is the original command prefixed with the rtk path.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
HOOK="$AGENTS_DIR/hooks/rtk-rewrite.js"
# AGENTS_CONFIG_DIR is needed by isAgentsEmit() in rtk-rewrite.js; pin it for
# test isolation so INJ-INACTIVE-AGENTS cases are not environment-dependent.
export AGENTS_CONFIG_DIR="$AGENTS_DIR"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Fixture isolation: never resolve the developer's live session/state.
unset CLAUDE_CODE_SESSION_ID

TMPDIR_T="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_T"' EXIT
# Node-visible form of the temp root (cygpath -m on Windows, identity elsewhere).
if command -v cygpath >/dev/null 2>&1; then WF_ROOT="$(cygpath -m "$TMPDIR_T")"; else WF_ROOT="$TMPDIR_T"; fi
# Dual-pin the workflow state + plans dirs (rules/test/fixture-isolation.md).
export CLAUDE_WORKFLOW_DIR="$WF_ROOT/workflow-state"
export WORKFLOW_PLANS_DIR="$WF_ROOT/plans"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WF_ROOT/transcripts"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR" "$CLAUDE_TRANSCRIPT_BASE_DIR"

# Fake rtk speaking the `hook claude` delegation protocol. The hook spawns the
# rtk binary with fixed args `["hook","claude"]` via spawnSync (no shell), so the
# fake must be a real executable node can launch on every platform — a shebang
# script or a .cmd is unspawnable by Windows node. We therefore use the node
# binary itself as RTK_BIN and let its first arg, "hook", be the program: node
# resolves argv[1]="hook" against the child's cwd, so a file literally named
# `hook` placed there runs as the delegate. It reads the PreToolUse payload from
# stdin (arg "claude" confirms the subcommand) and emits a hookSpecificOutput
# whose updatedInput.command is its own path ($argv[1]) + ' ' + tool_input.command.
NODE_BIN="$(node -e 'process.stdout.write(process.execPath)')"
FAKE_DIR="$TMPDIR_T"
cat > "$FAKE_DIR/hook" << 'SCRIPT_END'
const fs = require("fs");
if (process.argv[2] === "claude") {
  let s = "";
  try { s = fs.readFileSync(0, "utf8"); } catch (_e) {}
  const d = JSON.parse(s);
  process.stdout.write(JSON.stringify({
    hookSpecificOutput: {
      permissionDecision: "allow",
      updatedInput: { command: process.argv[1] + " " + d.tool_input.command },
    },
  }));
}
process.exit(0);
SCRIPT_END

PAYLOAD='{"tool_name":"Bash","tool_input":{"command":"git status"}}'

# cd into FAKE_DIR (in a subshell, leaving the test's own cwd untouched) so the
# hook's child resolves "hook" to our delegate; run-with-timeout does not alter cwd.
OUT="$(cd "$FAKE_DIR"; printf '%s' "$PAYLOAD" | RTK=on RTK_BIN="$NODE_BIN" \
    "$AGENTS_DIR/bin/run-with-timeout.sh" 180 node "$HOOK" 2>/dev/null)"

echo "hook output: $OUT"

DECISION="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);process.stdout.write((o.hookSpecificOutput&&o.hookSpecificOutput.permissionDecision)||"");}catch(e){}})')"
COMMAND="$(printf '%s' "$OUT" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{const o=JSON.parse(s);process.stdout.write((o.hookSpecificOutput&&o.hookSpecificOutput.updatedInput&&o.hookSpecificOutput.updatedInput.command)||"");}catch(e){}})')"

if [ "$DECISION" = "allow" ]; then
    pass "permissionDecision is allow"
else
    fail "permissionDecision expected allow, got '$DECISION'"
fi

case "$COMMAND" in
    *" git status")
        pass "updatedInput.command ends with ' git status' (got '$COMMAND')" ;;
    *)
        fail "updatedInput.command expected to end with ' git status', got '$COMMAND'" ;;
esac

# --- #2447: native-isolation pre-guard -----------------------------------------
# Under EnterWorktree (worktree_entered_at set, worktree_exited_at null) the
# rewritten `rtk git ...` is refused by the native isolation layer, so the hook
# must passthrough ({}) BEFORE delegating — rtk must not even be spawned.
SID_ACTIVE="test-2447-active"
SID_EXITED="test-2447-exited"
SID_NULL="test-2447-entered-null"
SID_NOSTATE="test-2447-nostate"
# mk_state <sid> <json-extra> — v1-shaped state (readState migrates it in memory).
mk_state() {
    node -e '
const fs=require("fs"),path=require("path");
const [dir,sid,extra]=process.argv.slice(1);
const st=()=>({status:"complete",updated_at:null});
const state={version:1,session_id:sid,created_at:"2026-09-29T00:00:00.000Z",
  steps:{workflow_init:st(),clarify_intent:st(),branching_complete:st()}};
Object.assign(state,JSON.parse(extra));
fs.writeFileSync(path.join(dir,sid+".json"),JSON.stringify(state,null,2));
' "$CLAUDE_WORKFLOW_DIR" "$1" "$2"
}
mk_state "$SID_ACTIVE" '{"worktree_entered_at":"2026-09-29T00:00:00.000Z"}'
mk_state "$SID_EXITED" '{"worktree_entered_at":"2026-09-29T00:00:00.000Z","worktree_exited_at":"2026-09-29T01:00:00.000Z"}'
mk_state "$SID_NULL" '{"worktree_entered_at":null,"worktree_exited_at":null}'

# run_sid <sid> <command> → raw hook stdout (real process, real state file).
run_sid() {
    local payload
    payload="$(node -e 'process.stdout.write(JSON.stringify({session_id:process.argv[1],tool_name:"Bash",tool_input:{command:process.argv[2]}}))' "$1" "$2")"
    (cd "$FAKE_DIR" || exit 1; printf '%s' "$payload" | RTK=on RTK_BIN="$NODE_BIN" \
        "$AGENTS_DIR/bin/run-with-timeout.sh" 180 node "$HOOK" 2>/dev/null | tr -d '\r\n')
}
# kind <raw> → passthrough | wrap | other:<raw>
kind() {
    case "$1" in
        '{}') printf 'passthrough' ;;
        *'"permissionDecision":"allow"'*) printf 'wrap' ;;
        *) printf 'other:%s' "$1" ;;
    esac
}
expect_kind() { # expect_kind <want> <label> <actual>
    if [ "$3" = "$1" ]; then pass "$2"; else fail "$2 (want=$1 got=$3)"; fi
}

for c in "git status" "git diff" "git -C /linked/wt diff"; do
    expect_kind passthrough "#2447 NI-ACTIVE: entered, not exited: '$c' → passthrough {}" \
        "$(kind "$(run_sid "$SID_ACTIVE" "$c")")"
done
expect_kind wrap "#2447 NI-EXITED: entered + exited: git status → wrap (guard off)" \
    "$(kind "$(run_sid "$SID_EXITED" "git status")")"
expect_kind wrap "#2447 NI-NULL: entered_at null: git status → wrap (guard off)" \
    "$(kind "$(run_sid "$SID_NULL" "git status")")"
expect_kind wrap "#2447 NI-NOSTATE: no state file: git status → wrap (guard off)" \
    "$(kind "$(run_sid "$SID_NOSTATE" "git status")")"

# inject <mode> <sid-or-empty> — decide() with an injected opts.readStateFn and a
# counting spawnFn; prints "<passthrough|wrap> spawns=<n> reads=<sid,...>".
inject() {
    node -e '
const { decide } = require(process.argv[1]);
const [, , mode, sid] = process.argv;
const ACTIVE = { worktree_entered_at: "2026-09-29T00:00:00.000Z", worktree_exited_at: null };
const reads = []; let spawns = 0;
const table = {
  active: (s) => { reads.push(s); return ACTIVE; },
  throws: (s) => { reads.push(s); throw new Error("state io boom"); },
  nullState: (s) => { reads.push(s); return null; },
};
const spawnFn = (_bin, _args, o) => {
  spawns++;
  const d = JSON.parse(o.input);
  return { status: 0, stdout: JSON.stringify({ hookSpecificOutput: {
    permissionDecision: "allow", updatedInput: { command: "rtk " + d.tool_input.command } } }) };
};
const input = { tool_name: "Bash", tool_input: { command: "git status" } };
if (sid) input.session_id = sid;
const out = decide(input, { rtkOn: true, rtkBin: "rtk", auditOn: false, spawnFn, readStateFn: table[mode] });
const k = out && out.hookSpecificOutput ? "wrap" : (JSON.stringify(out) === "{}" ? "passthrough" : "other");
process.stdout.write(k + " spawns=" + spawns + " reads=" + reads.join(","));
' "$HOOK" "$1" "$2" 2>&1 | tr -d '\r\n'
}
expect_kind "passthrough spawns=0 reads=sid-x" "#2447 INJ-ACTIVE: injected readStateFn active → passthrough, no rtk spawn, sid passed" \
    "$(inject active sid-x)"
expect_kind "wrap spawns=1 reads=sid-x" "#2447 INJ-THROWS: readStateFn throws → fail-open to normal wrap" \
    "$(inject throws sid-x)"
expect_kind "wrap spawns=1 reads=sid-x" "#2447 INJ-NULL: readStateFn returns null → normal wrap" \
    "$(inject nullState sid-x)"
expect_kind "wrap spawns=1 reads=" "#2447 INJ-NOSID: no session_id → guard off, readStateFn not consulted, wrap" \
    "$(inject active "")"

# inject_cmd <mode> <sid-or-empty> <command> — like inject() but with a caller-supplied
# command; used to verify that each firstRejectingGuard verdict still fires when native
# isolation is inactive (nullState → worktree_entered_at absent → pre-guard skipped).
inject_cmd() {
    node -e '
const { decide } = require(process.argv[1]);
const [, , mode, sid, cmd] = process.argv;
const ACTIVE = { worktree_entered_at: "2026-09-29T00:00:00.000Z", worktree_exited_at: null };
const reads = []; let spawns = 0;
const table = {
  active: (s) => { reads.push(s); return ACTIVE; },
  throws: (s) => { reads.push(s); throw new Error("state io boom"); },
  nullState: (s) => { reads.push(s); return null; },
};
const spawnFn = (_bin, _args, o) => {
  spawns++;
  const d = JSON.parse(o.input);
  return { status: 0, stdout: JSON.stringify({ hookSpecificOutput: {
    permissionDecision: "allow", updatedInput: { command: "rtk " + d.tool_input.command } } }) };
};
const input = { tool_name: "Bash", tool_input: { command: cmd } };
if (sid) input.session_id = sid;
const out = decide(input, { rtkOn: true, rtkBin: "rtk", auditOn: false, spawnFn, readStateFn: table[mode] });
const k = out && out.hookSpecificOutput ? "wrap" : (JSON.stringify(out) === "{}" ? "passthrough" : "other");
process.stdout.write(k + " spawns=" + spawns + " reads=" + reads.join(","));
' "$HOOK" "$1" "$2" "$3" 2>&1 | tr -d '\r\n'
}

# #2447: when native isolation is INACTIVE (nullState → null state → pre-guard skips),
# each firstRejectingGuard verdict must still fire and return passthrough — the pre-guard
# must not inadvertently suppress the guards when isolation is off.
expect_kind "passthrough spawns=0 reads=sid-y" "#2447 INJ-INACTIVE-AGENTS: nullState+agentsEmit → passthrough (guards still active)" \
    "$(inject_cmd nullState sid-y "$AGENTS_CONFIG_DIR/bin/foo")"
expect_kind "passthrough spawns=0 reads=sid-y" "#2447 INJ-INACTIVE-BUILTIN: nullState+shellBuiltin (echo) → passthrough (guards still active)" \
    "$(inject_cmd nullState sid-y 'echo hello')"
expect_kind "passthrough spawns=0 reads=sid-y" "#2447 INJ-INACTIVE-COMPOSITE: nullState+composite (&&) → passthrough (guards still active)" \
    "$(inject_cmd nullState sid-y 'git status && git diff')"
expect_kind "passthrough spawns=0 reads=sid-y" "#2447 INJ-INACTIVE-MACHINE: nullState+machineReadable (rev-parse) → passthrough (guards still active)" \
    "$(inject_cmd nullState sid-y 'git rev-parse HEAD')"
expect_kind "passthrough spawns=0 reads=sid-y" "#2447 INJ-INACTIVE-RTKSELF: nullState+rtkSelf (rtk) → passthrough (guards still active)" \
    "$(inject_cmd nullState sid-y 'rtk hook claude')"

echo "----"
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
