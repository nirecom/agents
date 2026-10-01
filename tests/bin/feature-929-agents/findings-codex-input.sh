# findings-codex-input.sh — fragment of tests/bin/feature-929-agents.sh (no frontmatter).
# #2475 engine integration (plan Step 15): assembled input, env-leak regression,
#   cursor advance on SUCCESS only, per-mode cursor, input limit + FAILED reason line,
#   plan artifact scope. Codex and gh are mocks; the missing-transcript assembly
#   failure (reason: input assembly failed) lives in findings-codex-status.sh.
# NOTE: RED until write-code wires hooks/lib/supervisor-codex-input.js into
#   bin/supervisor-findings-codex.
# TL3 gap: a real codex CLI (latency, genuine exit codes, 1 MiB stdin) is not exercised.

# Save the process-wide state this fragment changes; restored at the end.
_FCI_OLD_PWD="$PWD"
_FCI_OLD_HOME="${HOME-}"
_FCI_OLD_NO_LOG="${NO_LOG-__unset__}"
_FCI_OLD_ACD="${AGENTS_CONFIG_DIR-__unset__}"
_FCI_OLD_PROMPT="${PROMPT-__unset__}"
_fci_restore() { # <var> <saved>
    if [ "$2" = "__unset__" ]; then unset "$1"; else export "$1=$2"; fi
}

FC_TMP="$TMPDIR_BASE/findings-codex-input"
mkdir -p "$FC_TMP/home" "$FC_TMP/proj" "$FC_TMP/mock"
export HOME="$FC_TMP/home"
export NO_LOG=true
export AGENTS_CONFIG_DIR="$AGENTS_DIR"
unset PROMPT 2>/dev/null || true
PLANS="$WORKFLOW_PLANS_DIR"
cd "$FC_TMP" || exit 1

printf '%s\n' '#!/bin/bash' \
    'cat > "${CODEX_PROMPT_CAPTURE:-/dev/null}"' \
    'env > "${CODEX_ENV_CAPTURE:-/dev/null}"' \
    ': > "${MOCK_CALLED:-/dev/null}"' \
    'if [ "${MOCK_BAD:-0}" = 1 ]; then echo "not json"; exit 0; fi' \
    'if [ "${MOCK_AUDIT:-0}" = 1 ]; then printf "%s\n" "{\"verdict\":\"CONTINUE\",\"summary\":\"stub audit verdict\"}"; fi' \
    'printf "%s\n" "{\"categories\":[\"workflow\"],\"severity\":\"notice\",\"detail\":\"stub finding\"}"' \
    > "$FC_TMP/mock/codex"
printf '%s\n' '#!/bin/bash' 'echo "${GH_MOCK_STATE:-OPEN}"' > "$FC_TMP/mock/gh"
chmod +x "$FC_TMP/mock/codex" "$FC_TMP/mock/gh"
FC_MOCK_DIR="$FC_TMP/mock"
if command -v cygpath >/dev/null 2>&1; then FC_MOCK_DIR="$(cygpath -u "$FC_MOCK_DIR")"; fi
FC_PRESENT_PATH="$FC_MOCK_DIR:$PATH"
FC_ABSENT_PATH="$(codex_absent_path)"

export CODEX_PROMPT_CAPTURE="$FC_TMP/prompt.txt"
export CODEX_ENV_CAPTURE="$FC_TMP/env.txt"
export MOCK_CALLED="$FC_TMP/mock-called"

# fc_run <mode> <sid> <wsid> <transcript> [extra...] — sets FC_OUT (stdout); codex mock present.
fc_run() {
    local mode="$1" sid="$2" wsid="$3" tf="$4" audit=0
    shift 4
    [ "$mode" = audit ] && audit=1
    rm -f "$CODEX_PROMPT_CAPTURE" "$CODEX_ENV_CAPTURE" "$MOCK_CALLED"
    FC_OUT="$(MOCK_AUDIT=$audit PATH="${FC_PATH:-$FC_PRESENT_PATH}" run_with_timeout 120 bash "$FINDINGS_CLI" --mode "$mode" --sid "$sid" --wsid "$wsid" --transcript "$tf" "$@" 2>"$FC_TMP/stderr.txt")"
}
fc_prompt() { cat "$CODEX_PROMPT_CAPTURE" 2>/dev/null; }
fc_block() { # <NAME> — block of the captured prompt
    awk -v s="[$1 START]" -v e="[$1 END]" '$0==s{f=1;next} $0==e{f=0} f' "$CODEX_PROMPT_CAPTURE" 2>/dev/null
}
fc_cursor() { # <sid> <mode> — <mode>.transcript_cursor.line, or null / nostate
    node -e 'const fs=require("fs");try{const s=JSON.parse(fs.readFileSync(process.argv[1],"utf8"));const c=(s[process.argv[2]]||{}).transcript_cursor;process.stdout.write(c==null?"null":String(c.line));}catch(e){process.stdout.write("nostate");}' "$(to_node_path "$PLANS/$1-supervisor-state.json")" "$2"
}
fc_first() { printf '%s\n' "${FC_OUT%%$'\n'*}"; }
fc_reason() { printf '%s\n' "$FC_OUT" | grep '^reason:' | head -n 1; }
fc_human() { printf '{"type":"user","origin":{"kind":"human"},"message":{"role":"user","content":"%s"},"uuid":"%s","timestamp":"2026-01-01T00:00:00Z"}\n' "$1" "$2"; }
fc_bash() { printf '{"type":"assistant","message":{"role":"assistant","content":[{"type":"tool_use","id":"t-%s","name":"Bash","input":{"command":"%s"}}]},"uuid":"%s"}\n' "$2" "$1" "$2"; }

echo "--- findings-codex-input: env-leak regression ---"
FC_T1="$FC_TMP/proj/envleak.jsonl"
fc_human "env-leak-sentinel-omega" e1 > "$FC_T1"
export PROMPT=orig-prompt
fc_run alert fcenv UNAVAILABLE "$(to_node_path "$FC_T1")"
unset PROMPT
assert_eq "fci env-leak: STATUS: SUCCESS" "STATUS: SUCCESS" "$(fc_first)"
assert_not_contains "fci env-leak: codex child env lacks the prompt sentinel" "$(cat "$CODEX_ENV_CAPTURE" 2>/dev/null)" "env-leak-sentinel-omega"
if grep -qx 'PROMPT=orig-prompt' "$CODEX_ENV_CAPTURE" 2>/dev/null; then pass "fci env-leak: inherited PROMPT reaches codex unchanged"
else fail "fci env-leak: inherited PROMPT reaches codex unchanged — PROMPT line: $(grep '^PROMPT=' "$CODEX_ENV_CAPTURE" 2>/dev/null | head -c 200)"; fi
assert_contains "fci env-leak: prompt (stdin) carries the sentinel" "$(fc_prompt)" "env-leak-sentinel-omega"

echo "--- findings-codex-input: cursor advances on SUCCESS only ---"
FC_T2="$FC_TMP/proj/cursor.jsonl"
{ fc_human "cursor-utter-one" u1; fc_bash "echo cursor-one" u2; fc_human "cursor-utter-two" u3; } > "$FC_T2"
FC_T2N="$(to_node_path "$FC_T2")"
fc_run alert fccur fccur "$FC_T2N"
assert_eq "fci run1: STATUS: SUCCESS" "STATUS: SUCCESS" "$(fc_first)"
assert_contains "fci run1: CURSOR: advanced" "$FC_OUT" "CURSOR: advanced"
assert_eq "fci run1: alert cursor line 3" "3" "$(fc_cursor fccur alert)"
assert_contains "fci run1: prompt header cursor: fresh" "$(fc_prompt)" "cursor: fresh"
assert_contains "fci run1: ACTIONS has L2 cmd" "$(fc_block "ACTIONS SINCE PREVIOUS ALERT RUN")" "cmd: echo cursor-one"
assert_not_contains "fci run1: legacy [TRANSCRIPT START] block gone" "$(fc_prompt)" "[TRANSCRIPT START]"
fc_bash "echo cursor-four" u4 >> "$FC_T2"
fc_run alert fccur fccur "$FC_T2N"
assert_contains "fci run2: prompt header cursor: resume" "$(fc_prompt)" "cursor: resume"
FC_A="$(fc_block "ACTIONS SINCE PREVIOUS ALERT RUN")"
assert_contains "fci run2: ACTIONS has only the new L4" "$FC_A" "cmd: echo cursor-four"
assert_not_contains "fci run2: ACTIONS drop pre-cursor L2" "$FC_A" "cmd: echo cursor-one"
assert_contains "fci run2: USER UTTERANCES keep L1" "$(fc_block "USER UTTERANCES")" "cursor-utter-one"
assert_eq "fci run2: alert cursor line 4" "4" "$(fc_cursor fccur alert)"
MOCK_BAD=1 fc_run alert fccur fccur "$FC_T2N"
assert_eq "fci bad output: STATUS: FAILED" "STATUS: FAILED" "$(fc_first)"
FC_REASON="$(fc_reason)"
case "$FC_REASON" in
    "reason: "?*) pass "fci bad output: non-empty reason: line" ;;
    *) fail "fci bad output: non-empty reason: line — got: $(printf '%.300s' "$FC_OUT")" ;;
esac
if printf '%s\n' "$FC_OUT" | grep -q '^## .*: FAILED'; then fail "fci bad output: raw codex FAILED line not echoed — got: $(printf '%.300s' "$FC_OUT")"
else pass "fci bad output: raw codex FAILED line not echoed"; fi
assert_not_contains "fci bad output: no CURSOR: advanced" "$FC_OUT" "CURSOR: advanced"
assert_eq "fci bad output: cursor stays 4" "4" "$(fc_cursor fccur alert)"
FC_PATH="$FC_ABSENT_PATH" fc_run alert fccur fccur "$FC_T2N"
assert_eq "fci codex absent: STATUS: SKIPPED" "STATUS: SKIPPED" "$(fc_first)"
assert_eq "fci codex absent: cursor stays 4" "4" "$(fc_cursor fccur alert)"

echo "--- findings-codex-input: per-mode cursor ---"
fc_run audit fccur fccur "$FC_T2N"
assert_eq "fci audit after alert runs: STATUS: SUCCESS" "STATUS: SUCCESS" "$(fc_first)"
assert_contains "fci audit: own cursor fresh" "$(fc_prompt)" "cursor: fresh"
assert_contains "fci audit: ACTIONS from L1" "$(fc_block "ACTIONS SINCE PREVIOUS AUDIT RUN")" "cmd: echo cursor-one"
assert_eq "fci audit: audit cursor line 4" "4" "$(fc_cursor fccur audit)"
assert_eq "fci audit: alert cursor untouched" "4" "$(fc_cursor fccur alert)"

echo "--- findings-codex-input: input limit ---"
FC_T4="$FC_TMP/proj/big.jsonl"
node -e 'const fs=require("fs");fs.writeFileSync(process.argv[1],JSON.stringify({type:"user",origin:{kind:"human"},message:{role:"user",content:"a".repeat(1048577)},uuid:"b1",timestamp:"2026-01-01T00:00:00Z"})+"\n");' "$(to_node_path "$FC_T4")"
fc_run alert fcbig UNAVAILABLE "$(to_node_path "$FC_T4")"
assert_eq "fci over limit: STATUS: FAILED" "STATUS: FAILED" "$(fc_first)"
FC_REASON="$(fc_reason)"
if printf '%s\n' "$FC_REASON" | grep -Eq '^reason: input too large: [0-9]+ chars > limit 1048576$'; then
    pass "fci over limit: reason: input too large: <N> chars > limit 1048576"
else
    fail "fci over limit: reason: input too large: <N> chars > limit 1048576 — got: $(printf '%.300s' "$FC_REASON")"
fi
if [ -e "$MOCK_CALLED" ]; then fail "fci over limit: codex mock not invoked"; else pass "fci over limit: codex mock not invoked"; fi
case "$(fc_cursor fcbig alert)" in
    null|nostate) pass "fci over limit: cursor not written" ;;
    *) fail "fci over limit: cursor not written — got $(fc_cursor fcbig alert)" ;;
esac

echo "--- findings-codex-input: plan artifact scope ---"
FC_T6="$FC_TMP/proj/plans.jsonl"
fc_human "plan-scope-utter" p1 > "$FC_T6"
FC_T6N="$(to_node_path "$FC_T6")"
printf '%s\n' "# intent" "intent-art-body" > "$PLANS/wsP-intent.md"
printf '%s\n' "# outline" "outline-art-body" > "$PLANS/wsP-outline.md"
printf '%s\n' "# detail" "detail-art-body" > "$PLANS/wsP-detail.md"
fc_run alert fcplan wsP "$FC_T6N"
FC_P="$(fc_block "PLAN ARTIFACTS")"
assert_contains "fci active alert: intent" "$FC_P" "intent-art-body"
assert_contains "fci active alert: outline" "$FC_P" "outline-art-body"
assert_contains "fci active alert: detail" "$FC_P" "detail-art-body"
printf '%s\n' "# intent" "" "## Issues" "- #1" "" "intent-art-body" > "$PLANS/wsP-intent.md"
GH_MOCK_STATE=CLOSED fc_run alert fcplan wsP "$FC_T6N"
FC_P="$(fc_block "PLAN ARTIFACTS")"
assert_contains "fci terminated alert: intent kept" "$FC_P" "intent-art-body"
assert_not_contains "fci terminated alert: outline excluded" "$FC_P" "outline-art-body"
assert_not_contains "fci terminated alert: detail excluded" "$FC_P" "detail-art-body"
GH_MOCK_STATE=CLOSED fc_run audit fcplan wsP "$FC_T6N"
FC_P="$(fc_block "PLAN ARTIFACTS")"
assert_contains "fci terminated audit: intent" "$FC_P" "intent-art-body"
assert_contains "fci terminated audit: outline" "$FC_P" "outline-art-body"
assert_contains "fci terminated audit: detail" "$FC_P" "detail-art-body"
fc_run alert fcplan UNAVAILABLE "$FC_T6N" --artifact "$(to_node_path "$PLANS/wsP-intent.md")"
assert_eq "fci UNAVAILABLE: PLAN ARTIFACTS (none)" "(none)" "$(fc_block "PLAN ARTIFACTS" | tr -d '[:space:]')"
assert_not_contains "fci UNAVAILABLE: --artifact not embedded" "$(fc_prompt)" "intent-art-body"

echo "--- findings-codex-input: assembly failure reason line ---"
# A lib-copy AGENTS_CONFIG_DIR whose assembler is absent / throws / fails plainly.
# node's uncaught-exception stderr starts with a stack location, not the message,
# so the reason must come from the first ^[A-Za-z]*Error: line (fallback: line 1).
FCA_DIR="$FC_TMP/asm-cfg"
mkdir -p "$FCA_DIR/bin" "$FCA_DIR/hooks/lib"
cp -r "$AGENTS_DIR/bin/lib" "$FCA_DIR/bin/lib"
FCA_T="$FC_TMP/proj/asm.jsonl"
fc_human "asm-utter" a1 > "$FCA_T"
FCA_TN="$(to_node_path "$FCA_T")"
fca_assert_error_reason() { # <label>
    assert_eq "fci asm $1: STATUS: FAILED" "STATUS: FAILED" "$(fc_first)"
    FC_REASON="$(fc_reason)"
    assert_contains "fci asm $1: reason carries the Error: message" "$FC_REASON" "Error:"
    case "$FC_REASON" in
        "reason: input assembly failed: node:"*) fail "fci asm $1: reason is not node's stack location — got: $FC_REASON" ;;
        "") fail "fci asm $1: reason is not node's stack location — no reason: line" ;;
        *) pass "fci asm $1: reason is not node's stack location" ;;
    esac
}
rm -f "$FCA_DIR/hooks/lib/supervisor-codex-input.js"
AGENTS_CONFIG_DIR="$FCA_DIR" fc_run alert fcasm UNAVAILABLE "$FCA_TN"
fca_assert_error_reason "module absent"
assert_contains "fci asm module absent: reason names Cannot find module" "$(fc_reason)" "Error: Cannot find module"
printf '%s\n' "'use strict';" "const o = null;" "o.boom;" > "$FCA_DIR/hooks/lib/supervisor-codex-input.js"
AGENTS_CONFIG_DIR="$FCA_DIR" fc_run alert fcasm UNAVAILABLE "$FCA_TN"
fca_assert_error_reason "module throws"
assert_contains "fci asm module throws: reason names the TypeError" "$(fc_reason)" "TypeError:"
printf '%s\n' "process.stderr.write('asm-plain-failure-one\\nasm-plain-failure-two\\n');" "process.exit(3);" > "$FCA_DIR/hooks/lib/supervisor-codex-input.js"
AGENTS_CONFIG_DIR="$FCA_DIR" fc_run alert fcasm UNAVAILABLE "$FCA_TN"
assert_eq "fci asm no Error: line: STATUS: FAILED" "STATUS: FAILED" "$(fc_first)"
assert_eq "fci asm no Error: line: reason falls back to stderr line 1" "reason: input assembly failed: asm-plain-failure-one" "$(fc_reason)"
if [ -e "$MOCK_CALLED" ]; then fail "fci asm: codex mock not invoked after assembly failure"; else pass "fci asm: codex mock not invoked after assembly failure"; fi

# Restore process-wide state for later fragments.
unset CODEX_PROMPT_CAPTURE CODEX_ENV_CAPTURE MOCK_CALLED
export HOME="$_FCI_OLD_HOME"
_fci_restore NO_LOG "$_FCI_OLD_NO_LOG"
_fci_restore AGENTS_CONFIG_DIR "$_FCI_OLD_ACD"
_fci_restore PROMPT "$_FCI_OLD_PROMPT"
cd "$_FCI_OLD_PWD" || true
