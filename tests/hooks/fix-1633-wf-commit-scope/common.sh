# shellcheck shell=bash
# Shared helpers and fixture repos for fix-1633-wf-commit-scope.sh.
# Sourced by the entry script after harness_isolate pinned the state/plans dirs.

AGENTS_NODE="$(np "$SCRIPT_CHECKOUT_ROOT")"
GATE="$AGENTS_NODE/hooks/workflow-gate.js"
MARK="$AGENTS_NODE/hooks/workflow-mark.js"
HELPER="$TMP_ROOT/commit-scope-helper.js"
NEUTRAL="$TMP_ROOT/neutral"
FAKE_HOME="$TMP_ROOT/home"
mkdir -p "$NEUTRAL" "$FAKE_HOME"

# state <sid> <pending-csv|-> [<v1-extra-json>] — v1 file; listed steps pending, the rest complete.
# intent <sid> <repo=path>... — <sid>-intent.md with one ## worktrees entry per pair.
# payload <sid|-> <cwd> <tool> <commands-json> [nocwd] — PreToolUse input.
cat >"$HELPER" <<'JS'
"use strict";
const fs = require("fs");
const path = require("path");
const [agents, mode, ...a] = process.argv.slice(2);
if (mode === "state") {
  const { VALID_STEPS } = require(agents + "/hooks/workflow-state");
  const pending = a[1] === "-" ? [] : a[1].split(",");
  const steps = {};
  for (const s of VALID_STEPS) {
    steps[s] = { status: pending.includes(s) ? "pending" : "complete", updated_at: "2026-06-27T10:00:00.000Z" };
  }
  const extra = a[2] ? JSON.parse(a[2]) : {};
  const override = extra.__steps || {};
  delete extra.__steps;
  for (const [k, v] of Object.entries(override)) steps[k] = { status: v, updated_at: "2026-06-27T10:00:00.000Z" };
  const st = Object.assign({ version: 1, session_id: a[0], created_at: "2026-06-27T10:00:00.000Z", steps }, extra);
  fs.writeFileSync(path.join(process.env.WORKFLOW_STATE_DIR, a[0] + ".json"), JSON.stringify(st));
} else if (mode === "intent") {
  const lines = ["# intent", "", "## worktrees"];
  for (const pair of a.slice(1)) {
    const i = pair.indexOf("=");
    lines.push("- repo: " + pair.slice(0, i), "  worktree_path: " + pair.slice(i + 1));
  }
  lines.push("", "## notes", "");
  fs.writeFileSync(path.join(process.env.WORKFLOW_PLANS_DIR, a[0] + "-intent.md"), lines.join("\n"));
} else if (mode === "payload") {
  const cmds = JSON.parse(a[3]);
  const ti = a[2] === "runCommands" ? { commands: cmds, cwd: a[1] } : { command: cmds[0], cwd: a[1] };
  const o = { tool_name: a[2], tool_input: ti, cwd: a[1] };
  if (a[4] === "nocwd") { delete o.cwd; delete ti.cwd; }
  if (a[0] !== "-") o.session_id = a[0];
  process.stdout.write(JSON.stringify(o));
} else if (mode === "reset-payload") {
  const line = "<<WORKFLOW_RESET_FROM_" + a[1] + ": test reset fixture>>";
  process.stdout.write(JSON.stringify({ tool_name: "Bash", tool_input: { command: "echo \"" + line + "\"" },
    tool_response: { exit_code: 0, stdout: line, stderr: "" }, session_id: a[0] }));
} else if (mode === "status") {
  // status <sid> <step> — projected status after migration / events.
  const st = require(agents + "/hooks/workflow-state/state-io").readState(a[0]);
  const cur = st && st.current && st.current.steps && st.current.steps[a[1]];
  process.stdout.write(String(cur && cur.status));
}
JS

helper() { run_with_timeout 60 node "$(np "$HELPER")" "$AGENTS_NODE" "$@"; }

# corrupt <sid> — a state file that is not JSON.
corrupt() { printf '{not json' >"$WORKFLOW_STATE_DIR/$1.json"; }

mk_repo() {
  harness_git_init "$1"
  git -C "$1" config user.email t@example.com
  git -C "$1" config user.name t
  git -C "$1" config core.autocrlf false
  echo "seed-${1##*/}" >"$1/README.md"
  git -C "$1" add README.md
  git -C "$1" commit -q --no-verify -m init
}

# big_staged <repo> — stage a code file over the 500-line HARD limit (Gate 2).
big_staged() {
  local i
  for i in $(seq 1 620); do echo "const v$i = $i;"; done >"$1/big.js"
  git -C "$1" add big.js
}

# A: agents-like session-start repo; B: another repo; C: outside repo. Each has a linked worktree.
A="$(np "$TMP_ROOT/repo-a")"
B="$(np "$TMP_ROOT/repo-b")"
C="$(np "$TMP_ROOT/repo-c")"
AL="$(np "$TMP_ROOT/repo-a-linked")"
BL="$(np "$TMP_ROOT/repo-b-linked")"
CL="$(np "$TMP_ROOT/repo-c-linked")"
MISSING="$(np "$TMP_ROOT")/never-existed"
for r in "$A" "$B" "$C"; do mk_repo "$r"; done
git -C "$A" worktree add -q -b a-linked "$AL"
git -C "$B" worktree add -q -b b-linked "$BL"
git -C "$C" worktree add -q -b c-linked "$CL"
# G (+GL) is a clean session-start repo; H (+HL) holds a staged >500-line code file.
G="$(np "$TMP_ROOT/repo-g")"
H="$(np "$TMP_ROOT/repo-h")"
GL="$(np "$TMP_ROOT/repo-g-linked")"
HL="$(np "$TMP_ROOT/repo-h-linked")"
for r in "$G" "$H"; do mk_repo "$r"; done
git -C "$G" worktree add -q -b g-linked "$GL"
git -C "$H" worktree add -q -b h-linked "$HL"
big_staged "$H"
# FS: outside repo with a staged change, the only additionalDirectory of ADD_HOME.
FS="$(np "$TMP_ROOT/repo-fs")"
ADD_HOME="$TMP_ROOT/home-additional"
mk_repo "$FS"
echo staged >"$FS/staged.txt"
git -C "$FS" add staged.txt
mkdir -p "$ADD_HOME/.claude"
printf '{"permissions":{"additionalDirectories":["%s"]}}\n' "$FS" >"$ADD_HOME/.claude/settings.json"

# gate <sid|-> <payload-cwd> <project-dir|-> <tool> <commands-json> — prints the decision JSON.
# "-" unsets CLAUDE_PROJECT_DIR; GATE_HOME / GATE_CWD / GATE_PAYLOAD_CWD=nocwd override.
gate() {
  local sid="$1" cwd="$2" proj="$3" tool="$4" cmds="$5" payload home="${GATE_HOME:-$FAKE_HOME}"
  local -a projenv=(CLAUDE_PROJECT_DIR="$proj")
  [ "$proj" = "-" ] && projenv=(-u CLAUDE_PROJECT_DIR)
  payload="$(helper payload "$sid" "$cwd" "$tool" "$cmds" "${GATE_PAYLOAD_CWD:-keep}")"
  (cd "${GATE_CWD:-$NEUTRAL}" && printf '%s' "$payload" | env "${projenv[@]}" HOME="$home" \
    USERPROFILE="$(np "$home")" bash "$RWT" 60 node "$GATE" 2>/dev/null) || true
}

# reset_from <sid> <step> — apply <<WORKFLOW_RESET_FROM_<step>>> through workflow-mark.
reset_from() {
  local payload
  payload="$(helper reset-payload "$1" "$2")"
  (cd "$NEUTRAL" && printf '%s' "$payload" | bash "$RWT" 60 node "$MARK" >/dev/null 2>&1) || true
}

# expect <label> <approve|block> <reason-substring|-> <gate-output>
expect() {
  local label="$1" want="$2" needle="$3" got="$4"
  case "$got" in
    *"\"decision\":\"$want\""*) ;;
    *) fail "$label" "want $want, got: ${got:0:300}"; return 0 ;;
  esac
  if [ "$needle" != "-" ] && [[ "$got" != *"$needle"* ]]; then
    fail "$label" "$want but reason lacks '$needle': ${got:0:300}"
    return 0
  fi
  pass "$label"
}

# expect_lacks <label> <substring> <gate-output>
expect_lacks() {
  if [[ "$3" == *"$2"* ]]; then fail "$1" "reason unexpectedly holds '$2': ${3:0:300}"; else pass "$1"; fi
}
