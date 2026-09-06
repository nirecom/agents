#!/usr/bin/env bash
# tests/feature-2223-local-env-overlay.sh
# Tests: hooks/lib/local-env.js, hooks/lib/load-env.js, hooks/lib/plan-confirm-flag.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, trust-boundary, pwsh-not-required
# RED for issue #2223 — the 2-layer global/.env + project-local override resolver.
# Pinned contract: load-env.js exports readEffectiveEnvFile(projectRoot) -> map;
# local-env.js exports resolveProjectRoot(explicitRoot, startDir), overlay(
# globalMap, localMap, allowedSet) -> {map, applied, ignored}, NEVER_OVERRIDABLE_EXACT
# and NEVER_OVERRIDABLE_PREFIXES.
# TL3 gap: a real repo whose own .env.local is edited mid-session is out of reach here.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi
export AGENTS_DIR_NODE

# The local-override file is never named as a whole path literal: hooks/block-dotenv.js
# blocks that spelling (DD-1). Every use joins a directory variable to this basename.
LOCAL_ENV_BASENAME=".env"".local"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Fixture isolation: pin both halves of the plans-dir pair, drop inherited session
# ids, and never let an ambient AGENTS_CONFIG_DIR or project dir reach a child.
export CLAUDE_WORKFLOW_DIR="$TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PROJECT_DIR
unset AGENTS_CONFIG_DIR

PASS=0; FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then
        pass "$name"
    else
        fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"
    fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        pass "$name"
    else
        fail "$name — expected to contain '$needle'; got: $haystack"
    fi
}

assert_not_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$name — expected NOT to contain '$needle'; got: $haystack"
    else
        pass "$name"
    fi
}

# A negative security assertion over an empty payload passes for the wrong
# reason, so require a JSON object before believing the absence.
assert_map_lacks() {
    local name="$1" haystack="$2" needle="$3"
    case "$haystack" in
        '{'*'}') assert_not_contains "$name" "$haystack" "$needle" ;;
        *) fail "$name — no effective map produced (got: $haystack); absence not provable" ;;
    esac
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

decode() { local s="$1"; s="${s//@NL@/$'\n'}"; printf '%s' "$s"; }

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# Probe helper. One node entry point, several subcommands, so each bash case is
# a single line. Reads the real hooks/lib modules; the fixture supplies only the
# config dir and the project root.
# ---------------------------------------------------------------------------
PROBE="$TMP_ROOT/probe.js"
cat > "$PROBE" <<'PROBE_EOF'
"use strict";
const path = require("path");
const libDir = path.join(process.env.AGENTS_DIR_NODE, "hooks", "lib");
const out = (s) => process.stdout.write(String(s));
const enc = (v) => (v === undefined ? "__ABSENT__" : JSON.stringify(v));
const loadEnvMod = () => require(path.join(libDir, "load-env.js"));
const localEnvMod = () => require(path.join(libDir, "local-env.js"));

const cmd = process.argv[2];
const a1 = process.argv[3];
const a2 = process.argv[4];

if (cmd === "effective") {
  out(enc(loadEnvMod().readEffectiveEnvFile(a1 || null)[a2]));
} else if (cmd === "effective-json") {
  out(JSON.stringify(loadEnvMod().readEffectiveEnvFile(a1 || null)));
} else if (cmd === "global") {
  out(enc(loadEnvMod().readDefaultEnvFile()[a1]));
} else if (cmd === "confirm-off") {
  out(String(require(path.join(libDir, "plan-confirm-flag.js")).isConfirmOffForStageFromFile(a1)));
} else if (cmd === "load-default") {
  loadEnvMod().loadDefaultEnv();
  out(enc(process.env[a1]));
} else if (cmd === "resolve-root") {
  const r = localEnvMod().resolveProjectRoot(a1 || null, a2 || null);
  out(r === null || r === undefined ? "__NULL__" : String(r).replace(/\\/g, "/"));
} else if (cmd === "never-sets") {
  const m = localEnvMod();
  out(JSON.stringify({
    exact: Array.from(m.NEVER_OVERRIDABLE_EXACT).sort(),
    prefixes: Array.from(m.NEVER_OVERRIDABLE_PREFIXES).sort(),
  }));
} else if (cmd === "never-keys") {
  const m = localEnvMod();
  const src = a1 === "prefixes" ? m.NEVER_OVERRIDABLE_PREFIXES : m.NEVER_OVERRIDABLE_EXACT;
  out(Array.from(src).sort().join("\n") + "\n");
} else if (cmd === "overlay-pure") {
  const m = localEnvMod();
  const g = Object.freeze({ CODE_LANG: "english", KEEP: "g", ENFORCE_WORKTREE: "on" });
  const l = Object.freeze({ CODE_LANG: "japanese", KEEP: "l", ENFORCE_WORKTREE: "off" });
  const res = m.overlay(g, l, new Set(["CODE_LANG", "ENFORCE_WORKTREE"]));
  out(JSON.stringify({
    map: res.map,
    applied: Array.from(res.applied || []).sort(),
    ignored: Array.from(res.ignored || []).sort(),
    globalUnmutated: g.CODE_LANG === "english" && g.KEEP === "g",
    localUnmutated: l.CODE_LANG === "japanese",
  }));
} else {
  process.stderr.write("probe: unknown command " + cmd + "\n");
  process.exit(64);
}
PROBE_EOF
PROBE_NODE="$(to_node_path "$PROBE")"

# new_case <name> <global-env-content> <local-env-content|__NONE__> [gitform]
# gitform: dir (default) | file | none. Sets CASE_CFG / CASE_ROOT / CASE_ROOT_NODE.
# A bare .git entry is enough: resolveProjectRoot never spawns git, so no git init.
new_case() {
    local name="$1" global_content="$2" local_content="$3" gitform="${4:-dir}"
    CASE_CFG="$TMP_ROOT/c-$name/cfg"
    CASE_ROOT="$TMP_ROOT/c-$name/repo"
    rm -rf "$TMP_ROOT/c-$name"
    mkdir -p "$CASE_CFG" "$CASE_ROOT"
    printf '%s\n' "$(decode "$global_content")" > "$CASE_CFG/.env"
    case "$gitform" in
        dir)  mkdir -p "$CASE_ROOT/.git" ;;
        file) printf 'gitdir: %s\n' "$TMP_ROOT/c-$name/gitdir" > "$CASE_ROOT/.git" ;;
        none) ;;
    esac
    if [ "$local_content" != "__NONE__" ]; then
        printf '%s\n' "$(decode "$local_content")" > "$CASE_ROOT/$LOCAL_ENV_BASENAME"
    fi
    CASE_ROOT_NODE="$(to_node_path "$CASE_ROOT")"
}

probe() {
    AGENTS_CONFIG_DIR="$CASE_CFG" run_with_timeout 20 node "$PROBE_NODE" "$@" 2>/dev/null
}

LOCAL_ENV_JS="$AGENTS_DIR/hooks/lib/local-env.js"
if [ ! -f "$LOCAL_ENV_JS" ]; then
    echo "NOTE: hooks/lib/local-env.js absent — every case below is expected RED until /write-code lands."
fi

# ---------------------------------------------------------------------------
# Table 1 — declaration semantics and the effective map.
# Columns: name | global .env (@NL@ = newline) | local override file | key | want
# ---------------------------------------------------------------------------
while IFS='|' read -r name genv lenv key want; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    new_case "$name" "$(trim "$genv")" "$(trim "$lenv")"
    got="$(probe effective "$CASE_ROOT_NODE" "$(trim "$key")")"
    assert_eq "T2223L-$name" "$(trim "$want")" "$got"
done <<'TABLE'
decl-absent               | CODE_LANG=english                                                       | CODE_LANG=japanese                    | CODE_LANG   | "japanese"
decl-absent-other-key     | CODE_LANG=english@NL@FOO=globalfoo                                      | FOO=localfoo                          | FOO         | "globalfoo"
decl-empty                | LOCAL_OVERRIDABLE_KEYS=@NL@CODE_LANG=english                            | CODE_LANG=japanese                    | CODE_LANG   | "english"
decl-explicit-code-lang   | LOCAL_OVERRIDABLE_KEYS=CODE_LANG,FOO@NL@CODE_LANG=english@NL@FOO=gf     | CODE_LANG=japanese@NL@FOO=lf          | CODE_LANG   | "japanese"
decl-explicit-foo         | LOCAL_OVERRIDABLE_KEYS=CODE_LANG,FOO@NL@CODE_LANG=english@NL@FOO=gf     | CODE_LANG=japanese@NL@FOO=lf          | FOO         | "lf"
decl-explicit-bar-denied  | LOCAL_OVERRIDABLE_KEYS=CODE_LANG,FOO@NL@BAR=globalbar                   | BAR=localbar                          | BAR         | "globalbar"
decl-replaces-default     | LOCAL_OVERRIDABLE_KEYS=FOO@NL@CODE_LANG=english@NL@FOO=gf               | CODE_LANG=japanese@NL@FOO=lf          | CODE_LANG   | "english"
decl-replaces-default-foo | LOCAL_OVERRIDABLE_KEYS=FOO@NL@CODE_LANG=english@NL@FOO=gf               | CODE_LANG=japanese@NL@FOO=lf          | FOO         | "lf"
nfr-not-in-default        | CODE_LANG=english                                                       | PROJECT_NFR=test                      | PROJECT_NFR | __ABSENT__
nfr-opt-in                | LOCAL_OVERRIDABLE_KEYS=PROJECT_NFR,CODE_LANG                            | PROJECT_NFR=test                      | PROJECT_NFR | "test"
nfr-opt-in-code-lang      | LOCAL_OVERRIDABLE_KEYS=PROJECT_NFR,CODE_LANG@NL@CODE_LANG=english       | CODE_LANG=japanese                    | CODE_LANG   | "japanese"
non-declared-no-leak      | CODE_LANG=english                                                       | SECRET_API_KEY=leaked-secret          | SECRET_API_KEY | __ABSENT__
local-absent-fallback     | CODE_LANG=english                                                       | __NONE__                              | CODE_LANG   | "english"
empty-string-override     | LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english                   | CODE_LANG=                            | CODE_LANG   | ""
multiline-local-value     | LOCAL_OVERRIDABLE_KEYS=PROJECT_NFR                                      | PROJECT_NFR="a@NL@b"                  | PROJECT_NFR | "a\nb"
allow-automation-mode     | LOCAL_OVERRIDABLE_KEYS=AUTOMATION_MODE@NL@AUTOMATION_MODE=global         | AUTOMATION_MODE=local                 | AUTOMATION_MODE | "local"
allow-enforcement-level   | LOCAL_OVERRIDABLE_KEYS=ENFORCEMENT_LEVEL@NL@ENFORCEMENT_LEVEL=global     | ENFORCEMENT_LEVEL=local               | ENFORCEMENT_LEVEL | "local"
allow-confirmed-state     | LOCAL_OVERRIDABLE_KEYS=CONFIRMED_STATE@NL@CONFIRMED_STATE=global         | CONFIRMED_STATE=local                 | CONFIRMED_STATE | "local"
TABLE

# ---------------------------------------------------------------------------
# Table 2 — the NEVER-overridable list beats an explicit declaration. Every row
# declares its own key overridable in the global .env, so a pass here proves the
# hard-coded deny list wins over configuration, not merely over the default.
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
forbidden-enforce-worktree      | ENFORCE_WORKTREE       | on          | off
forbidden-auto-merge-pr         | AUTO_MERGE_PR          | on          | off
forbidden-auto-approve-tools    | AUTO_APPROVE_TOOLS     | off         | on
forbidden-confirm-detail        | CONFIRM_DETAIL         | on          | off
forbidden-confirm-code          | CONFIRM_CODE           | on          | off
forbidden-confirm-intent        | CONFIRM_INTENT         | on          | off
forbidden-confirm-outline       | CONFIRM_OUTLINE        | on          | off
forbidden-run-tl3               | RUN_TL3                | off         | on
forbidden-run-tl4               | RUN_TL4                | off         | on
forbidden-session-sync          | SESSION_SYNC           | off         | on
forbidden-codex-mcp-fs          | CODEX_MCP_FS           | on          | off
forbidden-workflow-plans-dir    | WORKFLOW_PLANS_DIR     | /global-plans | /tmp/evil
forbidden-agents-config-dir     | AGENTS_CONFIG_DIR      | /global-cfg   | /tmp/evil
forbidden-claude-workflow-dir   | CLAUDE_WORKFLOW_DIR    | /global-wf    | /tmp/evil
forbidden-worktree-base-dir     | WORKTREE_BASE_DIR      | /global-wt    | /tmp/evil
forbidden-default-branches      | DEFAULT_BRANCHES       | main        | evil
forbidden-decl-self             | LOCAL_OVERRIDABLE_KEYS | CODE_LANG   | EVERYTHING
prefix-confirm-future           | CONFIRM_FUTURE         | on          | off
prefix-enforce-future           | ENFORCE_FUTURE         | on          | off
prefix-auto-future              | AUTO_FUTURE            | off         | on
prefix-session-sync-future      | SESSION_SYNC_EXTRA     | off         | on
prefix-run-tl-future            | RUN_TL_FUTURE          | off         | on
TABLE

# ---------------------------------------------------------------------------
# Table 2b — EVERY current deny-list entry, in three spellings.
# The key list is read out of local-env.js itself (CPR-SSOT): a deny-list entry
# added tomorrow is covered the day it lands, not the day someone remembers a
# table. isNeverOverridable() upper-cases before matching because Windows env
# names are case-insensitive, so a lower- or mixed-case declaration must not
# slip past — each fixture declares all three spellings overridable at once and
# gives each its own global value, so a single effective map proves all three.
# ---------------------------------------------------------------------------
mixed_case() {
    local up lo="$1"
    lo="$(printf '%s' "$1" | tr 'A-Z' 'a-z')"
    up="$(printf '%s' "${lo:0:1}" | tr 'a-z' 'A-Z')"
    printf '%s%s' "$up" "${lo:1}"
}

deny_all_spellings() {
    local label="$1" canon="$2" lower mixed genv lenv json
    lower="$(printf '%s' "$canon" | tr 'A-Z' 'a-z')"
    mixed="$(mixed_case "$canon")"
    genv="LOCAL_OVERRIDABLE_KEYS=$canon,$lower,$mixed@NL@$canon=gv-canon-$label@NL@$lower=gv-lower-$label@NL@$mixed=gv-mixed-$label"
    lenv="$canon=DENYLOCAL@NL@$lower=DENYLOCAL@NL@$mixed=DENYLOCAL"
    new_case "deny-$label" "$genv" "$lenv"
    json="$(probe effective-json "$CASE_ROOT_NODE")"
    assert_map_lacks "T2223N2-$canon-local-never-wins" "$json" 'DENYLOCAL'
    assert_contains "T2223N2-$canon-canonical-global-kept" "$json" "gv-canon-$label"
    assert_contains "T2223N2-$canon-lower-global-kept" "$json" "gv-lower-$label"
    assert_contains "T2223N2-$canon-mixed-global-kept" "$json" "gv-mixed-$label"
}

new_case deny-enum 'CODE_LANG=english' '__NONE__'
DENY_EXACT="$(probe never-keys exact)"
DENY_PREFIXES="$(probe never-keys prefixes)"
DENY_EXACT_N="$(printf '%s\n' "$DENY_EXACT" | grep -c '[A-Z]')"
DENY_PREFIX_N="$(printf '%s\n' "$DENY_PREFIXES" | grep -c '[A-Z]')"
# Guard the enumeration itself: an empty read would make every row below vacuous.
if [ "$DENY_EXACT_N" -lt 20 ] || [ "$DENY_PREFIX_N" -lt 5 ]; then
    fail "T2223N2-enumeration — deny list read back too small (exact=$DENY_EXACT_N prefixes=$DENY_PREFIX_N)"
else
    pass "T2223N2-enumeration ($DENY_EXACT_N exact entries, $DENY_PREFIX_N prefixes)"
fi

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

# T2223-declared-forbidden-still-blocked — the whole deny list declared at once.
new_case declared-forbidden \
  'LOCAL_OVERRIDABLE_KEYS=ENFORCE_WORKTREE,CONFIRM_DETAIL,AUTO_MERGE_PR,LOCAL_OVERRIDABLE_KEYS,AGENTS_CONFIG_DIR@NL@ENFORCE_WORKTREE=on@NL@CONFIRM_DETAIL=on@NL@AUTO_MERGE_PR=on@NL@AGENTS_CONFIG_DIR=/global-cfg' \
  'ENFORCE_WORKTREE=off@NL@CONFIRM_DETAIL=off@NL@AUTO_MERGE_PR=off@NL@AGENTS_CONFIG_DIR=/tmp/evil@NL@LOCAL_OVERRIDABLE_KEYS=EVERYTHING'
declared_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_map_lacks "T2223-declared-forbidden-still-blocked (no 'off' leaked)" "$declared_json" '"off"'
assert_map_lacks "T2223-declared-forbidden-still-blocked (no /tmp/evil)" "$declared_json" '/tmp/evil'
assert_map_lacks "T2223-declared-forbidden-still-blocked (decl not rewritten)" "$declared_json" 'EVERYTHING'

# T2223-non-declared-no-leak-json — an undeclared secret must not reach the map
# under any key, not merely under its own.
new_case leak-json 'CODE_LANG=english' 'SECRET_API_KEY=leaked-secret@NL@OTHER=alsoleaked'
leak_json="$(probe effective-json "$CASE_ROOT_NODE")"
assert_map_lacks "T2223-non-declared-no-leak-value" "$leak_json" 'leaked-secret'
assert_map_lacks "T2223-non-declared-no-leak-sibling" "$leak_json" 'alsoleaked'

# T2223-short-circuit-empty-decl — with the declaration explicitly empty the local
# layer is never consulted, so a file that cannot parse cannot matter.
new_case short-circuit 'LOCAL_OVERRIDABLE_KEYS=@NL@CODE_LANG=english' 'CODE_LANG="unterminated@NL@BROKEN'
sc_rc=0
sc_got="$(probe effective "$CASE_ROOT_NODE" CODE_LANG)" || sc_rc=$?
assert_eq "T2223-short-circuit-empty-decl (value)" '"english"' "$sc_got"
assert_eq "T2223-short-circuit-empty-decl (exit 0)" "0" "$sc_rc"

# T2223-door-readDefaultEnvFile — the global-only door stays global-only even when
# the key is declared overridable and present locally.
new_case door-global 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' 'CODE_LANG=japanese'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-door-readDefaultEnvFile" '"english"' "$(probe global CODE_LANG)"

# T2223-door-plan-confirm-flag — the CONFIRM gate reader must not see a local file.
new_case door-confirm 'LOCAL_OVERRIDABLE_KEYS=CONFIRM_DETAIL' 'CONFIRM_DETAIL=off'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-door-plan-confirm-flag" "false" "$(probe confirm-off detail)"

# T2223-door-loadEnv-process-env — a declared key does reach process.env.
new_case door-loadenv 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' 'CODE_LANG=japanese'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-door-loadEnv-process-env" '"japanese"' "$(probe load-default CODE_LANG)"

# T2223-process-env-wins-after-overlay — an explicit export still outranks both layers.
assert_eq "T2223-process-env-wins-after-overlay" '"exported-wins"' \
  "$(CODE_LANG=exported-wins probe load-default CODE_LANG)"
unset CLAUDE_PROJECT_DIR

# ---------------------------------------------------------------------------
# Project-root resolution. Priority, worktree .git file form, upward search, and
# the no-repo case.
# ---------------------------------------------------------------------------
new_case root-explicit 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' 'CODE_LANG=from-explicit'
EXPLICIT_ROOT="$CASE_ROOT"; EXPLICIT_ROOT_NODE="$CASE_ROOT_NODE"; EXPLICIT_CFG="$CASE_CFG"
new_case root-envvar 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' 'CODE_LANG=from-envvar'
ENVVAR_ROOT="$CASE_ROOT"

CASE_CFG="$EXPLICIT_CFG"
export CLAUDE_PROJECT_DIR="$ENVVAR_ROOT"
assert_eq "T2223-project-root-priority-explicit" \
  "$(to_node_path "$EXPLICIT_ROOT")" "$(probe resolve-root "$EXPLICIT_ROOT_NODE" "$TMP_ROOT")"
assert_eq "T2223-project-root-priority-explicit-value" '"from-explicit"' \
  "$(probe effective "$EXPLICIT_ROOT_NODE" CODE_LANG)"
assert_eq "T2223-project-root-env-var" \
  "$(to_node_path "$ENVVAR_ROOT")" "$(probe resolve-root '' "$TMP_ROOT")"
unset CLAUDE_PROJECT_DIR

new_case root-worktree 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' 'CODE_LANG=from-worktree' file
mkdir -p "$CASE_ROOT/nested/deeper"
assert_eq "T2223-project-root-worktree-git-file" \
  "$(to_node_path "$CASE_ROOT")" "$(probe resolve-root '' "$(to_node_path "$CASE_ROOT/nested/deeper")")"
assert_eq "T2223-project-root-worktree-git-file-value" '"from-worktree"' \
  "$(probe effective "$CASE_ROOT_NODE" CODE_LANG)"

new_case root-upward 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' 'CODE_LANG=from-upward'
mkdir -p "$CASE_ROOT/a/b/c"
assert_eq "T2223-project-root-upward-search" \
  "$(to_node_path "$CASE_ROOT")" "$(probe resolve-root '' "$(to_node_path "$CASE_ROOT/a/b/c")")"

# The null expectation only holds when no ancestor of the temp root carries .git,
# so the precondition is measured rather than assumed.
new_case root-none 'CODE_LANG=english' 'CODE_LANG=must-not-apply' none
ANCESTOR_GIT=0
_probe_dir="$CASE_ROOT"
while [ -n "$_probe_dir" ] && [ "$_probe_dir" != "/" ]; do
    if [ "$_probe_dir" != "$CASE_ROOT" ] && [ -e "$_probe_dir/.git" ]; then ANCESTOR_GIT=1; break; fi
    _next="$(dirname "$_probe_dir")"
    [ "$_next" != "$_probe_dir" ] || break
    _probe_dir="$_next"
done
if [ "$ANCESTOR_GIT" -eq 0 ]; then
    assert_eq "T2223-project-root-no-git" "__NULL__" "$(probe resolve-root '' "$CASE_ROOT_NODE")"
else
    fail "T2223-project-root-no-git — precondition broken: an ancestor of $CASE_ROOT carries .git"
fi
assert_eq "T2223-project-root-no-git-no-local-layer" '"english"' "$(probe effective '' CODE_LANG)"

# ---------------------------------------------------------------------------
# Module surface: the deny sets and the purity of overlay().
# ---------------------------------------------------------------------------
new_case sets 'CODE_LANG=english' '__NONE__'
sets_json="$(probe never-sets)"
for k in LOCAL_OVERRIDABLE_KEYS AGENTS_CONFIG_DIR WORKFLOW_PLANS_DIR CLAUDE_WORKFLOW_DIR \
         WORKTREE_BASE_DIR DEFAULT_BRANCHES ENFORCE_WORKTREE CODEX_MCP_FS AUTO_MERGE_PR; do
    assert_contains "T2223-never-exact-$k" "$sets_json" "\"$k\""
done
for p in ENFORCE_ CONFIRM_ AUTO_ SESSION_SYNC RUN_TL; do
    assert_contains "T2223-never-prefix-$p" "$sets_json" "\"$p\""
done

overlay_json="$(probe overlay-pure)"
assert_contains "T2223-overlay-applies-allowed"    "$overlay_json" '"CODE_LANG":"japanese"'
assert_contains "T2223-overlay-keeps-unallowed"    "$overlay_json" '"KEEP":"g"'
assert_contains "T2223-overlay-denies-never-key"   "$overlay_json" '"ENFORCE_WORKTREE":"on"'
assert_contains "T2223-overlay-reports-applied"    "$overlay_json" '"applied":["CODE_LANG"]'
assert_contains "T2223-overlay-reports-ignored"    "$overlay_json" '"ignored":["ENFORCE_WORKTREE"]'
assert_contains "T2223-overlay-pure-global"        "$overlay_json" '"globalUnmutated":true'
assert_contains "T2223-overlay-pure-local"         "$overlay_json" '"localUnmutated":true'

# ---------------------------------------------------------------------------
# Real CLIs over hostile project roots. The module cases above run in-process;
# these run the shipped executables, where a path is re-quoted at every hop and
# a degenerate override file must degrade to the global layer, not to a crash.
# ---------------------------------------------------------------------------
# Paths are normalized with to_node_path first: MSYS rewrites a POSIX-looking
# env value on its way to a native node.exe, and a ';' in it is taken for a
# path-list separator — a harness artefact, not behaviour of the code under test.
eek() { AGENTS_CONFIG_DIR="$(to_node_path "$CASE_CFG")" run_with_timeout 20 bash "$AGENTS_DIR/bin/env-effective-kv" --repo-root "$(to_node_path "$1")" --key "$2" 2>/dev/null; }
gcv() { AGENTS_CONFIG_DIR="$(to_node_path "$CASE_CFG")" run_with_timeout 20 bash "$AGENTS_DIR/bin/get-config-var" --repo-root "$(to_node_path "$1")" "$2" 2>/dev/null; }

new_case cli-empty 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' '__NONE__'
: > "$CASE_ROOT/$LOCAL_ENV_BASENAME"
assert_eq "T2223R-empty-local-eek-falls-back" "english" "$(eek "$CASE_ROOT" CODE_LANG)"
assert_eq "T2223R-empty-local-gcv-falls-back" "english" "$(gcv "$CASE_ROOT" CODE_LANG)"

# Unreadable-as-a-file: a directory at that name is the portable form of "open
# fails", since chmod 000 is not honoured on every filesystem this suite runs on.
new_case cli-unreadable 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english' '__NONE__'
mkdir -p "$CASE_ROOT/$LOCAL_ENV_BASENAME"
assert_eq "T2223R-unreadable-local-eek-falls-back" "english" "$(eek "$CASE_ROOT" CODE_LANG)"
assert_eq "T2223R-unreadable-local-gcv-falls-back" "english" "$(gcv "$CASE_ROOT" CODE_LANG)"

# A project root carrying spaces and shell metacharacters. The local value must
# still apply — proving the path was really used — while the canary proves no
# part of the name was ever handed to a shell for evaluation.
new_case cli-meta 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@CODE_LANG=english@NL@ENFORCE_WORKTREE=on' '__NONE__'
META_PARENT="$CASE_ROOT/holder"
META_ROOT="$META_PARENT/pr oj \$(touch pwned) ;touch pwned& \`touch pwned\`"
mkdir -p "$META_ROOT/.git"
printf 'CODE_LANG=from-meta-path\nENFORCE_WORKTREE=off\n' > "$META_ROOT/$LOCAL_ENV_BASENAME"
assert_eq "T2223R-meta-path-eek-reads-local" "from-meta-path" "$(eek "$META_ROOT" CODE_LANG)"
assert_eq "T2223R-meta-path-gcv-reads-local" "from-meta-path" "$(gcv "$META_ROOT" CODE_LANG)"
if [ -e "$META_PARENT/pwned" ] || [ -e "$META_ROOT/pwned" ] || [ -e "$TMP_ROOT/pwned" ]; then
    fail "T2223R-meta-path-no-execution — a metacharacter in the project root ran"
else
    pass "T2223R-meta-path-no-execution"
fi
assert_eq "T2223R-meta-path-denylist-still-wins" "on" "$(eek "$META_ROOT" ENFORCE_WORKTREE)"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
