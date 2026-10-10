#!/usr/bin/env bash
# Tests: hooks/jev-shadow-pre.js, hooks/jev-shadow-post.js, bin/workflow/lib/jev-complexity-adapter.js, bin/workflow/normalize-judge-signals, settings.json
# Tags: TL3, hooks, jev, shadow-mode, agent-dispatch, payload-shape, hook-registration, live-host-dispatch, scope:issue-specific, pwsh-not-required

# Every TL2 fragment of feature-2460-jev-shadow.sh feeds payloads this repo composed. This
# drives one real `claude -p` Agent dispatch of a haiku fixture complexity-judge through
# the settings.json-registered jev-shadow hooks against the mock Jev, and checks the seams
# only a live host can show: the Agent payload fields, tool_use_id pairing, and that shadow
# mode injects no [JEV] text into the main transcript.
set -uo pipefail

# TL3 gap: this file IS the gap-closer for the day-to-day TL2 runner
# tests/hooks/feature-2460-jev-shadow.sh (synthetic payloads only). It is RUN_TL3-gated and
# Anthropic-billable, so CI normally skips it; R1 always runs so the field names the hooks
# read are checked on every invocation. The real Jev API is never contacted here.

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2460-jev-shadow/_lib.sh"
SESSION_UUID="3c2a9e71-2460-4b6f-9d1e-7a5b3c2d1e0f"

# R1: the payload fields T1-T3 rely on must be the fields the shipped sources read.
case_begin "R1-sources-read-the-asserted-fields" "hooks/jev-shadow-pre.js"
R1_SRCS=("$SCRIPT_CHECKOUT_ROOT/hooks/jev-shadow-pre.js" "$SCRIPT_CHECKOUT_ROOT/hooks/jev-shadow-post.js" "$SCRIPT_CHECKOUT_ROOT/bin/workflow/lib/jev-complexity-adapter.js")
R1_MISSING=""
for f in "${R1_SRCS[@]}"; do [ -f "$f" ] || R1_MISSING="$R1_MISSING ${f#"$SCRIPT_CHECKOUT_ROOT"/}"; done
if [ -n "$R1_MISSING" ]; then
  fail "R1: source files missing:$R1_MISSING"
else
  R1_PROBLEMS=""
  for field in subagent_type tool_use_id; do
    for f in "${R1_SRCS[@]:0:2}"; do
      grep -qF "$field" "$f" || R1_PROBLEMS="$R1_PROBLEMS [${f#"$SCRIPT_CHECKOUT_ROOT"/} never reads $field]"
    done
  done
  grep -qF tool_response "${R1_SRCS[2]}" || R1_PROBLEMS="$R1_PROBLEMS [the adapter never reads tool_response]"
  if [ -z "$R1_PROBLEMS" ]; then pass "R1: hooks read subagent_type and tool_use_id; the adapter reads tool_response"
  else fail "R1: the sources and this test disagree about the Agent payload;$R1_PROBLEMS"; fi
fi
case_end

# --- TL3 gates (environmental absence only) ---
[ -x "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" ] || { skip "T1-T5: bin/get-config-var not executable"; finish; exit; }
if "$SCRIPT_CHECKOUT_ROOT/bin/get-config-var" --is-off RUN_TL3 off; then
  skip "T1-T5: requires RUN_TL3=on in .env (Anthropic-billable)"; finish; exit
fi
command -v claude >/dev/null 2>&1 || { skip "T1-T5: claude CLI not found"; finish; exit; }
command -v jq >/dev/null 2>&1 || { skip "T1-T5: jq not found"; finish; exit; }

fx_new tl3
mock_start
mock_mode '{}'
REPO_FX="$FX/proj"
RECORD="$FX/io/agent-post.jsonl"
mkdir -p "$REPO_FX/.claude/agents"
cat > "$REPO_FX/.claude/agents/complexity-judge.md" <<'EOF'
---
name: complexity-judge
description: TL3 fixture judge. Outputs one fixed SIGNALS line.
model: haiku
tools: Read
---

Output exactly the single line `SIGNALS: S1-multi-file` and nothing else. Do not use any tool.
EOF
cat > "$FX/io/record.js" <<'EOF'
const fs = require("fs");
let raw = "";
process.stdin.on("data", (c) => { raw += c; });
process.stdin.on("end", () => {
  try { fs.appendFileSync(process.env.TL3_RECORD_FILE, raw.replace(/\r?\n/g, " ") + "\n"); } catch (_e) { /* evidence only */ }
  process.exit(0);
});
EOF

# Copy the registered jev-shadow groups out of the real settings.json; add the recorder.
SETTINGS_FX="$FX/io/settings.json"
cat > "$FX/io/pick-settings.js" <<'EOF'
const fs = require("fs");
const s = JSON.parse(fs.readFileSync(process.argv[2], "utf8"));
const pick = (ev, needle) => ((s.hooks && s.hooks[ev]) || []).filter((g) => (g.hooks || []).some((h) => String(h.command).includes(needle)));
const pre = pick("PreToolUse", "jev-shadow-pre.js"), post = pick("PostToolUse", "jev-shadow-post.js");
if (!pre.length || !post.length) { process.stdout.write("unregistered"); process.exit(0); }
const rec = { matcher: "Agent|Task", hooks: [{ type: "command", command: "node \"" + process.env.REC + "\"", timeout: 10 }] };
fs.writeFileSync(process.env.OUTF, JSON.stringify({ hooks: { PreToolUse: pre, PostToolUse: post.concat([rec]) } }));
process.stdout.write("ok");
EOF
REG_OK="$(REC="$(np "$FX/io/record.js")" OUTF="$(np "$SETTINGS_FX")" run_with_timeout 30 node "$(np "$FX/io/pick-settings.js")" "$REPO_N/settings.json" 2>/dev/null)"

case_begin "T0-settings-registration-copied" "settings.json"
check "T0: settings.json registers both jev-shadow hooks (copied into the fixture)" "ok" "$REG_OK"
case_end
[ "$REG_OK" = "ok" ] || { finish; exit; }

unset CLAUDECODE
( cd "$REPO_FX" && env -u CLAUDE_CODE_SESSION_ID \
    -u JEV_HTTP_TIMEOUT_MS -u JEV_PENDING_TTL_MS AGENTS_MAIN_ROOT="$REPO_N" JEV=on TYPESAFE_API_KEY="$SENTINEL_KEY" JEV_BASE_URL="$MOCK_URL" \
    TL3_RECORD_FILE="$(np "$RECORD")" \
    "$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh" 180 claude -p \
    "Use the Agent tool once with subagent_type complexity-judge and prompt 'classify this task', then stop." \
    --output-format json --session-id "$SESSION_UUID" --settings "$(np "$SETTINGS_FX")" \
    > "$FX/io/response.json" 2> "$FX/io/claude.err" )
CLAUDE_RC=$?

# Opted in with every prerequisite present: a failed or timed-out run is a FAIL, never a skip.
case_begin "T0b-claude-p-run-completes" "hooks/jev-shadow-post.js"
if [ "$CLAUDE_RC" -eq 0 ]; then pass "T0b: claude -p completed with rc=0"
else fail "T0b: claude -p exited rc=$CLAUDE_RC (124 = timeout); T1-T5 not verified" \
  "stderr tail: $(tail -c 300 "$FX/io/claude.err" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"; fi
case_end
[ "$CLAUDE_RC" -eq 0 ] || { finish; exit; }

case_begin "T1-agent-payload-recorded" "hooks/jev-shadow-post.js"
LINE="$(grep -E '"tool_name":"(Agent|Task)"' "$RECORD" 2>/dev/null | head -n 1)"
SUB="$(printf '%s' "$LINE" | jq -r '.tool_input.subagent_type // empty' 2>/dev/null)"
TID="$(printf '%s' "$LINE" | jq -r '.tool_use_id // empty' 2>/dev/null)"
check "T1: a PostToolUse Agent payload with subagent_type complexity-judge and a tool_use_id" "complexity-judge|true" \
  "$SUB|$([ -n "$TID" ] && echo true || echo false)"
printf '%s' "$LINE" > "$FX/io/payload.json"
if [ -n "${TL3_JEV_CAPTURE_TO:-}" ] && [ -n "$LINE" ]; then cp "$FX/io/payload.json" "$TL3_JEV_CAPTURE_TO"; fi
case_end

case_begin "T2-extract-then-parse" "bin/workflow/lib/jev-complexity-adapter.js"
T2_RAW="$FX/io/t2-raw.txt"
# The parser runs in-process via its exported normalize(), as the broker calls it; the CLI
# would write <stage>-signals.txt into a control dir.
T2_GOT="$(AD="$ADAPTER_JS" NJS="$PARSER" run_with_timeout 30 node -e '
  const fs = require("fs");
  const p = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const t = require(process.env.AD).extractLlmText(p.tool_response, p);
  const raw = t === null || t === undefined ? "" : String(t);
  fs.writeFileSync(process.argv[2], raw);
  process.stdout.write(String(require(process.env.NJS).normalize(raw)));
' "$(np "$FX/io/payload.json")" "$(np "$T2_RAW")" 2>/dev/null | tr -d '\r\n')"
if [ "$T2_GOT" = "S1-multi-file" ]; then pass "T2: extractLlmText -> parser gives S1-multi-file on the real payload"
else fail "T2: extractLlmText -> parser gave [$T2_GOT]" "extracted tail: $(tail -c 200 "$T2_RAW" 2>/dev/null | tr -d '\r' | tr '\n' ' ')"; fi
case_end

case_begin "T3-one-record-both-ok" "hooks/jev-shadow-post.js"
check "T3: exactly one record for the tool_use_id; jev ok, llm ok, llm answer S1-multi-file" "1|ok|ok|S1-multi-file" \
  "$(rq "$TID" 'recs.length + "|" + (r && [r.jev.status, r.llm.status, r.llm.answer].join("|"))')"
case_end

case_begin "T4-no-jev-block-in-transcript" "hooks/jev-shadow-post.js"
TPATH="$(printf '%s' "$LINE" | jq -r '.transcript_path // empty' 2>/dev/null)"
# Non-vacuity: absence only counts when the real transcript exists and is non-empty.
if [ -z "$TPATH" ] || [ ! -s "$TPATH" ]; then fail "T4: the main transcript is readable (non-vacuity)" "transcript_path=[$TPATH]"
elif grep -qF '[JEV]' "$TPATH" 2>/dev/null; then fail "T4: no [JEV] text in the main transcript" "transcript_path=[$TPATH] carries [JEV]"
else pass "T4: no [JEV] text in the main transcript"; fi
check "T4: no [JEV] text in the claude -p response either" "absent" "$(grep_absent '[JEV]' "$FX/io/response.json")"
case_end

case_begin "T5-sentinel-key-never-written" "hooks/jev-shadow-post.js"
check "T5: the sentinel key is absent from the log, the recorder and claude.err" "absent" \
  "$(grep_absent "$SENTINEL_KEY" "$FX/state" "$RECORD" "$FX/io/claude.err")"
case_end

finish
