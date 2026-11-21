#!/usr/bin/env bash
# Tests: hooks/record-finding-approval-answer.js
# Tags: TL3, hooks, posttooluse, askuserquestion, finding-approval, approval-key, live-host-dispatch, scope:issue-specific, pwsh-not-required, test-lang-exception:e2e
# #2019 S7: a real `claude -p` AskUserQuestion on the `issue-create.confirm-gate` dialog, answered by
# the host through the stdio permission prompt, reaches the PreToolUse + PostToolUse hook pair; the
# PostToolUse payload yields the chosen label's `[k:<8hex>]` key as one askuser-answer record.
# A node driver holds stdin open and answers the control_request with the first label.
# TL3 gap: an interactive (TTY) session is not run here. The day-to-day TL2 runner is
# tests/hooks/feature-2019-finding-approval-answer.js.

set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# --- skip gates (rules/test/claude-e2e.md acceptance criteria) ----------------
if [[ ! -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ]]; then
  echo "SKIP: bin/get-config-var not found or not executable" >&2; exit 77
fi
if "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off; then
  echo "SKIP: requires RUN_TL3=on in .env (Anthropic-billable)" >&2; exit 77
fi
if ! command -v claude >/dev/null 2>&1; then
  echo "SKIP: claude CLI not found" >&2; exit 77
fi

. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

readonly BASE="$(make_tmp)"
trap 'rm -rf "$BASE"' EXIT
harness_isolate "$BASE/iso"
unset CLAUDECODE CLAUDE_CODE_SESSION_ID
export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$BASE/transcripts")"
export JEV=off
mkdir -p "$BASE/transcripts" "$BASE/io"
harness_git_init "$BASE/proj"
mkdir -p "$BASE/proj/.claude"

REPO_N="$(np "$SCRIPT_CHECKOUT_ROOT")"
SID="5e1d2c3b-2019-4f01-8a9b-0c1d2e3f4f01"
QUESTION="Should this finding be filed?"
PICK="File it [k:1a2b3c4d]"
OTHER="Skip it [k:5e6f7a8b]"
APPROVAL="$WORKFLOW_STATE_DIR/$SID.finding-filing-approval"

node -e 'const [f,pre,post]=process.argv.slice(1);const h=(c)=>[{matcher:"AskUserQuestion",hooks:[{type:"command",command:`node "${c}"`,timeout:10}]}];require("fs").writeFileSync(f,JSON.stringify({hooks:{PreToolUse:h(pre),PostToolUse:h(post)}}));' \
  "$(np "$BASE/proj/.claude/settings.json")" "$REPO_N/hooks/pre-tool-use-askuser-jev.js" "$REPO_N/hooks/record-finding-approval-answer.js"

# The driver: sends one user message, answers the AskUserQuestion control_request with PICK,
# denies any other tool, and closes stdin on the result message.
cat >"$BASE/io/driver.js" <<'DRIVER'
const { spawn } = require("child_process");
const fs = require("fs");
const [sid, prompt, pick, outFile] = process.argv.slice(2);
const c = spawn("claude", ["-p", "--session-id", sid, "--setting-sources", "project", "--input-format", "stream-json",
  "--output-format", "stream-json", "--verbose", "--permission-prompt-tool", "stdio"], { stdio: ["pipe", "pipe", "inherit"], shell: process.platform === "win32" });
const out = fs.createWriteStream(outFile);
const send = (o) => c.stdin.write(JSON.stringify(o) + "\n");
send({ type: "user", message: { role: "user", content: prompt } });
let buf = "";
c.stdout.on("data", (d) => {
  out.write(d);
  buf += d;
  let i;
  while ((i = buf.indexOf("\n")) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    let m; try { m = JSON.parse(line); } catch { continue; }
    if (m.type === "control_request" && m.request && m.request.subtype === "can_use_tool") {
      const input = m.request.input || {};
      const ok = m.request.tool_name === "AskUserQuestion";
      const answers = {};
      for (const q of input.questions || []) answers[q.question] = pick;
      send({ type: "control_response", response: { subtype: "success", request_id: m.request_id,
        response: ok ? { behavior: "allow", updatedInput: Object.assign({}, input, { answers }) } : { behavior: "deny", message: "not allowed in this test" } } });
    }
    if (m.type === "result") c.stdin.end();
  }
});
c.on("exit", (code) => { out.end(); process.exit(code === null ? 1 : code); });
DRIVER

PROMPT="Use the AskUserQuestion tool exactly once with metadata {\"source\": \"issue-create.confirm-gate\"}. Ask the single question '$QUESTION' with header 'Finding', multiSelect false, and exactly two options labeled '$PICK' (first) and '$OTHER' (second), labels verbatim. After you get the answer, reply with only the chosen label."

case_begin "human-answer-recorded-from-real-payload" "hooks/record-finding-approval-answer.js"
RC=0
(cd "$BASE/proj" && run_with_timeout 180 node "$(np "$BASE/io/driver.js")" "$SID" "$PROMPT" "$PICK" "$(np "$BASE/io/stream.jsonl")") 2>"$BASE/io/claude.err" || RC=$?
check_eq() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1" "expected [$2] got [$3]"; fi; }
check_eq "claude -p completed (rc)" "0" "$RC"
# Control: the model did call AskUserQuestion, so a missing record is the hook's, not the fixture's.
if grep -qF '"name":"AskUserQuestion"' "$BASE/io/stream.jsonl" 2>/dev/null; then pass "control: AskUserQuestion was called"; else fail "control: AskUserQuestion was called" "no tool_use in the stream"; fi
if [ -f "$APPROVAL" ]; then pass "the approval file exists"; else fail "the approval file exists" "$(head -c 400 "$BASE/io/claude.err")"; fi
KEYS="$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((j.records||[]).filter(r=>r.type==="askuser-answer").flatMap(r=>r.keys||[]).join(","))}catch{}' "$(np "$APPROVAL")")"
check_eq "the chosen label's key is recorded" "1a2b3c4d" "$KEYS"
DIALOG="$(node -e 'try{const j=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const r=(j.records||[]).find(r=>r.type==="askuser-answer");process.stdout.write(r?r.dialog_id:"")}catch{}' "$(np "$APPROVAL")")"
check_eq "the record names the dialog" "issue-create.confirm-gate" "$DIALOG"
case_end

echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -eq 0 ]
