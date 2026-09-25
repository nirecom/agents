# tests/TL3-hook-record-off-skill-invocation/fixture-hooks.sh
# The fixture's HOOK SURFACE: the UserPromptSubmit capture wrapper, the PreToolUse
# Bash guard, the minimal project settings.json that registers them alongside the
# real consumer, and the environment the live `claude -p` turns run under.
# Sourced by ../TL3-hook-record-off-skill-invocation.sh; relies on that file's
# BASE/REPO/WFDIR/PLANSDIR/MOCKBIN/HOOK/AGENTS_DIR and node_path().

# A marker alone cannot say WHAT the hook was handed, so it cannot separate "the
# runtime delivered the typed command" from "something else happened to match".
# The wrapper records the VERBATIM stdin, then forwards it to the real hook
# unchanged (stdout and exit code passed through).
CAPTURE="$BASE/userpromptsubmit-capture.txt"
CAPTURE_M="$(node_path "$CAPTURE")"
HOOK_M="$(node_path "$HOOK")"
# Tests: hooks/record-off-skill-invocation.js, hooks/workflow-mark.js, hooks/workflow-mark/enforce-override-handlers/off-clearance.js
# Tags: off-clearance, emergency-off, provenance, hook, userpromptsubmit, posttooluse, TL3, run-e2e, scope:common
# The recorder's OWN exit status, per invocation. Without it an absent marker is
# ambiguous: a hook that crashed, was killed by a signal or timed out leaves the
# same evidence as a hook that deliberately declined to write, so turn B's
# negative control would pass for a reason that is not a negative result.
STATUS="$BASE/userpromptsubmit-status.jsonl"
STATUS_M="$(node_path "$STATUS")"
WRAPPER="$BASE/capture-wrapper.js"
cat > "$WRAPPER" <<WRAPPER_EOF
"use strict";
const fs = require("fs");
const { spawnSync } = require("child_process");
const chunks = [];
const buf = Buffer.alloc(4096);
while (true) {
  let n;
  try { n = fs.readSync(0, buf, 0, buf.length); } catch (e) { break; }
  if (!n) break;
  // COPY, never buf.slice(): a slice is a view over this reused buffer, so the
  // next read would rewrite bytes already handed to chunks and the wrapper would
  // corrupt the payload before the hook ever saw it.
  chunks.push(Buffer.from(buf.subarray(0, n)));
}
const raw = Buffer.concat(chunks);
fs.appendFileSync("$CAPTURE_M", raw.toString("utf8") + "\n---\n");
const r = spawnSync(process.execPath, ["$HOOK_M"], { input: raw });
if (r.stdout && r.stdout.length) process.stdout.write(r.stdout);
if (r.stderr && r.stderr.length) process.stderr.write(r.stderr);
let sid = null;
try { sid = JSON.parse(raw.toString("utf8")).session_id || null; } catch (e) {}
// r.status is null when the child was KILLED BY A SIGNAL, and \`status || 0\`
// would launder that into a clean success. 97/98 are this wrapper's own codes
// for "died" and "never started", distinct from anything the hook can exit with.
const status = typeof r.status === "number" ? r.status : (r.error ? 98 : 97);
fs.appendFileSync("$STATUS_M", JSON.stringify({
  sid: sid,
  status: status,
  signal: r.signal || null,
  error: r.error ? String(r.error.message) : null,
  stdout: (r.stdout || "").toString("utf8"),
  stderr: (r.stderr || "").toString("utf8"),
}) + "\n");
process.exit(status);
WRAPPER_EOF

# SAFETY: turn C's live model gets unrestricted Bash under
# --dangerously-skip-permissions; this guard denies every command except the
# expected sentinel (rules/test/claude-e2e.md).
GUARD="$BASE/bash-guard.js"
GUARD_LOG="$BASE/bash-guard-denials.log"
# node_path'd, like WFDIR/PLANSDIR/CAPTURE above: this file is opened by the
# native Windows node process the guard hook spawns as, so an unconverted MSYS
# `/tmp/...` spelling resolves relative to the current drive root and
# appendFileSync fails - silently, since the guard catches every write error
# to stay fail-closed. That produced a false FAIL on guard-log-records-the-
# runtime-denial: the guard genuinely denied both commands (confirmed by the
# CLI's own permission_denials and result text) but never recorded it.
GUARD_LOG_M="$(node_path "$GUARD_LOG")"
# Decision JSON on stdout + exit 0, the block-clearance-token-write.js
# convention - exit 2 discards stdout and relies on exit-code semantics no
# other hook here assumes.
cat > "$GUARD" <<GUARD_EOF
"use strict";
const fs = require("fs");
let raw = "";
try { raw = fs.readFileSync(0, "utf8"); } catch (e) {}
let input = {};
try { input = JSON.parse(raw); } catch (e) {}
const cmd = (input.tool_input && input.tool_input.command) || "";
const allowed = process.env.TL3_ALLOWED_BASH_CMD || "";
if (allowed && cmd === allowed) {
  console.log(JSON.stringify({
    decision: "approve",
    hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "allow" },
  }));
  process.exit(0);
}
try { fs.appendFileSync("$GUARD_LOG_M", cmd + "\\n"); } catch (e) {}
const reason = "TL3 fixture: Bash is restricted to the exact expected sentinel command";
console.log(JSON.stringify({
  decision: "block",
  reason: reason,
  hookSpecificOutput: { hookEventName: "PreToolUse", permissionDecision: "deny", permissionDecisionReason: reason },
}));
process.exit(0);
GUARD_EOF

# Minimal settings: the producer (through the capture wrapper) and the CONSUMER
# that reads its marker in the same turn - workflow-mark.js, registered exactly as
# the real settings.json registers it (PostToolUse on Bash). Nothing else. No
# disableBypassPermissionsMode - it neutralizes --dangerously-skip-permissions and
# hangs the run.
cat > "$REPO/.claude/settings.json" <<SETTINGS_EOF
{
  "hooks": {
    "UserPromptSubmit": [
      {
        "hooks": [
          {
            "type": "command",
            "command": "node \"$(node_path "$WRAPPER")\"",
            "timeout": 30
          }
        ]
      }
    ],
    "PostToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$(node_path "$AGENTS_DIR/hooks/workflow-mark.js")\"",
            "timeout": 30
          }
        ]
      }
    ],
    "PreToolUse": [
      {
        "matcher": "Bash",
        "hooks": [
          {
            "type": "command",
            "command": "node \"$(node_path "$GUARD")\"",
            "timeout": 10
          }
        ]
      }
    ]
  }
}
SETTINGS_EOF

unset CLAUDECODE CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
# Normalized, not the raw mktemp spelling: Node on Windows reads an MSYS
# `/c/...` path as relative to the current drive root, so the hook would write
# its marker into a directory this test never looks at and the run would fail
# for a reason that has nothing to do with provenance.
export CLAUDE_WORKFLOW_DIR="$(node_path "$WFDIR")"
export WORKFLOW_PLANS_DIR="$(node_path "$PLANSDIR")"
export AGENTS_CONFIG_DIR="$(node_path "$AGENTS_DIR")"
export PATH="$MOCKBIN:$PATH"
# Without these, MSYS/Git Bash rewrites an argument that begins with `/` into a
# Windows path before claude ever sees it, so `/enforce-workflow-off ...` arrives
# as `C:/Program Files/Git/enforce-workflow-off ...` and the run silently tests
# the wrong prompt. Unknown names elsewhere, so a no-op off Windows.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL='*'
