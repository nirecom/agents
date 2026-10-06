#!/usr/bin/env bash
# tests/hooks/feature-2434-classify-alias-expansion.sh
# Tests: hooks/block-clearance-token-write/bash-target-context/classify.js, hooks/lib/bash-write-targets/detection-expand.js, hooks/block-clearance-token-write/bash-scan/scan.js
# Tags: scope:issue-specific, feature-2434, detection-expand, classify, alias-expansion, workflow-dir, bash-write-targets, TL1, pwsh-not-required
# classify.js resolves a target's directory in the DETECTION direction, so every spelling of
# the workflow dir that bash resolves (`${VAR:-x}`, `${VAR-x}`, `${VAR:=x}`) must resolve here
# too, and a form it cannot resolve (`${VAR:+x}`) must fail closed. The one expander is
# detection-expand.js; classify.js keeps no private env-reference regex.

set -euo pipefail

# TL3 gap (hook registration; what this test does NOT catch):
# - that settings.json registers hooks/block-clearance-token-write.js for Bash
#   PreToolUse, so classify.js is actually consulted on a live tool call;
# - how the live Bash tool expands these spellings (verdicts come from the
#   production functions fed literal command text).

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
source "$AGENTS_DIR/tests/lib/harness.sh"

AGENTS_N="$(np "$AGENTS_DIR")"
CLASSIFY_JS="$AGENTS_DIR/hooks/block-clearance-token-write/bash-target-context/classify.js"

TMP="$(make_tmp)"
trap 'rm -rf "$TMP" 2>/dev/null || true' EXIT
mkdir -p "$TMP/home/wf" "$TMP/home/.workflow-state" "$TMP/home/.claude/projects/workflow" "$TMP/plans" "$TMP/tx" "$TMP/out"
export HOME; HOME="$(np "$TMP/home")"
if command -v cygpath >/dev/null 2>&1; then export USERPROFILE; USERPROFILE="$(cygpath -w "$TMP/home")"; fi
export WORKFLOW_STATE_DIR; WORKFLOW_STATE_DIR="$(np "$TMP/home/wf")"
export WORKFLOW_PLANS_DIR; WORKFLOW_PLANS_DIR="$(np "$TMP/plans")"
export CLAUDE_TRANSCRIPT_BASE_DIR; CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$TMP/tx")"
export AGENTS_CONFIG_DIR="$AGENTS_N"
unset CLAUDE_CODE_SESSION_ID CLAUDECODE 2>/dev/null || true
cd "$TMP"

SID="wsid"
WF="$WORKFLOW_STATE_DIR"
HOME_N="$HOME"
PLANS="$WORKFLOW_PLANS_DIR"
OUT="$(np "$TMP/out")"
# #2511: the resolver default is <home>/.workflow-state; the legacy root stays guarded.
DEFAULT_WF="$HOME_N/.workflow-state"
LEGACY_WF="$HOME_N/.claude/projects/workflow"

cat > "$TMP/probe.js" <<'JS'
"use strict";
const [agents, mode, a1, a2, a3] = process.argv.slice(2);
const fold = (v) => (typeof v === "string" ? v.replace(/\\/g, "/") : String(v));
try {
  if (mode === "rds") {
    const c = require(agents + "/hooks/block-clearance-token-write/bash-target-context/classify.js");
    process.stdout.write(fold(c.resolveDirSpelling(a1, a2 || undefined)));
  } else if (mode === "scan") {
    const { bashHitsProtected } = require(agents + "/hooks/block-clearance-token-write/bash-scan/scan.js");
    process.stdout.write(String(bashHitsProtected(a1, { cwd: a2, sessionCtx: { sessionId: a3 } })));
  } else if (mode === "expand") {
    const m = require(agents + "/hooks/lib/bash-write-targets/detection-expand.js");
    process.stdout.write(fold(m.expandForDetection(a1, { cwd: a2 })[a3]));
  }
} catch (e) {
  process.stdout.write("ERR:" + String(e && e.message).slice(0, 80));
}
JS

probe() { run_with_timeout 15 node "$TMP/probe.js" "$AGENTS_N" "$@" 2>/dev/null || true; }
probe_unset_wf() { run_with_timeout 15 env -u WORKFLOW_STATE_DIR node "$TMP/probe.js" "$AGENTS_N" "$@" 2>/dev/null || true; }
probe_empty_wf() { run_with_timeout 15 env WORKFLOW_STATE_DIR= node "$TMP/probe.js" "$AGENTS_N" "$@" 2>/dev/null || true; }
scan_verdict() { probe scan "$1" "$OUT" "$SID"; }

trim() { local s="$1"; s="${s#"${s%%[![:space:]]*}"}"; s="${s%"${s##*[![:space:]]}"}"; printf '%s' "$s"; }
root_of() {
    case "$1" in
        WF) printf '%s' "$WF" ;;
        HOME) printf '%s' "$HOME_N" ;;
        PLANS) printf '%s' "$PLANS" ;;
        DEFAULT_WF) printf '%s' "$DEFAULT_WF" ;;
        *) printf 'unknown-root:%s' "$1" ;;
    esac
}

case_begin "resolve-dir-spelling-alias-forms" "hooks/block-clearance-token-write/bash-target-context/classify.js"
# spelling | root it must resolve to (the helper appends /sub to both sides)
while IFS='|' read -r spelling root; do
    spelling="$(trim "$spelling")"; root="$(trim "$root")"
    [[ -z "$spelling" ]] && continue
    want="$(root_of "$root")/sub"
    got="$(probe rds "$spelling/sub" "$WF")"
    if [[ "$got" == "$want" ]]; then pass "rds $spelling -> $root"
    else fail "rds $spelling" "want=$want got=$got"; fi
done <<'TABLE'
${WORKFLOW_STATE_DIR:-x}   | WF
${WORKFLOW_STATE_DIR-x}    | WF
${WORKFLOW_STATE_DIR:=x}   | WF
${WORKFLOW_STATE_DIR=x}    | WF
$WORKFLOW_STATE_DIR        | WF
${WORKFLOW_STATE_DIR}      | WF
$HOME                       | HOME
${HOME}                     | HOME
${HOME:-x}                  | HOME
${HOME-x}                   | HOME
${HOME:=x}                  | HOME
$WORKFLOW_PLANS_DIR         | PLANS
${WORKFLOW_PLANS_DIR}       | PLANS
${WORKFLOW_PLANS_DIR:-x}    | PLANS
${WORKFLOW_PLANS_DIR-x}     | PLANS
${WORKFLOW_PLANS_DIR:=x}    | PLANS
TABLE
case_end

case_begin "resolve-dir-spelling-plus-operator-not-resolved" "hooks/block-clearance-token-write/bash-target-context/classify.js"
# `:+` substitutes the alternate word, so resolving it would be a guess; resolveDirSpelling
# returns an unresolvable spelling unchanged, so exactly the input must come back.
for spelling in '${WORKFLOW_STATE_DIR:+x}' '${HOME:+x}' '${WORKFLOW_PLANS_DIR:+x}'; do
    got="$(probe rds "$spelling/sub" "$WF")"
    if [[ "$got" == "$spelling/sub" ]]; then pass "rds $spelling stays unresolved ($got)"
    else fail "rds $spelling" "want=$spelling/sub (unchanged) got=${got:-empty}"; fi
done
case_end

case_begin "cwd-tracking-alias-resolution" "hooks/block-clearance-token-write/bash-scan/scan.js"
# name | command (__D__ = the directory spelling) | expected bashHitsProtected kind
while IFS='|' read -r dir cmd want; do
    dir="$(trim "$dir")"; cmd="$(trim "$cmd")"; want="$(trim "$want")"
    [[ -z "$dir" ]] && continue
    cmd="${cmd//__D__/$dir}"
    got="$(scan_verdict "$cmd")"
    if [[ "$got" == "$want" ]]; then pass "scan [$cmd] -> $got"
    else fail "scan [$cmd]" "want=$want got=$got"; fi
done <<'TABLE'
${WORKFLOW_STATE_DIR:-x}  | cd __D__ && echo x > s1*          | workflow-glob
${WORKFLOW_STATE_DIR-x}   | cd __D__ && echo x > s1*          | workflow-glob
${WORKFLOW_STATE_DIR:=x}  | cd __D__ && echo x > s1*          | workflow-glob
$WORKFLOW_STATE_DIR       | cd __D__ && echo x > s1*          | workflow-glob
${WORKFLOW_STATE_DIR}     | cd __D__ && echo x > s1*          | workflow-glob
${WORKFLOW_STATE_DIR:-x}  | cd __D__ && echo x > "s1$(date)"  | workflow-dynamic
${WORKFLOW_STATE_DIR:-x}  | echo x > __D__/s1*                | workflow-glob
${WORKFLOW_STATE_DIR-x}   | echo x > __D__/s1*                | workflow-glob
${WORKFLOW_STATE_DIR:=x}  | echo x > __D__/s1*                | workflow-glob
${WORKFLOW_STATE_DIR=x}   | echo x > __D__/s1*                | workflow-glob
${WORKFLOW_STATE_DIR=x}   | cd __D__ && echo x > s1*          | workflow-glob
${HOME:-x}/wf             | cd __D__ && echo x > s1*          | workflow-glob
${HOME-x}/wf               | echo x > __D__/s1*                | workflow-glob
$HOME/wf                   | cd __D__ && echo x > s1*          | workflow-glob
TABLE
case_end

case_begin "cwd-tracking-negatives" "hooks/block-clearance-token-write/bash-scan/scan.js"
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(trim "$cmd")"
    [[ -z "$name" ]] && continue
    cmd="${cmd//__OUT__/$OUT}"
    got="$(scan_verdict "$cmd")"
    if [[ "$got" == "null" ]]; then pass "negative $name -> null"
    else fail "negative $name" "want=null got=$got"; fi
done <<'TABLE'
cd-unrelated-glob   | cd __OUT__ && echo x > s1*
plans-default-glob  | cd ${WORKFLOW_PLANS_DIR:-x} && echo x > s1*
home-default-glob   | echo x > ${HOME:-x}/s1*
plans-note-static   | echo x > ${WORKFLOW_PLANS_DIR:-x}/wsid-note-x.md
plans-note-cd       | cd ${WORKFLOW_PLANS_DIR:-x} && echo x > wsid-note-x.md
home-note-static    | echo x > ${HOME:-x}/notes.txt
out-note-static     | echo x > __OUT__/notes.txt
TABLE
case_end

case_begin "plus-operator-fails-closed" "hooks/block-clearance-token-write/bash-scan/scan.js"
while IFS='|' read -r name cmd; do
    name="$(trim "$name")"; cmd="$(trim "$cmd")"
    [[ -z "$name" ]] && continue
    got="$(scan_verdict "$cmd")"
    case "$got" in
        null|ERR:*|'') fail "fail-closed $name" "want=blocked got=${got:-empty}" ;;
        *) pass "fail-closed $name -> $got" ;;
    esac
done <<'TABLE'
redirect-glob   | echo x > ${WORKFLOW_STATE_DIR:+x}/s1*
cd-then-glob    | cd ${WORKFLOW_STATE_DIR:+x} && echo x > s1*
cd-then-dynamic | cd ${WORKFLOW_STATE_DIR:+x} && echo x > "s1$(date)"
plus-no-colon   | echo x > ${WORKFLOW_STATE_DIR+x}/s1*
cd-plus-no-colon| cd ${WORKFLOW_STATE_DIR+x} && echo x > s1*
error-op        | echo x > ${WORKFLOW_STATE_DIR:?x}/s1*
cd-error-op     | cd ${WORKFLOW_STATE_DIR:?x} && echo x > s1*
prefix-strip    | echo x > ${WORKFLOW_STATE_DIR#p}/s1*
cd-prefix-strip | cd ${WORKFLOW_STATE_DIR#p} && echo x > s1*
length-op       | echo x > ${#WORKFLOW_STATE_DIR}/s1*
cd-length-op    | cd ${#WORKFLOW_STATE_DIR} && echo x > s1*
unterminated-brace | echo x > ${WORKFLOW_STATE_DIR/s1*
TABLE
case_end

case_begin "expander-quoting-and-malformed" "hooks/lib/bash-write-targets/detection-expand.js"
# Single quotes keep `$` literal in bash, whole-word or leading segment; an unterminated
# `${` cannot be placed, so it must come back dynamic (the caller fails closed).
while IFS='|' read -r name tok field want; do
    name="$(trim "$name")"; tok="$(trim "$tok")"; field="$(trim "$field")"; want="$(trim "$want")"
    [[ -z "$name" ]] && continue
    got="$(probe expand "$tok" "$OUT" "$field")"
    if [[ "$got" == "$want" ]]; then pass "expand $name $field -> $got"
    else fail "expand $name $field" "want=$want got=${got:-empty}"; fi
done <<'TABLE'
sq-whole-word       | '$WORKFLOW_STATE_DIR/x'  | path        | $WORKFLOW_STATE_DIR/x
unterminated-brace  | ${WORKFLOW_STATE_DIR/x   | dynamicTail | true
TABLE
# Partial quoting: expanding anyway is fail-safe (detection only widens), so either the
# literal or the workflow-dir expansion is accepted; narrowing is not required here.
got="$(probe expand "'\$WORKFLOW_STATE_DIR'/x" "$OUT" path)"
case "$got" in
    "\$WORKFLOW_STATE_DIR/x"|"$WF/x") pass "expand sq-leading-segment path -> $got" ;;
    *) fail "expand sq-leading-segment path" "want=\$WORKFLOW_STATE_DIR/x or $WF/x got=${got:-empty}" ;;
esac
case_end

case_begin "default-word-names-default-workflow-dir" "hooks/lib/bash-write-targets/detection-expand.js"
# `${WORKFLOW_STATE_DIR:-$HOME/.claude/projects/workflow}` with the variable unset or empty
# lands on the legacy workflow dir, which is protected like the configured one.
SPELL='${WORKFLOW_STATE_DIR:-$HOME/.claude/projects/workflow}'
for mode in unset empty; do
    pfn="probe_${mode}_wf"
    got="$("$pfn" expand "$SPELL/y" "$OUT" path)"
    if [[ "$got" == "$LEGACY_WF/y" ]]; then pass "expand[$mode] default-word -> legacy wf"
    else fail "expand[$mode] default-word" "want=$LEGACY_WF/y got=${got:-empty}"; fi
    got="$("$pfn" scan "echo x > $SPELL/s1*" "$OUT" "$SID")"
    if [[ "$got" == "workflow-glob" ]]; then pass "scan[$mode] default-word glob -> workflow-glob"
    else fail "scan[$mode] default-word glob" "want=workflow-glob got=${got:-empty}"; fi
    got="$("$pfn" scan "cd $SPELL && echo x > s1*" "$OUT" "$SID")"
    if [[ "$got" == "workflow-glob" ]]; then pass "scan[$mode] cd default-word glob -> workflow-glob"
    else fail "scan[$mode] cd default-word glob" "want=workflow-glob got=${got:-empty}"; fi
done
got="$(probe_unset_wf rds "$SPELL/sub" '')"
if [[ "$got" == "$LEGACY_WF/sub" ]]; then pass "rds[unset] default-word -> legacy wf"
else fail "rds[unset] default-word" "want=$LEGACY_WF/sub got=${got:-empty}"; fi
case_end

case_begin "expander-non-default-ops-never-resolve" "hooks/lib/bash-write-targets/detection-expand.js"
# Only :- - := = pick a value; every other operator must come back unresolved or dynamic.
for spelling in '${WORKFLOW_STATE_DIR:+x}' '${WORKFLOW_STATE_DIR+x}' '${WORKFLOW_STATE_DIR:?x}' '${WORKFLOW_STATE_DIR#p}' '${#WORKFLOW_STATE_DIR}'; do
    unres="$(probe expand "$spelling/s1" "$OUT" aliasUnresolved)"
    dyn="$(probe expand "$spelling/s1" "$OUT" dynamicTail)"
    if [[ "$unres" == "true" || "$dyn" == "true" ]]; then pass "expand $spelling -> unresolved=$unres dynamic=$dyn"
    else fail "expand $spelling" "resolved to a static path (unresolved=$unres dynamic=$dyn)"; fi
done
case_end

case_begin "set-but-empty-workflow-dir" "hooks/lib/bash-write-targets/detection-expand.js"
# WORKFLOW_STATE_DIR="" -> the resolver's default is the workflow dir. `:-` takes the
# default word; bare `-` keeps "" in bash, but detection-expand also takes the default,
# so the scan must at least not allow (fail closed), never approve by resolving to "".
got="$(probe_empty_wf expand '${WORKFLOW_STATE_DIR:-x}/y' "$OUT" path)"
if [[ "$got" == "x/y" ]]; then pass "expand empty \${WORKFLOW_STATE_DIR:-x} -> x/y"
else fail "expand empty \${WORKFLOW_STATE_DIR:-x}" "want=x/y got=$got"; fi
while IFS='|' read -r name cmd want; do
    name="$(trim "$name")"; cmd="$(trim "$cmd")"; want="$(trim "$want")"
    [[ -z "$name" ]] && continue
    cmd="${cmd//__DEF__/$DEFAULT_WF}"
    got="$(probe_empty_wf scan "$cmd" "$OUT" "$SID")"
    if [[ "$want" == "blocked" ]]; then
        case "$got" in
            null|ERR:*|'') fail "empty-wf $name" "want=blocked got=${got:-empty}" ;;
            *) pass "empty-wf $name -> $got" ;;
        esac
    elif [[ "$got" == "$want" ]]; then pass "empty-wf $name -> $got"
    else fail "empty-wf $name" "want=$want got=$got"; fi
done <<'TABLE'
colon-default-glob     | echo x > ${WORKFLOW_STATE_DIR:-__DEF__}/s1*         | workflow-glob
cd-colon-default-glob  | cd ${WORKFLOW_STATE_DIR:-__DEF__} && echo x > s1*   | workflow-glob
dash-default-glob      | echo x > ${WORKFLOW_STATE_DIR-__DEF__}/s1*          | blocked
cd-dash-default-glob   | cd ${WORKFLOW_STATE_DIR-__DEF__} && echo x > s1*    | blocked
bare-alias-glob        | echo x > $WORKFLOW_STATE_DIR/s1*                    | workflow-glob
TABLE
case_end

case_begin "unset-workflow-dir-falls-back-to-default" "hooks/block-clearance-token-write/bash-scan/scan.js"
# With WORKFLOW_STATE_DIR unset the resolver's default (<home>/.workflow-state) is the
# workflow dir; an alias spelling must resolve to it, never to "allow everything".
# The legacy root (<home>/.claude/projects/workflow) stays guarded while it exists.
while IFS='|' read -r name cmd want; do
    name="$(trim "$name")"; cmd="$(trim "$cmd")"; want="$(trim "$want")"
    [[ -z "$name" ]] && continue
    cmd="${cmd//__DEF__/$DEFAULT_WF}"
    got="$(probe_unset_wf scan "$cmd" "$OUT" "$SID")"
    if [[ "$got" == "$want" ]]; then pass "unset-wf $name -> $got"
    else fail "unset-wf $name" "want=$want got=$got"; fi
done <<'TABLE'
bare-alias-glob         | echo x > $WORKFLOW_STATE_DIR/s1*                    | workflow-glob
braced-alias-glob       | echo x > ${WORKFLOW_STATE_DIR}/s1*                  | workflow-glob
default-op-glob         | echo x > ${WORKFLOW_STATE_DIR:-__DEF__}/s1*         | workflow-glob
cd-default-op-glob      | cd ${WORKFLOW_STATE_DIR:-__DEF__} && echo x > s1*   | workflow-glob
tilde-default-glob      | echo x > ~/.workflow-state/s1*                       | workflow-glob
tilde-legacy-glob       | echo x > ~/.claude/projects/workflow/s1*             | workflow-glob
TABLE
got="$(probe_unset_wf rds '$WORKFLOW_STATE_DIR/sub' '')"
if [[ "$got" == "$DEFAULT_WF/sub" ]]; then pass "unset-wf rds \$WORKFLOW_STATE_DIR -> default"
else fail "unset-wf rds \$WORKFLOW_STATE_DIR" "want=$DEFAULT_WF/sub got=$got"; fi
case_end

case_begin "expander-unset-workflow-dir-default" "hooks/lib/bash-write-targets/detection-expand.js"
got_path="$(probe_unset_wf expand '$WORKFLOW_STATE_DIR/x' "$OUT" path)"
got_unres="$(probe_unset_wf expand '$WORKFLOW_STATE_DIR/x' "$OUT" aliasUnresolved)"
if [[ "$got_path" == "$DEFAULT_WF/x" ]]; then pass "expand unset alias -> default workflow dir"
else fail "expand unset alias path" "want=$DEFAULT_WF/x got=$got_path"; fi
if [[ "$got_unres" == "false" ]]; then pass "expand unset alias is resolved (not unresolved)"
else fail "expand unset alias aliasUnresolved" "want=false got=$got_unres"; fi
case_end

case_begin "classify-has-no-private-env-expander" "hooks/block-clearance-token-write/bash-target-context/classify.js"
cls_src="$(cat "$CLASSIFY_JS")"
if [[ "$cls_src" == *"ENV_REF_RE"* ]]; then fail "classify.js" "still defines a private ENV_REF_RE"
else pass "classify.js has no private ENV_REF_RE"; fi
if [[ "$cls_src" == *"detection-expand"* && "$cls_src" == *"expandForDetection"* ]]; then
    pass "classify.js resolves through detection-expand's expandForDetection"
else fail "classify.js" "does not import expandForDetection from detection-expand.js"; fi
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[[ "$FAIL" -eq 0 ]]
