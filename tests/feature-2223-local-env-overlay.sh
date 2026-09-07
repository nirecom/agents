#!/usr/bin/env bash
# tests/feature-2223-local-env-overlay.sh
# Tests: hooks/lib/local-env.js, hooks/lib/load-env.js, hooks/lib/plan-confirm-flag.js
# Tags: scope:issue-specific, TL2, load-env, local-env, security, trust-boundary, pwsh-not-required
# Issue #2223 — the 2-layer global/.env + project-local override resolver.
# Pinned contract: load-env.js exports readEffectiveEnvFile(projectRoot) -> map;
# local-env.js exports resolveProjectRoot, overlay(globalMap, localMap) ->
# {map, applied, ignored}, isBlocklisted(key), ENV_ENTRY_BLOCKLIST_EXACT and
# ENV_ENTRY_BLOCKLIST_PREFIX. No allowlist: only the blocklist gates the layer.

set -u

# TL3 gap (what this test does NOT catch):
# - A real repo whose own override file is edited mid-session, with the loader
#   run from the live Claude Code session's own cwd and inherited environment.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_DIR_NODE="$AGENTS_DIR"
fi
export AGENTS_DIR_NODE

# Never named as a whole path literal: hooks/block-dotenv.js blocks that (DD-1).
LOCAL_ENV_BASENAME=".env"".local"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

# Isolation: pin both halves of the plans-dir pair, drop inherited session ids,
# and let no ambient AGENTS_CONFIG_DIR, project dir, or tested key reach a child.
export CLAUDE_WORKFLOW_DIR="$TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PROJECT_DIR
unset AGENTS_CONFIG_DIR
unset CODE_LANG
unset PROJECT_NFR

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

# A negative assertion over an empty payload passes for the wrong reason.
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
# Probe helper. One node entry point, several subcommands, so each bash case is a
# single line. Reads the real hooks/lib modules; the fixture supplies the dirs.
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
} else if (cmd === "load-default-has-value") {
  loadEnvMod().loadDefaultEnv();
  out(String(Object.keys(process.env).some((k) => process.env[k] === a1)));
} else if (cmd === "is-blocklisted-raw") {
  const raws = { __UNDEF__: undefined, __NULL__: null, __NUM__: 42, __OBJ__: {}, __ARR__: [] };
  out(String(localEnvMod().isBlocklisted(raws[a1])));
} else if (cmd === "resolve-root") {
  const r = localEnvMod().resolveProjectRoot(a1 || null, a2 || null);
  out(r === null || r === undefined ? "__NULL__" : String(r).replace(/\\/g, "/"));
} else if (cmd === "blocklist-keys") {
  const m = localEnvMod();
  const src = a1 === "prefixes" ? m.ENV_ENTRY_BLOCKLIST_PREFIX : m.ENV_ENTRY_BLOCKLIST_EXACT;
  out(Array.from(src).sort().join("\n") + "\n");
} else if (cmd === "is-blocklisted") {
  out(String(localEnvMod().isBlocklisted(a1 === "__EMPTY__" ? "" : a1)));
} else if (cmd === "overlay-pure") {
  const m = localEnvMod();
  const g = Object.freeze({ CODE_LANG: "english", KEEP: "g", ONLY_GLOBAL: "gg", ENFORCE_WORKTREE: "on" });
  const l = Object.freeze({ CODE_LANG: "japanese", KEEP: "l", ENFORCE_WORKTREE: "off" });
  const res = m.overlay(g, l);
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
    echo "NOTE: hooks/lib/local-env.js absent — every case below is expected RED."
fi

# ---------------------------------------------------------------------------
# Table 1 — the effective map under the blocklist-only model. A project's key
# applies because nothing refuses it; no declaration grants anything any more.
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
undeclared-local-wins      | CODE_LANG=english                                  | CODE_LANG=japanese                | CODE_LANG      | "japanese"
undeclared-other-key-wins  | CODE_LANG=english@NL@FOO=globalfoo                 | FOO=localfoo                      | FOO            | "localfoo"
local-only-key-added       | CODE_LANG=english                                  | BRAND_NEW_KEY=fromlocal           | BRAND_NEW_KEY  | "fromlocal"
global-only-key-survives   | CODE_LANG=english@NL@ONLY_GLOBAL=gonly             | FOO=localfoo                      | ONLY_GLOBAL    | "gonly"
blocklisted-local-loses    | CODE_LANG=english@NL@ENFORCE_WORKTREE=on           | ENFORCE_WORKTREE=off              | ENFORCE_WORKTREE | "on"
stale-decl-grants-nothing  | LOCAL_OVERRIDABLE_KEYS=ENFORCE_WORKTREE@NL@ENFORCE_WORKTREE=on | ENFORCE_WORKTREE=off  | ENFORCE_WORKTREE | "on"
stale-decl-denies-nothing  | LOCAL_OVERRIDABLE_KEYS=NOTHING@NL@FOO=globalfoo    | FOO=localfoo                      | FOO            | "localfoo"
stale-decl-is-ordinary-key | LOCAL_OVERRIDABLE_KEYS=CODE_LANG                   | LOCAL_OVERRIDABLE_KEYS=EVERYTHING | LOCAL_OVERRIDABLE_KEYS | "EVERYTHING"
nfr-no-declaration-needed  | CODE_LANG=english                                  | PROJECT_NFR=test                  | PROJECT_NFR    | "test"
nfr-overrides-global       | PROJECT_NFR=global-nfr                             | PROJECT_NFR=local-nfr             | PROJECT_NFR    | "local-nfr"
local-absent-fallback      | CODE_LANG=english                                  | __NONE__                          | CODE_LANG      | "english"
empty-string-override      | CODE_LANG=english                                  | CODE_LANG=                        | CODE_LANG      | ""
multiline-local-value      | CODE_LANG=english                                  | PROJECT_NFR="a@NL@b"              | PROJECT_NFR    | "a\nb"
allow-confirm-detail       | CONFIRM_DETAIL=on                                  | CONFIRM_DETAIL=off                | CONFIRM_DETAIL | "off"
allow-auto-merge-pr        | AUTO_MERGE_PR=on                                   | AUTO_MERGE_PR=off                 | AUTO_MERGE_PR  | "off"
allow-run-tl3              | RUN_TL3=off                                        | RUN_TL3=on                        | RUN_TL3        | "on"
allow-run-tl4              | RUN_TL4=off                                        | RUN_TL4=on                        | RUN_TL4        | "on"
allow-plan-lang            | PLAN_LANG=english                                  | PLAN_LANG=japanese                | PLAN_LANG      | "japanese"
allow-conv-lang            | CONV_LANG=english                                  | CONV_LANG=japanese                | CONV_LANG      | "japanese"
allow-docs-lang-primary    | DOCS_LANG_PRIMARY=english                          | DOCS_LANG_PRIMARY=japanese        | DOCS_LANG_PRIMARY | "japanese"
allow-codegraph            | CODEGRAPH=off                                      | CODEGRAPH=on                      | CODEGRAPH      | "on"
allow-automation-mode      | AUTOMATION_MODE=global                             | AUTOMATION_MODE=local             | AUTOMATION_MODE | "local"
allow-enforcement-level    | ENFORCEMENT_LEVEL=global                           | ENFORCEMENT_LEVEL=local           | ENFORCEMENT_LEVEL | "local"
allow-confirmed-state      | CONFIRMED_STATE=global                             | CONFIRMED_STATE=local             | CONFIRMED_STATE | "local"
TABLE

# Every case about what the blocklist REFUSES lives in a sibling case file
# because this one exceeded the 500-line HARD limit of rules/coding/file-split.md.
# Sourced (not executed) so the cases share the helpers, fixtures and counters
# defined above.
CASES_FILE="$AGENTS_DIR/tests/feature-2223-local-env-overlay/blocklist-coverage.sh"
if [ -f "$CASES_FILE" ]; then
    . "$CASES_FILE"
else
    fail "T2223-blocklist-cases-file-present — $CASES_FILE missing"
fi

# T2223-malformed-local-degrades — an unterminated quote discards that key alone
# and never takes the global layer down with it.
new_case malformed 'CODE_LANG=english' 'CODE_LANG="unterminated@NL@BROKEN'
mal_rc=0
mal_got="$(probe effective "$CASE_ROOT_NODE" CODE_LANG)" || mal_rc=$?
assert_eq "T2223-malformed-local-degrades (value)" '"english"' "$mal_got"
assert_eq "T2223-malformed-local-degrades (exit 0)" "0" "$mal_rc"

# T2223-door-readDefaultEnvFile — the global-only door stays global-only even
# though the key is freely overridable in the effective map.
new_case door-global 'CODE_LANG=english' 'CODE_LANG=japanese'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-door-readDefaultEnvFile" '"english"' "$(probe global CODE_LANG)"

# T2223-door-plan-confirm-flag — the CONFIRM gate reader must not see a local
# file, even now that CONFIRM_* is overridable in the effective map.
new_case door-confirm 'CONFIRM_DETAIL=on' 'CONFIRM_DETAIL=off'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-door-plan-confirm-flag" "false" "$(probe confirm-off detail)"

# T2223-door-loadEnv-process-env — an ordinary local key does reach process.env.
new_case door-loadenv 'CODE_LANG=english' 'CODE_LANG=japanese'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-door-loadEnv-process-env" '"japanese"' "$(probe load-default CODE_LANG)"

# A blocklisted key must not reach process.env from the local layer either.
new_case door-loadenv-blocked 'ENFORCE_WORKTREE=on' 'ENFORCE_WORKTREE=off'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-door-loadEnv-blocklisted" '"on"' "$(probe load-default ENFORCE_WORKTREE)"

# T2223-process-env-wins-after-overlay — an explicit export still outranks both layers.
new_case door-loadenv2 'CODE_LANG=english' 'CODE_LANG=japanese'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-process-env-wins-after-overlay" '"exported-wins"' \
  "$(CODE_LANG=exported-wins probe load-default CODE_LANG)"

# The case-insensitive half of that guard. Windows env names are case-insensitive,
# so a local key spelled in another case must still meet the caller's export —
# the beforeUpperTruthy lookup, not a same-case hit, is what these rows pin.
new_case door-crosscase 'CODE_LANG=english' 'code_lang=hostile-local-2223'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-crosscase-export-protects" "false" \
  "$(CODE_LANG=exported-wins probe load-default-has-value hostile-local-2223)"
assert_eq "T2223-crosscase-export-value-kept" '"exported-wins"' \
  "$(CODE_LANG=exported-wins probe load-default CODE_LANG)"
# Positive control: unexported, the same cross-cased local key does reach
# process.env — so "false" above means the lookup refused it.
assert_eq "T2223-crosscase-control-applies" "true" \
  "$(probe load-default-has-value hostile-local-2223)"

# An exported EMPTY value is not protection: beforeUpperTruthy names truthy
# values only, so the local layer wins over it (symmetric to the truthy case).
new_case door-empty-export 'CODE_LANG=english' 'CODE_LANG=local-wins-2223'
export CLAUDE_PROJECT_DIR="$CASE_ROOT"
assert_eq "T2223-empty-export-not-protected" '"local-wins-2223"' \
  "$(CODE_LANG= probe load-default CODE_LANG)"
unset CLAUDE_PROJECT_DIR

# ---------------------------------------------------------------------------
# Project-root resolution. Priority, worktree .git file form, upward search, and
# the no-repo case.
# ---------------------------------------------------------------------------
new_case root-explicit 'CODE_LANG=english' 'CODE_LANG=from-explicit'
EXPLICIT_ROOT="$CASE_ROOT"; EXPLICIT_ROOT_NODE="$CASE_ROOT_NODE"; EXPLICIT_CFG="$CASE_CFG"
new_case root-envvar 'CODE_LANG=english' 'CODE_LANG=from-envvar'
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

new_case root-worktree 'CODE_LANG=english' 'CODE_LANG=from-worktree' file
mkdir -p "$CASE_ROOT/nested/deeper"
assert_eq "T2223-project-root-worktree-git-file" \
  "$(to_node_path "$CASE_ROOT")" "$(probe resolve-root '' "$(to_node_path "$CASE_ROOT/nested/deeper")")"
assert_eq "T2223-project-root-worktree-git-file-value" '"from-worktree"' \
  "$(probe effective "$CASE_ROOT_NODE" CODE_LANG)"

new_case root-upward 'CODE_LANG=english' 'CODE_LANG=from-upward'
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
# Module surface: the purity of the 2-argument overlay().
# ---------------------------------------------------------------------------
new_case sets 'CODE_LANG=english' '__NONE__'
overlay_json="$(probe overlay-pure)"
assert_contains "T2223-overlay-applies-local"      "$overlay_json" '"CODE_LANG":"japanese"'
assert_contains "T2223-overlay-applies-undeclared" "$overlay_json" '"KEEP":"l"'
assert_contains "T2223-overlay-keeps-global-only"  "$overlay_json" '"ONLY_GLOBAL":"gg"'
assert_contains "T2223-overlay-denies-blocklisted" "$overlay_json" '"ENFORCE_WORKTREE":"on"'
assert_contains "T2223-overlay-reports-applied"    "$overlay_json" '"applied":["CODE_LANG","KEEP"]'
assert_contains "T2223-overlay-reports-ignored"    "$overlay_json" '"ignored":["ENFORCE_WORKTREE"]'
assert_contains "T2223-overlay-pure-global"        "$overlay_json" '"globalUnmutated":true'
assert_contains "T2223-overlay-pure-local"         "$overlay_json" '"localUnmutated":true'

# ---------------------------------------------------------------------------
# Real CLIs over hostile project roots. The module cases above run in-process;
# these run the shipped executables, where a path is re-quoted at every hop and
# a degenerate override file must degrade to the global layer, not to a crash.
# Paths go through to_node_path first: MSYS rewrites a POSIX-looking env value on
# its way to native node.exe — a harness artefact, not behaviour under test.
eek() { AGENTS_CONFIG_DIR="$(to_node_path "$CASE_CFG")" run_with_timeout 20 bash "$AGENTS_DIR/bin/env-effective-kv" --repo-root "$(to_node_path "$1")" --key "$2" 2>/dev/null; }
gcv() { AGENTS_CONFIG_DIR="$(to_node_path "$CASE_CFG")" run_with_timeout 20 bash "$AGENTS_DIR/bin/get-config-var" --repo-root "$(to_node_path "$1")" "$2" 2>/dev/null; }

# The issue-#2223 outcome, end to end through both shipped readers: PROJECT_NFR
# from a project's own file with no declaration anywhere.
new_case cli-nfr 'CODE_LANG=english@NL@PROJECT_NFR=global-nfr' 'PROJECT_NFR=local-nfr-no-decl'
assert_eq "T2223R-nfr-eek-local-wins-undeclared" "local-nfr-no-decl" "$(eek "$CASE_ROOT" PROJECT_NFR)"
assert_eq "T2223R-nfr-gcv-local-wins-undeclared" "local-nfr-no-decl" "$(gcv "$CASE_ROOT" PROJECT_NFR)"

# A stale LOCAL_OVERRIDABLE_KEYS line in the global .env changes neither answer.
new_case cli-stale-decl 'LOCAL_OVERRIDABLE_KEYS=CODE_LANG@NL@PROJECT_NFR=global-nfr@NL@ENFORCE_WORKTREE=on' 'PROJECT_NFR=local-nfr-stale-decl@NL@ENFORCE_WORKTREE=off'
assert_eq "T2223R-stale-decl-grants-nothing" "on" "$(eek "$CASE_ROOT" ENFORCE_WORKTREE)"
assert_eq "T2223R-stale-decl-denies-nothing" "local-nfr-stale-decl" "$(eek "$CASE_ROOT" PROJECT_NFR)"

new_case cli-empty 'CODE_LANG=english' '__NONE__'
: > "$CASE_ROOT/$LOCAL_ENV_BASENAME"
assert_eq "T2223R-empty-local-eek-falls-back" "english" "$(eek "$CASE_ROOT" CODE_LANG)"
assert_eq "T2223R-empty-local-gcv-falls-back" "english" "$(gcv "$CASE_ROOT" CODE_LANG)"

# Unreadable-as-a-file: a directory at that name is the portable form of "open
# fails", since chmod 000 is not honoured on every filesystem this suite runs on.
new_case cli-unreadable 'CODE_LANG=english' '__NONE__'
mkdir -p "$CASE_ROOT/$LOCAL_ENV_BASENAME"
assert_eq "T2223R-unreadable-local-eek-falls-back" "english" "$(eek "$CASE_ROOT" CODE_LANG)"
assert_eq "T2223R-unreadable-local-gcv-falls-back" "english" "$(gcv "$CASE_ROOT" CODE_LANG)"

# A project root carrying spaces and shell metacharacters. The local value must
# still apply — proving the path was really used — while the canary proves no
# part of the name was ever handed to a shell for evaluation.
new_case cli-meta 'CODE_LANG=english@NL@ENFORCE_WORKTREE=on' '__NONE__'
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
assert_eq "T2223R-meta-path-blocklist-still-wins" "on" "$(eek "$META_ROOT" ENFORCE_WORKTREE)"

# The Bash-tool door in front of env-effective-kv --allow-dump. Same sibling-file
# form as the blocklist cases above; sourced last because it uses to_node_path.
DUMP_CASES_FILE="$AGENTS_DIR/tests/feature-2223-local-env-overlay/allow-dump-guard.sh"
if [ -f "$DUMP_CASES_FILE" ]; then
    . "$DUMP_CASES_FILE"
else
    fail "T2223AD-cases-file-present — $DUMP_CASES_FILE missing"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
