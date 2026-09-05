#!/usr/bin/env bash
# tests/feature-codegraph-explore-guard.sh
# Tests: hooks/block-dotenv.js, hooks/block-credentials.js
# Tags: codegraph, hook, security, credential-guard, mcp, classifier, TL2, pwsh-not-required, scope:issue-specific
# G1-G5 (#2150 review) — mcp__codegraph__codegraph_explore is Read-equivalent and is
# pre-approved in settings.json, so before the fix it was a pre-approved way to have
# .env or ~/.ssh/id_rsa read back verbatim without either credential guard ever
# seeing it. Pattern 2: the pre-fix hooks had no case for this tool name, so the
# switch fell through to approve and EVERY block row below failed against them.
set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DOTENV_HOOK="$AGENTS_DIR/hooks/block-dotenv.js"
CREDS_HOOK="$AGENTS_DIR/hooks/block-credentials.js"
RUN_WITH_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"
TOOL="mcp__codegraph__codegraph_explore"

# TL3 gap (what this test does NOT catch):
# - whether Claude Code really routes this tool name through PreToolUse at run time
#   (the matcher wiring is pinned statically by tests/feature-codegraph-wiring-static.sh).
# - whether the real codegraph MCP server would have returned the file it was asked for.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight, category: installer.

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

# Fixture isolation: the parent session exports the ids these hooks resolve for
# WORKFLOW_OFF, and the plans dir must be pinned in the same breath as the workflow
# dir or the supervisor emitter appends to the developer's real ~/.workflow-plans.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID 2>/dev/null || true
TMP_BASE="$(mktemp -d)"
trap 'rm -rf "$TMP_BASE"' EXIT
export CLAUDE_WORKFLOW_DIR="$TMP_BASE/wf" WORKFLOW_PLANS_DIR="$TMP_BASE/plans"
export HOME="$TMP_BASE/home"
mkdir -p "$HOME" "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"

for h in "$DOTENV_HOOK" "$CREDS_HOOK"; do
    [ -f "$h" ] || fail "IMPLEMENTATION MISSING: ${h#"$AGENTS_DIR"/}"
done
[ -f "$RUN_WITH_TIMEOUT" ] || { echo "FAIL: harness missing bin/run-with-timeout.sh"; exit 1; }

# run_hook <hook-path> <json> — echoes the hook's decision word, or a marker that
# names the failure mode, so a crashed hook can never read as "approve".
run_hook() {
    local hook="$1" json="$2" out rc=0
    out="$(printf '%s' "$json" | bash "$RUN_WITH_TIMEOUT" 60 node "$hook" 2>/dev/null)" || rc=$?
    if [ "$rc" -ne 0 ]; then printf 'EXIT-%s' "$rc"; return; fi
    case "$out" in
        *'"block"'*) printf 'block' ;;
        *'"approve"'*) printf 'approve' ;;
        *) printf 'NO-DECISION' ;;
    esac
}

assert_decision() {
    local name="$1" hook="$2" want="$3" json="$4" got
    got="$(run_hook "$hook" "$json")"
    if [ "$want" = "$got" ]; then pass "$name — $want"
    else fail "$name — want=$want got=$got"; fi
}

explore_query() { printf '{"tool_name":"%s","tool_input":{"query":"%s"}}' "$TOOL" "$1"; }
explore_root()  { printf '{"tool_name":"%s","tool_input":{"projectPath":"%s"}}' "$TOOL" "$1"; }

# --- G1/G2: the block direction, per guard. Every row here approved before the fix.
echo "=== G1: block-dotenv.js blocks a .env named in the explore input ==="
while IFS='|' read -r case_id field value; do
    [ -n "$case_id" ] || continue
    case_id="${case_id//[[:space:]]/}"; field="${field//[[:space:]]/}"; value="${value//[[:space:]]/}"
    if [ "$field" = "query" ]; then payload="$(explore_query "$value")"; else payload="$(explore_root "$value")"; fi
    assert_decision "G1/$case_id ($field=$value)" "$DOTENV_HOOK" block "$payload"
done <<'TABLE'
G1-a | query       | .env
G1-b | query       | .env.local
G1-c | query       | .env.production
G1-d | query       | config/.env
G1-e | query       | .env.*
G1-f | projectPath | /repo/.env
G1-g | projectPath | .env.local
TABLE

echo "=== G2: block-credentials.js blocks a credential path named in the explore input ==="
while IFS='|' read -r case_id field value; do
    [ -n "$case_id" ] || continue
    case_id="${case_id//[[:space:]]/}"; field="${field//[[:space:]]/}"; value="${value//[[:space:]]/}"
    if [ "$field" = "query" ]; then payload="$(explore_query "$value")"; else payload="$(explore_root "$value")"; fi
    assert_decision "G2/$case_id ($field=$value)" "$CREDS_HOOK" block "$payload"
done <<'TABLE'
G2-a | query       | ~/.ssh/id_rsa
G2-b | query       | ~/.aws/credentials
G2-c | query       | ~/.netrc
G2-d | query       | ~/.config/gh/hosts.yml
G2-e | projectPath | ~/.ssh
G2-f | projectPath | ~/.gnupg
TABLE

echo "=== G3: a sentence-shaped query is tokenized, not matched as a whole string ==="
# The realistic attack is prose, not a bare path: the tool takes free text, so the
# guard has to reach the path token buried inside a plausible-looking question.
assert_decision "G3-a (prose naming .env)" "$DOTENV_HOOK" block \
    "$(explore_query "how is the API token in .env loaded at startup")"
assert_decision "G3-b (prose naming .env.local, comma-separated)" "$DOTENV_HOOK" block \
    "$(explore_query "compare config.js, .env.local, and settings")"
assert_decision "G3-c (prose naming a private key)" "$CREDS_HOOK" block \
    "$(explore_query "explain the deploy script that reads ~/.ssh/id_rsa")"
assert_decision "G3-d (parenthesised credential path)" "$CREDS_HOOK" block \
    "$(explore_query "where is the registry token read (~/.npmrc) during publish")"

# --- G4: the allow direction (Pattern 4). A classifier proven only on the block
# side ships as over-blocking: this tool is the agents' primary reader, so a guard
# that trips on the word "environment" would quietly break every CodeGraph session.
echo "=== G4: benign explore input is approved by both guards ==="
while IFS='|' read -r case_id hook field value; do
    [ -n "$case_id" ] || continue
    case_id="${case_id//[[:space:]]/}"; hook="${hook//[[:space:]]/}"
    field="${field//[[:space:]]/}"
    value="${value#"${value%%[![:space:]]*}"}"; value="${value%"${value##*[![:space:]]}"}"
    case "$hook" in dotenv) hook_path="$DOTENV_HOOK" ;; *) hook_path="$CREDS_HOOK" ;; esac
    if [ "$field" = "query" ]; then payload="$(explore_query "$value")"; else payload="$(explore_root "$value")"; fi
    assert_decision "G4/$case_id ($hook, $field=$value)" "$hook_path" approve "$payload"
done <<'TABLE'
G4-a | dotenv | query       | how does the workflow gate decide to block
G4-b | dotenv | query       | .env.example
G4-c | dotenv | query       | document the .env.example defaults
G4-d | dotenv | query       | .envrc
G4-e | dotenv | query       | where is the environment resolved
G4-f | dotenv | projectPath | /repo/src
G4-g | creds  | query       | how does the workflow gate decide to block
G4-h | creds  | query       | hooks/block-credentials.js
G4-i | creds  | projectPath | /repo/src
TABLE

echo "=== G5: shape edges — a missing, empty or non-string field is not a match ==="
# The MCP client can omit either field. An implementation that coerced them would
# either crash the hook (fail-closed on every call) or match on "undefined".
while IFS='|' read -r case_id hook payload; do
    [ -n "$case_id" ] || continue
    case_id="${case_id//[[:space:]]/}"; hook="${hook//[[:space:]]/}"
    payload="${payload#"${payload%%[![:space:]]*}"}"; payload="${payload%"${payload##*[![:space:]]}"}"
    case "$hook" in dotenv) hook_path="$DOTENV_HOOK" ;; *) hook_path="$CREDS_HOOK" ;; esac
    assert_decision "G5/$case_id ($hook)" "$hook_path" approve "$payload"
done <<'TABLE'
G5-a | dotenv | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{}}
G5-b | dotenv | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{"query":""}}
G5-c | dotenv | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{"query":null}}
G5-d | dotenv | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{"query":123}}
G5-e | creds  | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{}}
G5-f | creds  | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{"query":""}}
G5-g | creds  | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{"query":null}}
G5-h | creds  | {"tool_name":"mcp__codegraph__codegraph_explore","tool_input":{"query":123}}
TABLE

echo "=== G6: the guard is bound to this tool name, and each guard keeps its own family ==="
# A guard that blocked on the payload regardless of tool_name would be matching the
# text, not the tool — which is a different (and much noisier) contract.
assert_decision "G6-a (unrelated tool name, .env in a query field)" "$DOTENV_HOOK" approve \
    '{"tool_name":"mcp__other__search","tool_input":{"query":".env"}}'
assert_decision "G6-b (unrelated tool name, id_rsa in a query field)" "$CREDS_HOOK" approve \
    '{"tool_name":"mcp__other__search","tool_input":{"query":"~/.ssh/id_rsa"}}'
assert_decision "G6-c (block-dotenv does not own the credential family)" "$DOTENV_HOOK" approve \
    "$(explore_query "~/.ssh/id_rsa")"
assert_decision "G6-d (block-credentials does not own the dotenv family)" "$CREDS_HOOK" approve \
    "$(explore_query ".env.local")"

echo ""
echo "=== Results: $PASS passed, $FAIL failed ==="
[ "$FAIL" -eq 0 ] || exit 1
exit 0
