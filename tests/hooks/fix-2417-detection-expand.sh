#!/usr/bin/env bash
# tests/hooks/fix-2417-detection-expand.sh
# Tests: hooks/lib/bash-write-targets/detection-expand.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/lib/bash-write-targets/cp-mv.js, hooks/lib/bash-write-targets/pwsh.js
# Tags: scope:issue-specific, fix-2417, detection-expand, marker-gate, TL1, bash-write-targets, pwsh-not-required

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
AGENTS_N="$(np "$AGENTS_DIR")"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
harness_isolate "$TMP"
TRANS_TMP="$(make_tmp)"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TRANS_TMP"

unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE 2>/dev/null || true

HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
DETECT_JS="$AGENTS_DIR/hooks/lib/bash-write-targets/detection-expand.js"
MARKER_GATE_JS="$AGENTS_DIR/hooks/enforce-worktree/bash-write-scope/marker-gate.js"
CP_MV_JS="$AGENTS_DIR/hooks/lib/bash-write-targets/cp-mv.js"
PWSH_JS="$AGENTS_DIR/hooks/lib/bash-write-targets/pwsh.js"

DETECT_PRESENT=no; [ -f "$DETECT_JS" ] && DETECT_PRESENT=yes

WFN="$(np "$WORKFLOW_STATE_DIR")"
SID="aa000000-0000-4000-8000-000000001001"
OTHER_SID="bb000000-0000-4000-8000-000000002002"
printf '{}' > "$WORKFLOW_STATE_DIR/$SID.json"

# ── local run-hook helper (equivalent to clearance-hook-harness; not mixed-source) ──
local_run_hook() {
    local tn="$1" input="$2" out rc
    [ -f "$HOOK" ] || { printf 'absent|'; return; }
    out=$(WORKFLOW_STATE_DIR="$tn" WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")" AGENTS_CONFIG_DIR="$AGENTS_N" \
        "$RWT" 12 node "$HOOK" <<< "$input" 2>/dev/null)
    rc=$?
    printf '%s|%s' "$rc" "$(printf '%s' "$out" | tr -d '\r\n')"
}
local_classify() {
    local raw="$1" rc out
    rc="${raw%%|*}"; out="${raw#*|}"
    case "$rc" in
        absent) printf 'hook-absent'; return ;;
        124) printf 'timeout'; return ;;
        0) ;;
        *) printf 'crash:%s' "$rc"; return ;;
    esac
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*) printf 'block'; return ;;
        *'"decision":"approve"'*) printf 'approve'; return ;;
        *'"permissionDecision":"allow"'*) printf 'approve'; return ;;
        *'"continue":true'*) printf 'approve'; return ;;
    esac
    printf 'unrecognized'
}
mk_bash_in() {
    "$RWT" 8 node -e \
      "process.stdout.write(JSON.stringify({tool_name:'Bash',session_id:process.argv[1],tool_input:{command:process.argv[2]}}))" \
      "$SID" "$1" 2>/dev/null
}
mk_file_in() {
    "$RWT" 8 node -e \
      "process.stdout.write(JSON.stringify({tool_name:process.argv[1],session_id:process.argv[2],tool_input:{file_path:process.argv[3]}}))" \
      "$1" "$SID" "$2" 2>/dev/null
}

# ── helper: call expandForDetection and extract a single field ──
expand_field() {
    # $1=token, $2=field (path|aliasRef|aliasUnresolved|dynamicTail), $3=cwd(optional)
    local tok="$1" fld="$2" cwd="${3:-/tmp}"
    "$RWT" 8 node -e "
try {
  const m = require(process.argv[1]);
  const r = m.expandForDetection(process.argv[2], {cwd: process.argv[3]});
  const v = r[process.argv[4]];
  process.stdout.write(v === undefined ? 'undefined' : String(v));
} catch(e) {
  process.stdout.write('ERR:' + (e.code === 'MODULE_NOT_FOUND' ? 'absent' : e.message.slice(0,60)));
}
" "$AGENTS_N/hooks/lib/bash-write-targets/detection-expand.js" "$tok" "$cwd" "$fld" 2>/dev/null
}

# ════════════════════════════════════════════════════════════════════
case_begin "expand-for-detection-aliases" "hooks/lib/bash-write-targets/detection-expand.js"

# Table: token | field | expected
# All alias forms should resolve (aliasUnresolved=false, dynamicTail=false)
while IFS='|' read -r tok fld want; do
    [[ -z "$tok" || "$tok" =~ ^[[:space:]]*# ]] && continue
    tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"; fld="${fld// /}"; want="${want// /}"
    # substitute __WF__ and __PLANS__ placeholders
    tok="${tok/__WF__/$WFN}"; tok="${tok/__PLANS__/$WORKFLOW_PLANS_DIR}"
    got="$(expand_field "$tok" "$fld")"
    if [ "$got" = "ERR:absent" ]; then
        fail "alias-table: $tok [$fld]  RED-EXPECTED: detection-expand.js not yet created"
    else
        assert_eq "$got" "$want"
    fi
done <<'TABLE'
~/__WF__/x                              | aliasUnresolved | false
$HOME/__WF__/x                          | aliasUnresolved | false
${HOME}/__WF__/x                        | aliasUnresolved | false
$WORKFLOW_STATE_DIR/x                  | aliasUnresolved | false
${WORKFLOW_STATE_DIR}/x               | aliasUnresolved | false
$WORKFLOW_PLANS_DIR/x                   | aliasUnresolved | false
${WORKFLOW_PLANS_DIR}/x                | aliasUnresolved | false
${WORKFLOW_PLANS_DIR:-__PLANS__}/x     | aliasUnresolved | false
${WORKFLOW_PLANS_DIR-__PLANS__}/x      | aliasUnresolved | false
${WORKFLOW_PLANS_DIR:=__PLANS__}/x     | aliasUnresolved | false
TABLE

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "expand-for-detection-operators" "hooks/lib/bash-write-targets/detection-expand.js"

# Unsupported operators → aliasUnresolved=true
while IFS='|' read -r tok fld want; do
    [[ -z "$tok" || "$tok" =~ ^[[:space:]]*# ]] && continue
    tok="${tok#"${tok%%[![:space:]]*}"}"; tok="${tok%"${tok##*[![:space:]]}"}"; fld="${fld// /}"; want="${want// /}"
    got="$(expand_field "$tok" "$fld")"
    if [ "$got" = "ERR:absent" ]; then
        fail "op-table: $tok [$fld]  RED-EXPECTED: detection-expand.js not yet created"
    else
        assert_eq "$got" "$want"
    fi
done <<'TABLE'
${WORKFLOW_STATE_DIR:+x}              | aliasUnresolved | true
${WORKFLOW_PLANS_DIR%suffix}           | aliasUnresolved | true
${WORKFLOW_PLANS_DIR#prefix}           | aliasUnresolved | true
${WORKFLOW_PLANS_DIR/old/new}          | aliasUnresolved | true
TABLE

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "expand-for-detection-env-control" "hooks/lib/bash-write-targets/detection-expand.js"

# Unset arbitrary var → dynamicTail (not blocked)
GOT="$(expand_field '$_CERTAINLY_UNSET_VAR_XYZ99/rest' 'dynamicTail')"
if [ "$GOT" = "ERR:absent" ]; then
    fail "unset-var-dynamicTail  RED-EXPECTED: detection-expand.js not yet created"
else
    assert_eq "$GOT" "true"
fi

# ${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}/<sid>-detail.md  resolves cleanly
DETAIL_TOK="\${WORKFLOW_PLANS_DIR:-$WORKFLOW_PLANS_DIR}/$SID-detail.md"
GOT_UR="$(expand_field "$DETAIL_TOK" 'aliasUnresolved')"
if [ "$GOT_UR" = "ERR:absent" ]; then
    fail "plans-default-detail-resolves  RED-EXPECTED: detection-expand.js not yet created"
else
    assert_eq "$GOT_UR" "false"
fi

# env var pointing at control dir → path under control dir (blocked)
export _TEST_CTL_VAR="$WORKFLOW_STATE_DIR/$SID.control"
CTL_TOK="\$_TEST_CTL_VAR/round-number.txt"
GOT_PATH="$(expand_field "$CTL_TOK" 'path')"
if [ "$GOT_PATH" = "ERR:absent" ]; then
    fail "env-var-to-control-dir  RED-EXPECTED: detection-expand.js not yet created"
else
    # Path should resolve under workflow dir (i.e., NOT null, NOT 'undefined');
    # node returns C:/ while the env var may hold /c/ or /tmp, so compare in one spelling.
    case "$GOT_PATH" in
        undefined|ERR:*) ;;
        *) GOT_PATH="$(np "$GOT_PATH")" ;;
    esac
    case "$GOT_PATH" in
        "$(np "$WORKFLOW_STATE_DIR")/"*) pass "env-var-to-control-dir path under wf dir" ;;
        undefined|ERR:*) fail "env-var-to-control-dir path unexpected: $GOT_PATH" ;;
        *) fail "env-var-to-control-dir path not under wf dir: $GOT_PATH" ;;
    esac
fi
unset _TEST_CTL_VAR

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "a-block-replay" "hooks/enforce-worktree/bash-write-scope/marker-gate.js"

# Replay (a) block-direction inputs from enforce-clearance-token-write.sh.
# These go through the real hook and must still block (regression guard).
HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes
T2="$(make_tmp)"
T2N="$(np "$T2")"
TOKEN="$T2N/$SID.off-clearance"

while IFS='|' read -r name cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"; cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}";
    cmd="${cmd/__TOK__/$TOKEN}"
    verdict="$(local_classify "$(local_run_hook "$T2N" "$(mk_bash_in "$cmd")")")"
    if [ "$verdict" = "block" ]; then pass "a-replay: $name"
    elif [ "$HOOK_PRESENT" = "no" ]; then skip "a-replay: $name (hook absent)"
    else fail "a-replay: $name — want=block got=$verdict"; fi
done <<'TABLE'
redirect-write      | echo x > __TOK__
tee-write           | echo x | tee __TOK__
rm-delete           | rm -f __TOK__
mv-rename           | mv __TOK__ /tmp/stash.bak
TABLE
# Write/Edit tool payloads use mk_file_in
for tool in Write Edit; do
    verdict="$(local_classify "$(local_run_hook "$T2N" "$(mk_file_in "$tool" "$TOKEN")")")"
    if [ "$verdict" = "block" ]; then pass "a-replay: $tool-tool"
    elif [ "$HOOK_PRESENT" = "no" ]; then skip "a-replay: $tool-tool (hook absent)"
    else fail "a-replay: $tool-tool — want=block got=$verdict"; fi
done
rm -rf "$T2" 2>/dev/null || true

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "allow-fixture-sample" "hooks/enforce-worktree/bash-write-scope/marker-gate.js"

# Allow-direction fixtures from expandStaticShellTokens must still approve.
T3="$(make_tmp)"
T3N="$(np "$T3")"
# #2434: the unrelated file lives outside the workflow dir (the strict placement guard owns it).
T3OUT="$(make_tmp)"
UNRELATED="$(np "$T3OUT")/notes.txt"

while IFS='|' read -r name cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"; cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}";
    cmd="${cmd/__UNRELATED__/$UNRELATED}"
    verdict="$(local_classify "$(local_run_hook "$T3N" "$(mk_bash_in "$cmd")")")"
    if [ "$verdict" = "approve" ]; then pass "allow-sample: $name"
    elif [ "$HOOK_PRESENT" = "no" ]; then skip "allow-sample: $name (hook absent)"
    else fail "allow-sample: $name — want=approve got=$verdict"; fi
done <<'TABLE'
redirect-unrelated  | echo x > __UNRELATED__
cat-read            | cat /etc/hosts
rm-unrelated        | rm -f __UNRELATED__
TABLE
rm -rf "$T3" "$T3OUT" 2>/dev/null || true

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "other-session-gate" "hooks/enforce-worktree/bash-write-scope/marker-gate.js"

# targetsHitOtherSessionWorkflowState must block ${WORKFLOW_STATE_DIR}/<other>.control/x
# and $HOME/.claude/projects/workflow/<other>.json (after detection-expand integration).
OTHER_CTL_TOK="\${WORKFLOW_STATE_DIR}/$OTHER_SID.control/x"
GOT_GATE="$("$RWT" 8 node -e "
try {
  const g = require(process.argv[1] + '/hooks/enforce-worktree/bash-write-scope/marker-gate.js');
  const r = g.targetsHitOtherSessionWorkflowState([process.argv[2]], {sessionId: process.argv[3]});
  process.stdout.write(String(r));
} catch(e) {
  process.stdout.write('ERR:' + e.message.slice(0,80));
}
" "$AGENTS_N" "$OTHER_CTL_TOK" "$SID" 2>/dev/null)"

case "$GOT_GATE" in
    "true")  pass "other-session-control-dir blocked" ;;
    "false") fail "other-session-control-dir not blocked — RED-EXPECTED: detection-expand integration not yet done" ;;
    ERR:*)   fail "other-session-control-dir error: $GOT_GATE" ;;
    *)       fail "other-session-control-dir unexpected: $GOT_GATE" ;;
esac

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "source-only-rename-out-of-control" "hooks/lib/bash-write-targets/cp-mv.js"

# Moving a control file OUT of the control dir deletes it: only the SOURCE side
# is protected, so destination-only detection would let these through. Both
# directions are driven through the real hook, and the protected source must
# stay byte-identical.
mkdir -p "$WORKFLOW_STATE_DIR/$SID.control"
CTL="$WFN/$SID.control"
SRC_FILE="$WORKFLOW_STATE_DIR/$SID.control/detail-plan-terminal.txt"
printf 'terminal round=3\n' > "$SRC_FILE"
SRC_BEFORE="$(cksum < "$SRC_FILE" | tr -d ' \t\r\n')"
T4="$(make_tmp)"
T4N="$(np "$T4")"
HOOK_PRESENT=no; [ -f "$HOOK" ] && HOOK_PRESENT=yes

while IFS='|' read -r name cmd; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"; cmd="${cmd#"${cmd%%[![:space:]]*}"}"; cmd="${cmd%"${cmd##*[![:space:]]}"}";
    cmd="${cmd//__CTL__/$CTL}"; cmd="${cmd//__OUT__/$T4N}"
    verdict="$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "$cmd")")")"
    if [ "$verdict" = "block" ]; then pass "src-rename: $name"
    elif [ "$HOOK_PRESENT" = "no" ]; then skip "src-rename: $name (hook absent)"
    else fail "src-rename: $name — want=block got=$verdict  RED-EXPECTED: source-side rename detection not yet wired"; fi
done <<'TABLE'
mv-out-to-tmp          | mv __CTL__/detail-plan-terminal.txt __OUT__/file
mv-out-t-flag          | mv -t __OUT__ __CTL__/detail-plan-terminal.txt
mv-out-target-dir      | mv --target-directory=__OUT__ __CTL__/detail-plan-terminal.txt
move-item-out          | Move-Item __CTL__/detail-plan-terminal.txt __OUT__/file
move-item-path-out     | Move-Item -Path __CTL__/detail-plan-terminal.txt -Destination __OUT__/file
mi-alias-out           | mi __CTL__/detail-plan-terminal.txt __OUT__/file
rename-item-in-place   | Rename-Item __CTL__/detail-plan-terminal.txt gone.txt
mv-in-from-outside     | mv __OUT__/file __CTL__/detail-plan-terminal.txt
TABLE

SRC_AFTER="$(cksum < "$SRC_FILE" 2>/dev/null | tr -d ' \t\r\n')"
if [ "$SRC_AFTER" = "$SRC_BEFORE" ]; then pass "src-rename: protected source byte-identical"
else fail "src-rename: protected source changed — before=$SRC_BEFORE after=$SRC_AFTER"; fi
if [ -e "$T4/file" ]; then fail "src-rename: a moved copy appeared outside"; else pass "src-rename: nothing appeared outside"; fi

# Allow counterpart: moving an unrelated file out of an unrelated dir.
printf 'x' > "$T4/a.txt"
verdict="$(local_classify "$(local_run_hook "$WFN" "$(mk_bash_in "mv $T4N/a.txt $T4N/b.txt")")")"
if [ "$verdict" = "approve" ]; then pass "src-rename: unrelated mv allowed"
elif [ "$HOOK_PRESENT" = "no" ]; then skip "src-rename: unrelated mv (hook absent)"
else fail "src-rename: unrelated mv — want=approve got=$verdict"; fi
rm -rf "$T4" 2>/dev/null || true

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "extract-rename-sources-posix" "hooks/lib/bash-write-targets/cp-mv.js"

# extractRenameSources for POSIX mv (doesn't exist yet → RED-EXPECTED)
while IFS='|' read -r name cmd want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"; want="${want// /}"
    got="$("$RWT" 8 node -e "
try {
  const m = require(process.argv[1] + '/hooks/lib/bash-write-targets/cp-mv.js');
  if (typeof m.extractRenameSources !== 'function') { process.stdout.write('absent:no-export'); }
  else { const r = m.extractRenameSources(process.argv[2]); process.stdout.write(JSON.stringify(r)); }
} catch(e) {
  process.stdout.write('ERR:' + (e.code === 'MODULE_NOT_FOUND' ? 'absent' : e.message.slice(0,60)));
}
" "$AGENTS_N" "$cmd" 2>/dev/null)"
    case "$got" in
        ERR:absent|absent:*) fail "posix-rename: $name  RED-EXPECTED: extractRenameSources not yet added to cp-mv.js" ;;
        *)  assert_eq "$got" "$want" ;;
    esac
done <<'TABLE'
mv-simple       | mv a.txt b.txt          | ["a.txt"]
mv-t-flag       | mv -t dir/ a.txt b.txt  | ["a.txt","b.txt"]
mv-target-dir   | mv --target-directory=dir/ src.txt | ["src.txt"]
mv-end-of-opts  | mv -- a.txt b.txt       | ["a.txt"]
mv-multi-src    | mv a.txt b.txt dir/     | ["a.txt","b.txt"]
TABLE

case_end

# ════════════════════════════════════════════════════════════════════
case_begin "extract-rename-sources-pwsh" "hooks/lib/bash-write-targets/pwsh.js"

# extractRenameSources for PowerShell Move-Item/Rename-Item (doesn't exist yet)
while IFS='|' read -r name cmd want; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name#"${name%%[![:space:]]*}"}"; name="${name%"${name##*[![:space:]]}"}"; want="${want// /}"
    got="$("$RWT" 8 node -e "
try {
  const m = require(process.argv[1] + '/hooks/lib/bash-write-targets/pwsh.js');
  if (typeof m.extractRenameSources !== 'function') { process.stdout.write('absent:no-export'); }
  else { const r = m.extractRenameSources(process.argv[2]); process.stdout.write(JSON.stringify(r)); }
} catch(e) {
  process.stdout.write('ERR:' + (e.code === 'MODULE_NOT_FOUND' ? 'absent' : e.message.slice(0,60)));
}
" "$AGENTS_N" "$cmd" 2>/dev/null)"
    case "$got" in
        ERR:absent|absent:*) fail "pwsh-rename: $name  RED-EXPECTED: extractRenameSources not yet added to pwsh.js" ;;
        *)  assert_eq "$got" "$want" ;;
    esac
done <<'TABLE'
Move-Item       | Move-Item a.txt b.txt   | ["a.txt"]
mi-alias        | mi a.txt b.txt          | ["a.txt"]
Rename-Item     | Rename-Item a.txt b.txt | ["a.txt"]
rni-alias       | rni a.txt b.txt         | ["a.txt"]
mi-named-path   | Move-Item -Path a.txt -Destination b.txt | ["a.txt"]
mi-literalpath  | Move-Item -LiteralPath a.txt b.txt | ["a.txt"]
TABLE

case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
