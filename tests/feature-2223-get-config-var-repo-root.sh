#!/usr/bin/env bash
# tests/feature-2223-get-config-var-repo-root.sh
# Tests: bin/get-config-var, bin/env-effective-kv, hooks/lib/load-env.sh
# Tags: scope:issue-specific, TL2, get-config-var, env-effective-kv, cli, security, pwsh-not-required
# RED for issue #2223 — the --repo-root CLI surface and the env-effective-kv door.
# env-effective-kv is the config-only reader the NFR path depends on: it must
# never answer from process.env, must emit NUL-separated KEY/VALUE pairs, and
# must degrade to empty-stdout/exit-0 when node is unavailable.
# Parity gap: the PowerShell -RepoRoot half lives in the sibling .Tests.ps1.

set -u

# TL3 gap (what this test does NOT catch):
# - Parameter binding of -IsOff / -RepoRoot / positional Name under a real pwsh.
# - $LASTEXITCODE propagation out of get-config-var.ps1 to a PowerShell caller.
# - Write-Error stream shape for the exit-3 diagnostic — a value leak could
#   survive on the pwsh side while this bash file stays green.
# - node resolution via $env:AGENTS_CONFIG_DIR vs $PSScriptRoot under pwsh.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh, category pwsh-required.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
GCV="$AGENTS_DIR/bin/get-config-var"
EEK="$AGENTS_DIR/bin/env-effective-kv"
LOAD_ENV_SH="$AGENTS_DIR/hooks/lib/load-env.sh"

TMP_ROOT="$(mktemp -d)"
trap 'rm -rf "$TMP_ROOT"' EXIT

export HOME="$TMP_ROOT/home"
export CLAUDE_WORKFLOW_DIR="$TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$TMP_ROOT/plans"
mkdir -p "$HOME" "$CLAUDE_WORKFLOW_DIR" "$WORKFLOW_PLANS_DIR"
unset CLAUDE_SESSION_ID
unset CLAUDE_CODE_SESSION_ID
unset CLAUDE_PROJECT_DIR
unset CODE_LANG
unset PROJECT_NFR
# Every key the cases below branch on is pinned to a fixture file, so an ambient
# export of any of them must not answer instead (skills/_shared/test-design.md).
unset ENFORCE_WORKTREE
unset CONFIRM_DETAIL
unset PLAIN_KEY

LOCAL_ENV_BASENAME=".env"".local"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name — want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

assert_contains() {
    local name="$1" haystack="$2" needle="$3"
    if printf '%s' "$haystack" | grep -qF -- "$needle"; then pass "$name"
    else fail "$name — expected '$needle'; got: $haystack"; fi
}

# Absence over an empty payload is not evidence, so require content first.
assert_lacks_nonempty() {
    local name="$1" haystack="$2" needle="$3"
    if [ -z "$haystack" ]; then
        fail "$name — empty output; absence of '$needle' not provable"
    elif printf '%s' "$haystack" | grep -qF -- "$needle"; then
        fail "$name — '$needle' unexpectedly present; got: $haystack"
    else
        pass "$name"
    fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    printf '%s' "$s"
}

# ---------------------------------------------------------------------------
# One shared fixture. There is no allowlist any more: the global .env still
# carries a stale LOCAL_OVERRIDABLE_KEYS line to prove the dead setting grants
# nothing and denies nothing, and the project's local file overrides both an
# ordinary key and a blocklisted one.
# ---------------------------------------------------------------------------
CFG="$TMP_ROOT/cfg"
mkdir -p "$CFG"
printf '%s\n' \
    'LOCAL_OVERRIDABLE_KEYS=CODE_LANG' \
    'CODE_LANG=english' \
    'PROJECT_NFR=global-nfr' \
    'ENFORCE_WORKTREE=on' \
    'CONFIRM_DETAIL=on' \
    'PLAIN_KEY=globalplain' > "$CFG/.env"

PROJ="$TMP_ROOT/proj"
mkdir -p "$PROJ/.git"
printf '%s\n' \
    'CODE_LANG=japanese' \
    'PROJECT_NFR=local-nfr-no-decl' \
    'ENFORCE_WORKTREE=off' \
    'CONFIRM_DETAIL=off' \
    'PLAIN_KEY=localplain' > "$PROJ/$LOCAL_ENV_BASENAME"

gcv() { AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$GCV" "$@" 2>/dev/null; }

gcv_rc() {
    AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$GCV" "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

if [ ! -f "$EEK" ]; then
    echo "NOTE: bin/env-effective-kv absent — the eek-* cases are expected RED."
fi

# ---------------------------------------------------------------------------
# Table 1 — bin/get-config-var value mode. Columns: name | args | want
# `@R@` stands in for the project root so the table stays one line per case.
# ---------------------------------------------------------------------------
while IFS='|' read -r name args want; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    args="$(trim "$args")"; args="${args//@R@/$PROJ}"
    # shellcheck disable=SC2086 — the table supplies pre-split, space-free tokens.
    got="$(gcv $args)"
    assert_eq "T2223V-$name" "$(trim "$want")" "$got"
done <<'TABLE'
gcv-no-repo-root-global          | CODE_LANG                                  | english
gcv-repo-root-applies-override   | --repo-root @R@ CODE_LANG                  | japanese
gcv-repo-root-blocklisted-denied | --repo-root @R@ ENFORCE_WORKTREE           | on
gcv-repo-root-undeclared-applies | --repo-root @R@ PLAIN_KEY                  | localplain
gcv-repo-root-nfr-applies        | --repo-root @R@ PROJECT_NFR                | local-nfr-no-decl
gcv-repo-root-default-used       | --repo-root @R@ MISSING_KEY fallbackvalue  | fallbackvalue
gcv-repo-root-missing-dir        | --repo-root @R@/nope CODE_LANG             | english
gcv-repo-root-missing-dir-nfr    | --repo-root @R@/nope PROJECT_NFR           | global-nfr
TABLE

# Flag order must not change the answer — the current parser only inspects $1,
# so a second flag position is a real risk here.
assert_eq "T2223V-gcv-repo-root-order-independent" \
    "$(gcv --repo-root "$PROJ" --is-off CONFIRM_DETAIL; printf 'rc=%s' "$?")" \
    "$(gcv --is-off --repo-root "$PROJ" CONFIRM_DETAIL; printf 'rc=%s' "$?")"

# --is-off exit matrix under --repo-root: 0 = OFF, 1 = ON, 2 = unset.
# A blocklisted gate keeps its global ON despite the local off...
assert_eq "T2223V-gcv-is-off-blocklisted-stays-on" "1" \
    "$(gcv_rc --is-off --repo-root "$PROJ" ENFORCE_WORKTREE)"
# ...while an ordinary gate now follows the local file with no declaration.
assert_eq "T2223V-gcv-is-off-undeclared-local-off" "0" \
    "$(gcv_rc --is-off --repo-root "$PROJ" CONFIRM_DETAIL)"
assert_eq "T2223V-gcv-is-off-unset-key" "2" \
    "$(gcv_rc --is-off --repo-root "$PROJ" NO_SUCH_KEY_AT_ALL)"
assert_eq "T2223V-gcv-repo-root-missing-value" "64" \
    "$(gcv_rc --repo-root)"

# An exported value still outranks both config layers in value mode — the
# documented get-config-var contract, unchanged by --repo-root.
assert_eq "T2223V-gcv-process-env-still-wins" "exported" \
    "$(CODE_LANG=exported gcv --repo-root "$PROJ" CODE_LANG)"

# ---------------------------------------------------------------------------
# Table 2 — bin/env-effective-kv. Columns: name | args | want
# ---------------------------------------------------------------------------
eek() { AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" "$@" 2>/dev/null; }

# A missing binary makes bash exit 127 with empty stdout, which would satisfy
# several of the expectations below by accident. Every such case goes through
# this guard so an absent CLI reads as RED rather than as evidence.
assert_eek_eq() {
    if [ ! -f "$EEK" ]; then fail "$1 — bin/env-effective-kv does not exist"
    else assert_eq "$1" "$2" "$3"; fi
}

while IFS='|' read -r name args want; do
    name="$(trim "$name")"
    [ -n "$name" ] || continue
    case "$name" in \#*) continue ;; esac
    args="$(trim "$args")"; args="${args//@R@/$PROJ}"
    # shellcheck disable=SC2086 — pre-split, space-free tokens from the table.
    got="$(eek $args)"
    assert_eek_eq "T2223E-$name" "$(trim "$want")" "$got"
done <<'TABLE'
eek-key-global-only        | --global-only --key CODE_LANG          | english
eek-key-repo-root-override | --repo-root @R@ --key CODE_LANG        | japanese
eek-key-blocklisted-denied | --repo-root @R@ --key ENFORCE_WORKTREE | on
eek-key-undeclared-applies | --repo-root @R@ --key PLAIN_KEY        | localplain
eek-key-nfr-applies        | --repo-root @R@ --key PROJECT_NFR      | local-nfr-no-decl
eek-key-nfr-global-only    | --global-only --key PROJECT_NFR        | global-nfr
eek-key-absent-empty       | --global-only --key NO_SUCH_KEY        |
TABLE

# A bare invocation (no --key, no --allow-dump) must refuse rather than dump
# the whole map: dump output is opt-in only, so a plain values secret sitting
# in the global .env is never one unmarked invocation away from a transcript.
noarg_out="$TMP_ROOT/eek-noarg.bin"
AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" > "$noarg_out" 2>/dev/null
noarg_rc="$?"
assert_eek_eq "T2223E-eek-no-arg-usage-error" "64" "$noarg_rc"
assert_eek_eq "T2223E-eek-no-arg-empty-stdout" "0" "$(wc -c < "$noarg_out" | tr -d ' ')"

# --global-only alone (dump implied but not acknowledged) must also refuse —
# --allow-dump is mandatory for whole-map output regardless of selector.
selector_only_rc_out="$TMP_ROOT/eek-selector-only.bin"
AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" --global-only > "$selector_only_rc_out" 2>/dev/null
assert_eek_eq "T2223E-eek-global-only-without-allow-dump-usage-error" "64" "$?"

# --global-only --allow-dump and --allow-dump (default selector) are two
# spellings of one behaviour that must not drift apart silently.
global_out="$TMP_ROOT/eek-global.bin"
default_dump_out="$TMP_ROOT/eek-default-dump.bin"
AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" --global-only --allow-dump > "$global_out" 2>/dev/null
AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" --allow-dump > "$default_dump_out" 2>/dev/null
if [ -s "$default_dump_out" ] && cmp -s "$default_dump_out" "$global_out"; then
    pass "T2223E-eek-default-selector-equals-global-only"
else
    fail "T2223E-eek-default-selector-equals-global-only — outputs differ or are empty ($(wc -c < "$default_dump_out" | tr -d ' ') vs $(wc -c < "$global_out" | tr -d ' ') bytes)"
fi

# The stream contract is NUL-separated KEY\0VALUE\0, so a value containing a
# newline or an '=' cannot be mistaken for a record boundary.
nul_count="$(tr -dc '\0' < "$global_out" 2>/dev/null | wc -c | tr -d ' ')"
[ -n "$nul_count" ] || nul_count=0
if [ "$nul_count" -ge 2 ]; then
    pass "T2223E-eek-nul-separated (found $nul_count NUL bytes)"
else
    fail "T2223E-eek-nul-separated — expected NUL-separated records, found $nul_count NUL bytes"
fi
pairs_text="$(tr '\0' '\n' < "$global_out" 2>/dev/null)"
assert_contains "T2223E-eek-emits-key-token" "$pairs_text" "CODE_LANG"
assert_contains "T2223E-eek-emits-value-token" "$pairs_text" "english"

# The whole reason this binary exists rather than reusing get-config-var.
env_out="$(CODE_LANG=exported-should-not-appear eek --global-only --key CODE_LANG)"
assert_eq "T2223E-eek-never-reads-process-env" "english" "$env_out"
env_dump="$(PLAIN_KEY=exported-dump eek --global-only --allow-dump)"
assert_lacks_nonempty "T2223E-eek-dump-never-reads-process-env" "$env_dump" "exported-dump"

# Mutually exclusive selectors must be rejected rather than silently ranked.
AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" --repo-root "$PROJ" --global-only >/dev/null 2>&1
conflict_rc="$?"
if [ ! -f "$EEK" ]; then
    fail "T2223E-eek-conflicting-selectors-rejected — bin/env-effective-kv does not exist"
elif [ "$conflict_rc" -ne 0 ] && [ "$conflict_rc" -ne 127 ]; then
    pass "T2223E-eek-conflicting-selectors-rejected (exit $conflict_rc)"
else
    fail "T2223E-eek-conflicting-selectors-rejected — expected a usage exit, got $conflict_rc"
fi

# node absent: empty stdout, exit 0, a warning on stderr. A hook that shells out
# to this must not be broken by a missing runtime.
NONODE_BIN="$TMP_ROOT/nonode"
mkdir -p "$NONODE_BIN"
for t in bash cat printf grep sed awk tr dirname basename realpath mktemp rm timeout perl env wc; do
    src="$(command -v "$t" 2>/dev/null)"
    [ -n "$src" ] && ln -sf "$src" "$NONODE_BIN/$t" 2>/dev/null
done
command -v cygpath >/dev/null 2>&1 && ln -sf "$(command -v cygpath)" "$NONODE_BIN/cygpath" 2>/dev/null
NONODE_OUT="$TMP_ROOT/nonode-out.txt"
NONODE_ERR="$TMP_ROOT/nonode-err.txt"
REAL_BASH="$(command -v bash)"
(
    export AGENTS_CONFIG_DIR="$CFG"
    export PATH="$NONODE_BIN"
    "$REAL_BASH" "$EEK" --global-only --allow-dump
) > "$NONODE_OUT" 2> "$NONODE_ERR"
nonode_rc="$?"
assert_eek_eq "T2223E-eek-no-node-exit-0" "0" "$nonode_rc"
assert_eek_eq "T2223E-eek-no-node-empty-stdout" "0" "$(wc -c < "$NONODE_OUT" | tr -d ' ')"
if [ ! -f "$EEK" ]; then
    fail "T2223E-eek-no-node-warns-on-stderr — bin/env-effective-kv does not exist"
elif [ -s "$NONODE_ERR" ]; then
    pass "T2223E-eek-no-node-warns-on-stderr"
else
    fail "T2223E-eek-no-node-warns-on-stderr — stderr was empty; the degradation is silent"
fi

# ---------------------------------------------------------------------------
# hooks/lib/load-env.sh stays a global-only door. It is the bash-side twin of
# readDefaultEnvFile(), so the local layer must be invisible to it.
# ---------------------------------------------------------------------------
les() {
    AGENTS_CONFIG_DIR="$CFG" CLAUDE_PROJECT_DIR="$PROJ" run_with_timeout 25 bash -c '
      . "$1" || exit 3
      _load_env_only_value "$2"
    ' _ "$LOAD_ENV_SH" "$1" 2>/dev/null
}

assert_eq "T2223S-load-env-sh-reads-global" "english" "$(les CODE_LANG)"
assert_eq "T2223S-load-env-sh-ignores-local-override" "english" "$(les CODE_LANG)"
assert_eq "T2223S-load-env-sh-default-syntax" "fallbackvalue" "$(les 'NO_SUCH_KEY:-fallbackvalue')"

# Even with the project dir pinned, a forbidden key keeps its global value.
assert_eq "T2223S-load-env-sh-forbidden-key-global" "on" "$(les ENFORCE_WORKTREE)"

# ---------------------------------------------------------------------------
# env-effective-kv usage errors. Every rejection must be exit 64 with an empty
# stdout and a stderr that names no config value: a usage message is printed
# before any resolution happens, so a value reaching it would mean the reader
# ran first.
# ---------------------------------------------------------------------------
eek_usage_case() {
    local name="$1"; shift
    local out="$TMP_ROOT/eeku-out.bin" err="$TMP_ROOT/eeku-err.txt" rc
    AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" "$@" > "$out" 2> "$err"
    rc="$?"
    assert_eek_eq "T2223E-$name-exit-64" "64" "$rc"
    assert_eek_eq "T2223E-$name-empty-stdout" "0" "$(wc -c < "$out" | tr -d ' ')"
    if [ ! -f "$EEK" ]; then
        fail "T2223E-$name-no-value-in-stderr — bin/env-effective-kv does not exist"
    elif grep -qF -e 'english' -e 'globalplain' -e 'japanese' "$err" 2>/dev/null; then
        fail "T2223E-$name-no-value-in-stderr — a config value reached stderr: $(cat "$err")"
    else
        pass "T2223E-$name-no-value-in-stderr"
    fi
}

eek_usage_case eek-repo-root-missing-value --repo-root
eek_usage_case eek-key-missing-value --global-only --key
eek_usage_case eek-unknown-flag --global-only --bogus --key CODE_LANG

# --key together with --allow-dump is NOT rejected by the current parser: --key
# simply wins. The leak boundary is what matters, so this pins the observable
# consequence — one value out, never the whole map. Tightening this pair into a
# usage error is a source change and out of scope for this test-only pass.
both_out="$TMP_ROOT/eek-both.bin"
AGENTS_CONFIG_DIR="$CFG" run_with_timeout 25 bash "$EEK" --global-only --key CODE_LANG --allow-dump > "$both_out" 2>/dev/null
assert_eek_eq "T2223E-eek-key-plus-allow-dump-single-value" "english" "$(cat "$both_out")"
assert_lacks_nonempty "T2223E-eek-key-plus-allow-dump-no-whole-map" "$(cat "$both_out")" "globalplain"

# ---------------------------------------------------------------------------
# --is-off exit matrix, every controlling value pinned in a fixture .env rather
# than inherited: an ambient export of any of these names would otherwise
# answer instead of the file and flip the code under test.
# ---------------------------------------------------------------------------
unset GCV_TOGGLE_A GCV_TOGGLE_B GCV_TOGGLE_C GCV_SECRET_TOGGLE GCV_NO_SUCH_TOGGLE

CFG2="$TMP_ROOT/cfg2"
mkdir -p "$CFG2"
printf '%s\n' \
    'GCV_TOGGLE_A=off' \
    'GCV_TOGGLE_B=on' \
    'GCV_TOGGLE_C=on' \
    'GCV_SECRET_TOGGLE=on' > "$CFG2/.env"

PROJ2="$TMP_ROOT/proj2"
mkdir -p "$PROJ2/.git"
GCV_SECRET_LITERAL='CONFIDENTIAL-2223-NfrValue-9f8e7d'
printf '%s\n' \
    'GCV_TOGGLE_C=neither-on-nor-off' \
    "GCV_SECRET_TOGGLE=$GCV_SECRET_LITERAL" > "$PROJ2/$LOCAL_ENV_BASENAME"

gcv2_rc() {
    AGENTS_CONFIG_DIR="$CFG2" run_with_timeout 25 bash "$GCV" "$@" >/dev/null 2>&1
    printf '%s' "$?"
}

assert_eq "T2223X-is-off-exit-0-off" "0" "$(gcv2_rc --is-off --repo-root "$PROJ2" GCV_TOGGLE_A)"
assert_eq "T2223X-is-off-exit-1-on" "1" "$(gcv2_rc --is-off --repo-root "$PROJ2" GCV_TOGGLE_B)"
assert_eq "T2223X-is-off-exit-2-unset" "2" "$(gcv2_rc --is-off --repo-root "$PROJ2" GCV_NO_SUCH_TOGGLE)"
assert_eq "T2223X-is-off-exit-3-unrecognized" "3" "$(gcv2_rc --is-off --repo-root "$PROJ2" GCV_TOGGLE_C)"

# Exit 4 is the internal-failure code: load-env.js present but unrequirable.
BROKENCFG="$TMP_ROOT/cfg-broken"
mkdir -p "$BROKENCFG/hooks/lib"
printf '%s\n' 'throw new Error("load-env deliberately broken for T2223X");' > "$BROKENCFG/hooks/lib/load-env.js"
printf '%s\n' 'GCV_TOGGLE_A=off' > "$BROKENCFG/.env"
AGENTS_CONFIG_DIR="$BROKENCFG" run_with_timeout 25 bash "$GCV" --is-off --repo-root "$PROJ2" GCV_TOGGLE_A >/dev/null 2>&1
assert_eq "T2223X-is-off-exit-4-internal-failure" "4" "$?"

# Regression: the exit-3 diagnostic must not echo the value it rejected. With
# --repo-root the value can come from a reviewed project's local override file,
# so printing it would put a secret-shaped config value on stderr.
LEAK_OUT="$TMP_ROOT/gcv-leak-out.txt"
LEAK_ERR="$TMP_ROOT/gcv-leak-err.txt"
AGENTS_CONFIG_DIR="$CFG2" run_with_timeout 25 bash "$GCV" --is-off --repo-root "$PROJ2" GCV_SECRET_TOGGLE > "$LEAK_OUT" 2> "$LEAK_ERR"
leak_rc="$?"
assert_eq "T2223X-secret-toggle-exit-3" "3" "$leak_rc"
assert_lacks_nonempty "T2223X-secret-not-on-stderr" "$(cat "$LEAK_ERR")" "$GCV_SECRET_LITERAL"
if [ -s "$LEAK_OUT" ]; then
    fail "T2223X-secret-not-on-stdout — stdout was non-empty: $(cat "$LEAK_OUT")"
else
    pass "T2223X-secret-not-on-stdout"
fi
assert_contains "T2223X-diagnostic-names-the-key" "$(cat "$LEAK_ERR")" "GCV_SECRET_TOGGLE"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
