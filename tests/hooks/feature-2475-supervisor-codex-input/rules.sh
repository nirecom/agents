# rules.sh — fragment of tests/hooks/feature-2475-supervisor-codex-input.sh (no frontmatter).
# Plan Step 9. Assumed API: rules.js exports classify(entry[, ctx]) returning
#   {rule, keep, text} (or an array of them); ctx is optional for context-free rules.
# Context-dependent rules (tool_use <-> tool_result pairing, queued dedup, multi-record
#   Bash+sentinel, skipped_unparsable) are asserted black-box through the CLI render.

cat > "$SCI_TMP/classify.js" <<'JS'
'use strict';
const fs = require('fs');
const [rulesPath, entryFile, wantRule, wantKeep, wantTextFile] = process.argv.slice(2);
let m;
try { m = require(rulesPath); } catch (e) { process.stdout.write('ERROR: cannot load rules.js: ' + e.message.split('\n')[0]); process.exit(0); }
if (typeof m.classify !== 'function') { process.stdout.write('ERROR: classify is not exported'); process.exit(0); }
const entry = JSON.parse(fs.readFileSync(entryFile, 'utf8'));
let r;
try { r = m.classify(entry); } catch (e) { process.stdout.write('ERROR: classify threw: ' + e.message); process.exit(0); }
const recs = (Array.isArray(r) ? r : [r]).filter(Boolean);
const keep = wantKeep === 'true';
let hit;
if (wantRule === '*') {
  hit = recs.find((x) => !!x.keep === keep) || (recs.length === 0 && !keep ? { keep: false } : undefined);
} else {
  hit = recs.find((x) => x.rule === wantRule);
}
if (!hit) { process.stdout.write('MISMATCH got=' + JSON.stringify(recs)); process.exit(0); }
if (!!hit.keep !== keep) { process.stdout.write('MISMATCH keep=' + JSON.stringify(hit)); process.exit(0); }
if (wantTextFile && fs.existsSync(wantTextFile)) {
  const want = fs.readFileSync(wantTextFile, 'utf8');
  if (hit.text !== want) { process.stdout.write('MISMATCH text=' + JSON.stringify(hit.text) + ' want=' + JSON.stringify(want)); process.exit(0); }
}
process.stdout.write('OK');
JS

# rc_check <label> <entry-json> <want-rule|*> <want-keep true|false> [want-text]
rc_check() {
  printf '%s\n' "$2" > "$SCI_TMP/entry.json"
  rm -f "$SCI_TMP/want.txt"
  if [ $# -ge 5 ]; then printf '%s' "$5" > "$SCI_TMP/want.txt"; fi
  local got
  got="$(run_with_timeout 20 node "$(np "$SCI_TMP/classify.js")" "$SCI_RULES" "$(np "$SCI_TMP/entry.json")" "$3" "$4" "$(np "$SCI_TMP/want.txt")" 2>&1)"
  if [ "$got" = "OK" ]; then pass "$1"; else fail "$1" "$got"; fi
}

echo "--- rules: classify() per row ---"
rc_check "U-human plain string" '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"decision: plan A"},"uuid":"u1"}' U-human true "decision: plan A"
rc_check "D-meta beats U-human" '{"type":"user","isMeta":true,"origin":{"kind":"human"},"message":{"role":"user","content":"decision: plan A"},"uuid":"u1"}' D-meta false
rc_check "D-sidechain beats U-human" '{"type":"user","isSidechain":true,"origin":{"kind":"human"},"message":{"role":"user","content":"decision: plan A"},"uuid":"u1"}' D-sidechain false
rc_check "D-task-notif" '{"type":"user","origin":{"kind":"task-notification"},"message":{"role":"user","content":"task done"},"uuid":"u2"}' D-task-notif false
rc_check "D-compact by leading text" '{"type":"user","message":{"role":"user","content":"This session is being continued from a previous conversation"},"uuid":"u3"}' D-compact false
rc_check "D-compact by isCompactSummary" '{"type":"user","isCompactSummary":true,"message":{"role":"user","content":"summary"},"uuid":"u3b"}' D-compact false
rc_check "U-human strips IDE tag in a separate block" '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>x</ide_opened_file>"},{"type":"text","text":"real instruction"}]},"uuid":"u4"}' U-human true "real instruction"
rc_check "U-human strips IDE tag in the same block" '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>x</ide_opened_file>\nreal instruction"}]},"uuid":"u5"}' U-human true "real instruction"
rc_check "U-human strips system-reminder and ide_selection" '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"<system-reminder>r</system-reminder>\n<ide_selection>s</ide_selection>\nkept body"},"uuid":"u5b"}' U-human true "kept body"
rc_check "U-human keeps slash command-message" '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"<command-message>workflow-init</command-message>"},"uuid":"u6"}' U-human true "<command-message>workflow-init</command-message>"
rc_check "U-human drops [Request interrupted" '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"[Request interrupted by user]"},"uuid":"u7"}' '*' false
rc_check "U-human drops <local-command-" '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"<local-command-stdout>x</local-command-stdout>"},"uuid":"u7b"}' '*' false
rc_check "U-deferred-answer" '{"type":"user","message":{"content":[{"type":"text","text":"Answering your earlier question \"how to proceed?\": accept remaining gaps"}]},"uuid":"u9"}' U-deferred-answer true 'Answering your earlier question "how to proceed?": accept remaining gaps'
rc_check "D-meta beats U-deferred-answer" '{"type":"user","isMeta":true,"message":{"content":[{"type":"text","text":"Answering your earlier question \"how to proceed?\": accept"}]},"uuid":"u9b"}' D-meta false
rc_check "U-queued array prompt, tag stripped" '{"type":"attachment","attachment":{"type":"queued_command","prompt":[{"type":"text","text":"<ide_opened_file>a.js</ide_opened_file>\nmid-task instruction"}],"origin":{"kind":"human"},"commandMode":"prompt"},"uuid":"q1"}' U-queued true "mid-task instruction"
rc_check "U-queued string prompt" '{"type":"attachment","attachment":{"type":"queued_command","prompt":"mid-task instruction 2","origin":{"kind":"human"},"commandMode":"prompt"},"uuid":"q2"}' U-queued true "mid-task instruction 2"
rc_check "queued task-notification without origin is D-other" '{"type":"attachment","attachment":{"type":"queued_command","prompt":"<task-notification>done</task-notification>","commandMode":"task-notification"},"uuid":"q3"}' D-other false
rc_check "A-bash" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"git status"}}]},"uuid":"a1"}' A-bash true "cmd: git status"
rc_check "A-edit omits old_string" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Edit","input":{"file_path":"C:/r/a.js","old_string":"x","new_string":"y"}}]},"uuid":"a2"}' A-edit true "edit: Edit C:/r/a.js"
rc_check "A-edit NotebookEdit uses notebook_path" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2b","name":"NotebookEdit","input":{"notebook_path":"C:/r/n.ipynb","new_source":"z"}}]},"uuid":"a2b"}' A-edit true "edit: NotebookEdit C:/r/n.ipynb"
rc_check "A-invoke Skill" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Skill","input":{"skill":"run-tests","args":"x"}}]},"uuid":"a3"}' A-invoke true "skill: run-tests x"
rc_check "A-invoke Agent" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Agent","input":{"subagent_type":"general-purpose","description":"find x","prompt":"p"}}]},"uuid":"a4"}' A-invoke true "agent: general-purpose find x"
rc_check "A-sentinel in assistant text (lowercase step name allowed)" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"resetting <<WORKFLOW_RESET_FROM_write_code: r>> now"}]},"uuid":"a5"}' A-sentinel true "sentinel: <<WORKFLOW_RESET_FROM_write_code: r>>"
rc_check "lowercase-led <<x: y>> is not a sentinel" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"text","text":"see <<lowercase: x>>"}]},"uuid":"a6"}' '*' false
rc_check "A-stop-block" '{"type":"attachment","attachment":{"type":"hook_blocking_error","hookEvent":"Stop","hookName":"supervisor-guard","blockingError":{"blockingError":"run supervisor"}},"uuid":"h1"}' A-stop-block true "hook-block: Stop supervisor-guard: run supervisor"
rc_check "hook_success attachment dropped" '{"type":"attachment","attachment":{"type":"hook_success","hookEvent":"Stop","hookName":"x"},"uuid":"h2"}' '*' false
rc_check "Read tool_use dropped" '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t5","name":"Read","input":{"file_path":"C:/r/a.js"}}]},"uuid":"a7"}' '*' false
rc_check "system stop_hook_summary dropped" '{"type":"system","subtype":"stop_hook_summary","content":"x","uuid":"s1"}' '*' false
rc_check "unpaired non-error tool_result dropped" '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"zz","content":"ok"}]},"uuid":"r1"}' '*' false

echo "--- rules: context-dependent rows via CLI ---"
RC_T="$SCI_TMP/proj/ctx.jsonl"
{
  printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"start work"},"uuid":"c1","timestamp":"2026-01-01T00:00:01Z"}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t1","name":"AskUserQuestion","input":{"questions":[]}}]},"uuid":"c2"}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"The user answered: B"}]},"uuid":"c3","timestamp":"2026-01-01T00:00:03Z"}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"git status"}}]},"uuid":"c4"}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t2","is_error":true,"content":"Exit code 127\nfoo-tail-xyz"}]},"uuid":"c5"}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t3","name":"Bash","input":{"command":"rm x"}}]},"uuid":"c6"}'
  printf '%s\n' '{"type":"user","message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t3","is_error":true,"content":"PreToolUse:Bash hook error: blocked by bash-guard"}]},"uuid":"c7"}'
  printf '%s\n' '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"mid-task-dup"},"uuid":"c8","timestamp":"2026-01-01T00:00:08Z"}'
  printf '%s\n' '{"type":"attachment","attachment":{"type":"queued_command","prompt":"mid-task-dup","origin":{"kind":"human"},"commandMode":"prompt"},"uuid":"c9"}'
  printf '%s\n' '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t4","name":"Bash","input":{"command":"echo \"<<WORKFLOW_NEXT_STEP_PAUSE: x>>\""}}]},"uuid":"c10"}'
  printf '%s\n' '{broken json line'
} > "$RC_T"
RC_OUT="$SCI_TMP/ctx-out.txt"
sci_run "$(np "$RC_OUT")" --mode alert --sid rcsid --wsid UNAVAILABLE --transcript "$(np "$RC_T")"
sci_eq "ctx render exits 0 despite an unparsable line" "$SCI_RC" "0"
RC_U="$(sci_block "$RC_OUT" "USER UTTERANCES")"
RC_A="$(sci_block "$RC_OUT" "ACTIONS SINCE PREVIOUS ALERT RUN")"
RC_H="$(sci_header "$RC_OUT")"
sci_has "U-ask-answer: tool_result paired with AskUserQuestion is an utterance" "$RC_U" "The user answered: B"
sci_has "U-human: start work kept" "$RC_U" "start work"
sci_eq "queued dedup: identical U-queued body listed once" "$(printf '%s\n' "$RC_U" | grep -c -F 'mid-task-dup')" "1"
sci_has "A-bash: cmd line" "$RC_A" "cmd: git status"
sci_has "A-cmd-error: first line of the error annotates the command" "$RC_A" "error: Exit code 127"
sci_lacks "A-cmd-error: only the first line of the error" "$RC_A" "foo-tail-xyz"
sci_has "A-hook-deny: full hook error text" "$RC_A" "hook-block: PreToolUse:Bash hook error: blocked by bash-guard"
sci_lacks "A-hook-deny wins over A-cmd-error" "$RC_A" "error: PreToolUse"
sci_has "Bash with sentinel: A-bash record" "$RC_A" 'cmd: echo "<<WORKFLOW_NEXT_STEP_PAUSE: x>>"'
sci_has "Bash with sentinel: A-sentinel record" "$RC_A" "sentinel: <<WORKFLOW_NEXT_STEP_PAUSE: x>>"
sci_lacks "AskUserQuestion tool_use itself is not an action" "$RC_A" "AskUserQuestion"
sci_match "header counts skipped_unparsable = 1" "$RC_H" 'skipped_unparsable[^0-9]{0,3}1([^0-9]|$)'
