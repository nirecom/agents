#!/bin/bash
# tests/feature-2278-pretool-lang-gates/settings-cases.sh
# Tests: settings.json
# Tags: lang, hook, pretooluse, hook-registration, TL2, scope:issue-specific
# Sourced by ../feature-2278-pretool-lang-gates.sh — helpers come from there.
# SET-T1..T3: settings.json registers the two PreToolUse gates (matcher +
# command) and keeps the PostToolUse checkers as backstops.
# SET-T4..T5: the registration LINE itself is executed — the command literal is
# parsed out of settings.json (never hardcoded) and spawned through a shell so
# `$AGENTS_CONFIG_DIR` expands exactly as Claude Code's hook runner expands it,
# with a hook-runner-shaped payload on stdin.

echo ""
echo "=== SET: settings.json hook registration ==="

SETTINGS_JSON_NODE="$(cygpath -m "$SETTINGS_JSON" 2>/dev/null || echo "$SETTINGS_JSON")"

SET_EXPECTED_MATCHER='Write|Edit|MultiEdit|editFiles'

# settings_hook_exact <event> <script basename> <expected command literal>
# Prints "<entries matching>|<matchers>|<types>|<exact-command matches>" where the
# last field counts hook objects whose command string EQUALS the literal (the
# `$AGENTS_CONFIG_DIR` dollar sign is part of the literal, no shell expansion).
settings_hook_exact() {
    run_with_timeout 10 node -e '
const fs = require("fs");
const [file, event, script, expected] = process.argv.slice(1);
try {
  const s = JSON.parse(fs.readFileSync(file, "utf8"));
  const entries = (s.hooks && Array.isArray(s.hooks[event])) ? s.hooks[event] : [];
  const matchers = [], types = []; let exact = 0;
  for (const e of entries) {
    const cmds = Array.isArray(e.hooks) ? e.hooks : [];
    const hit = cmds.filter((h) => typeof h.command === "string" && h.command.includes(script));
    if (hit.length === 0) continue;
    matchers.push(e.matcher || "");
    for (const h of hit) { types.push(String(h.type)); if (h.command === expected) exact++; }
  }
  process.stdout.write(matchers.length + "|" + matchers.join(",") + "|" + types.join(",") + "|" + exact);
} catch (err) { process.stdout.write("ERROR: " + err.message); }
' "$SETTINGS_JSON_NODE" "$1" "$2" "$3" 2>/dev/null
}

# SET-T1 / SET-T2: exactly one PreToolUse entry each, 4-tool matcher, type
# "command", and the command string equal to the literal below.
for _gate in gate-plan-lang.js gate-worktree-notes-lang.js; do
    case "$_gate" in
        gate-plan-lang.js) _id="SET-T1" ;;
        *) _id="SET-T2" ;;
    esac
    _cmd='node "$AGENTS_CONFIG_DIR/hooks/'"$_gate"'"'
    _rep="$(settings_hook_exact PreToolUse "$_gate" "$_cmd")"
    if [ "$_rep" = "1|$SET_EXPECTED_MATCHER|command|1" ]; then
        pass "$_id: settings.json PreToolUse registers $_gate exactly once — matcher $SET_EXPECTED_MATCHER, type command, command == $_cmd"
    else
        fail "$_id: expected '1|$SET_EXPECTED_MATCHER|command|1' for $_gate (command literal $_cmd), got: '$_rep'"
    fi
done

# SET-T3: PostToolUse backstops remain registered
_set3_ok=1
_set3_report=""
for _chk in check-plan-lang.js check-worktree-notes-lang.js; do
    _cmd='node "$AGENTS_CONFIG_DIR/hooks/'"$_chk"'"'
    _rep="$(settings_hook_exact PostToolUse "$_chk" "$_cmd")"
    [ "$_rep" = "1|$SET_EXPECTED_MATCHER|command|1" ] || { _set3_ok=0; _set3_report+=" $_chk='$_rep'"; }
done
if [ "$_set3_ok" -eq 1 ]; then
    pass "SET-T3: PostToolUse still registers check-plan-lang.js and check-worktree-notes-lang.js exactly once (backstops kept, exact command)"
else
    fail "SET-T3: PostToolUse backstop missing:$_set3_report"
fi

# ── SET-T4/T5 (C6): execute the registration line, do not merely inspect it ──
# SET-T1..T3 read settings.json as data; PLG/WNG invoke the hook script by an
# absolute path this test file chose. Neither can fail when the registered
# command string itself is wrong (bad `$AGENTS_CONFIG_DIR` spelling, wrong
# script name, a matcher that does not select the write tools). These two cases
# close that seam: the matcher and the command come out of settings.json, the
# command is expanded by a shell exactly as the hook runner expands it, and the
# verdict is read off the hook's own stdout for a blocking AND a clean payload.

# settings_hook_command <event> <script> — the command literal of the single
# registered hook entry naming <script>; "" when it is not registered exactly once.
settings_hook_command() {
    run_with_timeout 10 node -e '
const fs = require("fs");
const [file, event, script] = process.argv.slice(1);
try {
  const s = JSON.parse(fs.readFileSync(file, "utf8"));
  const entries = (s.hooks && Array.isArray(s.hooks[event])) ? s.hooks[event] : [];
  const out = [];
  for (const e of entries) {
    for (const h of (Array.isArray(e.hooks) ? e.hooks : [])) {
      if (typeof h.command === "string" && h.command.includes(script)) out.push(h.command);
    }
  }
  process.stdout.write(out.length === 1 ? out[0] : "");
} catch (err) { process.stdout.write(""); }
' "$SETTINGS_JSON_NODE" "$1" "$2" 2>/dev/null
}

# settings_matcher_selects <event> <script> <tool_name> — "yes"/"no": does the
# registered matcher regex select <tool_name> when anchored as Claude Code anchors it?
settings_matcher_selects() {
    run_with_timeout 10 node -e '
const fs = require("fs");
const [file, event, script, tool] = process.argv.slice(1);
try {
  const s = JSON.parse(fs.readFileSync(file, "utf8"));
  const entries = (s.hooks && Array.isArray(s.hooks[event])) ? s.hooks[event] : [];
  const hit = entries.filter((e) => (Array.isArray(e.hooks) ? e.hooks : [])
    .some((h) => typeof h.command === "string" && h.command.includes(script)));
  const ok = hit.length === 1 && new RegExp("^(?:" + String(hit[0].matcher) + ")$").test(tool);
  process.stdout.write(ok ? "yes" : "no");
} catch (err) { process.stdout.write("no"); }
' "$SETTINGS_JSON_NODE" "$1" "$2" "$3" 2>/dev/null
}

# run_registered <event> <script> <payload> <cwd> [KEY=VAL ...]
# Spawns the settings.json command literal via `bash -c` with AGENTS_CONFIG_DIR
# pointed at the repo under test, so the registered `$AGENTS_CONFIG_DIR/hooks/...`
# spelling is what resolves the script. Policy keys are passed as real exports —
# hooks/lib/load-env.js lets a non-empty process.env win over .env, so the case
# controls the policy without writing into the repo's own .env.
# Sets GATE_STDOUT / GATE_RC / GATE_STDERR (same contract as run_gate).
run_registered() {
    local event="$1" script="$2" payload="$3" cwd="$4"; shift 4
    local cmd errf="$TEST_ROOT/registered-stderr.txt"
    cmd="$(settings_hook_command "$event" "$script")"
    GATE_STDERR_FILE="$errf"
    if [ -z "$cmd" ]; then
        GATE_STDOUT=""; GATE_RC=90
        GATE_STDERR="no unique $event registration for $script in settings.json"
        : > "$errf"
        return
    fi
    GATE_STDOUT="$(
        cd "$cwd" || exit 97
        unset PLAN_LANG DOCS_LANG_PUBLIC DOCS_LANG_PRIVATE
        unset DOCS_LANG_HISTORY_PUBLIC DOCS_LANG_HISTORY_PRIVATE
        unset DOCS_LANG_CHANGELOG_PUBLIC DOCS_LANG_CHANGELOG_PRIVATE
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDE_PROJECT_DIR
        export AGENTS_CONFIG_DIR="$AGENTS_DIR_NODE"
        for _kv in "$@"; do export "${_kv?}"; done
        printf '%s' "$payload" | run_with_timeout 20 bash -c "$cmd" 2>"$errf"
    )"
    GATE_RC=$?
    GATE_STDERR="$(grep -m1 -E 'Error|Cannot find|No such file' "$errf" 2>/dev/null || tail -n 1 "$errf" 2>/dev/null || true)"
}

# SET-T4: gate-plan-lang.js through its own registration line.
if [ "$(settings_matcher_selects PreToolUse gate-plan-lang.js Write)" = "yes" ] \
   && [ "$(settings_matcher_selects PreToolUse gate-plan-lang.js MultiEdit)" = "yes" ] \
   && [ "$(settings_matcher_selects PreToolUse gate-plan-lang.js Read)" = "no" ]; then
    pass "SET-T4a: the registered PreToolUse matcher selects Write and MultiEdit and not Read (anchored as Claude Code anchors it)"
else
    fail "SET-T4a: registered matcher does not select the write tools (or selects Read) for gate-plan-lang.js"
fi
run_registered PreToolUse gate-plan-lang.js "$(mk_payload Write "$INTENT_TS" content "$EN_PROSE")" "$NEUTRAL_CWD" PLAN_LANG=japanese
assert_block_prefix "SET-T4b: command spawned from settings.json, English Write to a plan artifact under PLAN_LANG=japanese → block" "$PLG_PREFIX_JA"
run_registered PreToolUse gate-plan-lang.js "$(mk_payload Write "$INTENT_TS" content "$JA_PROSE")" "$NEUTRAL_CWD" PLAN_LANG=japanese
assert_approve "SET-T4c: same registered command, compliant Japanese Write → approve (the registration line is not a blanket blocker)"

# SET-T5: gate-worktree-notes-lang.js through its own registration line.
if [ "$(settings_matcher_selects PreToolUse gate-worktree-notes-lang.js Edit)" = "yes" ] \
   && [ "$(settings_matcher_selects PreToolUse gate-worktree-notes-lang.js editFiles)" = "yes" ] \
   && [ "$(settings_matcher_selects PreToolUse gate-worktree-notes-lang.js Bash)" = "no" ]; then
    pass "SET-T5a: the registered PreToolUse matcher selects Edit and editFiles and not Bash"
else
    fail "SET-T5a: registered matcher does not select the write tools (or selects Bash) for gate-worktree-notes-lang.js"
fi
run_registered PreToolUse gate-worktree-notes-lang.js "$(mk_payload Write "$PRIV_NOTES" content "$DOC_HIST_EN")" "$PRIV_REPO" DOCS_LANG_PRIVATE=japanese
assert_block_prefix "SET-T5b: command spawned from settings.json, English History bullet in a private repo under DOCS_LANG_PRIVATE=japanese → block" "$WNG_PREFIX"
run_registered PreToolUse gate-worktree-notes-lang.js "$(mk_payload Write "$PRIV_NOTES" content "$DOC_HIST_JA")" "$PRIV_REPO" DOCS_LANG_PRIVATE=japanese
assert_approve "SET-T5c: same registered command, compliant Japanese History bullet → approve"
