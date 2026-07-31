#!/usr/bin/env bash
# Tests: bin/get-config-var, .env.example, install.sh, install.ps1
# Tags: bin, install, installer, session-sync, toggle, scope:common
#
# Contract under test — the SESSION_SYNC toggle itself, separated from the two
# profile-snippet call sites (those live in
# tests/fix-1225-profile-snippet-guards/session-sync-gate.sh and
# tests/main-profile-codes.Tests.ps1):
#
#   1. the resolver contract — which exit code bin/get-config-var --is-off
#      produces for every point in the SESSION_SYNC value domain, including the
#      degraded case where node cannot run at all;
#   2. the shipped-default contract — .env.example must document the variable
#      and ship it off.
#
# Manual `bin/session-sync.sh` / `bin/session-sync.ps1` subcommands, and the
# installers' one-time `session-sync-init` bootstrap step in install.sh /
# install.ps1, are deliberately NOT gated; SESSION_SYNC governs only the two
# *automatic* profile-snippet call sites (startup auto-fetch, `codes()`
# auto-push). Without an unconditional bootstrap the manual subcommands would
# have no repo/remote/attributes to act on. That contract is pinned in
# tests/main-session-sync/session-sync-independence.sh,
# tests/main-session-sync.Tests.ps1, and T20/T21 below.
#
# TL3 gap (what this test does NOT catch):
# - A real `install.sh` / `install.ps1` run on a clean machine: the executed
#   matrix in tests/main-session-sync-toggle/installer-exec.sh stubs every
#   install step except the gate under test, so a step whose real behaviour
#   re-execs or reorders the installer is still unexercised.
# - The resolver reading the user's real `.env`: it is exercised against a
#   mirror config directory, so a malformed or OS-conditional real `.env` that
#   changes how SESSION_SYNC parses is not covered.
# - The pwsh resolver (`bin/get-config-var.ps1`) under a real Windows profile;
#   only the bash side's exit codes are pinned here.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: installer.

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RUN_TIMEOUT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0
FAIL=0

pass() { PASS=$((PASS + 1)); printf 'PASS: %s\n' "$1"; }
fail() { FAIL=$((FAIL + 1)); printf 'FAIL: %s\n' "$1"; }

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ---------------------------------------------------------------------------
# Mirror config sandbox.
#
# bin/get-config-var resolves hooks/lib/load-env.js through AGENTS_CONFIG_DIR,
# and load-env.js short-circuits on that same variable, so pointing both at a
# throwaway directory makes the sandbox the single source of config. Without
# it the developer's own repo .env would leak into every expectation.
#
# $1 (optional): body written to the sandbox .env. Omitted → no .env at all,
# which is the "fresh checkout" shape (a missing .env is a silent no-op, so the
# resolver still reports a loaded config).
# ---------------------------------------------------------------------------
make_config_sandbox() {
    local env_body="${1:-}"
    local sb
    sb="$(mktemp -d "$TMPDIR_BASE/cfg.XXXXXX")"
    mkdir -p "$sb/hooks" "$sb/bin" "$sb/nonode"
    cp -R "$AGENTS_DIR/hooks/lib" "$sb/hooks/lib"
    cp "$AGENTS_DIR/bin/get-config-var" "$sb/bin/get-config-var"
    if [ -n "$env_body" ]; then
        printf '%s\n' "$env_body" > "$sb/.env"
    fi
    # A `node` that always fails, used to model an unreadable config.
    printf '#!/bin/sh\necho "node: simulated failure" >&2\nexit 127\n' > "$sb/nonode/node"
    chmod +x "$sb/nonode/node"
    printf '%s' "$sb"
}

# run_gcv <sandbox> <SESSION_SYNC|UNSET> <with-node|no-node> [args...]
# Stdout is captured to $GCV_OUT, stderr to $GCV_ERR; the exit code is returned.
run_gcv() {
    local sb="$1" ss="$2" node_mode="$3"
    shift 3
    local path="$PATH"
    [ "$node_mode" = "no-node" ] && path="$sb/nonode:$PATH"
    local rc=0
    if [ "$ss" = "UNSET" ]; then
        env -u SESSION_SYNC AGENTS_CONFIG_DIR="$sb" PATH="$path" \
            bash "$RUN_TIMEOUT" 30 bash "$sb/bin/get-config-var" "$@" \
            > "$TMPDIR_BASE/gcv.out" 2> "$TMPDIR_BASE/gcv.err" || rc=$?
    else
        env SESSION_SYNC="$ss" AGENTS_CONFIG_DIR="$sb" PATH="$path" \
            bash "$RUN_TIMEOUT" 30 bash "$sb/bin/get-config-var" "$@" \
            > "$TMPDIR_BASE/gcv.out" 2> "$TMPDIR_BASE/gcv.err" || rc=$?
    fi
    GCV_OUT="$(cat "$TMPDIR_BASE/gcv.out")"
    GCV_ERR="$(cat "$TMPDIR_BASE/gcv.err")"
    return "$rc"
}

# ---------------------------------------------------------------------------
# 1. Resolver exit codes — table-driven over the whole SESSION_SYNC value
#    domain plus the two boundary conditions (no default supplied, node broken).
#
#    Exit-code semantics are load-bearing: every call site branches on them, and
#    the shell idiom `--is-off X off && off_path || on_path` maps 0 → OFF and
#    1/2/3/4 → ON. Pinning them here means a resolver change cannot silently
#    flip the fail-safe direction of the gate.
# ---------------------------------------------------------------------------
# tc_isoff <label> <SESSION_SYNC|UNSET> <with-node|no-node> <default|NONE> <expect_rc> <why>
tc_isoff() {
    local label="$1" ss="$2" node_mode="$3" default="$4" expect_rc="$5" why="$6"
    local sb
    sb="$(make_config_sandbox)"
    local rc=0
    if [ "$default" = "NONE" ]; then
        run_gcv "$sb" "$ss" "$node_mode" --is-off SESSION_SYNC || rc=$?
    else
        run_gcv "$sb" "$ss" "$node_mode" --is-off SESSION_SYNC "$default" || rc=$?
    fi
    if [ "$rc" = "$expect_rc" ]; then
        pass "$label: --is-off SESSION_SYNC exits $expect_rc ($why)"
    else
        fail "$label: --is-off SESSION_SYNC exited $rc, expected $expect_rc ($why). stderr: $GCV_ERR"
    fi
    rm -rf "$sb"
}

tc_isoff "T1" off    with-node off  0 "explicit off"
tc_isoff "T2" UNSET  with-node off  0 "unset falls back to the shipped default off"
tc_isoff "T3" on     with-node off  1 "explicit on"
tc_isoff "T4" ON     with-node off  1 "value match is case-insensitive"
tc_isoff "T5" oFf    with-node off  0 "case-insensitivity is symmetric for off"
tc_isoff "T6" maybe  with-node off  3 "unrecognized value is reported, not silently treated as off"
tc_isoff "T7" ""     with-node off  0 "empty value falls back to the default, same as unset"
tc_isoff "T8" UNSET  with-node NONE 2 "unset with no default is distinguishable from an explicit off"
# T9/T10 pin the degraded path. With no usable node the resolver cannot read
# any config at all, so the value it was given is irrelevant — both an explicit
# off and an unrecognized value land on the same exit 2. Callers must therefore
# treat exit 2 as "could not determine", not as "off".
tc_isoff "T9"  maybe no-node   off  2 "node absent: config unreadable, resolver cannot report off"
tc_isoff "T10" off   no-node   off  2 "node absent: even an explicit off is unreadable"

# Note on cross-platform asymmetry: bin/get-config-var.ps1 exits 4 (internal
# failure) for the same node-absent condition, because it inspects a temp file
# it created itself, whereas the bash side sees an empty value first and exits
# 2. Both are non-zero, so both fail safe in the `&& off || on` idiom, but the
# codes differ. Unifying them is deliberately out of scope for this session —
# this note exists so the asymmetry is a recorded, not an accidental, gap.

# T11 — the unrecognized-value path must be observable, not silent.
tc_isoff_warns() {
    local sb
    sb="$(make_config_sandbox)"
    local rc=0
    run_gcv "$sb" maybe with-node --is-off SESSION_SYNC off || rc=$?
    if [ "$rc" = "3" ] && printf '%s' "$GCV_ERR" | grep -qi "unrecognized value"; then
        pass "T11: an unrecognized SESSION_SYNC value warns on stderr"
    else
        fail "T11: expected exit 3 plus an 'unrecognized value' stderr warning (rc=$rc, stderr: '$GCV_ERR')"
    fi
    rm -rf "$sb"
}
tc_isoff_warns

# T11b — the last remaining verdict. When load-env.js itself cannot be loaded
# the resolver reports 4 (internal failure) rather than guessing a value, which
# keeps "config broken" distinguishable from "config says on".
tc_isoff_internal_failure() {
    local sb
    sb="$(make_config_sandbox)"
    printf 'throw new Error("simulated loader failure");\n' > "$sb/hooks/lib/load-env.js"
    local rc=0
    run_gcv "$sb" off with-node --is-off SESSION_SYNC off || rc=$?
    if [ "$rc" = "4" ]; then
        pass "T11b: an unloadable config loader exits 4 (internal failure), not 0"
    else
        fail "T11b: expected exit 4 for an unloadable load-env.js, got $rc. stderr: $GCV_ERR"
    fi
    rm -rf "$sb"
}
tc_isoff_internal_failure

# T11c — security: the configured value reaches a `case` comparison, never a
# shell evaluation. A value carrying shell metacharacters must be rejected as
# unrecognized and must not execute anything (CWE-78).
tc_isoff_no_injection() {
    local sb
    sb="$(make_config_sandbox)"
    local marker="$sb/pwned"
    local rc=0
    run_gcv "$sb" "off; touch '$marker'" with-node --is-off SESSION_SYNC off || rc=$?
    if [ "$rc" = "3" ] && [ ! -e "$marker" ]; then
        pass "T11c: a SESSION_SYNC value with shell metacharacters is rejected, not executed"
    else
        fail "T11c: expected exit 3 and no side effect (rc=$rc, marker_exists=$([ -e "$marker" ] && echo yes || echo no))"
    fi
    rm -rf "$sb"
}
tc_isoff_no_injection

# ---------------------------------------------------------------------------
# 2. The value actually comes from config, and process env still wins.
#    Guards the two directions of the precedence rule the resolver documents.
# ---------------------------------------------------------------------------
tc_env_file_source() {
    local sb
    sb="$(make_config_sandbox "SESSION_SYNC=on")"
    local rc=0
    run_gcv "$sb" UNSET with-node --is-off SESSION_SYNC off || rc=$?
    if [ "$rc" = "1" ]; then
        pass "T12: SESSION_SYNC=on in .env is honoured (exit 1 = ON)"
    else
        fail "T12: .env value not honoured — exit $rc, expected 1. stderr: $GCV_ERR"
    fi
    rm -rf "$sb"
}
tc_env_file_source

tc_process_env_wins() {
    local sb
    sb="$(make_config_sandbox "SESSION_SYNC=on")"
    local rc=0
    run_gcv "$sb" off with-node --is-off SESSION_SYNC off || rc=$?
    if [ "$rc" = "0" ]; then
        pass "T13: process env off overrides .env on (exit 0 = OFF)"
    else
        fail "T13: process env did not win over .env — exit $rc, expected 0. stderr: $GCV_ERR"
    fi
    rm -rf "$sb"
}
tc_process_env_wins

# T14 — value mode (no --is-off) is the other public interface of the resolver.
tc_value_mode() {
    local sb
    sb="$(make_config_sandbox)"
    run_gcv "$sb" UNSET with-node SESSION_SYNC off || true
    if [ "$GCV_OUT" = "off" ]; then
        pass "T14: value mode prints the default 'off' when SESSION_SYNC is unset"
    else
        fail "T14: value mode printed '$GCV_OUT', expected 'off'"
    fi
    rm -rf "$sb"
}
tc_value_mode

# ---------------------------------------------------------------------------
# 3. Shipped default — .env.example must document the toggle and ship it off.
# ---------------------------------------------------------------------------
tc_env_example_entry() {
    local f="$AGENTS_DIR/.env.example"
    if grep -qE '^SESSION_SYNC=off[[:space:]]*$' "$f"; then
        pass "T15: .env.example ships SESSION_SYNC=off"
    else
        local found
        found="$(grep -nE '^SESSION_SYNC=' "$f" || true)"
        fail "T15: .env.example has no 'SESSION_SYNC=off' line (found: ${found:-none})"
    fi
}
tc_env_example_entry

# The .env.example convention requires a 1-5 line user-facing comment block
# directly above each variable. A bare SESSION_SYNC=off with no explanation
# would pass T15 but leave users with an undocumented switch.
tc_env_example_comment_block() {
    local f="$AGENTS_DIR/.env.example"
    local line
    line="$(grep -nE '^SESSION_SYNC=' "$f" | head -1 | cut -d: -f1)"
    if [ -z "$line" ]; then
        fail "T16: no SESSION_SYNC entry in .env.example, so its comment block cannot be checked"
        return
    fi
    local count=0 i=$((line - 1))
    while [ "$i" -ge 1 ]; do
        local text
        text="$(sed -n "${i}p" "$f")"
        case "$text" in
            '#'*) count=$((count + 1)); i=$((i - 1)) ;;
            *) break ;;
        esac
    done
    if [ "$count" -ge 1 ] && [ "$count" -le 5 ]; then
        pass "T16: the SESSION_SYNC entry carries a $count-line comment block"
    else
        fail "T16: the SESSION_SYNC entry has a $count-line comment block, expected 1-5"
    fi
}
tc_env_example_comment_block

# T16b — the comment block must say the right thing, not merely exist.
#
# T16 above only counts lines, so a placeholder comment ("# session sync") would
# satisfy it while leaving the two facts a user actually needs undocumented:
#   1. the toggle governs AUTOMATIC sync only — `bin/session-sync.sh push|pull|
#      reset` keep working when it is off, which is the whole reason the manual
#      subcommands are ungated (pinned in
#      tests/main-session-sync/session-sync-independence.sh);
#   2. the value domain, in the same `Format: off (default) | on.` shape every
#      other boolean entry uses (RUN_TL3, ENFORCE_WORKTREE), so the shipped
#      default is legible without reading the resolver.
# Fact 1 is asserted on substance, not on layout: it may sit on either the
# "What you can do" or the "What you can't do" line, but it must name the manual
# commands AND say they are unaffected — a bare mention of "push" would not.
tc_env_example_comment_wording() {
    local f="$AGENTS_DIR/.env.example"
    local line
    line="$(grep -nE '^SESSION_SYNC=' "$f" | head -1 | cut -d: -f1)"
    if [ -z "$line" ]; then
        fail "T16b: no SESSION_SYNC entry in .env.example, so its comment wording cannot be checked"
        return
    fi
    local block="" i=$((line - 1)) text
    while [ "$i" -ge 1 ]; do
        text="$(sed -n "${i}p" "$f")"
        case "$text" in
            '#'*) block="$text
$block"; i=$((i - 1)) ;;
            *) break ;;
        esac
    done

    local lower
    lower="$(printf '%s' "$block" | tr '[:upper:]' '[:lower:]')"

    if printf '%s' "$lower" | grep -qE 'automatic|automatically'; then
        pass "T16b-1: the SESSION_SYNC comment scopes the toggle to automatic sync"
    else
        fail "T16b-1: the SESSION_SYNC comment never says the toggle covers automatic sync. Block: $(printf '%s' "$block" | tr '\n' ' ')"
    fi

    local names="" unaffected=""
    printf '%s' "$lower" | grep -qE 'manual|push/pull|session-sync\.(sh|ps1)' && names=1
    printf '%s' "$lower" | grep -qE 'regardless|always|still|unaffected|not affected|even (when|if)' && unaffected=1
    if [ -n "$names" ] && [ -n "$unaffected" ]; then
        pass "T16b-2: the comment carves the manual session-sync commands out of the toggle"
    else
        fail "T16b-2: the comment does not tell users the manual session-sync commands keep working when the toggle is off (names them: ${names:-no}, says they are unaffected: ${unaffected:-no}). Block: $(printf '%s' "$block" | tr '\n' ' ')"
    fi

    # Same wording as the other boolean toggles, so the shipped default reads the
    # same way across the file (CPR-5). A trailing clause is fine; the leading
    # `off (default) | on.` shape is what has to match.
    if printf '%s' "$block" | grep -qE '^#[[:space:]]*Format:[[:space:]]*off \(default\) \| on\.'; then
        pass "T16b-3: the comment declares 'Format: off (default) | on.' like the other boolean entries"
    else
        local got
        got="$(printf '%s' "$block" | grep -E '^#[[:space:]]*Format:' || true)"
        fail "T16b-3: the SESSION_SYNC Format line does not match the 'off (default) | on.' convention (got: ${got:-<none>})"
    fi
}
tc_env_example_comment_wording

# ---------------------------------------------------------------------------
# 4. Installer bootstrap — both installers' `session-sync-init` call is
#    unconditional bootstrap infrastructure, required for the manual sync
#    subcommands to have a repo/remote/attributes to act on at all. It is
#    symmetric across both shells (CPR-5): neither installer may gate it
#    without the other. Proven here by execution (T20/T21 below), not by
#    static grep — a grep cannot distinguish a real gate from a comment that
#    merely mentions the variable, which is exactly the shape of the code
#    today (a nearby explanatory comment names SESSION_SYNC without gating
#    anything).
# ---------------------------------------------------------------------------

# T20/T21 — the same installer contract proven by execution rather than by
# source text: both installers are run as real subprocesses against a fully
# stubbed install/ tree, and the session-sync init step's own stub is the
# observable. See tests/main-session-sync-toggle/installer-exec.sh for why the
# static T17/T18 assertions above cannot stand alone.
# shellcheck source=main-session-sync-toggle/installer-exec.sh
. "$AGENTS_DIR/tests/main-session-sync-toggle/installer-exec.sh"

printf '\nPASS: %d FAIL: %d\n' "$PASS" "$FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
