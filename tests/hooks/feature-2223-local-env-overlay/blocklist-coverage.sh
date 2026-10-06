#!/usr/bin/env bash
# tests/hooks/feature-2223-local-env-overlay/blocklist-coverage.sh
# Tests: hooks/lib/local-env.js, hooks/lib/load-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, trust-boundary, pwsh-not-required
# Case file for tests/hooks/feature-2223-local-env-overlay.sh — sourced from it, never
# run standalone (it uses that file's helpers, fixtures and PASS/FAIL counters).
# Split off because the parent exceeded the 500-line HARD limit; the
# sibling-folder form is the split rules/coding/file-split.md sanctions.
# Holds every case about what the blocklist REFUSES from the local layer.
# TL3 gap: same as the parent's — a real repo edited mid-session is out of reach.
LOCAL_ENV_BLOCKLIST_CASES_LOADED=1

# ---------------------------------------------------------------------------
# Table 2 — the blocklist keeps the GLOBAL value in force. A stale
# LOCAL_OVERRIDABLE_KEYS line naming the very key under test rides along in the
# global fixture, so a pass also proves that dead setting grants nothing.
# Columns: name | key | global value | local value
# ---------------------------------------------------------------------------
while IFS='|' read -r name key gval lval; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    key="$(trim "$key")"; gval="$(trim "$gval")"; lval="$(trim "$lval")"
    new_case "$name" "LOCAL_OVERRIDABLE_KEYS=$key@NL@$key=$gval" "$key=$lval"
    got="$(probe effective "$CASE_ROOT_NODE" "$key")"
    assert_eq "T2223N-$name" "\"$gval\"" "$got"
done <<'TABLE'
blocked-enforce-worktree        | ENFORCE_WORKTREE            | on            | off
blocked-enforce-worktree-excl   | ENFORCE_WORKTREE_EXCLUDE    | repoA         | evil
blocked-auto-approve-tools      | AUTO_APPROVE_TOOLS          | off           | on
blocked-workflow-plans-dir      | WORKFLOW_PLANS_DIR          | /global-plans | /tmp/evil
blocked-workflow-state-dir     | WORKFLOW_STATE_DIR         | /global-wf    | /tmp/evil
blocked-agents-config-dir       | AGENTS_CONFIG_DIR           | /global-cfg   | /tmp/evil
blocked-agents-state-dir        | AGENTS_STATE_DIR            | /global-state | /tmp/evil
blocked-worktree-base-dir      | WORKTREE_BASE_DIR           | /global-wt    | /tmp/evil
blocked-default-branches        | DEFAULT_BRANCHES            | main          | evil
blocked-sweep-age-days          | SWEEP_AGE_DAYS              | 30            | 0
blocked-mcp-fs-debug            | MCP_FS_DEBUG                | off           | on
blocked-code-file-extensions    | CODE_FILE_EXTENSIONS        | js            | evil
blocked-code-lang-exclude       | CODE_LANG_EXCLUDE           | none          | everything
prefix-session-anything         | SESSION_ANYTHING            | off           | on
prefix-propagate-labels-pat     | PROPAGATE_LABELS_PAT        | globaltoken   | stolen
prefix-codex-nfr-max-lines      | CODEX_NFR_MAX_LINES         | 200           | 999999
prefix-comment-block-max-lines  | COMMENT_BLOCK_MAX_LINES     | 10            | 9999
blocked-jev                     | JEV                         | off           | on
blocked-typesafe-api-key        | TYPESAFE_API_KEY            | globalkey     | repokey
prefix-jev-base-url             | JEV_BASE_URL                | https://g.example | http://127.0.0.1:1
TABLE

# ---------------------------------------------------------------------------
# Table 2b — EVERY current blocklist entry, in three spellings. The key list is
# read out of local-env.js itself (CPR-SSOT), so an entry added tomorrow is
# covered the day it lands. isBlocklisted() upper-cases before matching because
# Windows env names are case-insensitive, so a lower- or mixed-case key must not
# slip past; each fixture gives all three spellings their own global value.
# ---------------------------------------------------------------------------
mixed_case() {
    local up lo
    lo="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    up="$(printf '%s' "${lo:0:1}" | tr 'a-z' 'A-Z')"
    printf '%s%s' "$up" "${lo:1}"
}

deny_all_spellings() {
    local label="$1" canon="$2" lower mixed genv lenv json
    lower="$(printf '%s' "$canon" | tr 'A-Z' 'a-z')"
    mixed="$(mixed_case "$canon")"
    genv="$canon=gv-canon-$label@NL@$lower=gv-lower-$label@NL@$mixed=gv-mixed-$label"
    lenv="$canon=DENYLOCAL@NL@$lower=DENYLOCAL@NL@$mixed=DENYLOCAL"
    new_case "deny-$label" "$genv" "$lenv"
    json="$(probe effective-json "$CASE_ROOT_NODE")"
    assert_map_lacks "T2223N2-$canon-local-never-wins" "$json" 'DENYLOCAL'
    assert_contains "T2223N2-$canon-canonical-global-kept" "$json" "gv-canon-$label"
    assert_contains "T2223N2-$canon-lower-global-kept" "$json" "gv-lower-$label"
    assert_contains "T2223N2-$canon-mixed-global-kept" "$json" "gv-mixed-$label"
}

new_case deny-enum 'CODE_LANG=english' '__NONE__'
DENY_EXACT="$(probe blocklist-keys exact)"
DENY_PREFIXES="$(probe blocklist-keys prefixes)"

# Full membership, not a count: a silently dropped entry is the regression here.
WANT_EXACT="$(printf '%s\n' AGENTS_CONFIG_DIR AGENTS_STATE_DIR AUTO_APPROVE_TOOLS \
    CLAUDE_CODE_AUTO_COMPACT_WINDOW WORKFLOW_STATE_DIR \
    CODE_FILE_EXTENSIONS CODE_LANG_EXCLUDE DEFAULT_BRANCHES ENFORCE_WORKTREE \
    ENFORCE_WORKTREE_ADDITIONAL_REPOS ENFORCE_WORKTREE_EXCLUDE ISSUE_VERDICT_WEB_SEARCH \
    JEV MCP_FS_DEBUG MERGE_BASE_MAX_DIFF_FILES MERGE_BASE_MAX_DIFF_LINES \
    NODE_EXTRA_CA_CERTS NODE_OPTIONS NODE_TLS_REJECT_UNAUTHORIZED NODE_USE_ENV_PROXY \
    PLAN_SYNC_REMOTE_URL SWEEP_AGE_DAYS TYPESAFE_API_KEY VERBOSE_PROMPT_MODELS \
    WORKFLOW_PLANS_DIR WORKTREE_BASE_DIR)"
WANT_PREFIXES="$(printf '%s\n' CODEX_ COMMENT_BLOCK_ JEV_ PROPAGATE_ SESSION_)"
assert_eq "T2223N2-exact-set-membership" "$WANT_EXACT" "$(printf '%s' "$DENY_EXACT" | sed '/^$/d')"
assert_eq "T2223N2-prefix-list-membership" "$WANT_PREFIXES" "$(printf '%s' "$DENY_PREFIXES" | sed '/^$/d')"
assert_not_contains "T2223N2-stale-decl-key-not-blocklisted" "$DENY_EXACT" 'LOCAL_OVERRIDABLE_KEYS'

# The allowlist half of the old two-stage gate is gone from the module surface.
for gone in DEFAULT_LOCAL_OVERRIDABLE NEVER_OVERRIDABLE_EXACT NEVER_OVERRIDABLE_PREFIXES \
            isNeverOverridable resolveOverridableKeys; do
    if grep -qE "exports\.$gone|^[[:space:]]*$gone," "$LOCAL_ENV_JS" 2>/dev/null; then
        fail "T2223N2-removed-export-$gone — still exported by local-env.js"
    else
        pass "T2223N2-removed-export-$gone"
    fi
done

# isBlocklisted's fail-closed edges: a non-string and an empty key are refused.
assert_eq "T2223N2-isBlocklisted-empty-key" "true" "$(probe is-blocklisted __EMPTY__)"
assert_eq "T2223N2-isBlocklisted-ordinary-key" "false" "$(probe is-blocklisted PROJECT_NFR)"
assert_eq "T2223N2-isBlocklisted-lowercase-blocked" "true" "$(probe is-blocklisted enforce_worktree)"
assert_eq "T2223N2-isBlocklisted-mixedcase-blocked" "true" "$(probe is-blocklisted Enforce_Worktree)"
assert_eq "T2223N2-isBlocklisted-stale-decl-key" "false" "$(probe is-blocklisted LOCAL_OVERRIDABLE_KEYS)"

# The same fail-closed edge for a key that is not a string at all — a parser
# regression handing over undefined, null, a number or a container must refuse,
# never fall through to the ordinary-key verdict.
for _raw in __UNDEF__ __NULL__ __NUM__ __OBJ__ __ARR__; do
    assert_eq "T2223N2-isBlocklisted-nonstring-$_raw" "true" "$(probe is-blocklisted-raw "$_raw")"
done

# The isolation pair: a local WORKFLOW_STATE_DIR or AGENTS_CONFIG_DIR would
# relocate the workflow-state root, or the directory this layer reads the global
# .env from — named here so a removal from the exact set fails by name.
assert_eq "T2223N2-isBlocklisted-workflow-state-dir" "true" "$(probe is-blocklisted WORKFLOW_STATE_DIR)"
assert_eq "T2223N2-isBlocklisted-workflow-state-dir-lower" "true" "$(probe is-blocklisted workflow_state_dir)"
assert_eq "T2223N2-isBlocklisted-agents-config-dir" "true" "$(probe is-blocklisted AGENTS_CONFIG_DIR)"
assert_eq "T2223N2-isBlocklisted-agents-config-dir-lower" "true" "$(probe is-blocklisted agents_config_dir)"
# Their sibling (#2460): the state/log root that Jev retention deletes under.
assert_eq "T2223N2-isBlocklisted-agents-state-dir" "true" "$(probe is-blocklisted AGENTS_STATE_DIR)"
assert_eq "T2223N2-isBlocklisted-agents-state-dir-lower" "true" "$(probe is-blocklisted agents_state_dir)"
# The four names Node itself reads (#2460): TLS verification, a trusted CA, an env proxy
# and code preload, in the hook that makes the credentialed Jev call.
for _nk in NODE_TLS_REJECT_UNAUTHORIZED NODE_OPTIONS NODE_EXTRA_CA_CERTS NODE_USE_ENV_PROXY \
           node_options Node_Tls_Reject_Unauthorized; do
    assert_eq "T2223N2-isBlocklisted-node-$_nk" "true" "$(probe is-blocklisted "$_nk")"
done

_i=0
while IFS= read -r _k; do
    [ -n "$_k" ] || continue
    _i=$((_i + 1))
    deny_all_spellings "e$_i" "$_k"
done <<EOF
$DENY_EXACT
EOF

# A prefix is proven by a key that only the prefix can deny — a name the exact
# set does not carry, so a pass cannot come from the exact list by accident.
_i=0
while IFS= read -r _p; do
    [ -n "$_p" ] || continue
    _i=$((_i + 1))
    deny_all_spellings "p$_i" "${_p}CANARY2223"
done <<EOF
$DENY_PREFIXES
EOF

# T2223-blocklist-batch — several blocklisted keys at once, alongside a stale
# declaration the local file tries to rewrite. Nothing local may reach the map.
new_case blocklist-batch \
  'LOCAL_OVERRIDABLE_KEYS=ENFORCE_WORKTREE,WORKTREE_BASE_DIR@NL@ENFORCE_WORKTREE=on@NL@WORKTREE_BASE_DIR=/global-wt@NL@MCP_FS_DEBUG=off@NL@SESSION_KIND=global@NL@CODEX_MODE=global' \
  'ENFORCE_WORKTREE=EVILLOCAL@NL@WORKTREE_BASE_DIR=EVILLOCAL@NL@MCP_FS_DEBUG=EVILLOCAL@NL@SESSION_KIND=EVILLOCAL@NL@CODEX_MODE=EVILLOCAL'
batch_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_map_lacks "T2223-blocklist-batch-nothing-local-applied" "$batch_json" 'EVILLOCAL'
assert_contains "T2223-blocklist-batch-global-kept" "$batch_json" '"ENFORCE_WORKTREE":"on"'
assert_contains "T2223-blocklist-batch-prefix-global-kept" "$batch_json" '"SESSION_KIND":"global"'

# T2223-ordinary-local-keys-apply — the symmetric counterpart: a key the
# blocklist does not name reaches the map even though nothing declared it.
new_case ordinary-apply 'CODE_LANG=english' 'PROJECT_NFR=nfr-from-local@NL@OTHER_KEY=other-from-local'
ordinary_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_contains "T2223-ordinary-local-nfr-applied" "$ordinary_json" 'nfr-from-local'
assert_contains "T2223-ordinary-local-sibling-applied" "$ordinary_json" 'other-from-local'

# ---------------------------------------------------------------------------
# The damage the two NEW entries would do, asserted the way ENFORCE_WORKTREE's
# is (T2223-door-loadEnv-blocklisted) — CPR-ORTH. WORKFLOW_STATE_DIR travels
# through process.env via applyLocalOverlayToProcessEnv and relocates the
# workflow-state root; AGENTS_CONFIG_DIR redirects the directory this very layer
# reads the global .env from.
# The naive probe would pass for the wrong reason: the harness exports both, and
# a non-empty process.env outranks either layer — so each row unsets first.
# ---------------------------------------------------------------------------
new_case escalate-wf 'CODE_LANG=english' 'WORKFLOW_STATE_DIR=/tmp/evil-wf-2223'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
esc_wf="$( ( unset WORKFLOW_STATE_DIR; probe load-default WORKFLOW_STATE_DIR ) )"
assert_eq "T2223N2-escalate-workflow-dir-never-injected" "__ABSENT__" "$esc_wf"

# Positive control in the same shape: without it the row above could pass
# because the probe itself is broken rather than because the key was refused.
new_case escalate-wf-control 'CODE_LANG=english' 'ORDINARY_WF_KEY=/tmp/ok-2223'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
esc_ok="$( ( unset WORKFLOW_STATE_DIR; probe load-default ORDINARY_WF_KEY ) )"
assert_eq "T2223N2-escalate-control-ordinary-key-injected" '"/tmp/ok-2223"' "$esc_ok"

# AGENTS_STATE_DIR (#2460) in the same shape: a local value would move the state
# root that Jev retention deletes under. The ordinary key beside it in the same
# local file is the control that the file was read and the probe is live.
new_case escalate-state 'CODE_LANG=english' \
  'AGENTS_STATE_DIR=/tmp/evil-state-2460@NL@ORDINARY_STATE_KEY=/tmp/ok-state-2460'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
esc_state="$( ( unset AGENTS_STATE_DIR; probe load-default AGENTS_STATE_DIR ) )"
assert_eq "T2223N2-escalate-state-dir-never-injected" "__ABSENT__" "$esc_state"
esc_state_ok="$( ( unset AGENTS_STATE_DIR; probe load-default ORDINARY_STATE_KEY ) )"
assert_eq "T2223N2-escalate-state-control-ordinary-key-injected" '"/tmp/ok-state-2460"' "$esc_state_ok"
esc_state_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_map_lacks "T2223N2-escalate-state-dir-absent-from-map" "$esc_state_json" 'evil-state-2460'
# overlay() names the refused key in `ignored` (both spellings) and applies the
# look-alike one character past the boundary.
esc_state_overlay="$(run_with_timeout 20 node -e '
  const m = require(require("path").join(process.env.AGENTS_DIR_NODE, "hooks", "lib", "local-env.js"));
  const r = m.overlay({ AGENTS_STATE_DIR: "global-state-2460" },
    { AGENTS_STATE_DIR: "evil-2460", agents_state_dir: "evil-2460", AGENTS_STATE_DIRX: "applied-2460" });
  process.stdout.write(JSON.stringify({ map: r.map, applied: r.applied, ignored: r.ignored }));
' 2>/dev/null)"
assert_eq "T2223N2-overlay-reports-state-dir-ignored" \
  '{"map":{"AGENTS_STATE_DIR":"global-state-2460","AGENTS_STATE_DIRX":"applied-2460"},"applied":["AGENTS_STATE_DIRX"],"ignored":["AGENTS_STATE_DIR","agents_state_dir"]}' \
  "$esc_state_overlay"

# The Node runtime names (#2460) in the same shape: a repo's local file must not switch
# off TLS verification or preload code in the loader's own process. NODE_ENV in the same
# file is the control: read, applied, and proof the entries are exact, not a NODE_ prefix.
NODE_OPT_VALUE='--title=evil-node-options-2460'
new_case escalate-node 'CODE_LANG=english' \
  "NODE_OPTIONS=$NODE_OPT_VALUE@NL@NODE_TLS_REJECT_UNAUTHORIZED=0@NL@node_options=$NODE_OPT_VALUE@NL@NODE_ENV=node-env-2460"
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
# node_probe <probe args...>: the probe with every tested NODE_* name absent from its env.
node_probe() {
    ( unset NODE_OPTIONS NODE_TLS_REJECT_UNAUTHORIZED NODE_ENV node_options; probe "$@" )
}
assert_eq "T2223N2-escalate-node-options-never-injected" "__ABSENT__" "$(node_probe load-default NODE_OPTIONS)"
assert_eq "T2223N2-escalate-node-tls-never-injected" "__ABSENT__" \
  "$(node_probe load-default NODE_TLS_REJECT_UNAUTHORIZED)"
assert_eq "T2223N2-escalate-node-options-value-in-no-env-slot" "false" \
  "$(node_probe load-default-has-value "$NODE_OPT_VALUE")"
assert_eq "T2223N2-escalate-node-control-node-env-injected" '"node-env-2460"' "$(node_probe load-default NODE_ENV)"
esc_node_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_map_lacks "T2223N2-escalate-node-options-absent-from-map" "$esc_node_json" 'evil-node-options-2460'
assert_not_contains "T2223N2-escalate-node-tls-absent-from-map" "$esc_node_json" 'NODE_TLS_REJECT_UNAUTHORIZED'
assert_contains "T2223N2-escalate-node-env-in-map" "$esc_node_json" '"NODE_ENV":"node-env-2460"'
unset CLAUDE_PROJECT_DIR

# A decoy config dir the local file tries to point the reader at. Load-bearing on
# the map itself: the decoy path must be absent from it, so removing
# AGENTS_CONFIG_DIR from the exact set lets the key ride in and fails this row.
DECOY_CFG="$TMP_ROOT/decoy-cfg-2223"
mkdir -p "$DECOY_CFG"
printf 'CODE_LANG=decoy-2223\n' > "$DECOY_CFG/.env"
new_case escalate-cfg 'CODE_LANG=english' \
  "AGENTS_CONFIG_DIR=$(to_node_path "$DECOY_CFG")@NL@ORDINARY_CFG_KEY=ok-cfg-2223"
esc_cfg_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_map_lacks "T2223N2-escalate-config-dir-never-redirects" "$esc_cfg_json" 'decoy-cfg-2223'
assert_eq "T2223N2-escalate-config-dir-global-value-kept" '"english"' \
  "$(probe effective "$CASE_ROOT_NODE" CODE_LANG)"
# Controls: the local file really was read at all, and the decoy really is a
# readable config dir with a different answer of its own.
assert_contains "T2223N2-escalate-control-local-file-read" "$esc_cfg_json" 'ok-cfg-2223'
ESC_SAVED_CFG="$CASE_CFG"
CASE_CFG="$DECOY_CFG"
assert_eq "T2223N2-escalate-decoy-config-dir-is-real" '"decoy-2223"' "$(probe global CODE_LANG)"
CASE_CFG="$ESC_SAVED_CFG"

# ---------------------------------------------------------------------------
# Boundary negatives. deny_all_spellings proves <PREFIX>CANARY2223 is denied but
# never proves the ALLOW verdict just outside the boundary — silent
# over-blocking of a project's ordinary key is the false positive that catches.
# Columns: name | key | want
# ---------------------------------------------------------------------------
new_case boundary-probe 'CODE_LANG=english' '__NONE__'
while IFS='|' read -r name key want; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    key="$(trim "$key")"; want="$(trim "$want")"
    assert_eq "T2223N2-boundary-$name" "$want" "$(probe is-blocklisted "$key")"
done <<'TABLE'
codex-bare                 | CODEX                     | false
session-bare               | SESSION                   | false
propagate-bare             | PROPAGATE                 | false
comment-block-bare         | COMMENT_BLOCK             | false
agents-config-dir-suffixed | AGENTS_CONFIG_DIR_OLD     | false
agents-state-dir-longer    | AGENTS_STATE_DIRX         | false
agents-state-dir-shorter   | AGENTS_STATE              | false
workflow-state-dir-longer  | WORKFLOW_STATE_DIRECTORY | false
auto-approve-tools-extra   | AUTO_APPROVE_TOOLS_EXTRA  | false
enforce-bare               | ENFORCE                   | false
codex-prefix-itself        | CODEX_                    | true
session-prefix-itself      | SESSION_                  | true
propagate-prefix-itself    | PROPAGATE_                | true
comment-block-prefix-itself| COMMENT_BLOCK_            | true
jev-bare-longer            | JEVX                      | false
jev-prefix-itself          | JEV_                      | true
node-env                   | NODE_ENV                  | false
node-bare                  | NODE                      | false
node-prefix-only           | NODE_                     | false
node-options-longer        | NODE_OPTIONSX             | false
node-path                  | NODE_PATH                 | false
https-proxy                | HTTPS_PROXY               | false
http-proxy                 | HTTP_PROXY                | false
no-proxy                   | NO_PROXY                  | false
TABLE

# End to end: a boundary key really does reach the effective map.
new_case boundary-applies 'CODE_LANG=english' \
  'CODEX=applied-2223@NL@AGENTS_CONFIG_DIR_OLD=applied-2223'
boundary_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_contains "T2223N2-boundary-codex-bare-applies" "$boundary_json" '"CODEX":"applied-2223"'
assert_contains "T2223N2-boundary-config-dir-suffixed-applies" "$boundary_json" \
  '"AGENTS_CONFIG_DIR_OLD":"applied-2223"'
