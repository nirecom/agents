#!/usr/bin/env bash
# j2-signal-timed-exec.sh — stop signals reach a test running under its registry timeout (#2501).
# Tests: tests/run-all.sh, bin/lib/timed-exec.sh, bin/lib/run-all-launch.sh
# Tags: tests, bin, parallel, timeout, scope:issue-specific

# WHY: a test with an effective timeout runs under timed_exec (the shipped bash entry is null, so the fixture pins 600).
# GNU timeout leaves the runner's process group, so run-all's group kill no longer reaches
# the test unless timed_exec forwards it. A deadline abort, Ctrl-C (INT) and TERM must each
# leave neither the wrapped bash test nor its grandchild alive 3s after the runner is gone.

set -uo pipefail
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
# shellcheck source=../../lib/harness.sh
. "$FX_REPO_ROOT/tests/lib/harness.sh"
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$FX_REPO_ROOT/tests/lib/test-language-registry-fixture.sh"

fx_init "j2-signal-timed-exec"
export RUN_ALL_CACHE_DIR="$FX_CACHE_DIR"
export WORKFLOW_STATE_DIR="$FX_TMP_ROOT/workflow"
export WORKFLOW_PLANS_DIR="$FX_TMP_ROOT/plans"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

kill -0 "$$" 2>/dev/null || { echo "SKIP: kill -0 is unavailable on this host"; exit 77; }
[ -f "$FX_REPO_ROOT/bin/lib/timed-exec.sh" ] ||
    fx_fail "bin/lib/timed-exec.sh is not present — timed_exec signal forwarding is not implemented"

SET_BASH_TIMEOUT='const fs=require("fs");const p=process.argv[1];const j=JSON.parse(fs.readFileSync(p,"utf8"));for(const e of j.entries){if(e.id==="bash"){e.launch.timeoutSeconds=600}}fs.writeFileSync(p,JSON.stringify(j,null,2))'

# te_root — a root running the REAL launcher, with bash launch.timeoutSeconds=600 pinned.
te_root() {
    local root lib
    root="$(fx_new_root)" || return 1
    install_test_language_registry "$root" "$FX_REPO_ROOT" >/dev/null || return 1
    cp "$FX_REPO_ROOT/bin/run-with-timeout.sh" "$root/bin/run-with-timeout.sh" || return 1
    for lib in run-all-launch.sh timed-exec.sh run-all-classify.sh run-all-report.sh test-language-registry-plain.sh; do
        [ -f "$FX_REPO_ROOT/bin/lib/$lib" ] && cp "$FX_REPO_ROOT/bin/lib/$lib" "$root/bin/lib/$lib"
    done
    [ -d "$FX_REPO_ROOT/bin/lib/test-wrappers" ] && cp -R "$FX_REPO_ROOT/bin/lib/test-wrappers" "$root/bin/lib/"
    [ -d "$FX_REPO_ROOT/hooks/lib/test-language-registry" ] &&
        cp -R "$FX_REPO_ROOT/hooks/lib/test-language-registry" "$root/hooks/lib/"
    node -e "$SET_BASH_TIMEOUT" "$(np "$root/hooks/lib/test-language-registry.json")" || return 1
    [ -f "$root/bin/lib/run-all-launch.sh" ] || return 1
    echo "$root"
}

# te_case <tag> <how: deadline|INT|TERM> — one k1 (sleep 60 + grandchild) through the launcher.
te_case() {
    local tag="$1" how="$2" root self grand waited=0
    root="$(te_root)" || { fx_fail "J2-$tag. fixture root with the real launcher could not be built"; return 0; }
    fx_add_dummy "$root" k1 --sleep 60 --grandchild
    if [ "$how" = "deadline" ]; then
        RUN_ALL_REGISTRY_LIB="$root/bin/lib/test-language-registry.sh" \
            fx_exec_bg "$root" "$FX_TMP_ROOT/$tag.out" "$FX_TMP_ROOT/$tag.err" -j 2 --deadline 3 --all
    else
        RUN_ALL_REGISTRY_LIB="$root/bin/lib/test-language-registry.sh" \
            fx_exec_bg "$root" "$FX_TMP_ROOT/$tag.out" "$FX_TMP_ROOT/$tag.err" -j 2 --all
    fi
    while [ ! -s "$root/pids/k1.grandchild" ] && [ "$waited" -lt 12 ] && fx_pid_alive "$FX_BG_PID"; do
        sleep 1; waited=$((waited + 1))
    done
    self="$(cat "$root/pids/k1.self" 2>/dev/null)"
    grand="$(cat "$root/pids/k1.grandchild" 2>/dev/null)"
    if [ -z "$self" ] || [ -z "$grand" ]; then
        kill -KILL "$FX_BG_PID" 2>/dev/null || true
        fx_fail "J2-$tag. the wrapped test never recorded its pids, so teardown is unverifiable"
        return 0
    fi
    [ "$how" = "deadline" ] || kill -"$how" "$FX_BG_PID" 2>/dev/null || true
    if ! fx_wait_gone 20 "$FX_BG_PID"; then
        kill -KILL "$FX_BG_PID" 2>/dev/null || true
        fx_fail "J2-$tag. the runner was still alive 20s after the $how stop"
    fi
    wait "$FX_BG_PID" 2>/dev/null || true
    if fx_wait_gone 3 "$self" "$grand"; then
        fx_pass "J2-$tag. $how: the timed bash test and its grandchild are gone within 3s of the runner"
    else
        fx_fail "J2-$tag. $how: survivors 3s after the runner exited (test $self alive=$(fx_pid_alive "$self" && echo y || echo n), grandchild $grand alive=$(fx_pid_alive "$grand" && echo y || echo n))"
        kill -KILL "$self" "$grand" 2>/dev/null || true
    fi
}

case_begin "deadline-reaches-timed-test" "bin/lib/timed-exec.sh"
te_case deadline deadline
case_end

case_begin "int-reaches-timed-test" "bin/lib/timed-exec.sh"
te_case int INT
case_end

case_begin "term-reaches-timed-test" "bin/lib/timed-exec.sh"
te_case term TERM
case_end

fx_finish
