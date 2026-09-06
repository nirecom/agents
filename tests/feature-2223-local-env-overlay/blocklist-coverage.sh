#!/usr/bin/env bash
# tests/feature-2223-local-env-overlay/blocklist-coverage.sh
# Tests: hooks/lib/local-env.js, hooks/lib/load-env.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, trust-boundary, pwsh-not-required
# Case file for tests/feature-2223-local-env-overlay.sh — sourced from it, never
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
blocked-worktree-base-dir       | WORKTREE_BASE_DIR           | /global-wt    | /tmp/evil
blocked-default-branches        | DEFAULT_BRANCHES            | main          | evil
blocked-sweep-age-days          | SWEEP_AGE_DAYS              | 30            | 0
blocked-mcp-fs-debug            | MCP_FS_DEBUG                | off           | on
blocked-code-file-extensions    | CODE_FILE_EXTENSIONS        | js            | evil
blocked-code-lang-exclude       | CODE_LANG_EXCLUDE           | none          | everything
prefix-session-anything         | SESSION_ANYTHING            | off           | on
prefix-propagate-labels-pat     | PROPAGATE_LABELS_PAT        | globaltoken   | stolen
prefix-codex-nfr-max-lines      | CODEX_NFR_MAX_LINES         | 200           | 999999
prefix-comment-block-max-lines  | COMMENT_BLOCK_MAX_LINES     | 10            | 9999
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
WANT_EXACT="$(printf '%s\n' AUTO_APPROVE_TOOLS CLAUDE_CODE_AUTO_COMPACT_WINDOW \
    CODE_FILE_EXTENSIONS CODE_LANG_EXCLUDE DEFAULT_BRANCHES ENFORCE_WORKTREE \
    ENFORCE_WORKTREE_ADDITIONAL_REPOS ENFORCE_WORKTREE_EXCLUDE ISSUE_VERDICT_WEB_SEARCH \
    MCP_FS_DEBUG MERGE_BASE_MAX_DIFF_FILES MERGE_BASE_MAX_DIFF_LINES \
    SHOW_PLAN_LINK_NO_AUTO_OPEN SWEEP_AGE_DAYS VERBOSE_PROMPT_MODELS \
    WORKFLOW_PLANS_DIR WORKTREE_BASE_DIR)"
WANT_PREFIXES="$(printf '%s\n' CODEX_ COMMENT_BLOCK_ PROPAGATE_ SESSION_)"
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
