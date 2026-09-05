#!/usr/bin/env bash
# tests/feat-2218-review-tests-choke-point.sh
# Tests: skills/review-tests/scripts/run-codex-review-loop.sh, hooks/lib/handoff-artifact.js
# Tags: review-tests, handoff, choke-point, class-d, exit-code, regression-2218, scope:issue-specific, pwsh-not-required, TL1

# Issue #2218 Step 12 — exits 4, 7 and 8 leave the review loop without ever reaching the completion-sentinel choke point that records every other outcome, so those three are precisely the ones a resumed session would find no trace of. The record therefore belongs in the script itself, immediately before the exit, and must name the code and which path was taken (HALT vs no-sentinel) — "the review ended" is not enough to resume from.

# TL3 gap: the real codex loop is stubbed, so the mapping from a genuine codex verdict to exit 4/7/8 is not re-verified here (bin/run-codex-review-loop owns that); this file drives the exit codes directly and asserts only what the script does with them. Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: workflow-state.

# TDD (write_code has not run): every case is expected to FAIL with "MODULE NOT FOUND: hooks/lib/handoff-artifact.js".

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
LOOP="$AGENTS_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t 'wf2218'; }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }

AGENTS_DIR_NODE="$(node_path "$AGENTS_DIR")"

ARTIFACT="hooks/lib/handoff-artifact.js"

require_module() {
    if [ -f "$AGENTS_DIR/$1" ]; then return 0; fi
    fail "MODULE NOT FOUND: $1 — expected per issue #2218 Step 12, not yet implemented (write_code has not run)"
    return 1
}

# One config fixture serves every case: a copy of the real hooks/ and bin/ (so
# the recorder resolves the same way it will in production, whichever of the two
# roots the implementation picks) with the two commands this script shells out to
# replaced by stubs. The forced exit code travels in an env var, so the stub is
# built once and the table below varies only the environment.
CFG=""
build_cfg() {
    CFG="$(make_tmp)"
    cp -r "$AGENTS_DIR/hooks" "$CFG/hooks" 2>/dev/null || true
    cp -r "$AGENTS_DIR/bin" "$CFG/bin" 2>/dev/null || true
    mkdir -p "$CFG/bin" "$CFG/skills/_shared"
    printf '#!/bin/bash\nexit "${FORCE_RC:-0}"\n' > "$CFG/bin/run-codex-review-loop"
    # No-colon default: only a truly UNSET FORCE_TARGET becomes NOSTATE, so a
    # caller can still force the empty-commit-target branch by setting it to "".
    printf '#!/bin/bash\nprintf %%s "${FORCE_TARGET-NOSTATE}"\n' > "$CFG/bin/resolve-worktree-path"
    chmod +x "$CFG/bin/run-codex-review-loop" "$CFG/bin/resolve-worktree-path"
}

# REVIEW_TESTS_FULL_SCAN=1 keeps the soft-scope block from needing a git repo:
# the exit paths under test are reached before any diff would matter.
run_loop() {
    local tmp="$1" sid="$2" rc_forced="$3" target="$4"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        AGENTS_CONFIG_DIR="$CFG" SESSION_ID="$sid" PLANS_DIR="$tmp/wf" EXTENSIONS_USED="0" \
        REVIEW_TESTS_FULL_SCAN=1 FORCE_RC="$rc_forced" FORCE_TARGET="$target" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 60 bash "$LOOP" >/dev/null 2>&1
}

# Same as run_loop, but from a caller-chosen CWD — needed to drive the NOSTATE
# branch's own `git rev-parse` down its non-git path (line ~35) instead of
# discovering this worktree's real repo.
run_loop_at() {
    local dir="$1" tmp="$2" sid="$3" rc_forced="$4" target="$5"
    ( cd "$dir" 2>/dev/null || exit 90
      env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
          AGENTS_CONFIG_DIR="$CFG" SESSION_ID="$sid" PLANS_DIR="$tmp/wf" EXTENSIONS_USED="0" \
          REVIEW_TESTS_FULL_SCAN=1 FORCE_RC="$rc_forced" FORCE_TARGET="$target" \
          CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
          HOME="$tmp/home" USERPROFILE="$tmp/home" \
          "$RWT" 60 bash "$LOOP" >/dev/null 2>&1 )
}

# Read the entry back through the module's own reader: the grammar belongs to
# the writer, this file only claims what the record must say.
inspect() {
    local tmp="$1" sid="$2" want_code="$3" want_path="$4"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        SID="$sid" WANT_CODE="$want_code" WANT_PATH="$want_path" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readHandoff } = require('$AGENTS_DIR_NODE/$ARTIFACT');
const problems = [];
const doc = readHandoff(process.env.SID);
const all = [].concat.apply([], Object.values(doc.entriesByClass || {})).filter((x) => x.key === 'review-tests:codex-exit');
if (all.length !== 1) problems.push('codex-exit-entries:' + all.length);
else {
  const e = all[0];
  if (e.class !== 'D') problems.push('class:' + e.class);
  const s = String(e.summary);
  if (!new RegExp('(^|[^0-9])' + process.env.WANT_CODE + '([^0-9]|$)').test(s)) problems.push('summary-omits-exit-code:' + s);
  if (s.toLowerCase().indexOf(process.env.WANT_PATH.toLowerCase()) === -1) problems.push('summary-omits-path:' + s);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1
}

# Same claim as inspect(), minus the path-text check — the three
# EXIT_REINVOKE_AFTER_TERMINAL sites (R1's line-61 row, and R6/R7 below) share
# one exit code but the wording of "which path was taken" is not pinned here.
inspect_code_only() {
    local tmp="$1" sid="$2" want_code="$3"
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        SID="$sid" WANT_CODE="$want_code" \
        CLAUDE_WORKFLOW_DIR="$tmp/wf" WORKFLOW_PLANS_DIR="$tmp/wf" \
        HOME="$tmp/home" USERPROFILE="$tmp/home" \
        "$RWT" 30 node -e "
const { readHandoff } = require('$AGENTS_DIR_NODE/$ARTIFACT');
const problems = [];
const doc = readHandoff(process.env.SID);
const all = [].concat.apply([], Object.values(doc.entriesByClass || {})).filter((x) => x.key === 'review-tests:codex-exit');
if (all.length !== 1) problems.push('codex-exit-entries:' + all.length);
else {
  const e = all[0];
  if (e.class !== 'D') problems.push('class:' + e.class);
  const s = String(e.summary);
  if (!new RegExp('(^|[^0-9])' + process.env.WANT_CODE + '([^0-9]|$)').test(s)) problems.push('summary-omits-exit-code:' + s);
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');
" 2>&1
}

# R1 — the table. Each row is an exit that never reaches the completion sentinel:
# 4 and 7 come back from the codex loop itself (HALT), 8 is the #1361 re-invoke
# guard firing before the loop is ever started (no-sentinel). All three must
# leave one class D record naming the code and the path, and none may alter the
# script's own exit code.
run_R1() {
    require_module "$ARTIFACT" || return 0
    local tmp out rc problems row code want_path sid
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    for row in "4:HALT" "7:HALT" "8:no-sentinel"; do
        code="${row%%:*}"; want_path="${row##*:}"
        sid="codex-exit-$code"
        if [ "$code" = "8" ]; then
            # Arm the guard: a terminal marker whose fingerprint cannot be
            # compared (no git repo under the target) takes the fail-CLOSED exit.
            printf '2\nprev-fingerprint\n' > "$tmp/wf/$sid-test-review-terminal.txt"
            run_loop "$tmp" "$sid" 0 "$tmp/target"; rc=$?
        else
            run_loop "$tmp" "$sid" "$code" "$tmp/target"; rc=$?
        fi
        [ "$rc" -eq "$code" ] || problems="$problems [$code]exit-code-changed:$rc"
        out="$(inspect "$tmp" "$sid" "$code" "$want_path")"
        [ "$out" = "OK" ] || problems="$problems [$code]entry:'$out'"
    done
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R1: exits 4, 7 and 8 each record one class D review-tests:codex-exit entry naming the code and the path taken, without changing the exit code"
    else
        fail "R1: —$problems"
    fi
}

# R2 — the negative row that keeps R1 honest. Exit 0 reaches the completion
# sentinel, which already owns that outcome; a second record here would be a
# duplicate of a fact the sentinel path already carries (CPR-SSOT).
run_R2() {
    require_module "$ARTIFACT" || return 0
    local tmp rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    run_loop "$tmp" "clean-sid-r2" 0 "$tmp/target"; rc=$?
    [ "$rc" -eq 0 ] || problems="$problems exit:$rc"
    if [ -f "$tmp/wf/clean-sid-r2-handoff.md" ]; then
        grep -q 'review-tests:codex-exit' "$tmp/wf/clean-sid-r2-handoff.md" && problems="$problems recorded-a-sentinel-reaching-run"
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R2: a clean exit 0 reaches the completion sentinel and records no codex-exit entry"
    else
        fail "R2: —$problems"
    fi
}

# R3 — the same block repeated is not news, and a re-run that ends the same way
# must not grow the artifact one line per retry.
run_R3() {
    require_module "$ARTIFACT" || return 0
    local tmp problems n
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    run_loop "$tmp" "repeat-sid-r3" 4 "$tmp/target"
    run_loop "$tmp" "repeat-sid-r3" 4 "$tmp/target"
    run_loop "$tmp" "repeat-sid-r3" 4 "$tmp/target"
    if [ ! -f "$tmp/wf/repeat-sid-r3-handoff.md" ]; then
        problems="$problems nothing-recorded"
    else
        n=$(grep -c 'review-tests:codex-exit' "$tmp/wf/repeat-sid-r3-handoff.md" 2>/dev/null || true)
        [ "${n:-0}" -eq 1 ] || problems="$problems repeated-identical-exit-wrote:${n:-0}"
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R3: the same terminal exit repeated three times stays one line (noop-identical)"
    else
        fail "R3: —$problems"
    fi
}

# R4 — the invariant. The review's verdict is the script's contract; a breadcrumb
# that cannot be written must not turn exit 4 into anything else.
run_R4() {
    require_module "$ARTIFACT" || return 0
    local tmp rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf/unwritable-sid-r4-handoff.md"
    run_loop "$tmp" "unwritable-sid-r4" 4 "$tmp/target"; rc=$?
    [ "$rc" -eq 4 ] || problems="$problems exit-changed-by-a-failed-artifact-write:$rc"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R4: a failing handoff write leaves the script's exit code at 4"
    else
        fail "R4: —$problems"
    fi
}

# R5 — the classifier's other direction. Exits 1, 2 and 6 leave this script
# through arm_terminal_guard same as 4/7/8's HALT, but they are not the three
# choke-point exits (#2218 Step 12 names only 4, 7, 8): the guard must still
# arm, but no review-tests:codex-exit record belongs to this non-choke-point
# exit. An implementation that records on every nonzero rc fails this row.
run_R5() {
    require_module "$ARTIFACT" || return 0
    local tmp sid rc problems
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    sid="codex-exit-6-nonrecording"
    run_loop "$tmp" "$sid" 6 "$tmp/target"; rc=$?
    [ "$rc" -eq 6 ] || problems="$problems exit-code:$rc"
    [ -f "$tmp/wf/$sid-test-review-terminal.txt" ] || problems="$problems guard-not-armed"
    if [ -f "$tmp/wf/$sid-handoff.md" ]; then
        grep -q 'review-tests:codex-exit' "$tmp/wf/$sid-handoff.md" && problems="$problems recorded-a-non-choke-point-exit"
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R5: exit 6 arms the #1361 re-invoke guard but records no review-tests:codex-exit entry (only 4/7/8 do)"
    else
        fail "R5: —$problems"
    fi
}

# R6 — the first of the two under-exercised EXIT_REINVOKE_AFTER_TERMINAL sites
# (line ~35): COMMIT_TARGET is NOSTATE and the fallback `git rev-parse` also
# fails because the loop is driven from a non-git CWD, so this exits before
# REPO_ROOT_VAL is ever assigned — a different site than R1's line-61 row.
run_R6() {
    require_module "$ARTIFACT" || return 0
    local tmp sid rc problems out
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    sid="codex-exit-8-nostate-nongit"
    printf '2\nprev-fingerprint\n' > "$tmp/wf/$sid-test-review-terminal.txt"
    run_loop_at "$tmp" "$tmp" "$sid" 0 "NOSTATE"; rc=$?
    [ "$rc" -eq 8 ] || problems="$problems exit-code:$rc"
    [ -f "$tmp/wf/$sid-test-review-terminal.txt" ] || problems="$problems terminal-marker-removed"
    out="$(inspect_code_only "$tmp" "$sid" "8")"
    [ "$out" = "OK" ] || problems="$problems entry:'$out'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R6: EXIT_REINVOKE_AFTER_TERMINAL at the NOSTATE/non-git-CWD site (line ~35) records the choke-point entry"
    else
        fail "R6: —$problems"
    fi
}

# R7 — the second under-exercised site (line ~43): resolve-worktree-path
# returns the empty string outright (never NOSTATE), so the guard fires on
# the sibling `elif [[ -z "$COMMIT_TARGET" ]]` branch.
run_R7() {
    require_module "$ARTIFACT" || return 0
    local tmp sid rc problems out
    tmp="$(make_tmp)"; problems=""
    mkdir -p "$tmp/wf"
    sid="codex-exit-8-emptytarget"
    printf '2\nprev-fingerprint\n' > "$tmp/wf/$sid-test-review-terminal.txt"
    run_loop "$tmp" "$sid" 0 ""; rc=$?
    [ "$rc" -eq 8 ] || problems="$problems exit-code:$rc"
    [ -f "$tmp/wf/$sid-test-review-terminal.txt" ] || problems="$problems terminal-marker-removed"
    out="$(inspect_code_only "$tmp" "$sid" "8")"
    [ "$out" = "OK" ] || problems="$problems entry:'$out'"
    rm -rf "$tmp" 2>/dev/null || true
    if [ -z "$problems" ]; then
        pass "R7: EXIT_REINVOKE_AFTER_TERMINAL at the empty-commit-target site (line ~43) records the choke-point entry"
    else
        fail "R7: —$problems"
    fi
}

if [ ! -f "$LOOP" ]; then
    fail "SCRIPT NOT FOUND: skills/review-tests/scripts/run-codex-review-loop.sh"
else
    # Copying the config fixture is only worth its cost once the recorder exists;
    # until then every case stops at its own require_module guard.
    if [ -f "$AGENTS_DIR/$ARTIFACT" ]; then build_cfg; fi
    run_R1
    run_R2
    run_R3
    run_R4
    run_R5
    run_R6
    run_R7
    [ -n "$CFG" ] && rm -rf "$CFG" 2>/dev/null
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
