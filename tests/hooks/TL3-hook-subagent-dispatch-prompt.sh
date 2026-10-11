#!/usr/bin/env bash
# Tests: hooks/subagent-dispatch-prompt.js, hooks/jev-shadow-pre.js
# Tags: TL3, hooks, subagent-dispatch, updated-input, live-host-dispatch, spike, scope:issue-specific, pwsh-not-required
# The #2263 Step 2 spike: does a real `claude -p` host apply a PreToolUse updatedInput to an
# Agent call (P1), keep the other fields (P2), keep permissions (P3), coexist with another
# Agent|Task hook (P4), and keep a JSON-input fixed-contract agent working (P5)?
set -uo pipefail

# TL3 gap: this file IS the gap-closer for tests/hooks/feature-2263-subagent-dispatch-prompt.sh
# (synthetic payloads only). It is RUN_TL3-gated and Anthropic-billable (4 runs); R always runs.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2263-subagent-dispatch-prompt/_lib.sh"

# R: the composition of updatedInput is undefined when two hooks on one matcher return it, so
# the jev observer sharing Agent|Task must stay silent (no updatedInput, no permission verdict).
case_begin "R-jev-pre-emits-no-rewrite" "hooks/jev-shadow-pre.js"
JEV_PRE="$SCRIPT_CHECKOUT_ROOT/hooks/jev-shadow-pre.js"
if [ ! -f "$JEV_PRE" ]; then fail "R: hooks/jev-shadow-pre.js exists" "missing"
else
  check "R: jev-shadow-pre.js never mentions updatedInput or permissionDecision" "absent" \
    "$(grep -qE 'updatedInput|permissionDecision' "$JEV_PRE" && echo present || echo absent)"
fi
case_end

# --- TL3 gates (environmental absence only): exit 77 unless R already failed ---
tl3_skip() { skip "P1-P5: $1"; finish || exit 1; exit 77; }
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || tl3_skip "bin/get-config-var not executable"
"$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off && tl3_skip "requires RUN_TL3=on in .env (Anthropic-billable)"
command -v claude >/dev/null 2>&1 || tl3_skip "claude CLI not found"
command -v jq >/dev/null 2>&1 || tl3_skip "jq not found"
[ -f "$HOOK_JS" ] || { fail "P0: hooks/subagent-dispatch-prompt.js exists" "missing"; finish; exit 1; }

FX="$TMPROOT/tl3"
REPO_FX="$FX/proj"
mkdir -p "$REPO_FX/.claude/agents" "$FX/io"
git -C "$REPO_FX" init -q
git -C "$REPO_FX" config core.hooksPath /dev/null

cat > "$FX/io/record.js" <<'EOF'
const fs = require("fs");
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  try { fs.appendFileSync(process.argv[2], raw.replace(/\r?\n/g, " ") + "\n"); } catch (_e) { /* evidence only */ }
  process.exit(0);
});
EOF
# P2 auxiliary: a hook that returns ONLY the prompt, to learn replace-vs-merge (recorded, not judged).
cat > "$FX/io/prompt-only.js" <<'EOF'
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  try {
    const p = JSON.parse(raw).tool_input.prompt;
    process.stdout.write(JSON.stringify({ hookSpecificOutput: { hookEventName: "PreToolUse", updatedInput: { prompt: p + "\n\nPROMPT-ONLY-MARK" } } }));
  } catch (_e) { process.stdout.write("{}"); }
  process.exit(0);
});
EOF
# P3: proves the host invoked the rewrite hook itself, then relays the real hook's stdout and exit code.
cat > "$FX/io/tee-rewriter.js" <<'EOF'
const fs = require("fs"), path = require("path"), { spawnSync } = require("child_process");
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  try { fs.appendFileSync(path.join(__dirname, "rewriter-fired.jsonl"), raw.replace(/\r?\n/g, " ") + "\n"); } catch (_e) { /* evidence only */ }
  const hook = fs.readFileSync(path.join(__dirname, "rewriter-target.txt"), "utf8").trim();
  const r = spawnSync(process.execPath, [hook], { input: raw, encoding: "utf8" });
  process.stdout.write(r.stdout || "");
  process.exit(r.status === null ? 1 : r.status);
});
EOF
printf '%s' "$HOOK_N" > "$FX/io/rewriter-target.txt"
# P5(b): the text of a PostToolUse tool_response, one text block per line.
cat > "$FX/io/reply-text.js" <<'EOF'
const p = JSON.parse(require("fs").readFileSync(process.argv[2], "utf8"));
const acc = [];
const walk = (v) => { if (typeof v === "string") return; if (Array.isArray(v)) return v.forEach(walk); if (v && typeof v === "object") { if (typeof v.text === "string") acc.push(v.text); Object.values(v).forEach(walk); } };
if (typeof p.tool_response === "string") acc.push(p.tool_response); else walk(p.tool_response);
process.stdout.write(acc.join("\n"));
EOF
# A bare "Agent" deny drops the tool from the model's list, so the call would never reach
# PreToolUse; a subagent-scoped deny keeps it offered and is decided after the hooks run.
cat > "$FX/io/mk-settings.js" <<'EOF'
const fs = require("fs");
const [out, rewriter, rec, io, deny] = process.argv.slice(2);
const grp = (cmd) => ({ matcher: "Agent|Task", hooks: [{ type: "command", command: cmd, timeout: 10 }] });
const s = { hooks: {
  PreToolUse: [grp("node \"" + rewriter + "\""), grp("node \"" + rec + "\" \"" + io + "/pre.jsonl\"")],
  PostToolUse: [grp("node \"" + rec + "\" \"" + io + "/post.jsonl\"")],
} };
if (deny === "deny") s.permissions = { deny: ["Agent(general-purpose)", "Task(general-purpose)"] };
fs.writeFileSync(out, JSON.stringify(s));
EOF
cat > "$REPO_FX/.claude/agents/fixture-json-worker.md" <<'EOF'
---
name: fixture-json-worker
description: TL3 fixture. Takes a JSON object and replies with exactly three lines.
tools: Bash, Read
---

Input contract: the task prompt is a JSON object `{topic, marker}`.

Output contract: reply with exactly three lines and no other output:
status: ok
summary: <the value of marker, verbatim>
artifact_path: (none)

Do not use any tool.
EOF

# run_case <name> <rewriter-js> <deny|allow> <prompt>: one billed claude -p run into $FX/<name>/.
run_case() {
  local d="$FX/$1"
  mkdir -p "$d"
  run_with_timeout 30 node "$(np "$FX/io/mk-settings.js")" "$(np "$d/settings.json")" "$(np "$2")" "$(np "$FX/io/record.js")" "$(np "$d")" "$3"
  ( cd "$REPO_FX" && unset CLAUDECODE && env -u CLAUDE_CODE_SESSION_ID \
      "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 180 claude -p "$4" \
      --output-format json --settings "$(np "$d/settings.json")" \
      > "$d/response.json" 2> "$d/claude.err" )
  printf '%s' "$?" > "$d/rc"
}
rc_of() { cat "$FX/$1/rc" 2>/dev/null; }
first_agent() { grep -E '"tool_name":"(Agent|Task)"' "$1" 2>/dev/null | head -n 1; }

ECHO_PROMPT="Use the Agent tool exactly once with subagent_type general-purpose, description 'echo last line', and prompt 'Reply with the final line of your own task prompt, verbatim, and nothing else. Do not use any tool.' Then print the subagent's reply verbatim and stop."
P5_MARKER="mk-2263-$$-$RANDOM"
P5_JSON="{\"topic\":\"tl3 fixture\",\"marker\":\"$P5_MARKER\"}"
P5_PROMPT="Use the Agent tool exactly once with subagent_type fixture-json-worker, description 'json worker', and pass this JSON string verbatim as the prompt: $P5_JSON  Then print the subagent's reply verbatim and stop."

run_case p1 "$HOOK_JS" allow "$ECHO_PROMPT"
run_case p3 "$FX/io/tee-rewriter.js" deny "$ECHO_PROMPT"
run_case p5 "$HOOK_JS" allow "$P5_PROMPT"
run_case aux "$FX/io/prompt-only.js" allow "$ECHO_PROMPT"

case_begin "P1-subagent-receives-line" "hooks/subagent-dispatch-prompt.js"
check "P1: the default (no deny) run finishes in time with no approval hang" "0" "$(rc_of p1)"
check "P1: the subagent's echoed last line names the section and this checkout's rule path" "yes|yes" \
  "$(grep -qF 'Subagent Dispatch Prompts' "$FX/p1/response.json" && echo yes || echo no)|$(grep -qF "$SDP_RULE_PATH" "$FX/p1/response.json" && echo yes || echo no)"
case_end

case_begin "P2-fields-preserved" "hooks/subagent-dispatch-prompt.js"
PRE1="$(first_agent "$FX/p1/pre.jsonl")"
POST1="$(first_agent "$FX/p1/post.jsonl")"
check "P2: PostToolUse tool_input keeps description and subagent_type and carries the rewritten prompt" "true|true|true" \
  "$(jq -n --argjson a "${PRE1:-null}" --argjson b "${POST1:-null}" --arg c "$SDP_CANON_PRE$SDP_RULE_PATH$SDP_CANON_POST" \
    '[($a.tool_input.description == $b.tool_input.description and $b.tool_input.description != null), ($a.tool_input.subagent_type == $b.tool_input.subagent_type and $b.tool_input.subagent_type != null), ($b.tool_input.prompt == ($a.tool_input.prompt + "\n\n" + $c))] | map(tostring) | join("|")' 2>/dev/null)"
AUX_POST="$(first_agent "$FX/aux/post.jsonl")"
echo "INFO: P2 auxiliary (prompt-only updatedInput, not judged): $(jq -n --argjson b "${AUX_POST:-null}" '{description: ($b.tool_input.description != null), subagent_type: ($b.tool_input.subagent_type != null), prompt_marked: (($b.tool_input.prompt // "") | contains("PROMPT-ONLY-MARK"))}' 2>/dev/null)"
case_end

case_begin "P3-deny-still-denies" "hooks/subagent-dispatch-prompt.js"
check "P3: with permissions.deny Agent/Task the run still finishes (rc not 124)" "finished" "$([ "$(rc_of p3)" != "124" ] && echo finished || echo timeout)"
check "P3: the host invoked the rewrite hook for the Agent call and the parallel observer saw it" "yes|yes" \
  "$([ -n "$(first_agent "$FX/io/rewriter-fired.jsonl")" ] && echo yes || echo no)|$([ -n "$(first_agent "$FX/p3/pre.jsonl")" ] && echo yes || echo no)"
check "P3: no Agent call reached PostToolUse (the hook did not turn a deny into an allow)" "" "$(first_agent "$FX/p3/post.jsonl")"
check "P3: the CLI result records the Agent/Task call as a permission denial" "true" \
  "$(jq '[.permission_denials[]?.tool_name] | any(. == "Agent" or . == "Task")' "$FX/p3/response.json" 2>/dev/null)"
case_end

case_begin "P4-coexists-with-observer" "hooks/subagent-dispatch-prompt.js"
check "P4: the parallel Agent|Task observer fired and saw the pre-rewrite prompt" "true" \
  "$(jq -n --argjson a "${PRE1:-null}" '($a != null) and (($a.tool_input.prompt // "") | contains("Subagent Dispatch Prompts") | not)' 2>/dev/null)"
case_end

case_begin "P5-json-fixed-contract" "hooks/subagent-dispatch-prompt.js"
POST5="$(first_agent "$FX/p5/post.jsonl")"
if [ -z "$POST5" ]; then
  fail "P5: the fixture project agent ran, so JSON delivery and the 3-line reply are asserted" "no PostToolUse Agent record (rc=$(rc_of p5))"
else
  check "P5(a): the prompt is still JSON with topic/marker kept and dispatch_directive = canonical line" "true" \
    "$(jq -n --argjson b "$POST5" --arg c "$SDP_CANON_PRE$SDP_RULE_PATH$SDP_CANON_POST" --arg m "$P5_MARKER" \
      '($b.tool_input.prompt | fromjson) as $o | ($o.topic == "tl3 fixture") and ($o.marker == $m) and ($o.dispatch_directive == $c)' 2>/dev/null)"
  printf '%s' "$POST5" > "$FX/p5/post-one.json"
  REPLY5="$(run_with_timeout 30 node "$(np "$FX/io/reply-text.js")" "$(np "$FX/p5/post-one.json")" 2>/dev/null | tr -d '\r' | grep -v '^[[:space:]]*$')"
  check "P5(b): the reply is exactly three lines with the contract prefixes and no deviations section" "3|status:|summary:|artifact_path:|absent" \
    "$(printf '%s\n' "$REPLY5" | grep -c .)|$(printf '%s\n' "$REPLY5" | sed -n 1p | cut -d' ' -f1)|$(printf '%s\n' "$REPLY5" | sed -n 2p | cut -d' ' -f1)|$(printf '%s\n' "$REPLY5" | sed -n 3p | cut -d' ' -f1)|$(printf '%s' "$REPLY5" | grep -qF 'Command-form deviations' && echo present || echo absent)"
  check "P5(c): the summary line carries the marker (the JSON was understood)" "yes" \
    "$(printf '%s\n' "$REPLY5" | grep -E '^summary:' | grep -qF "$P5_MARKER" && echo yes || echo no)"
fi
case_end

finish
