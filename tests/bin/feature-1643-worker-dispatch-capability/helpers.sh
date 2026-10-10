#!/usr/bin/env bash
# tests/bin/feature-1643-worker-dispatch-capability/helpers.sh
# Tests: bin/worker-dispatch/capability.js, bin/worker-dispatch/fsguard.js, bin/worker-dispatch/spawn.js, bin/worker-dispatch/anchor.js, hooks/lib/worker-dispatch-registry.js
# Tags: worker-dispatch, capability, fsguard, spawn, security, attack-matrix, TL1, scope:issue-specific
# Sourced by ../feature-1643-worker-dispatch-capability.sh — counters, assertions, temp-dir lifecycle.

PASS=0
FAIL=0

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

# Whitespace trim, in-process. The `$(echo "$x" | xargs)` idiom this replaces
# costs a fork + two process starts per column; at ~70 table rows x 3-4 columns
# that alone was over a minute of the suite's wall-clock budget on Windows.
# It is also safer for this table: xargs applies quote and backslash processing,
# and several rows here are *about* backslashes.
trim() {
    local s="$1"
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    TRIMMED="$s"
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wd-cap-$$")"
mkdir -p "$TMPD"
# An inherited EXIT trap runs when a ( ) subshell or a "$( )" substitution exits
# on some bash builds (it does not on others — the behaviour is not portable).
# This suite is full of both: snapshot_all cds into each fixture directory, and
# run_dispatch cds into the main worktree. Unguarded, the first such subshell
# deletes the whole fixture tree MID-RUN, and every later row fails to cd — the
# suite then ends with no summary line at all, which reads as a pass to anything
# that only checks the exit status.
#
# $$ cannot express the guard: it stays the PID of the *invoking* shell inside a
# subshell. $BASHPID is the one that changes, so it is what the comparison uses.
TMPD_OWNER_PID="${BASHPID:-$$}"
cleanup_tmpd() {
    [ "${BASHPID:-$$}" = "$TMPD_OWNER_PID" ] || return 0
    rm -rf "$TMPD"
}
trap cleanup_tmpd EXIT

nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

# A fixture that could not be built ends the run with a counted failure and a summary line.
fixture_abort() {
    fail "fixture/$1"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
}

mk_repo() {
    local d="$1"
    mkdir -p "$d"
    git -C "$d" init -q -b main
    git -C "$d" config user.email "test@example.com"
    git -C "$d" config user.name "Test"
    git -C "$d" config core.hooksPath /dev/null
    echo init > "$d/README.md"
    git -C "$d" add README.md 2>/dev/null
    git -C "$d" commit -q --no-verify -m initial 2>/dev/null
}
