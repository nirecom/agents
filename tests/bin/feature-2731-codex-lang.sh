#!/bin/bash
# tests/bin/feature-2731-codex-lang.sh
# Tests: bin/lib/codex-core.sh, bin/lib/codex-lang.sh
# Tags: codex, conv-lang, plan-lang, preamble, fail-open, TL2, scope:issue-specific, pwsh-not-required
# #2731 R3: codex_core_adversarial_preamble <kind> [conv|plan] appends the CODEX_FREE_TEXT line.
# TL3 gap: only a real codex CLI on a native host shows the model honours the language line.

# RED until write-code lands S4 (codex-lang.sh, `lang-directive.js --codex`, preamble 2nd arg);
# the no-surface byte-identity and noop cases are GREEN now as regression guards.
set -uo pipefail

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
_ISOLATION_TMP_ROOT="$(make_tmp)"; readonly _ISOLATION_TMP_ROOT
harness_isolate "$_ISOLATION_TMP_ROOT"
trap 'rm -rf "$_ISOLATION_TMP_ROOT"' EXIT
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true
# The language reader loads $AGENTS_MAIN_ROOT/.env; the shared decoy's .env may carry other
# tests' language keys, so point AGENTS_MAIN_ROOT at a per-test .env that sets none.
# shellcheck source=../lib/confirm-env-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/confirm-env-fixture.sh"
LANG_CFG_DIR="$_ISOLATION_TMP_ROOT/lang-cfg"
confirm_env_root "$LANG_CFG_DIR"
EMPTY_CFG_ROOT="$AGENTS_MAIN_ROOT"

CORE_SH="$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-core.sh"
LANG_DIRECTIVE_JS="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/lib/lang-directive.js")"
KIND="supervisor audit-mode session"

# The current preamble, rebuilt from its known text (byte-identity baseline).
WANT_PREAMBLE="The following $KIND was authored by Claude (a different LLM, not by a human). Your job is to provide an independent, adversarial second opinion. Do not assume Claude's reasoning is correct. Actively look for blind spots and issues Claude may have missed. Be skeptical of design choices and challenge them."

# preamble <surface-or-empty> — the preamble from a fresh shell in a neutral CWD;
# the caller sets or unsets the language env so every branch is explicit.
preamble() {
    (cd "$_ISOLATION_TMP_ROOT" && run_with_timeout 60 bash -c '. "$1"; if [ -n "$3" ]; then codex_core_adversarial_preamble "$2" "$3"; else codex_core_adversarial_preamble "$2"; fi' _ "$CORE_SH" "$KIND" "$1" 2>/dev/null) | tr -d '\r'
}

# directive <surface> — the expected language line, straight from the SSOT CLI.
directive() {
    (cd "$_ISOLATION_TMP_ROOT" && run_with_timeout 30 node "$LANG_DIRECTIVE_JS" --codex "$1" 2>/dev/null </dev/null) | tr -d '\r'
}

# expect_lang_line <label> <surface> <var> <value> — with <var>=<value> pinned on both calls,
# the preamble == the bare preamble + exactly one directive line.
expect_lang_line() {
    local label="$1" surface="$2" var="$3" value="$4" got line
    got="$(export "$var=$value"; preamble "$surface")"
    line="$(export "$var=$value"; directive "$surface")"
    case "$line" in
        "Write every free-text field"*japanese*) ;;
        *) fail "$label: lang-directive.js --codex $surface gave no japanese CODEX_FREE_TEXT line (RED until S1/S4)" "got=$(printf '%q' "$line")"; return ;;
    esac
    assert_eq "$got" "$WANT_PREAMBLE"$'\n'"$line"
    assert_eq "$(printf '%s\n' "$got" | grep -c 'Write every free-text field')" "1"
}

case_begin "preamble-no-surface-unchanged" "bin/lib/codex-core.sh"
# With no surface argument the output stays the single preamble line, whatever the language.
assert_eq "$(CONV_LANG=japanese PLAN_LANG=japanese preamble "")" "$WANT_PREAMBLE"
case_end

case_begin "preamble-conv-japanese" "bin/lib/codex-core.sh"
expect_lang_line "conv japanese" conv CONV_LANG japanese
case_end

case_begin "preamble-plan-japanese" "bin/lib/codex-core.sh"
expect_lang_line "plan japanese" plan PLAN_LANG japanese
case_end

case_begin "preamble-conv-noop" "bin/lib/codex-core.sh"
# CONV_LANG noop values: english, any, unset -> no extra line.
assert_eq "$(export CONV_LANG=english; preamble conv)" "$WANT_PREAMBLE"
assert_eq "$(export CONV_LANG=any; preamble conv)" "$WANT_PREAMBLE"
assert_eq "$(unset CONV_LANG; preamble conv)" "$WANT_PREAMBLE"
case_end

case_begin "preamble-plan-noop" "bin/lib/codex-core.sh"
# PLAN_LANG noop values: any, unset -> no extra line (english is a real directive for plan).
assert_eq "$(export PLAN_LANG=any; preamble plan)" "$WANT_PREAMBLE"
assert_eq "$(unset PLAN_LANG; preamble plan)" "$WANT_PREAMBLE"
case_end

case_begin "preamble-plan-env-file-root" "bin/lib/codex-core.sh"
# Positive control for the isolation: a polluted .env under AGENTS_MAIN_ROOT does reach the
# preamble, and the per-test empty .env yields none.
POLLUTED_DIR="$_ISOLATION_TMP_ROOT/polluted-cfg"
mkdir -p "$POLLUTED_DIR"
printf 'PLAN_LANG=english\n' >"$POLLUTED_DIR/.env"
POLLUTED_ROOT="$(np "$POLLUTED_DIR")"
got_polluted="$(unset PLAN_LANG; export AGENTS_MAIN_ROOT="$POLLUTED_ROOT"; preamble plan)"
assert_eq "$(printf '%s\n' "$got_polluted" | grep -c 'Write every free-text field')" "1"
assert_eq "$(unset PLAN_LANG; export AGENTS_MAIN_ROOT="$EMPTY_CFG_ROOT"; preamble plan)" "$WANT_PREAMBLE"
case_end

case_begin "codex-lang-line-sourced" "bin/lib/codex-lang.sh"
# codex-core.sh sources codex-lang.sh, so callers need one source line only.
got_type="$(cd "$_ISOLATION_TMP_ROOT" && run_with_timeout 60 bash -c '. "$1"; type -t codex_lang_line' _ "$CORE_SH" 2>/dev/null)"
assert_eq "$got_type" "function"
# codex_lang_line conv emits the SSOT CLI line unchanged.
want_line="$(export CONV_LANG=japanese; directive conv)"
got_line="$(export CONV_LANG=japanese; cd "$_ISOLATION_TMP_ROOT" && run_with_timeout 60 bash -c '. "$1"; codex_lang_line conv' _ "$CORE_SH" 2>/dev/null | tr -d '\r')"
if [ -n "$want_line" ]; then
    assert_eq "$got_line" "$want_line"
else
    fail "codex_lang_line conv: no directive line to compare against (RED until S1/S4)"
fi
# Noop: codex_lang_line prints nothing and still exits 0.
rc=0
got_noop="$(export CONV_LANG=english; cd "$_ISOLATION_TMP_ROOT" && run_with_timeout 60 bash -c '. "$1"; codex_lang_line conv' _ "$CORE_SH" 2>/dev/null)" || rc=$?
assert_eq "$got_noop" ""
assert_eq "$rc" "0"
case_end

# run_without_node <path-var-value> <script> — run <script> under bash with PATH=<value> and the
# japanese language env; prints "rc=<n>", then stdout, then "stderr=<escaped>".
run_without_node() {
    local out err rc=0
    err="$_ISOLATION_TMP_ROOT/nonode.err"
    out="$(cd "$_ISOLATION_TMP_ROOT" && CONV_LANG=japanese PLAN_LANG=japanese run_with_timeout 60 env PATH="$1" "$BASH" -c "$2" _ "$CORE_SH" 2>"$err")" || rc=$?
    printf 'rc=%s\n%s\nstderr=%q\n' "$rc" "$out" "$(tr -d '\r' <"$err")"
}

NODE_STUB_DIR="$_ISOLATION_TMP_ROOT/node-stub"
mkdir -p "$NODE_STUB_DIR"
printf '#!/bin/sh\necho "node: stub failure" >&2\nexit 127\n' >"$NODE_STUB_DIR/node"
chmod +x "$NODE_STUB_DIR/node"
STUB_PATH="$NODE_STUB_DIR:$PATH"
want_empty_line="rc=0"$'\n\n'"stderr=''"
want_bare_preamble="rc=0"$'\n'"$WANT_PREAMBLE"$'\n'"stderr=''"

case_begin "codex-lang-line-fail-open-node-fails" "bin/lib/codex-lang.sh"
# node exiting 127 (a broken or absent runtime): no line, rc 0, stderr silent, for both surfaces.
assert_eq "$(run_without_node "$STUB_PATH" '. "$1"; codex_lang_line conv')" "$want_empty_line"
assert_eq "$(run_without_node "$STUB_PATH" '. "$1"; codex_lang_line plan')" "$want_empty_line"
assert_eq "$(run_without_node "$STUB_PATH" '. "$1"; codex_core_adversarial_preamble "'"$KIND"'" conv')" "$want_bare_preamble"
case_end

case_begin "codex-lang-line-fail-open-node-absent" "bin/lib/codex-lang.sh"
# A PATH with no node at all (bash's own "command not found" must not leak either).
NO_NODE_PATH="/usr/bin:/bin"
if (PATH="$NO_NODE_PATH"; command -v node >/dev/null 2>&1); then
    skip "node is present in $NO_NODE_PATH on this host; the stub case covers fail-open"
else
    assert_eq "$(run_without_node "$NO_NODE_PATH" '. "$1"; codex_lang_line conv')" "$want_empty_line"
    got_np="$(run_without_node "$NO_NODE_PATH" '. "$1"; codex_core_adversarial_preamble "'"$KIND"'" plan')"
    assert_eq "$got_np" "$want_bare_preamble"
fi
case_end

echo ""
echo "=== Results (feature-2731-codex-lang) ==="
echo "PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
