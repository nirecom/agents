# shellcheck shell=bash
# TL3 seam body for session-start.js (SessionStart).
# Sourced by ../TL3-hook-session-start.sh after helpers.sh.
# Tests: hooks/session-start.js
# Tags: TL3, hook, session-start, scope:common

echo ""
echo "=== TL3: session-start.js SessionStart real invocation ==="

SS_SID="e2292100-0000-0000-0000-000000000002"
SS_BASE="$(make_tmp_base)"
trap 'rm -rf "$SS_BASE"' EXIT

SS_REPO="$SS_BASE/repo"
SS_WORKFLOW_DIR="$SS_BASE/workflow"
SS_PLANS_DIR="$SS_BASE/plans"
mkdir -p "$SS_REPO/.claude" "$SS_WORKFLOW_DIR" "$SS_PLANS_DIR"

git -C "$SS_REPO" init -q
git -C "$SS_REPO" config user.email "test@example.com"
git -C "$SS_REPO" config user.name "Test"

HOOK_JS="$(node_path "$AGENTS_DIR/hooks/session-start.js")"

# Minimal settings.json: only the SessionStart hook; no disableBypassPermissionsMode.
cat > "$SS_REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "SessionStart": [
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

SS_STATE_FILE="$SS_WORKFLOW_DIR/$SS_SID.json"

# --- #1305 fixture: an abandoned prior session in exactly the same cwd+branch.
# This is the situation the bug was about: a genuinely NEW session (source=
# "startup", no lineage to anything) silently picking up whatever session last
# ran in this directory. Only a real launch produces a real `source`, so this is
# the one place the gate can be observed end-to-end.
SS_DONOR="e2292100-0000-0000-0000-0000000000d0"
SS_TBASE="$SS_BASE/transcripts"
SS_ENC="$(cd "$SS_REPO" && node -e 'console.log(require("path").resolve(process.cwd()).toLowerCase().replace(/[^a-zA-Z0-9]/g,"-"))')"
mkdir -p "$SS_TBASE/$SS_ENC"
node -e '
  const fs = require("fs"), path = require("path");
  const [dir, sid, cwd, branch, now] = process.argv.slice(1);
  const steps = {};
  for (const s of ["workflow_init", "research", "outline", "detail"]) {
    steps[s] = { status: "complete", updated_at: now };
  }
  fs.writeFileSync(path.join(dir, sid + ".json"), JSON.stringify({
    version: 1, session_id: sid, cwd, git_branch: branch, created_at: now, steps,
  }, null, 2));
' "$(node_path "$SS_WORKFLOW_DIR")" "$SS_DONOR" \
  "$(cd "$SS_REPO" && node -e 'console.log(require("path").resolve(process.cwd()))')" \
  "$(git -C "$SS_REPO" rev-parse --abbrev-ref HEAD)" \
  "$(node -e 'console.log(new Date().toISOString())')"
printf '{"type":"attachment","attachment":{"hookEvent":"SessionStart","exitCode":0,"stdout":"Current workflow session_id: %s"}}\n' \
    "$SS_DONOR" > "$SS_TBASE/$SS_ENC/$SS_DONOR.jsonl"

# CRITICAL: do NOT pre-create the state file — session-start.js only runs
# createInitialState when no existing state is found for the session.
SS_OUTPUT=$(
    cd "$SS_REPO" &&
    unset CLAUDECODE &&
    CLAUDE_WORKFLOW_DIR="$SS_WORKFLOW_DIR" \
    WORKFLOW_PLANS_DIR="$SS_PLANS_DIR" \
    CLAUDE_TRANSCRIPT_BASE_DIR="$(node_path "$SS_TBASE")" \
    run_with_timeout 180 claude -p \
        'Output the exact text: SESSION_START_CONFIRMED' \
        --session-id "$SS_SID" \
        --setting-sources project \
        --dangerously-skip-permissions \
        --output-format json \
    2>&1
)
SS_RC=$?

# PRIMARY assert: state file created with all steps pending (initial shape proves createInitialState ran).
if [ -f "$SS_STATE_FILE" ]; then
    SS_ALL_PENDING=$(node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const steps=s.steps||{};
const keys=Object.keys(steps);
const allPending = keys.length>0 && keys.every(k => steps[k] && steps[k].status==='pending');
process.stdout.write(allPending ? 'yes' : 'no');
" -- "$(node_path "$SS_STATE_FILE")" 2>/dev/null)
    if [ "$SS_ALL_PENDING" = "yes" ]; then
        pass "SS-E1. session-start.js created initial state with all steps pending"
    else
        fail "SS-E1. state file present but not all steps pending (got \"$SS_ALL_PENDING\"). claude rc=$SS_RC"
    fi
else
    fail "SS-E1. state file $SS_STATE_FILE not created. claude rc=$SS_RC output: $SS_OUTPUT"
fi

# SS-E3 (#1305): a real `source=startup` must NOT adopt the prior session's
# steps, even though that session shares this exact cwd and branch. The fixture
# is only meaningful if the donor was actually there to be found, so its
# presence is asserted first rather than assumed.
if [ ! -f "$SS_WORKFLOW_DIR/$SS_DONOR.json" ] || [ ! -f "$SS_TBASE/$SS_ENC/$SS_DONOR.jsonl" ]; then
    fail "SS-E3. fixture broken: the prior-session donor was never seeded (nothing could have been inherited)"
elif [ ! -f "$SS_STATE_FILE" ]; then
    fail "SS-E3. no state file for the new session; the startup gate is unproven. claude rc=$SS_RC"
else
    SS_INHERITED=$(node -e "
const s=JSON.parse(require('fs').readFileSync(process.argv[1],'utf8'));
const evs=Array.isArray(s.events)?s.events:[];
const inh=evs.filter(e=>e.origin==='session-inherit'||e.inherited_from);
const nonPending=Object.entries(s.steps||{}).filter(([,v])=>v&&v.status!=='pending').map(([k])=>k);
process.stdout.write(inh.length===0&&nonPending.length===0?'clean':'inherited:'+nonPending.join(','));
" -- "$(node_path "$SS_STATE_FILE")" 2>/dev/null)
    if [ "$SS_INHERITED" = "clean" ]; then
        pass "SS-E3. a real source=startup does not adopt the same-cwd prior session's state"
    else
        fail "SS-E3. startup session inherited from the abandoned prior session ($SS_INHERITED). claude rc=$SS_RC"
    fi
fi

# NOTE: the former SS-E2 case asserted that `claude -p --output-format json`
# output contains "Current workflow session_id: <sid>". That field is the hook's
# own additionalContext and never appears in that output shape, so the assertion
# was permanently red at the wrong seam (#1619/#1648). It was removed; the
# contract is now covered at TL2 as case C6 in
# tests/feature-772-session-start-cleanup-inherit.sh, which invokes
# hooks/session-start.js directly and asserts on its stdout.

# TL3 gap: CONV_LANG/settings-drift injection branches depend on host env config
# and are not asserted here; covered at L2 in feature-772-session-start-cleanup-inherit.sh.
