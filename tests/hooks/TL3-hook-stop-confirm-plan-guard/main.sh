# shellcheck shell=bash
# TL3 seam body for stop-confirm-plan-guard.js (Stop).
# Sourced by ../TL3-hook-stop-confirm-plan-guard.sh after helpers.sh.

echo ""
echo "=== TL3: stop-confirm-plan-guard.js Stop real invocation (marker consumed) ==="

SCP_SID="e4a4a300-0000-0000-0000-000000000004"
SCP_BASE="$(make_tmp_base)"
trap 'rm -rf "$SCP_BASE"' EXIT

SCP_REPO="$SCP_BASE/repo"
SCP_WORKFLOW_DIR="$SCP_BASE/workflow"
SCP_PLANS_DIR="$SCP_BASE/plans"
mkdir -p "$SCP_REPO/.claude" "$SCP_WORKFLOW_DIR" "$SCP_PLANS_DIR"

git -C "$SCP_REPO" init -q
git -C "$SCP_REPO" config user.email "test@example.com"
git -C "$SCP_REPO" config user.name "Test"

HOOK_JS="$(node_path "$SCRIPT_CHECKOUT_ROOT/hooks/stop-confirm-plan-guard.js")"

# Minimal settings.json: only the Stop hook; no disableBypassPermissionsMode.
cat > "$SCP_REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"$HOOK_JS\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

# Pre-create a per-turn marker in WORKFLOW_STATE_DIR. readAndDeleteTurnMarkers()
# consumes any <sid>.confirm-plan-turn-*.json on Stop.
SCP_MARKER="$SCP_WORKFLOW_DIR/$SCP_SID.confirm-plan-turn-abcd1234.json"
cat > "$SCP_MARKER" <<'MARKER_EOF'
{"absPath":"/tmp/test-plan.md","suffix":"detail","ts":1234567890,"created_at":"2026-07-19T00:00:00.000Z"}
MARKER_EOF

# PRIMARY assert (before): marker exists.
if [ -f "$SCP_MARKER" ]; then
    pass "SCP-E0. turn marker present before Stop"
else
    fail "SCP-E0. turn marker fixture $SCP_MARKER missing before run"
fi

# Prompt emits a plain "DONE"; the marker names a plan file that does not exist, so the
# turn-end plan-link check has nothing to require.
set +e
SCP_OUTPUT=$(
    cd "$SCP_REPO" &&
    unset CLAUDECODE &&
    WORKFLOW_STATE_DIR="$SCP_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$SCP_PLANS_DIR" \
    run_with_timeout 180 claude -p \
        'Output the exact text: DONE' \
        --session-id "$SCP_SID" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format text \
    2>&1
)
SCP_RC=$?
set -e

# PRIMARY assert (after): marker deleted by readAndDeleteTurnMarkers().
if [ ! -f "$SCP_MARKER" ]; then
    pass "SCP-E1. stop-confirm-plan-guard.js consumed (deleted) the turn marker"
else
    fail "SCP-E1. turn marker still present after Stop — hook did not fire. claude rc=$SCP_RC output: $SCP_OUTPUT"
fi

# TL3 gap: a block decision is non-deterministic here — it depends on what the model
# leaves out of its reply. Only marker consumption is exercised deterministically above.

echo ""
echo "=== TL3: plan-link check passes a reply that holds the plan's local path (plan-sync off) ==="
# #2513 plan-link: a turn that wrote a plan artifact must show the plan. With no URL
# (PLAN_SYNC_REMOTE_URL empty, unprovisioned plans dir) the plan's local path in the reply
# is what satisfies the check, and that path is no longer refused — the turn ends normally.
SCP_SID3="e4a4a300-0000-0000-0000-000000000043"
SCP_CFG3="$SCP_BASE/cfg3"
mkdir -p "$SCP_CFG3"
printf 'intent body\n' > "$SCP_PLANS_DIR/$SCP_SID3-intent.md"
SCP_PLAN3="$SCP_PLANS_DIR/$SCP_SID3-intent.md"
SCP_MARKER3="$SCP_WORKFLOW_DIR/$SCP_SID3.confirm-plan-turn-a1b2c3d4.json"
printf '{"absPath":"%s","suffix":"intent","ts":1234567890,"created_at":"2026-07-19T00:00:00.000Z"}\n' \
    "$SCP_PLAN3" > "$SCP_MARKER3"

set +e
SCP_OUTPUT3=$(
    cd "$SCP_REPO" &&
    unset CLAUDECODE &&
    WORKFLOW_STATE_DIR="$SCP_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$SCP_PLANS_DIR" \
    AGENTS_MAIN_ROOT="$SCP_CFG3" \
    PLAN_SYNC_REMOTE_URL="" \
    run_with_timeout 180 claude -p \
        "Output the exact text: DONE $SCP_PLAN3" \
        --session-id "$SCP_SID3" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format text \
    2>&1
)
SCP_RC3=$?
set -e

if [ "$SCP_RC3" -eq 0 ] && printf '%s' "$SCP_OUTPUT3" | grep -q "DONE" && [ ! -f "$SCP_MARKER3" ]; then
    pass "SCP-E3. no URL + local plan path in the reply — turn ended normally, marker consumed"
else
    fail "SCP-E3. local-path pass — rc=$SCP_RC3 marker_left=$([ -f "$SCP_MARKER3" ] && echo yes || echo no) output: $SCP_OUTPUT3"
fi
# The final reply still holds the path: a blocked first Stop would have made the model
# re-issue the reply, and the old refusal told it to drop the path.
if printf '%s' "$SCP_OUTPUT3" | grep -qF "$SCP_SID3-intent.md"; then
    pass "SCP-E3b. the reply shown to the user holds the plan's local path"
else
    fail "SCP-E3b. the plan's local path is missing from the reply — output: $SCP_OUTPUT3"
fi

# TL3 gap (plan-link, block paths): a plan with a URL whose reply omits it, and a plan
# without a URL whose reply omits the local path, both need a model turn that reliably
# omits something, so they are non-deterministic here.
# tests/hooks/feature-plan-url-stop-guard.sh covers them on a synthetic transcript; real
# Stop dispatch of those blocks stays a hook-registration gap (bin/check-verification-gate.sh).

echo ""
echo "=== TL3: plan-link check covers every same-stage plan file a turn wrote ==="
# Two detail markers in one turn (the second file carries another session's id). The guard
# must check each file, not only the first. The reply's text is fixed by the prompt, so the
# first Stop's verdict is deterministic; a recording wrapper around the hook captures it
# (stdin/stdout/stderr/exit pass through unchanged). The block reason names the stage, not
# the file, so a block in SCP-M1 is what proves the second file was checked.
SCP_REPO_M="$SCP_BASE/repo-multi"
SCP_CFG_M="$SCP_BASE/cfg-multi"
SCP_WRAP_M="$(node_path "$SCP_BASE/hook-recorder.js")"
mkdir -p "$SCP_REPO_M/.claude" "$SCP_CFG_M"
git -C "$SCP_REPO_M" init -q
git -C "$SCP_REPO_M" config core.hooksPath /dev/null
cat > "$SCP_BASE/hook-recorder.js" <<'WRAP_EOF'
const fs = require("fs");
const { spawnSync } = require("child_process");
const input = fs.readFileSync(0, "utf8");
// claude -p can fire Stop before the reply's assistant line reaches the transcript; wait
// (max 10s) for assistant text after the last user prompt so the verdict is on the reply.
const hasReply = (tp) => {
  let lines = [];
  try { lines = fs.readFileSync(tp, "utf8").split("\n").filter(Boolean); } catch (_) { return false; }
  for (let i = lines.length - 1; i >= 0; i--) {
    let e; try { e = JSON.parse(lines[i]); } catch (_) { continue; }
    const c = e && e.message && e.message.content;
    if (e.type === "user" && (typeof c === "string" || (Array.isArray(c) && c.some((x) => !x || x.type !== "tool_result")))) return false;
    if (e.type === "assistant" && Array.isArray(c) && c.some((x) => x && x.type === "text")) return true;
  }
  return false;
};
// The reply text the hook judged: every assistant text block after the last user prompt.
const replyText = (tp) => {
  let lines = [];
  try { lines = fs.readFileSync(tp, "utf8").split("\n").filter(Boolean); } catch (_) { return ""; }
  const parts = [];
  for (let i = lines.length - 1; i >= 0; i--) {
    let e; try { e = JSON.parse(lines[i]); } catch (_) { continue; }
    const c = e && e.message && e.message.content;
    if (e.type === "user" && (typeof c === "string" || (Array.isArray(c) && c.some((x) => !x || x.type !== "tool_result")))) break;
    if (e.type === "assistant" && Array.isArray(c)) parts.unshift(c.filter((x) => x && x.type === "text").map((x) => x.text).join("\n"));
  }
  return parts.join("\n");
};
let reply = "";
try {
  const tp = JSON.parse(input).transcript_path;
  for (let n = 0; n < 100 && tp && !hasReply(tp); n++) Atomics.wait(new Int32Array(new SharedArrayBuffer(4)), 0, 0, 100);
  if (tp) reply = replyText(tp);
} catch (_) {}
const r = spawnSync(process.execPath, [process.env.SCP_HOOK_JS], { input, encoding: "utf8" });
let active = null;
try { active = JSON.parse(input).stop_hook_active === true; } catch (_) {}
const status = typeof r.status === "number" ? r.status : -1;
if (process.env.SCP_HOOK_LOG) {
  fs.appendFileSync(process.env.SCP_HOOK_LOG, JSON.stringify({ active, status, stdout: r.stdout || "", reply }) + "\n");
}
process.stdout.write(r.stdout || "");
process.stderr.write(r.stderr || "");
process.exit(status);
WRAP_EOF
cat > "$SCP_REPO_M/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"$SCP_WRAP_M\"",
            "timeout": 20
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

# scp_multi_run <sid> <other-sid> <log> <prompt-shows: first|second|both>
# Writes <sid>-detail.md and <other-sid>-detail.md, drops one detail marker per file, and runs
# claude -p with a prompt whose reply shows the chosen file path(s). Sets SCP_M_P1/SCP_M_P2/SCP_M_RC/SCP_M_OUT.
scp_multi_run() {
    local sid="${1:?sid}" other="${2:?other sid}" log="${3:?log}" shows="${4:?shows}" text
    SCP_M_P1="$SCP_PLANS_DIR/$sid-detail.md"
    SCP_M_P2="$SCP_PLANS_DIR/$other-detail.md"
    printf 'detail body one\n' > "$SCP_M_P1"
    printf 'detail body two\n' > "$SCP_M_P2"
    printf '{"absPath":"%s","suffix":"detail","ts":1234567890,"created_at":"2026-07-19T00:00:00.000Z"}\n' \
        "$SCP_M_P1" > "$SCP_WORKFLOW_DIR/$sid.confirm-plan-turn-0a0a0a01.json"
    printf '{"absPath":"%s","suffix":"detail","ts":1234567890,"created_at":"2026-07-19T00:00:00.000Z"}\n' \
        "$SCP_M_P2" > "$SCP_WORKFLOW_DIR/$sid.confirm-plan-turn-0a0a0a02.json"
    case "$shows" in
        first) text="DONE $SCP_M_P1" ;;
        second) text="DONE $SCP_M_P2" ;;
        *) text="DONE $SCP_M_P1 $SCP_M_P2" ;;
    esac
    rm -f "$log"
    set +e
    SCP_M_OUT=$(
        cd "$SCP_REPO_M" &&
        unset CLAUDECODE CLAUDE_CODE_SESSION_ID &&
        WORKFLOW_STATE_DIR="$SCP_WORKFLOW_DIR" \
        WORKFLOW_PLANS_DIR="$SCP_PLANS_DIR" \
        AGENTS_MAIN_ROOT="$SCP_CFG_M" \
        PLAN_SYNC_REMOTE_URL="" \
        SCP_HOOK_JS="$HOOK_JS" \
        SCP_HOOK_LOG="$(node_path "$log")" \
        run_with_timeout 180 claude -p \
            "Output the exact text: $text" \
            --session-id "$sid" \
            --setting-sources project \
            --dangerously-skip-permissions \
            --output-format text \
        2>&1
    )
    SCP_M_RC=$?
    set -e
}

# scp_log_field <log> <line-index> <field> -> the field of that recorded hook call ("" when absent).
scp_log_field() {
    node -e '
const [f, i, k] = process.argv.slice(1);
let v = "";
try {
  const rows = require("fs").readFileSync(f, "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l));
  const r = rows[Number(i)];
  if (k === "count") v = String(rows.length);
  else if (r && k === "reason") { try { const o = JSON.parse(r.stdout || "{}"); v = o.decision === "block" ? String(o.reason || "") : ""; } catch (_) {} }
  else if (r) v = String(r[k]);
} catch (_) {}
process.stdout.write(v);
' "$(node_path "$1")" "$2" "$3"
}

# scp_assert_first_block <label> <log> — first Stop (stop_hook_active false) blocked on the plan-link check.
scp_assert_first_block() {
    local label="$1" log="$2" st act reason
    st="$(scp_log_field "$log" 0 status)"
    act="$(scp_log_field "$log" 0 active)"
    reason="$(scp_log_field "$log" 0 reason)"
    if [[ "$act" == "false" && "$st" == "2" && "$reason" == *"[confirm-plan] plan-link:"* && "$reason" == *"detail plan"* ]]; then
        pass "$label"
    else
        fail "$label — active=$act status=$st reason=$reason claude rc=$SCP_M_RC output: $SCP_M_OUT"
    fi
}

# scp_assert_second_pass <label> <log> — the re-entered Stop (stop_hook_active true) passes silently.
scp_assert_second_pass() {
    local label="$1" log="$2" st act out
    st="$(scp_log_field "$log" 1 status)"
    act="$(scp_log_field "$log" 1 active)"
    out="$(scp_log_field "$log" 1 stdout)"
    if [[ "$act" == "true" && "$st" == "0" && -z "$out" ]]; then
        pass "$label"
    else
        fail "$label — active=$act status=$st stdout=$out"
    fi
}

# scp_assert_reply <label> <log> <first: yes|no> <second: yes|no> — PRECONDITION on the reply the
# first Stop judged: which plan file names it holds. A failure here is the model not following
# the prompt, not a guard defect.
scp_assert_reply() {
    local label="$1" log="$2" want1="$3" want2="$4" reply has1=no has2=no
    reply="$(scp_log_field "$log" 0 reply)"
    [[ "$reply" == *"$(basename "$SCP_M_P1")"* ]] && has1=yes
    [[ "$reply" == *"$(basename "$SCP_M_P2")"* ]] && has2=yes
    if [[ "$has1" == "$want1" && "$has2" == "$want2" ]]; then
        pass "$label"
    else
        fail "$label — PRECONDITION (model reply, not guard): first=$has1 (want $want1) second=$has2 (want $want2) reply: $reply"
    fi
}

# SCP-M1: reply shows only the first file — the second file's missing link must block.
# A guard that checked only the first marker path would pass this turn.
SCP_LOG_M1="$SCP_BASE/hook-m1.jsonl"
scp_multi_run "e4a4a300-0000-0000-0000-000000000051" "e4a4a300-0000-0000-0000-0000000000a1" "$SCP_LOG_M1" first
scp_assert_reply "SCP-M1p. precondition: the judged reply holds the first path, not the second" "$SCP_LOG_M1" yes no
scp_assert_first_block "SCP-M1. two detail plans, reply shows only the first — Stop blocks on the second" "$SCP_LOG_M1"
scp_assert_second_pass "SCP-M1d. stop_hook_active=true re-entry passes the same turn" "$SCP_LOG_M1"

# SCP-M2: reply shows only the second file (another session's id) — the first file must block.
SCP_LOG_M2="$SCP_BASE/hook-m2.jsonl"
scp_multi_run "e4a4a300-0000-0000-0000-000000000052" "e4a4a300-0000-0000-0000-0000000000a2" "$SCP_LOG_M2" second
scp_assert_reply "SCP-M2p. precondition: the judged reply holds the second path, not the first" "$SCP_LOG_M2" no yes
scp_assert_first_block "SCP-M2. two detail plans, reply shows only the second — Stop blocks on the first" "$SCP_LOG_M2"
scp_assert_second_pass "SCP-M2d. stop_hook_active=true re-entry passes the same turn" "$SCP_LOG_M2"

# SCP-M3: reply shows both files — the turn ends normally with one silent Stop.
SCP_LOG_M3="$SCP_BASE/hook-m3.jsonl"
scp_multi_run "e4a4a300-0000-0000-0000-000000000053" "e4a4a300-0000-0000-0000-0000000000a3" "$SCP_LOG_M3" both
scp_assert_reply "SCP-M3p. precondition: the judged reply holds both paths" "$SCP_LOG_M3" yes yes
SCP_M3_ST="$(scp_log_field "$SCP_LOG_M3" 0 status)"
SCP_M3_OUT="$(scp_log_field "$SCP_LOG_M3" 0 stdout)"
SCP_M3_N="$(scp_log_field "$SCP_LOG_M3" 0 count)"
if [[ "$SCP_M_RC" -eq 0 && "$SCP_M3_ST" == "0" && -z "$SCP_M3_OUT" && "$SCP_M3_N" == "1" ]]; then
    pass "SCP-M3. two detail plans, reply shows both — Stop allows, no re-entry"
else
    fail "SCP-M3. both shown — rc=$SCP_M_RC status=$SCP_M3_ST stdout=$SCP_M3_OUT stop_calls=$SCP_M3_N output: $SCP_M_OUT"
fi
