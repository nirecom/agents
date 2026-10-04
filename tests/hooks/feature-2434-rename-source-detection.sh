#!/usr/bin/env bash
# tests/hooks/feature-2434-rename-source-detection.sh
# Tests: hooks/block-clearance-token-write/bash-scan/scan.js, hooks/lib/bash-write-targets/cp-mv.js, hooks/lib/bash-write-targets/detection-targets.js, hooks/lib/bash-write-targets/pwsh.js, hooks/block-clearance-token-write.js
# Tags: scope:issue-specific, feature-2434, rename-source, extract-rename-sources, off-clearance, clearance-token, workflow-off, bash-write-targets, TL1, TL2, pwsh-not-required
# Renaming a protected (a) file away deletes it as surely as rm does, so the SOURCE side of
# mv / Move-Item / Rename-Item must block — also under WORKFLOW=off, which releases only the
# placement classes (b)/(c). Driven through bashHitsProtected and the real hook; the operand
# parsing itself must live only in extractRenameSources (cp-mv.js / pwsh.js).

set -euo pipefail

# TL3 gap (hook registration; what this test does NOT catch):
# - that settings.json registers hooks/block-clearance-token-write.js for Bash and
#   PowerShell PreToolUse, and that Claude Code feeds it this exact stdin shape;
# - the real PowerShell tool path (Move-Item / Rename-Item are fed as Bash text here).
# Closest-to-action mitigation: the real hook entrypoint runs as a subprocess.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

AGENTS_N="$(np "$AGENTS_DIR")"
HOOK="$AGENTS_DIR/hooks/block-clearance-token-write.js"
SCAN_JS="$AGENTS_DIR/hooks/block-clearance-token-write/bash-scan/scan.js"
DETECT_TARGETS_JS="$AGENTS_DIR/hooks/lib/bash-write-targets/detection-targets.js"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/home" "$TMP/wf" "$TMP/plans" "$TMP/tx" "$TMP/out"
export HOME="$TMP/home"
if command -v cygpath >/dev/null 2>&1; then export USERPROFILE; USERPROFILE="$(cygpath -w "$TMP/home")"; fi
export WORKFLOW_STATE_DIR; WORKFLOW_STATE_DIR="$(np "$TMP/wf")"
export WORKFLOW_PLANS_DIR; WORKFLOW_PLANS_DIR="$(np "$TMP/plans")"
export CLAUDE_TRANSCRIPT_BASE_DIR; CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/tx")"
export AGENTS_CONFIG_DIR="$AGENTS_N"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE CLAUDECODE 2>/dev/null || true
cd "$TMP"

SID="wsid"
WF="$WORKFLOW_STATE_DIR"
OUT="$(np "$TMP/out")"
OFF_MARKER="$TMP/wf/$SID.workflow-off"

# Probe for the production functions: bashHitsProtected and both extractRenameSources.
cat > "$TMP/probe.js" <<'JS'
"use strict";
const [agents, mode, cmd, cwd, sid] = process.argv.slice(2);
try {
  if (mode === "scan") {
    const { bashHitsProtected } = require(agents + "/hooks/block-clearance-token-write/bash-scan/scan.js");
    process.stdout.write(String(bashHitsProtected(cmd, { cwd, sessionCtx: { sessionId: sid } })));
  } else {
    const file = mode === "ers-posix" ? "cp-mv.js" : "pwsh.js";
    const m = require(agents + "/hooks/lib/bash-write-targets/" + file);
    if (typeof m.extractRenameSources !== "function") process.stdout.write("absent:no-export");
    else process.stdout.write(JSON.stringify(m.extractRenameSources(cmd)));
  }
} catch (e) {
  process.stdout.write("ERR:" + String(e && e.message).slice(0, 80));
}
JS
MKIN_JS="process.stdout.write(JSON.stringify({tool_name:process.argv[4]||'Bash',session_id:process.argv[1],tool_input:{command:process.argv[2],cwd:process.argv[3]}}))"

probe() { run_with_timeout 15 node "$TMP/probe.js" "$AGENTS_N" "$@" 2>/dev/null || true; }
scan_verdict() { probe scan "$1" "$OUT" "$SID"; }

# hook_verdict <command> [tool_name] -> approve|block|timeout|crash:<rc>|empty|unrecognized
hook_verdict() {
    local input out rc=0
    input="$(run_with_timeout 8 node -e "$MKIN_JS" "$SID" "$1" "$OUT" "${2:-Bash}" 2>/dev/null || true)"
    out="$(run_with_timeout 15 node "$HOOK" <<< "$input" 2>/dev/null)" || rc=$?
    case "$rc" in 0) ;; 124) printf 'timeout'; return ;; *) printf 'crash:%s' "$rc"; return ;; esac
    out="$(printf '%s' "$out" | tr -d '\r\n')"
    case "$out" in
        '') printf 'empty' ;;
        *'"decision":"block"'*) printf 'block' ;;
        *'"decision":"approve"'*) printf 'approve' ;;
        *) printf 'unrecognized' ;;
    esac
}

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
fill() {
    local c="$1"
    c="${c//__TOK__/$OUT/$SID.off-clearance}"
    c="${c//__MRK__/$OUT/$SID.worktree-off}"
    c="${c//__WFTOK__/$WF/$SID.off-clearance}"
    c="${c//__WFOFF__/$WF/$SID.workflow-off}"
    c="${c//__OUT__/$OUT}"
    c="${c//__WF__/$WF}"
    c="${c//__SID__/$SID}"
    printf '%s' "$c"
}

# name | command | expected bashHitsProtected kind. Protected files sit OUTSIDE the
# workflow dir so the placement guard cannot be what blocks them.
RENAME_TABLE="$(cat <<'TABLE'
mv-plain              | mv __TOK__ __OUT__/x                                  | token
mv-t-flag             | mv -t __OUT__/d __TOK__                               | token
mv-target-directory   | mv --target-directory=__OUT__/d __TOK__               | token
mv-force              | mv -f __TOK__ __OUT__/x                               | token
mv-marker             | mv __MRK__ __OUT__/x                                  | marker
move-item-path        | Move-Item -Path __TOK__ -Destination __OUT__/x        | token
move-item-literalpath | Move-Item -LiteralPath __TOK__ -Destination __OUT__/x | token
move-item-positional  | Move-Item __TOK__ __OUT__/x                           | token
mi-alias              | mi __TOK__ __OUT__/x                                  | token
rename-item-path      | Rename-Item -Path __TOK__ -NewName y                  | token
rni-alias             | rni __TOK__ y                                         | token
rename-item-marker    | Rename-Item __MRK__ y                                 | marker
mv-dq-source          | mv "__TOK__" __OUT__/x                                | token
mv-sq-source          | mv '__TOK__' __OUT__/x                                | token
mv-double-dash        | mv -- __TOK__ __OUT__/x                               | token
mv-combined-flags     | mv -fv __TOK__ __OUT__/x                              | token
mv-multi-one-protected| mv __OUT__/a __TOK__ __OUT__/d                        | token
mv-after-true         | true && mv __TOK__ __OUT__/x                          | token
mv-cd-relative        | cd __OUT__ && mv __SID__.off-clearance __OUT__/x      | token
move-item-dq-path     | Move-Item -Path "__TOK__" -Destination __OUT__/x      | token
move-item-sq-literal  | Move-Item -LiteralPath '__TOK__' -Destination __OUT__/x | token
rename-item-dq-path   | Rename-Item -Path "__TOK__" -NewName y                | token
mv-t-attached         | mv -t__OUT__/d __TOK__                                | token
mv-target-dir-space   | mv --target-directory __OUT__/d __TOK__               | token
mv-ft-combined        | mv -ft __OUT__/d __TOK__                              | token
mv-second-segment     | mv __OUT__/a __OUT__/b && mv __TOK__ __OUT__/x        | token
env-wrapped-mv        | env mv __TOK__ __OUT__/x                              | token
command-wrapped-mv    | command mv __TOK__ __OUT__/x                          | token
env-prefix-mv         | FOO=1 mv __TOK__ __OUT__/x                            | token
move-item-force-first | Move-Item -Force __TOK__ __OUT__/x                    | token
move-item-dest-first  | Move-Item -Destination __OUT__/x __TOK__              | token
move-item-path-array  | Move-Item -Path __OUT__/a,__TOK__ -Destination __OUT__/d | token
move-item-lowercase   | move-item -path __TOK__ -destination __OUT__/x        | token
rni-uppercase         | RNI __TOK__ y                                         | token
TABLE
)"

case_begin "rename-source-scan-kind" "hooks/block-clearance-token-write/bash-scan/scan.js"
while IFS='|' read -r name cmd want; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"; want="$(trim "$want")"
    [[ -z "$name" ]] && continue
    got="$(scan_verdict "$cmd")"
    if [[ "$got" == "$want" ]]; then pass "scan $name -> $got"
    else fail "scan $name" "want=$want got=$got"; fi
done <<< "$RENAME_TABLE"
case_end

case_begin "rename-source-hook-blocks" "hooks/block-clearance-token-write.js"
while IFS='|' read -r name cmd _want; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    got="$(hook_verdict "$cmd")"
    if [[ "$got" == "block" ]]; then pass "hook $name -> block"
    else fail "hook $name" "want=block got=$got"; fi
done <<< "$RENAME_TABLE"
case_end

case_begin "workflow-off-marker-is-live" "hooks/block-clearance-token-write.js"
# Control pair: without this, a block under WORKFLOW=off could merely be the placement guard.
rm -f "$OFF_MARKER"
got_on="$(hook_verdict "mv $WF/plain-a.txt $WF/plain-b.txt")"
: > "$OFF_MARKER"
got_off="$(hook_verdict "mv $WF/plain-a.txt $WF/plain-b.txt")"
if [[ "$got_on" == "block" ]]; then pass "unrelated mv under the workflow dir blocks while ON"
else fail "unrelated mv under the workflow dir while ON" "want=block got=$got_on"; fi
if [[ "$got_off" == "approve" ]]; then pass "the same mv is released under WORKFLOW=off"
else fail "unrelated mv under the workflow dir while OFF" "want=approve got=$got_off"; fi
case_end

case_begin "non-protected-wf-source-on-off-pair" "hooks/block-clearance-token-write.js"
# CPR-ORTH: a plain file under the workflow dir renamed away is a placement write, so it
# blocks while ON and is released under WORKFLOW=off — for every rename spelling.
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    rm -f "$OFF_MARKER"
    got_on="$(hook_verdict "$cmd")"
    : > "$OFF_MARKER"
    got_off="$(hook_verdict "$cmd")"
    rm -f "$OFF_MARKER"
    if [[ "$got_on" == "block" ]]; then pass "pair[on] $name -> block"
    else fail "pair[on] $name" "want=block got=$got_on"; fi
    if [[ "$got_off" == "approve" ]]; then pass "pair[off] $name -> approve"
    else fail "pair[off] $name" "want=approve got=$got_off"; fi
done <<'TABLE'
mv-wf-plain          | mv __WF__/plain-a.txt __OUT__/x
mv-t-wf-plain        | mv -t __OUT__ __WF__/plain-a.txt
move-item-wf-plain   | Move-Item -Path __WF__/plain-a.txt -Destination __OUT__/x
rni-wf-plain         | rni __WF__/plain-a.txt y
TABLE
case_end

case_begin "pwsh-param-forms-placement-blocks" "hooks/lib/bash-write-targets/detection-targets.js"
# A control-dir file with no protected basename: only the placement guard (which reads the
# source through the pwsh parser) can block it, so argv-scan cannot mask a parser miss.
rm -f "$OFF_MARKER"
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    got="$(hook_verdict "$cmd")"
    if [[ "$got" == "block" ]]; then pass "placement[on] $name -> block"
    else fail "placement[on] $name" "want=block got=$got"; fi
done <<'TABLE'
move-item-colon-path | Move-Item -Path:__WF__/__SID__.control/x.json -Destination __OUT__/x
move-item-lp-alias   | Move-Item -LP __WF__/__SID__.control/x.json __OUT__/x
move-item-pspath     | Move-Item -PSPath __WF__/__SID__.control/x.json __OUT__/x
move-item-colon-lit  | Move-Item -LiteralPath:__WF__/__SID__.control/x.json __OUT__/x
rni-lp-alias         | rni -LP __WF__/__SID__.control/x.json y
move-item-unknown    | Move-Item -Foo __WF__/__SID__.control/x.json __OUT__/x
TABLE
# The same placement rows are released under WORKFLOW=off (class (b)/(c), not (a)).
: > "$OFF_MARKER"
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    got="$(hook_verdict "$cmd")"
    if [[ "$got" == "approve" ]]; then pass "placement[off] $name -> approve"
    else fail "placement[off] $name" "want=approve got=$got"; fi
done <<'TABLE'
move-item-colon-path | Move-Item -Path:__WF__/__SID__.control/x.json -Destination __OUT__/x
move-item-lp-alias   | Move-Item -LP __WF__/__SID__.control/x.json __OUT__/x
move-item-pspath     | Move-Item -PSPath __WF__/__SID__.control/x.json __OUT__/x
move-item-colon-lit  | Move-Item -LiteralPath:__WF__/__SID__.control/x.json __OUT__/x
rni-lp-alias         | rni -LP __WF__/__SID__.control/x.json y
move-item-unknown    | Move-Item -Foo __WF__/__SID__.control/x.json __OUT__/x
TABLE
rm -f "$OFF_MARKER"
case_end

case_begin "powershell-tool-name-input" "hooks/block-clearance-token-write.js"
# Same verdicts when the call arrives as tool_name PowerShell instead of Bash.
while IFS='|' read -r name cmd want_on want_off; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    want_on="$(trim "$want_on")"; want_off="$(trim "$want_off")"
    [[ -z "$name" ]] && continue
    rm -f "$OFF_MARKER"
    got="$(hook_verdict "$cmd" PowerShell)"
    if [[ "$got" == "$want_on" ]]; then pass "pwsh-tool[on] $name -> $got"
    else fail "pwsh-tool[on] $name" "want=$want_on got=$got"; fi
    : > "$OFF_MARKER"
    got="$(hook_verdict "$cmd" PowerShell)"
    rm -f "$OFF_MARKER"
    if [[ "$got" == "$want_off" ]]; then pass "pwsh-tool[off] $name -> $got"
    else fail "pwsh-tool[off] $name" "want=$want_off got=$got"; fi
done <<'TABLE'
move-item-token    | Move-Item -Path __TOK__ -Destination __OUT__/x | block | block
rni-wf-plain       | rni __WF__/plain-a.txt y                       | block | approve
TABLE
case_end

case_begin "rename-source-blocks-under-workflow-off" "hooks/block-clearance-token-write.js"
: > "$OFF_MARKER"
while IFS='|' read -r name cmd _want; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    got="$(hook_verdict "$cmd")"
    if [[ "$got" == "block" ]]; then pass "R7 $name -> block"
    else fail "R7 $name" "want=block got=$got"; fi
done <<< "$RENAME_TABLE"
# The same forms with the (a) file inside the workflow dir, where (b)/(c) are released.
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    got="$(hook_verdict "$cmd")"
    if [[ "$got" == "block" ]]; then pass "R7-wf $name -> block"
    else fail "R7-wf $name" "want=block got=$got"; fi
done <<'TABLE'
mv-wf-token            | mv __WFTOK__ __OUT__/x
mv-t-wf-token          | mv -t __OUT__ __WFTOK__
mv-wf-off-marker-away  | mv __WFOFF__ __OUT__/x
move-item-wf-token     | Move-Item -Path __WFTOK__ -Destination __OUT__/x
rename-item-wf-off     | Rename-Item -LiteralPath __WFOFF__ -NewName y
rni-wf-token           | rni __WFTOK__ y
cd-wf-relative-token   | cd __WF__ && mv __SID__.off-clearance __OUT__/x
cd-wf-relative-mi      | cd __WF__ && Move-Item -Path __SID__.off-clearance -Destination __OUT__/x
TABLE
rm -f "$OFF_MARKER"
case_end

case_begin "rename-source-alias-spellings" "hooks/block-clearance-token-write.js"
# The source spelled through a workflow-dir / HOME alias: scan kind, then the hook ON and OFF.
while IFS='|' read -r name cmd want; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"; want="$(trim "$want")"
    [[ -z "$name" ]] && continue
    got="$(scan_verdict "$cmd")"
    if [[ "$got" == "$want" ]]; then pass "alias scan $name -> $got"
    else fail "alias scan $name" "want=$want got=$got"; fi
    for state in on off; do
        if [[ "$state" == "off" ]]; then : > "$OFF_MARKER"; else rm -f "$OFF_MARKER"; fi
        got="$(hook_verdict "$cmd")"
        if [[ "$got" == "block" ]]; then pass "alias hook[$state] $name -> block"
        else fail "alias hook[$state] $name" "want=block got=$got"; fi
    done
    rm -f "$OFF_MARKER"
done <<'TABLE'
mv-braced-alias        | mv ${WORKFLOW_STATE_DIR}/__SID__.off-clearance __OUT__/x                    | token
mv-bare-alias          | mv $WORKFLOW_STATE_DIR/__SID__.off-clearance __OUT__/x                      | token
mv-dq-alias            | mv "$WORKFLOW_STATE_DIR/__SID__.off-clearance" __OUT__/x                    | token
mv-home-default-wf     | mv $HOME/.claude/projects/workflow/__SID__.off-clearance __OUT__/x           | token
mv-tilde-default-wf    | mv ~/.claude/projects/workflow/__SID__.off-clearance __OUT__/x               | token
mv-default-op-alias    | mv ${WORKFLOW_STATE_DIR:-x}/__SID__.off-clearance __OUT__/x                 | token
mv-alias-off-marker    | mv ${WORKFLOW_STATE_DIR}/__SID__.workflow-off __OUT__/x                     | marker
move-item-braced-alias | Move-Item -Path ${WORKFLOW_STATE_DIR}/__SID__.off-clearance -Destination __OUT__/x | token
move-item-bare-alias   | Move-Item $WORKFLOW_STATE_DIR/__SID__.off-clearance __OUT__/x               | token
move-item-home-alias   | Move-Item -Path $HOME/.claude/projects/workflow/__SID__.off-clearance -Destination __OUT__/x | token
move-item-default-op   | Move-Item -LiteralPath ${WORKFLOW_STATE_DIR:-x}/__SID__.off-clearance __OUT__/x | token
rename-item-braced     | Rename-Item -Path ${WORKFLOW_STATE_DIR}/__SID__.off-clearance -NewName y    | token
rename-item-bare       | Rename-Item $WORKFLOW_STATE_DIR/__SID__.off-clearance y                     | token
rename-item-home-alias | Rename-Item -LiteralPath $HOME/.claude/projects/workflow/__SID__.off-clearance -NewName y | token
rename-item-default-op | rni ${WORKFLOW_STATE_DIR:-x}/__SID__.off-clearance y                        | token
TABLE
case_end

case_begin "rename-source-indirect-under-workflow-off" "hooks/block-clearance-token-write.js"
# A source reached through a shell variable or a glob: the scan must still name the token
# class (or fail closed as unparsed-token), and the hook must block under WORKFLOW=off.
: > "$TMP/wf/$SID.off-clearance"
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    got="$(scan_verdict "$cmd")"
    case "$got" in
        token|unparsed-token) pass "indirect scan $name -> $got" ;;
        *) fail "indirect scan $name" "want=token|unparsed-token got=$got" ;;
    esac
    : > "$OFF_MARKER"
    got="$(hook_verdict "$cmd")"
    rm -f "$OFF_MARKER"
    if [[ "$got" == "block" ]]; then pass "indirect hook[off] $name -> block"
    else fail "indirect hook[off] $name" "want=block got=$got"; fi
done <<'TABLE'
var-assigned-source | T=__WFTOK__; mv $T __OUT__/x
glob-source         | mv __WF__/*.off-clearance __OUT__/x
move-item-li-prefix | Move-Item -Li __TOK__ -Destination __OUT__/x
rename-item-pa-prefix | Rename-Item -Pa __TOK__ -NewName y
pwsh-var-source     | $T='__WFTOK__'; Move-Item -Path $T -Destination __OUT__/x
TABLE
rm -f "$TMP/wf/$SID.off-clearance"
case_end

case_begin "rename-negatives-allowed" "hooks/block-clearance-token-write.js"
for state in on off; do
    if [[ "$state" == "off" ]]; then : > "$OFF_MARKER"; else rm -f "$OFF_MARKER"; fi
    while IFS='|' read -r name cmd; do
        name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
        [[ -z "$name" ]] && continue
        got="$(hook_verdict "$cmd")"
        if [[ "$got" == "approve" ]]; then pass "negative[$state] $name -> approve"
        else fail "negative[$state] $name" "want=approve got=$got"; fi
    done <<'TABLE'
mv-unrelated          | mv __OUT__/a.txt __OUT__/b.txt
mv-t-unrelated        | mv -t __OUT__/d __OUT__/a.txt
move-item-unrelated   | Move-Item -Path __OUT__/a.txt -Destination __OUT__/b.txt
rename-item-unrelated | Rename-Item __OUT__/a.txt b.txt
cat-token-read        | cat __TOK__
move-item-unknown-param | Move-Item -Foo __OUT__/a.txt __OUT__/b.txt
move-item-include     | Move-Item -Include *.txt -Path __OUT__/a.txt -Destination __OUT__/b.txt
move-item-colon-path  | Move-Item -Path:__OUT__/a.txt -Destination __OUT__/b.txt
move-item-lp-alias    | Move-Item -LP __OUT__/a.txt __OUT__/b.txt
TABLE
done
rm -f "$OFF_MARKER"
case_end

case_begin "a-input-replay-non-narrowing" "hooks/block-clearance-token-write.js"
# Block rows of tests/hooks/enforce-clearance-token-write.sh (B1-B3, B7-B9) and the
# a-replay table of tests/hooks/fix-2417-detection-expand.sh, replayed ON and OFF.
for state in on off; do
    if [[ "$state" == "off" ]]; then : > "$OFF_MARKER"; else rm -f "$OFF_MARKER"; fi
    while IFS='|' read -r name cmd; do
        name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
        [[ -z "$name" ]] && continue
        got="$(hook_verdict "$cmd")"
        if [[ "$got" == "block" ]]; then pass "replay[$state] $name -> block"
        else fail "replay[$state] $name" "want=block got=$got"; fi
    done <<'TABLE'
B1-redirect        | echo x > __WFTOK__
B2-tee             | echo x | tee __WFTOK__
B3-cp-to-token     | cp /etc/hosts __WFTOK__
B7-rm              | rm -f __WFTOK__
B8-rm-rf           | rm -rf __WFTOK__
B9-mv-away         | mv __WFTOK__ __WF__/stash.bak
a-redirect-out     | echo x > __TOK__
a-tee-out          | echo x | tee __TOK__
a-rm-out           | rm -f __TOK__
a-mv-out           | mv __TOK__ /tmp/stash.bak
TABLE
done
rm -f "$OFF_MARKER"
case_end

case_begin "malformed-and-unknown-forms-fail-closed" "hooks/block-clearance-token-write/bash-scan/scan.js"
# A command the parser cannot read, or a pwsh parameter it does not know, must not
# let a protected source through.
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(fill "$(trim "$cmd")")"
    [[ -z "$name" ]] && continue
    got="$(scan_verdict "$cmd")"
    case "$got" in
        token|unparsed-token) pass "fail-closed scan $name -> $got" ;;
        *) fail "fail-closed scan $name" "want=token|unparsed-token got=$got" ;;
    esac
    : > "$OFF_MARKER"
    got="$(hook_verdict "$cmd")"
    rm -f "$OFF_MARKER"
    if [[ "$got" == "block" ]]; then pass "fail-closed hook[off] $name -> block"
    else fail "fail-closed hook[off] $name" "want=block got=$got"; fi
done <<'TABLE'
mv-unterminated-dq     | mv "__TOK__ __OUT__/x
mv-unterminated-sq     | mv '__TOK__ __OUT__/x
move-item-unterminated | Move-Item -Path "__TOK__ -Destination __OUT__/x
move-item-unknown-param| Move-Item -Foo __TOK__ __OUT__/x
move-item-colon-bound  | Move-Item -Path:__TOK__ -Destination __OUT__/x
rename-item-unknown    | Rename-Item -Bogus -Path __TOK__ -NewName y
TABLE
case_end

case_begin "extract-rename-sources-posix-unit" "hooks/lib/bash-write-targets/cp-mv.js"
while IFS='|' read -r name cmd want; do
    name="$(trim "$name")"; cmd="$(trim "$cmd")"; want="$(trim "$want")"
    [[ -z "$name" ]] && continue
    got="$(probe ers-posix "$cmd")"
    if [[ "$got" == "$want" ]]; then pass "posix $name -> $got"
    else fail "posix $name" "want=$want got=$got"; fi
done <<'TABLE'
mv-simple          | mv a.txt b.txt                          | ["a.txt"]
mv-force           | mv -f a.txt b.txt                       | ["a.txt"]
mv-t-flag          | mv -t dir a.txt                         | ["a.txt"]
mv-target-dir-eq   | mv --target-directory=dir a.txt b.txt   | ["a.txt","b.txt"]
mv-multi-src       | mv a.txt b.txt dir                      | ["a.txt","b.txt"]
mv-after-cd        | cd /x && mv a.txt b.txt                 | ["a.txt"]
cp-not-rename      | cp a.txt b.txt                          | []
rm-not-rename      | rm -f a.txt                             | []
echo-not-rename    | echo mv a.txt b.txt                     | []
mv-unterminated    | mv "a.txt b.txt                         | null
mv-dq-source       | mv "a.txt" b.txt                        | ["a.txt"]
mv-sq-source       | mv 'a.txt' b.txt                        | ["a.txt"]
mv-double-dash     | mv -- a.txt b.txt                       | ["a.txt"]
mv-dash-name       | mv -- -a.txt b.txt                      | ["-a.txt"]
mv-combined-flags  | mv -fv a.txt b.txt                      | ["a.txt"]
mv-after-true      | true && mv a.txt b.txt                  | ["a.txt"]
mv-t-attached      | mv -tdir a.txt                          | ["a.txt"]
mv-target-dir-space| mv --target-directory dir a.txt         | ["a.txt"]
mv-ft-combined     | mv -ft dir a.txt                        | ["a.txt"]
mv-both-segments   | mv a.txt b.txt && mv c.txt d.txt        | ["a.txt","c.txt"]
env-wrapped-mv     | env mv a.txt b.txt                      | ["a.txt"]
command-wrapped-mv | command mv a.txt b.txt                  | ["a.txt"]
env-prefix-mv      | FOO=1 mv a.txt b.txt                    | ["a.txt"]
mv-single-operand  | mv a.txt                                | []
mv-suffix-option   | mv -S .bak a.txt b.txt                  | ["a.txt"]
mv-suffix-long-eq  | mv --suffix=.bak a.txt b.txt            | ["a.txt"]
mv-suffix-long-sp  | mv --suffix .bak a.txt b.txt            | ["a.txt"]
mv-fS-combined     | mv -fS .bak a.txt b.txt                 | ["a.txt"]
TABLE
case_end

case_begin "extract-rename-sources-pwsh-unit" "hooks/lib/bash-write-targets/pwsh.js"
while IFS='|' read -r name cmd want; do
    name="$(trim "$name")"; cmd="$(trim "$cmd")"; want="$(trim "$want")"
    [[ -z "$name" ]] && continue
    got="$(probe ers-pwsh "$cmd")"
    if [[ "$got" == "$want" ]]; then pass "pwsh $name -> $got"
    else fail "pwsh $name" "want=$want got=$got"; fi
done <<'TABLE'
move-item-path        | Move-Item -Path a.txt -Destination b.txt  | ["a.txt"]
move-item-literalpath | Move-Item -LiteralPath a.txt b.txt        | ["a.txt"]
move-item-positional  | Move-Item a.txt b.txt                     | ["a.txt"]
mi-alias              | mi a.txt b.txt                            | ["a.txt"]
rename-item-path      | Rename-Item -Path a.txt -NewName b.txt    | ["a.txt"]
rni-alias             | rni a.txt b.txt                           | ["a.txt"]
copy-item-not-rename  | Copy-Item a.txt b.txt                     | []
remove-item-not-rename| Remove-Item a.txt                         | []
get-content-read      | Get-Content a.txt                         | []
move-item-unterminated| Move-Item -Path "a.txt b.txt              | null
move-item-dq-path     | Move-Item -Path "a.txt" -Destination b.txt| ["a.txt"]
move-item-sq-literal  | Move-Item -LiteralPath 'a.txt' b.txt      | ["a.txt"]
rename-item-dq-path   | Rename-Item -Path "a.txt" -NewName b.txt  | ["a.txt"]
move-item-force-first | Move-Item -Force a.txt b.txt              | ["a.txt"]
move-item-dest-first  | Move-Item -Destination b.txt a.txt        | ["a.txt"]
move-item-path-array  | Move-Item -Path x.txt,a.txt -Destination d| ["x.txt","a.txt"]
move-item-lowercase   | move-item -path a.txt -destination b.txt  | ["a.txt"]
rni-uppercase         | RNI a.txt b.txt                           | ["a.txt"]
move-item-both-segments | Move-Item a.txt b.txt; Move-Item c.txt d.txt | ["a.txt","c.txt"]
move-item-colon-path  | Move-Item -Path:a.txt -Destination b.txt  | ["a.txt"]
move-item-lp-alias    | Move-Item -LP a.txt b.txt                 | ["a.txt"]
move-item-pspath      | Move-Item -PSPath a.txt b.txt             | ["a.txt"]
move-item-colon-literal | Move-Item -LiteralPath:a.txt b.txt      | ["a.txt"]
move-item-unknown-param | Move-Item -Foo a.txt b.txt              | null
move-item-colon-drive | Move-Item -Path:C:/x/a.txt b.txt          | ["C:/x/a.txt"]
rename-item-unknown   | Rename-Item -Bogus a.txt b.txt            | null
move-item-colon-dest  | Move-Item -Destination:b.txt a.txt        | ["a.txt"]
TABLE
case_end

case_begin "detection-targets-uses-extract-rename-sources" "hooks/lib/bash-write-targets/detection-targets.js"
# CPR-SSOT: detection-targets.js keeps no mv / rename operand parsing of its own.
dt_src="$(cat "$DETECT_TARGETS_JS")"
if [[ "$dt_src" == *"extractRenameSources"* ]]; then pass "detection-targets.js calls extractRenameSources"
else fail "detection-targets.js" "does not reference extractRenameSources"; fi
if [[ "$dt_src" == *"slice(0, -1)"* || "$dt_src" == *"slice(0,-1)"* ]]; then
    fail "detection-targets.js" "still slices mv positionals itself (private source parsing)"
else pass "detection-targets.js has no private mv source slice"; fi
if [[ "$dt_src" == *"extractRenameSources("* ]]; then pass "detection-targets.js calls extractRenameSources("
else fail "detection-targets.js" "never calls extractRenameSources("; fi
case_end

case_begin "scan-uses-extract-rename-sources" "hooks/block-clearance-token-write/bash-scan/scan.js"
# Both an import of a module that exports it and an actual call are required.
IMPORT_RE='(\{[^}]*\bextractRenameSources\b[^}]*\}\s*=\s*require\(\s*["'"'"'][^"'"'"']*(bash-write-targets|cp-mv|pwsh)[^"'"'"']*["'"'"']\s*\))|(require\(\s*["'"'"'][^"'"'"']*(bash-write-targets|cp-mv|pwsh)[^"'"'"']*["'"'"']\s*\)\.extractRenameSources)'
has_import="$(run_with_timeout 15 node -e 'const s=require("fs").readFileSync(process.argv[1],"utf8");process.stdout.write(String(new RegExp(process.argv[2]).test(s)))' "$(np "$SCAN_JS")" "$IMPORT_RE" 2>/dev/null || true)"
if [[ "$has_import" == "true" ]]; then pass "scan.js imports extractRenameSources from bash-write-targets"
else fail "scan.js" "no require of a bash-write-targets module binding extractRenameSources (got=${has_import:-empty})"; fi
scan_src="$(cat "$SCAN_JS")"
if [[ "$scan_src" == *"extractRenameSources("* ]]; then pass "scan.js calls extractRenameSources("
else fail "scan.js" "never calls extractRenameSources("; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
