# shellcheck shell=bash
# #2650 SCP-C1: the same-turn CONFIRM continuation end to end on a live claude -p session.
# Sourced by ../TL3-hook-stop-confirm-plan-guard.sh after main.sh (reuses its sandbox, recorder and helpers).
#   WORKFLOW_STATE_DIR / WORKFLOW_PLANS_DIR are pinned on every claude -p / node call, as in main.sh.
# TL3 gap: the echo depends on the model following the continuation reason; SCP-C1p* lines are model preconditions.

echo ""
echo "=== TL3: #2650 same-turn continuation — Stop block, echo, checkpoint pass, approval sha ==="
# A session at outline (intent approved, plan on disk, a turn marker). The reply ends on the
# plan-link line; the first Stop blocks with the continuation reason, the model echoes
# CONFIRM_OUTLINE in the same turn, confirm-checkpoint passes it, workflow-mark records the
# approval, and the recorded sha equals the presented plan's sha.
SCP_REPO_C="$SCP_BASE/repo-cont"
SCP_CFG_C="$SCP_BASE/cfg-cont"
SCP_LOG_C="$SCP_BASE/hook-c1-stop.jsonl"
SCP_LOG_CP="$SCP_BASE/hook-c1-pre.jsonl"
mkdir -p "$SCP_REPO_C/.claude" "$SCP_CFG_C"
git -C "$SCP_REPO_C" init -q
git -C "$SCP_REPO_C" config core.hooksPath /dev/null
# #2726/#2729: plan-stage gates are read from $AGENTS_MAIN_ROOT/.env only — pin them in SCP_CFG_C/.env.
# shellcheck source=../../lib/confirm-env-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/confirm-env-fixture.sh"
confirm_env_set "$SCP_CFG_C" CONFIRM_INTENT=on CONFIRM_OUTLINE=on CONFIRM_DETAIL=on

# Generic PreToolUse recorder: node pre-recorder.js <hook.js> <log> — passes I/O through unchanged.
cat > "$SCP_BASE/pre-recorder.js" <<'PRE_EOF'
const fs = require("fs");
const { spawnSync } = require("child_process");
const [hook, log] = process.argv.slice(2);
const input = fs.readFileSync(0, "utf8");
const r = spawnSync(process.execPath, [hook], { input, encoding: "utf8" });
let command = "";
try { command = String((JSON.parse(input).tool_input || {}).command || ""); } catch (_) {}
fs.appendFileSync(log, JSON.stringify({ command, status: r.status, stdout: r.stdout || "" }) + "\n");
process.stdout.write(r.stdout || "");
process.stderr.write(r.stderr || "");
process.exit(typeof r.status === "number" ? r.status : 1);
PRE_EOF

SCP_PRE_JS="$(node_path "$SCP_BASE/pre-recorder.js")"
SCP_CC_JS="$(node_path "$SCRIPT_CHECKOUT_ROOT/hooks/confirm-checkpoint.js")"
SCP_WM_JS="$(node_path "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-mark.js")"
SCP_WRAP_C="$(node_path "$SCP_BASE/hook-recorder.js")"
cat > "$SCP_REPO_C/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "Stop": [ { "hooks": [ { "type": "command", "command": "node \"$SCP_WRAP_C\"", "timeout": 30 } ] } ],
    "PreToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "node \"$SCP_PRE_JS\" \"$SCP_CC_JS\" \"$(node_path "$SCP_LOG_CP")\"", "timeout": 20 } ] } ],
    "PostToolUse": [ { "matcher": "Bash", "hooks": [ { "type": "command", "command": "node \"$SCP_WM_JS\"", "timeout": 20 } ] } ]
  }
}
SETTINGS_EOF

# scp_c_node <script> [args...] — node with the sandbox pins (state, plans, config root, gates on).
scp_c_node() {
    WORKFLOW_STATE_DIR="$SCP_WORKFLOW_DIR" WORKFLOW_PLANS_DIR="$SCP_PLANS_DIR" AGENTS_MAIN_ROOT="$SCP_CFG_C" \
    PLAN_SYNC_REMOTE_URL="" PLAN_LANG=english \
    env -u CONFIRM_INTENT -u CONFIRM_OUTLINE -u CONFIRM_DETAIL node -e "$1" "$(node_path "$SCRIPT_CHECKOUT_ROOT")" "${@:2}"
}

# A session at outline through the #2650 fixture: prints "<sid>\t<plan-link line>\t<sha>".
SCP_C_SETUP="$(scp_c_node '
const root = process.argv[1];
const X = require(root + "/tests/hooks/feature-2650-confirm-continuation/fixture");
const { computeArtifactSha } = require(root + "/hooks/workflow-state/completion-approval");
const s = X.sessionAt("outline");
X.turnMarker(s.sid, "outline", s.plan);
process.stdout.write([s.sid, s.line, computeArtifactSha(s.sid, "outline") || ""].join("\t"));
' 2>&1)"
IFS=$'\t' read -r SCP_C_SID SCP_C_LINE SCP_C_SHA <<< "$SCP_C_SETUP"

if [[ -z "${SCP_C_SID:-}" || -z "${SCP_C_LINE:-}" || -z "${SCP_C_SHA:-}" ]]; then
    fail "SCP-C1s. fixture setup — $SCP_C_SETUP"
else
    rm -f "$SCP_LOG_C" "$SCP_LOG_CP"
    set +e
    SCP_C_OUT=$(
        cd "$SCP_REPO_C" &&
        unset CLAUDECODE CLAUDE_CODE_SESSION_ID CONFIRM_INTENT CONFIRM_OUTLINE CONFIRM_DETAIL &&
        WORKFLOW_STATE_DIR="$SCP_WORKFLOW_DIR" \
        WORKFLOW_PLANS_DIR="$SCP_PLANS_DIR" \
        AGENTS_MAIN_ROOT="$SCP_CFG_C" \
        PLAN_SYNC_REMOTE_URL="" PLAN_LANG=english \
        SCP_HOOK_JS="$HOOK_JS" \
        SCP_HOOK_LOG="$(node_path "$SCP_LOG_C")" \
        run_with_timeout 300 claude -p \
            "Reply with exactly this one line and nothing else: $SCP_C_LINE" \
            --session-id "$SCP_C_SID" \
            --setting-sources project \
            --dangerously-skip-permissions \
            --output-format text \
        2>&1
    )
    SCP_C_RC=$?
    set -e

    # Precondition: the reply the first Stop judged ends on the plan-link line.
    SCP_C_REPLY="$(scp_log_field "$SCP_LOG_C" 0 reply)"
    if [[ "$SCP_C_REPLY" == *"$SCP_C_LINE"* ]]; then
        pass "SCP-C1p. precondition: the judged reply holds the outline plan-link line"
    else
        fail "SCP-C1p. PRECONDITION (model reply): plan-link line missing — reply: $SCP_C_REPLY"
    fi

    # 1st Stop: continuation block.
    SCP_C_ST="$(scp_log_field "$SCP_LOG_C" 0 status)"
    SCP_C_ACT="$(scp_log_field "$SCP_LOG_C" 0 active)"
    SCP_C_REASON="$(scp_log_field "$SCP_LOG_C" 0 reason)"
    if [[ "$SCP_C_ACT" == "false" && "$SCP_C_ST" == "2" && "$SCP_C_REASON" == *"[confirm-plan] continue:"* ]]; then
        pass "SCP-C1a. the presentation turn's first Stop blocks with the continuation reason"
    else
        fail "SCP-C1a. continuation block — active=$SCP_C_ACT status=$SCP_C_ST reason=$SCP_C_REASON claude rc=$SCP_C_RC output: $SCP_C_OUT"
    fi

    # confirm-checkpoint on the echo: no deny, the dialog fact line (#2731: "[outline] ...", no "Click Allow").
    SCP_C_CP="$(node -e '
const rows = (() => { try { return require("fs").readFileSync(process.argv[1], "utf8").split("\n").filter(Boolean).map((l) => JSON.parse(l)); } catch (_) { return []; } })();
const r = rows.find((x) => /WORKFLOW_CONFIRM_OUTLINE/.test(x.command));
if (!r) { process.stdout.write("no-echo"); process.exit(0); }
let o = {}; try { o = JSON.parse(r.stdout || "{}"); } catch (_) {}
const deny = ((o.hookSpecificOutput || {}).permissionDecision) === "deny";
process.stdout.write(!deny && /^\[outline\] /.test(String(o.systemMessage || "")) ? "pass" : "other:" + r.stdout);
' "$(node_path "$SCP_LOG_CP")")"
    if [[ "$SCP_C_CP" == "no-echo" ]]; then
        fail "SCP-C1p2. PRECONDITION (model behaviour): no CONFIRM_OUTLINE echo reached PreToolUse — output: $SCP_C_OUT"
    elif [[ "$SCP_C_CP" == "pass" ]]; then
        pass "SCP-C1b. confirm-checkpoint passes the same-turn echo to the dialog"
    else
        fail "SCP-C1b. confirm-checkpoint on the same-turn echo — $SCP_C_CP"
    fi

    # The recorded approval is bound to the sha of the plan that was presented.
    SCP_C_REC="$(scp_c_node '
const root = process.argv[1];
const st = require(root + "/hooks/workflow-state").readState(process.argv[2]) || {};
const rec = (st.plan_approvals || {}).outline || {};
process.stdout.write(String(rec.source || "") + "|" + String(rec.artifact_sha256 || ""));
' "$SCP_C_SID" 2>&1)"
    if [[ "$SCP_C_REC" == "confirm-sentinel|$SCP_C_SHA" ]]; then
        pass "SCP-C1c. the outline approval is recorded with the presented plan's sha"
    else
        fail "SCP-C1c. approval record — got '$SCP_C_REC', want 'confirm-sentinel|$SCP_C_SHA'"
    fi

    # The re-entered Stop (stop_hook_active true) ends the turn silently.
    scp_assert_second_pass "SCP-C1d. stop_hook_active=true re-entry after the echo passes" "$SCP_LOG_C"
fi
