#!/usr/bin/env bash
# Tests: hooks/block-subagent-sentinels.js, hooks/lib/workflow-driver-commands.js, hooks/lib/tool-command-text.js, hooks/lib/subagent-detect.js, hooks/workflow-state/record-step-verdict.js
# Tags: tl2, hook, pretooluse, subagent, guard, classifier, door-parity, scope:issue-specific, pwsh-not-required

# INV-4 + C1 (#2102): once a completion door is a CLI call rather than a sentinel echo,
# the subagent backstop must recognise the CLI form too -- and across all three
# command-executing tools, element-wise, because sentinel-patterns anchors ^...$ without
# the `m` flag so commands[1] can never match the joined text.

# TL3 gap (what this test does NOT catch): whether the PreToolUse chain actually reaches
# this hook before the approval dialog in a live subagent call, and hook registration
# order. Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight,
# bin/check-verification-gate.sh category: skill-orchestration.

set -uo pipefail

command -v node >/dev/null 2>&1 || { echo "SKIP: node not available"; exit 77; }

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
nrm() { cygpath -m "$1" 2>/dev/null || echo "$1"; }
AGENTS_DIR_N="$(nrm "$AGENTS_DIR")"
HOOK="$AGENTS_DIR_N/hooks/block-subagent-sentinels.js"
DRIVER_MOD="$AGENTS_DIR_N/hooks/lib/workflow-driver-commands.js"; export DRIVER_MOD
RSV_MOD="$AGENTS_DIR_N/hooks/workflow-state/record-step-verdict.js"; export RSV_MOD
WFSTATE_MODULE="$AGENTS_DIR_N/hooks/workflow-state"; export WFSTATE_MODULE

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
check() { if [ "$3" = "$2" ]; then pass "$1"; else fail "$1 -- expected [$2] got [$3]"; fi; }
check_not_contains() {
  case "$3" in *"$2"*) fail "$1 -- did NOT expect [$2] in: $3" ;; *) pass "$1" ;; esac
}
run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}

# Step names and advance-class CLI names come from the modules that own them, never
# retyped: a rename must break this file loudly rather than leave it testing a ghost.
STEP="$(run_with_timeout node -e '
  const wf = require(process.env.WFSTATE_MODULE);
  process.stdout.write(wf.VALID_STEPS[2]);' 2>/dev/null || echo "STEP_LOOKUP_FAILED")"
ADVANCE_CLIS="$(run_with_timeout node -e '
  const m = require(process.env.RSV_MOD);
  process.stdout.write(Object.keys(m.ADVANCE_ORIGINS || {}).join(" "));' 2>/dev/null || echo "")"
check "M0a: the step name resolved from VALID_STEPS" "research" "$STEP"
check "M0b: ADVANCE_ORIGINS still names four advance-class CLIs" 4 "$(printf '%s' "$ADVANCE_CLIS" | wc -w | tr -d ' ')"

# Block-reason strings come from the hook module itself (CPR-SSOT), never retyped:
# assert_payload proves WHICH door tripped, not merely that some door tripped.
BLOCK_MSGS="$(HOOK_MOD="$HOOK" run_with_timeout node -e '
  const m = require(process.env.HOOK_MOD);
  process.stdout.write(m.BLOCK_MESSAGE + "\x01" + m.DRIVER_BLOCK_MESSAGE);' 2>/dev/null || echo $'\x01')"
IFS=$'\x01' read -r SENTINEL_BLOCK_MSG DRIVER_BLOCK_MSG <<< "$BLOCK_MSGS"
check "M0c: BLOCK_MESSAGE resolved from the hook module" true "$([ -n "$SENTINEL_BLOCK_MSG" ] && echo true || echo false)"
check "M0d: DRIVER_BLOCK_MESSAGE resolved from the hook module" true "$([ -n "$DRIVER_BLOCK_MSG" ] && echo true || echo false)"

SENTINEL_CMD="echo \"<<WORKFLOW_MARK_STEP_${STEP}_complete>>\""
ADVANCE_CMD="node \"\$AGENTS_CONFIG_DIR/bin/workflow/next-step\" --session \"\$SESSION_ID\" --advance --step ${STEP} --complete --next"
PLAIN_CMD="node \"\$AGENTS_CONFIG_DIR/bin/workflow/next-step\" --session \"\$SESSION_ID\""
FACTS_CMD="node \"\$AGENTS_CONFIG_DIR/bin/workflow/read-session-facts\" --session \"\$SESSION_ID\""

# Sets DECISION / DECISION_COUNT / RAW_RC / RAW_OUT / RAW_ERR as globals rather than
# printing the verdict: a $(...) capture runs in a subshell, so the hook's real exit
# status and stderr -- the evidence that it did not crash right after emitting a valid
# decision -- would be discarded before any assertion could see them.
DECISION=""; DECISION_COUNT=0; RAW_RC=0; RAW_OUT=""; RAW_ERR=""; REASON=""
NODE_STACK_MARK="    at "
decide() {
  local json="$1" f="$TMPDIR_BASE/in.json" ef="$TMPDIR_BASE/in.err" parsed
  printf '%s' "$json" > "$f"
  RAW_RC=0
  RAW_OUT="$(run_with_timeout node "$HOOK" < "$f" 2>"$ef")" || RAW_RC=$?
  RAW_ERR="$(cat "$ef" 2>/dev/null || echo "")"
  parsed="$(CMD_JSON="$RAW_OUT" run_with_timeout node -e '
    const raw = process.env.CMD_JSON || "";
    const objs = [];
    const push = (t) => {
      try { const o = JSON.parse(t); if (o && typeof o === "object" && "decision" in o) objs.push(o); }
      catch (e) {}
    };
    push(raw);
    if (!objs.length) raw.split("\n").filter((l) => l.trim()).forEach(push);
    const one = objs.length === 1 ? objs[0] : null;
    const decision = one ? String(one.decision || "") : "PARSE_FAIL";
    const reason = one && typeof one.reason === "string" ? one.reason : "";
    process.stdout.write(objs.length + "\x01" + decision + "\x01" + reason);' 2>/dev/null || echo $'0\x01PARSE_FAIL\x01')"
  IFS=$'\x01' read -r DECISION_COUNT DECISION REASON <<< "$parsed"
}
mk_json() {
  TOOL="$1" CMD="$2" AGENT="${3:-}" run_with_timeout node -e '
    const tool = process.env.TOOL, cmd = process.env.CMD, agent = process.env.AGENT;
    const input = { tool_name: tool, session_id: "s1" };
    input.tool_input = tool === "runCommands" ? { commands: [cmd] } : { command: cmd };
    if (agent) input.agent_id = agent;
    process.stdout.write(JSON.stringify(input));'
}
# Four assertions per cell, not one: the verdict is only trustworthy if the process that
# produced it exited cleanly, said it exactly once, and left no stack trace behind.
assert_payload() {
  local id="$1" json="$2" want="$3"
  decide "$json"
  check "$id" "$want" "$DECISION"
  check "$id [exits 0]" 0 "$RAW_RC"
  check "$id [exactly one decision object]" 1 "$DECISION_COUNT"
  check_not_contains "$id [no stack trace]" "$NODE_STACK_MARK" "$RAW_OUT$RAW_ERR"
  # A block decision alone does not prove WHICH door tripped -- a driver-command
  # payload that happened to hit the sentinel branch would still read "block".
  # Pin the reason string to the door the payload actually targets.
  if [ "$want" = "block" ]; then
    case "$json" in
      *WORKFLOW_MARK_STEP*) check "$id [reason: sentinel door]" "$SENTINEL_BLOCK_MSG" "$REASON" ;;
      *) check "$id [reason: driver door]" "$DRIVER_BLOCK_MSG" "$REASON" ;;
    esac
  fi
}
assert_cell() {
  local id="$1" tool="$2" cmd="$3" agent="$4" want="$5"
  assert_payload "$id" "$(mk_json "$tool" "$cmd" "$agent")" "$want"
}

echo "=== G1: the 12-cell matrix -- tool x door x subagent ==="
# agent_id present: every tool, every door, blocked. agent_id absent: the same twelve
# inputs approved, because the orchestrator owns both doors (classifier symmetry).
for tool in Bash runInTerminal runCommands; do
  assert_cell "G1: $tool + sentinel door + subagent -> block" "$tool" "$SENTINEL_CMD" a1 block
  assert_cell "G1: $tool + advance CLI door + subagent -> block" "$tool" "$ADVANCE_CMD" a1 block
done
for tool in Bash runInTerminal runCommands; do
  assert_cell "G1: $tool + sentinel door + main conversation -> approve" "$tool" "$SENTINEL_CMD" "" approve
  assert_cell "G1: $tool + advance CLI door + main conversation -> approve" "$tool" "$ADVANCE_CMD" "" approve
done

echo ""
echo "=== G2: runCommands is adjudicated ELEMENT-WISE, not on the joined text ==="
mk_commands_json() {
  CMDS="$1" AGENT="${2:-}" run_with_timeout node -e '
    const input = { tool_name: "runCommands", session_id: "s1",
                    tool_input: { commands: JSON.parse(process.env.CMDS) } };
    if (process.env.AGENT) input.agent_id = process.env.AGENT;
    process.stdout.write(JSON.stringify(input));'
}
C0="$(CMDS_A="$SENTINEL_CMD" run_with_timeout node -e 'process.stdout.write(JSON.stringify([process.env.CMDS_A, "git status"]))')"
C1="$(CMDS_A="$SENTINEL_CMD" run_with_timeout node -e 'process.stdout.write(JSON.stringify(["git status", process.env.CMDS_A]))')"
C1ADV="$(CMDS_A="$ADVANCE_CMD" run_with_timeout node -e 'process.stdout.write(JSON.stringify(["git status", process.env.CMDS_A]))')"
assert_payload "G2a: target in commands[0] -> block" "$(mk_commands_json "$C0" a1)" block
# The crux. Before this fix: approve (the joined "git status\n<sentinel>" cannot match an
# ^...$ pattern without the m flag). After this fix: block.
assert_payload "G2b: target in commands[1] (non-first element) -> block" "$(mk_commands_json "$C1" a1)" block
assert_payload "G2c: advance CLI call in commands[1] -> block" "$(mk_commands_json "$C1ADV" a1)" block
assert_payload "G2d: commands[1] target from the main conversation -> approve" "$(mk_commands_json "$C1" "")" approve
# A `commands` payload that is neither an array nor a command string degrades to a
# non-matching String() rather than throwing: the hook stays fail-open.
NOTARR="$(run_with_timeout node -e 'process.stdout.write(JSON.stringify({tool_name:"runCommands",session_id:"s1",agent_id:"a1",tool_input:{commands:{0:"echo \"<<WORKFLOW_MARK_STEP_research_complete>>\""}}}))')"
assert_payload "G2e: commands is not an array -> approve (fail-open)" "$NOTARR" approve

echo ""
echo "=== G3: runInTerminal reads tool_input.command, one cell per door ==="
# Before this fix runInTerminal was never inspected at all (the hook narrowed on
# tool_name === "Bash"), so both of these were approve.
assert_cell "G3a: runInTerminal + sentinel door + subagent -> block" runInTerminal "$SENTINEL_CMD" a1 block
assert_cell "G3b: runInTerminal + advance CLI door + subagent -> block" runInTerminal "$ADVANCE_CMD" a1 block

echo ""
echo "=== G4: every advance-class CLI is covered (CPR-ORTH over ADVANCE_ORIGINS) ==="
for cli in $ADVANCE_CLIS; do
  assert_cell "G4: $cli --advance from a subagent -> block" Bash \
    "node \"\$AGENTS_CONFIG_DIR/bin/workflow/$cli\" --session \"\$SESSION_ID\" --advance --step ${STEP} --complete" \
    a1 block
done

echo ""
echo "=== G5: non-vacuity -- read-only workflow commands still pass ==="
# Without these the guard could be a blanket ban on the word "workflow" and G1/G4 would
# stay green while every read-only helper became unusable inside a subagent.
assert_cell "G5a: next-step WITHOUT --advance from a subagent -> approve" Bash "$PLAIN_CMD" a1 approve
assert_cell "G5b: read-session-facts from a subagent -> approve" Bash "$FACTS_CMD" a1 approve
assert_cell "G5c: read-session-facts via runCommands from a subagent -> approve" runCommands "$FACTS_CMD" a1 approve
assert_cell "G5d: an ordinary command from a subagent -> approve" Bash "git status" a1 approve
assert_cell "G5e: a non-command tool + subagent + sentinel text -> approve" Edit "$SENTINEL_CMD" a1 approve
assert_cell "G5f: empty command + subagent -> approve" Bash "" a1 approve

echo ""
echo "=== G6: isWorkflowStateDriverCommand contract (hooks/lib/workflow-driver-commands.js) ==="
# The hook's new predicate gets its own table so a decision regression is separable
# from a detector regression (CPR-SC).
driver_says() {
  CMD="$1" run_with_timeout node -e '
    try {
      const { isWorkflowStateDriverCommand } = require(process.env.DRIVER_MOD);
      process.stdout.write(String(isWorkflowStateDriverCommand(process.env.CMD) === true));
    } catch (e) { process.stdout.write("MODULE_LOAD_FAILED"); }' 2>/dev/null || echo "MODULE_LOAD_FAILED"
}
check "G6a: the migrated next-step advance call is a driver command" true "$(driver_says "$ADVANCE_CMD")"
check "G6b: a record-complexity-and-skip advance call is a driver command" true \
  "$(driver_says "bash \"\$AGENTS_CONFIG_DIR/bin/workflow/record-complexity-and-skip\" --session s1 --signals \"\" --target outline --advance")"
check "G6c: next-step without --advance is not" false "$(driver_says "$PLAIN_CMD")"
check "G6d: read-session-facts is not" false "$(driver_says "$FACTS_CMD")"
check "G6e: an ordinary command is not" false "$(driver_says "git status")"
check "G6f: the empty string is not" false "$(driver_says "")"
# The word alone must not be enough, or G5 would be luck rather than design.
check "G6g: the bare word advance is not" false "$(driver_says "echo advance")"
# MUTATING_FLAGS lists --advance, --mark and --reset (bin/workflow/lib/next-step/advance-args.js);
# a roster that shrinks to --advance alone would still pass every case above.
check "G6h: a next-step --mark call is a driver command" true \
  "$(driver_says "node \"\$AGENTS_CONFIG_DIR/bin/workflow/next-step\" --session s1 --mark ${STEP}")"
check "G6i: a next-step --reset call is a driver command" true \
  "$(driver_says "node \"\$AGENTS_CONFIG_DIR/bin/workflow/next-step\" --session s1 --reset --step ${STEP}")"

echo ""
echo "=== G7: adversarial command shapes -- detector AND decision, block half and allow half ==="
# A guard that reads only the first token, or only an unquoted `--advance`, is bypassable
# by shapes a subagent can type freely. Every row is driven twice: through the detector
# (isWorkflowStateDriverCommand) and through the hook itself from a subagent, so a
# detector that is right while the decision is wrong cannot hide. Step names come from
# $STEP, pinned to VALID_STEPS[2] by M0a.
# Field order is want|id|command, not command-last-but-one: with IFS='|' the FINAL read
# variable takes the rest of the line verbatim, which is the only way a row whose command
# contains `||` or a pipe survives field splitting intact.
while IFS='|' read -r rwant rid rcmd; do
  [ -n "$rid" ] || continue
  case "$rwant" in \#*) continue ;; esac
  check "G7 $rid: detector" "$rwant" "$(driver_says "$rcmd")"
  if [ "$rwant" = "true" ]; then rdec=block; else rdec=approve; fi
  assert_cell "G7 $rid: subagent decision" Bash "$rcmd" a1 "$rdec"
done <<MATRIX
true|a1-chain-semicolon|git status; node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete
true|a2-chain-and|cd /tmp && node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete
true|a3-chain-or|false || node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete
false|a4-chain-readonly|git status; node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1
false|a5-piped-readonly|git status | grep node
true|b1-env-prefix|FOO=1 BAR=2 node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete
false|b2-env-prefix-readonly|FOO=1 node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1
true|c1-bash-c|bash -c 'node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete'
true|c2-sh-c|sh -c "node \$AGENTS_CONFIG_DIR/bin/workflow/next-step --session s1 --advance --step ${STEP} --complete"
false|c3-bash-c-readonly|bash -c 'node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1'
true|d1-double-quoted-flag|node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 "--advance" --step ${STEP} --complete
true|d2-single-quoted-flag|node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 '--advance' --step ${STEP} --complete
true|d3-escaped-flag|node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 \\-\\-advance --step ${STEP} --complete
false|d4-flag-inside-a-value|node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session "s1 --advance"
true|e1-advance-in-a-late-segment|echo start; git status && node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete; echo done
false|e2-late-segment-readonly|echo start; git status && cat README.md; echo done
true|f1-node-exe-lookalike|node.exe "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete
true|f2-absolute-interpreter|/usr/bin/node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete
false|f3-lookalike-readonly|node.exe "\$AGENTS_CONFIG_DIR/bin/workflow/read-session-facts" --session s1
false|g1-flag-as-echoed-data|echo "next-step --session s1 --advance --step ${STEP} --complete"
false|g2-flag-as-grep-pattern|grep -- --advance "\$AGENTS_CONFIG_DIR/install/settings-allow-commands.txt"
true|g3-data-then-real-call|printf '%s' "--advance"; node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --advance --step ${STEP} --complete
true|h1-mark-recovery-call|node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --mark ${STEP}
true|h2-reset-recovery-call|node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --reset --step ${STEP}
true|h3-mark-in-later-segment|git status && node "\$AGENTS_CONFIG_DIR/bin/workflow/next-step" --session s1 --mark ${STEP}
true|i1-pwsh-command|pwsh -Command "node \$AGENTS_CONFIG_DIR/bin/workflow/next-step --session s1 --advance --step ${STEP} --complete"
true|i2-powershell-c-lower|powershell -c "node \$AGENTS_CONFIG_DIR/bin/workflow/next-step --session s1 --advance --step ${STEP} --complete"
false|i3-pwsh-command-readonly|pwsh -Command "node \$AGENTS_CONFIG_DIR/bin/workflow/next-step --session s1"
true|j1-cmd-c|cmd /c "node \$AGENTS_CONFIG_DIR/bin/workflow/next-step --session s1 --advance --step ${STEP} --complete"
true|j2-cmd-k-upper|cmd /K "node \$AGENTS_CONFIG_DIR/bin/workflow/next-step --session s1 --advance --step ${STEP} --complete"
false|j3-cmd-c-readonly|cmd /c "node \$AGENTS_CONFIG_DIR/bin/workflow/read-session-facts --session s1"
true|k1-pwsh-flag-uppercase|pwsh -COMMAND "node \$AGENTS_CONFIG_DIR/bin/workflow/next-step --session s1 --advance --step ${STEP} --complete"
true|m1-windows-spaced-program-files-path|C:\Program Files\nodejs\node.exe C:\git\agents\bin\workflow\next-step --session s1 --advance --step ${STEP} --complete
false|m2-windows-spaced-program-files-path-readonly|C:\Program Files\nodejs\node.exe C:\git\agents\bin\workflow\next-step --session s1
MATRIX

echo ""
echo "=== Results ==="
echo "Total: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
