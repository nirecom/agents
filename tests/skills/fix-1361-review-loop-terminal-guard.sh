#!/usr/bin/env bash
# tests/skills/fix-1361-review-loop-terminal-guard.sh
# Tests: skills/review-tests/scripts/run-codex-review-loop.sh, hooks/workflow-state/state-io.js, hooks/workflow-mark/review-tests-handler.js, bin/workflow-control-dir, hooks/workflow-state/state-io/control-dir.js
# Tags: review-tests, review-loop, terminal-guard, fingerprint, staged-tests, review-scope, exit9, scope:issue-specific, pwsh-not-required, TL2
#
# #1361: after a terminal exit (2/3/6/7), a caller that re-invokes the script with
# tests UNCHANGED must be blocked (exit 8) instead of silently restarting ROUND=1.
# The reset seam is the review-scope fingerprint (computeReviewScopeFingerprint SSOT):
# a MISMATCH auto-clears the marker, a COMPUTATION FAILURE keeps it (fail-CLOSED).
# TL3 gap: a real /review-tests invocation with the real shared wrapper and a
# session-bound worktree — checked at the WORKFLOW_USER_VERIFIED preflight.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"
_AGENTS_DIR_NODE="$(np "$AGENTS_DIR")"
SCRIPT="$AGENTS_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0

# Fixture isolation (rules/test/fixture-isolation.md): no inherited session id, a
# throwaway HOME and dual-pinned state dirs, and a neutral CWD. Each case below
# re-pins both dirs to its own root, so markers never leak between cases.
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
ISO_ROOT="$(make_tmp)"
trap 'rm -rf "$ISO_ROOT" 2>/dev/null || true' EXIT
mkdir -p "$ISO_ROOT/home"
export HOME="$ISO_ROOT/home" USERPROFILE="$ISO_ROOT/home"
harness_isolate "$ISO_ROOT"
cd "$ISO_ROOT" || exit 1

if ! command -v git >/dev/null 2>&1; then
    skip "git unavailable — cannot exercise fingerprint seam"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi

# NOTE (detail plan): the terminal guard file holds 2 lines: rc (exit code) and the
# review-scope fingerprint. The reset seam is the fingerprint mismatch, not invalidateReviewTests
# (which has been deleted). A mismatch auto-clears the marker; a compute failure keeps it (fail-CLOSED).

# --- Build a fake AGENTS_CONFIG_DIR with stub bin scripts + real evidence.js ---
build_fake_config() {
    local with_evidence="$1" fake
    fake=$(make_tmp)
    mkdir -p "$fake/bin" "$fake/hooks/workflow-gate"
    cat > "$fake/bin/run-codex-review-loop" <<'STUB'
#!/usr/bin/env bash
# stub: exit with STUB_RC (never calls codex)
exit "${STUB_RC:-0}"
STUB
    cat > "$fake/bin/resolve-worktree-path" <<'STUB'
#!/usr/bin/env bash
echo NOSTATE
STUB
    # #2270: the script resolves the session id through this bridge before it
    # touches the worktree, so the fake config dir has to answer rc 0 — a missing
    # file would read as rc 127 (node absent) and HALT the loop at exit 4.
    cat > "$fake/bin/resolve-session-id" <<'STUB'
#!/usr/bin/env bash
printf 'sid1361'
STUB
    cat > "$fake/bin/resolve-accepted-tradeoffs-file" <<'STUB'
#!/usr/bin/env bash
echo /dev/null
exit 0
STUB
    chmod +x "$fake/bin/run-codex-review-loop" "$fake/bin/resolve-worktree-path" \
        "$fake/bin/resolve-session-id" "$fake/bin/resolve-accepted-tradeoffs-file"
    if [ "$with_evidence" = "yes" ]; then
        cp "$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js" "$fake/hooks/workflow-gate/review-tests-evidence.js"
    fi
    printf '%s' "$fake"
}

# --- Build a git repo with a staged tests/ file ---
build_repo() {
    local repo; repo=$(make_tmp)
    git -C "$repo" init -q 2>/dev/null
    git -C "$repo" config core.hooksPath /dev/null 2>/dev/null || true
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    mkdir -p "$repo/tests"
    echo "echo hi" > "$repo/tests/foo.sh"
    git -C "$repo" add tests/foo.sh 2>/dev/null
    printf '%s' "$repo"
}

# mk_root — one case's isolated root: wf/ (CLAUDE_WORKFLOW_DIR), plans/ (PLANS_DIR
# and WORKFLOW_PLANS_DIR), home/.
mk_root() {
    local r; r="$(make_tmp)"
    mkdir -p "$r/wf" "$r/plans" "$r/home"
    printf '%s' "$r"
}
# pinned <root> <env-assignments…> <cmd…> — run with the root's dirs pinned.
pinned() {
    local r="$1"; shift
    env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$(np "$r/wf")" WORKFLOW_PLANS_DIR="$(np "$r/plans")" \
        HOME="$r/home" USERPROFILE="$r/home" "$@"
}

# The #1361 terminal marker lives in <sid>.control/ since #2434; the legacy
# PLANS_DIR name must never reappear.
term_of() { printf '%s' "$1/wf/$2.control/test-review-terminal.txt"; }
legacy_of() { printf '%s' "$1/plans/$2-test-review-terminal.txt"; }
no_marker() { [ ! -f "$(term_of "$1" "$2")" ] && [ ! -f "$(legacy_of "$1" "$2")" ]; }
# #2357: exit-6 accept marker, a sibling in the same control dir.
ACCEPT_NAME="review-tests-exit6-accepted.txt"

# seed_control <root> <sid> <name> <line…> — write a control file through the
# real control-dir resolver (--for-write creates <sid>.control).
seed_control() {
    local r="$1" sid="$2" name="$3" dir
    shift 3
    dir="$(pinned "$r" node "$AGENTS_DIR/bin/workflow-control-dir" --session "$sid" --for-write)" || return 1
    printf '%s\n' "$@" > "$dir/$name"
}

# run_loop <root> <fake_config> <repo> <stub_rc> → prints exit code
run_loop() {
    local root="$1" fake="$2" repo="$3" rc="$4" ec
    ( cd "$repo" && pinned "$root" AGENTS_CONFIG_DIR="$fake" SESSION_ID="sid1361" \
        PLANS_DIR="$(np "$root/plans")" \
        CLAUDE_CODE_SESSION_ID="sid1361" CLAUDE_SESSION_ID="sid1361" \
        EXTENSIONS_USED=0 STUB_RC="$rc" "$RWT" 40 bash "$SCRIPT" >/dev/null 2>&1 )
    ec=$?
    printf '%s' "$ec"
}

# run_accept_handler <root> <sid> — the real WARNINGS_ACCEPTED call site.
run_accept_handler() {
    pinned "$1" "$RWT" 20 node -e "
const handler = require('$_AGENTS_DIR_NODE/hooks/workflow-mark/review-tests-handler.js');
handler.handle({
  cmd: 'echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: accept coverage gap for now>>\"',
  sessionId: process.argv[1],
  pushMessage: () => {},
  signalFatal: () => {},
  repoCwd: process.cwd(),
});
" "$2" >/dev/null 2>&1 || true
}

# ===================== (a) terminal exit → marker + re-invoke blocked =====================
run_case_a() {
    local plans fake repo term rc1 rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    rc1=$(run_loop "$plans" "$fake" "$repo" 2)   # terminal ESCALATE
    if [ -f "$term" ] && [ ! -f "$(legacy_of "$plans" sid1361)" ]; then
        pass "(a1) terminal exit 2 writes ${term##*/} (rc+fingerprint marker)"
    else
        fail "(a1) RED-EXPECTED (guard absent): terminal marker not written after exit 2"
    fi
    # re-invoke with tests UNCHANGED → must be blocked with exit 8. The guard's
    # own code moved off 6 because 6 is HIGH_UNRESOLVED for every format now
    # (#2068); 8 is unused by the shared wrapper's contract.
    rc2=$(run_loop "$plans" "$fake" "$repo" 2)
    if [ "$rc2" = "8" ]; then
        pass "(a2) re-invoke with unchanged tests → exit 8 (REINVOKE_AFTER_TERMINAL)"
    else
        fail "(a2) RED-EXPECTED (guard absent): re-invoke after terminal exit gave rc=$rc2, want 8"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (b) success terminal (exit 0) writes NO marker ======================
run_case_b() {
    local plans fake repo term
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    run_loop "$plans" "$fake" "$repo" 0 >/dev/null
    if no_marker "$plans" sid1361; then
        pass "(b) exit 0 (COMPLETE) does NOT write terminal marker — clean re-review not blocked"
    else
        fail "(b) exit 0 must not create terminal marker (would wrongly block a fresh review)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (c) real restart: fingerprint change auto-clears (sanctioned pass) ==
run_case_c() {
    local plans fake repo term rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    run_loop "$plans" "$fake" "$repo" 2 >/dev/null   # create marker
    # legitimately re-edit + re-stage tests → fingerprint MISMATCH
    echo "echo changed" >> "$repo/tests/foo.sh"
    git -C "$repo" add tests/foo.sh 2>/dev/null
    rc2=$(run_loop "$plans" "$fake" "$repo" 1)
    # CPR-ORTH sanctioned-pass counterpart of (a2): a genuine restart must NOT be blocked (exit != 8/9)
    if [ "$rc2" != "8" ] && [ "$rc2" != "9" ]; then
        pass "(c) tests re-edited (fingerprint mismatch) → NOT blocked (rc=$rc2 != 8/9)"
    else
        fail "(c) legitimate restart wrongly blocked with exit $rc2 (over-blocking)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (d) WARNINGS_ACCEPTED handler clears terminal marker ===============
run_case_d() {
    local plans term
    plans=$(mk_root)
    term="$(term_of "$plans" sidD)"
    seed_control "$plans" sidD test-review-terminal.txt 2 abc123   # pre-existing terminal marker
    if [ ! -f "$term" ]; then
        fail "(d-seed) terminal marker could not be seeded at ${term#"$plans"/}"
        rm -rf "$plans" 2>/dev/null || true
        return
    fi
    run_accept_handler "$plans" sidD
    if no_marker "$plans" sidD; then
        pass "(d) WARNINGS_ACCEPTED handler clears the terminal marker (real call site)"
    else
        fail "(d) RED-EXPECTED (clearReviewTestsTerminalMarker not wired): marker survived WARNINGS_ACCEPTED"
    fi
    rm -rf "$plans" 2>/dev/null || true
}

# ===================== (e) fingerprint COMPUTATION FAILURE keeps marker + exit 8 ==========
run_case_e() {
    local plans fake repo term rc2
    plans=$(mk_root)
    # fake config WITHOUT evidence.js → fingerprint node -e require fails → compute failure
    fake=$(build_fake_config no)
    repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    # pre-seed a terminal marker as if a prior terminal exit happened
    seed_control "$plans" sid1361 test-review-terminal.txt 2 deadbeefcafebabe
    # re-invoke with STUB_RC=2 (so a naive pass-through would be 2, not 8)
    rc2=$(run_loop "$plans" "$fake" "$repo" 2)
    if [ "$rc2" = "8" ] && [ -f "$term" ]; then
        pass "(e) fingerprint compute failure → exit 8 + marker retained (fail-CLOSED)"
    else
        fail "(e) RED-EXPECTED (fail-CLOSED guard absent): rc=$rc2 (want 8), marker present=$([ -f "$term" ] && echo yes || echo no)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (f) exit 6 (HIGH_UNRESOLVED) is a terminal too =====================
# A round ending on an unresolved HIGH ends the loop as surely as an escalate
# does, so the guard must arm on it: without the marker a caller could restart at
# round 1 over the very concern the exit was about (#2068, CPR-ORTH with (a)).
run_case_f() {
    local plans fake repo term rc1 rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    rc1=$(run_loop "$plans" "$fake" "$repo" 6)   # terminal HIGH_UNRESOLVED
    if [ -f "$term" ] && [ ! -f "$(legacy_of "$plans" sid1361)" ]; then
        pass "(f1) terminal exit 6 writes ${term##*/} like the other terminals"
    else
        fail "(f1) RED-EXPECTED: exit 6 left no terminal marker, so a restart is unguarded"
    fi
    rc2=$(run_loop "$plans" "$fake" "$repo" 6)
    if [ "$rc2" = "8" ]; then
        pass "(f2) and re-invoking over unchanged tests is blocked with exit 8"
    else
        fail "(f2) RED-EXPECTED: re-invoke after an exit-6 terminal gave rc=$rc2, want 8"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (g-new) #2357: PREV_RC=2/7/3 + fingerprint change → NOT exit 9 =======
# CPR-ORTH counterpart of (g): the exit-9 gate is specific to exit-6 (HIGH_UNRESOLVED).
# Exit-2 (escalate), exit-7 (finalize-failed), exit-3 (codex-unavailable) must NOT fire it.
run_case_g_new() {
    local plans fake repo term rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    # Arm via a real exit-2 run (arm_terminal_guard fires on 2|3|6|7), then change fingerprint.
    run_loop "$plans" "$fake" "$repo" 2 >/dev/null
    if [ ! -f "$term" ]; then
        fail "(g-new-arm) exit-2 did not write terminal marker — setup failed"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "echo changed" >> "$repo/tests/foo.sh"
    git -C "$repo" add tests/foo.sh 2>/dev/null
    rc2=$(run_loop "$plans" "$fake" "$repo" 1)
    if [ "$rc2" != "9" ] && no_marker "$plans" sid1361; then
        pass "(g-new) exit-2 arm + fingerprint change → NOT exit 9, marker auto-cleared (rc=$rc2)"
    elif [ "$rc2" = "9" ]; then
        fail "(g-new) exit-9 fired for non-exit-6 terminal (over-blocking): rc=$rc2"
    else
        fail "(g-new) marker not deleted after auto-clear path (rc=$rc2)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

run_case_g_new2() {
    local plans fake repo term rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    # Arm via a real exit-7 run (arm_terminal_guard fires on 2|3|6|7), then change fingerprint.
    run_loop "$plans" "$fake" "$repo" 7 >/dev/null
    if [ ! -f "$term" ]; then
        fail "(g-new2-arm) exit-7 did not write terminal marker — setup failed"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "echo changed" >> "$repo/tests/foo.sh"
    git -C "$repo" add tests/foo.sh 2>/dev/null
    rc2=$(run_loop "$plans" "$fake" "$repo" 1)
    if [ "$rc2" != "9" ] && no_marker "$plans" sid1361; then
        pass "(g-new2) exit-7 arm + fingerprint change → NOT exit 9, marker auto-cleared (rc=$rc2)"
    elif [ "$rc2" = "9" ]; then
        fail "(g-new2) exit-9 fired for exit-7 terminal (over-blocking): rc=$rc2"
    else
        fail "(g-new2) marker not deleted after auto-clear path (rc=$rc2)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (g) #2357: exit 6 + fingerprint change → exit 9 =====================
# The #1361 auto-clear (case c) is a bypass when the terminal was exit 6: an
# attacker touches tests to flip the fingerprint, the marker auto-clears, and the
# unresolved HIGH gets a fresh 2+1 budget. The exit-9 gate must fire before the
# rm when PREV_RC==6 and no accept marker exists — and must keep the marker.
run_case_g() {
    local plans fake repo term rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    # Full attack sequence (mirrors case f): arm via a real exit-6 run so the marker
    # carries the live review-scope fingerprint, then re-edit + re-stage to flip it,
    # then re-invoke. The exit-9 gate must fire before the auto-clear rm.
    run_loop "$plans" "$fake" "$repo" 6 >/dev/null   # arm exit-6 marker (real fingerprint)
    if [ ! -f "$term" ]; then
        fail "(g-arm) exit 6 did not write terminal marker — setup failed, cannot continue"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    echo "echo changed" >> "$repo/tests/foo.sh"
    git -C "$repo" add tests/foo.sh 2>/dev/null
    rc2=$(run_loop "$plans" "$fake" "$repo" 1)
    if [ "$rc2" = "9" ] && [ -f "$term" ]; then
        pass "(g) exit-6 arm → tests re-edited → exit 9, marker retained (bypass blocked)"
    else
        fail "(g) RED-EXPECTED (exit-9 gate absent): rc=$rc2 (want 9), marker present=$([ -f "$term" ] && echo yes || echo no)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (h) #2357: exit 6 + accept marker → NOT exit 9 (sanctioned) ========
# CPR-ORTH counterpart of (g): with the accept marker present the exit-9 gate must
# stand down and let the re-review through (STUB_RC=1 → expect 1, never 9 or 8).
run_case_h() {
    local plans fake repo term accept rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    seed_control "$plans" sid1361 test-review-terminal.txt 6 deadbeefcafebabe0000   # pre-seed exit-6 marker
    seed_control "$plans" sid1361 "$ACCEPT_NAME" accepted                           # sanction the residual HIGH
    rc2=$(run_loop "$plans" "$fake" "$repo" 1)
    if [ "$rc2" = "1" ] && no_marker "$plans" sid1361; then
        pass "(h) exit-6 marker + accept file → rc=$rc2, marker deleted (guard stood down, accept path cleared marker)"
    elif [ "$rc2" = "1" ]; then
        fail "(h) rc=1 but terminal marker was not deleted on accept path"
    else
        fail "(h) accept file must let review through with rc=1 (got rc=$rc2, over-blocking or stub bypassed)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (i) #2357: WARNINGS_ACCEPTED clears marker → NOT exit 9 ============
# Interaction with the existing clearReviewTestsTerminalMarker handler: accepting
# via the sentinel deletes the whole marker, so the exit-9 gate never sees it. The
# two accept mechanisms must not collide into a spurious exit 9.
run_case_i() {
    local plans fake repo term rc2
    plans=$(mk_root); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$(term_of "$plans" sid1361)"
    seed_control "$plans" sid1361 test-review-terminal.txt 6 deadbeefcafebabe0000   # pre-seed exit-6 marker
    if [ ! -f "$term" ]; then
        fail "(i-seed) terminal marker could not be seeded at ${term#"$plans"/}"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    run_accept_handler "$plans" sid1361
    if ! no_marker "$plans" sid1361; then
        fail "(i) WARNINGS_ACCEPTED should have cleared the exit-6 marker but it survived"
        rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
        return
    fi
    rc2=$(run_loop "$plans" "$fake" "$repo" 1)
    if [ "$rc2" != "9" ]; then
        pass "(i) WARNINGS_ACCEPTED deletes the marker → next run is NOT exit 9 (rc=$rc2)"
    else
        fail "(i) marker cleared yet re-run still exit 9 — gate fired on a deleted marker: rc=$rc2"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

case_begin "terminal-arm-and-reinvoke" "skills/review-tests/scripts/run-codex-review-loop.sh"
run_case_a
run_case_b
run_case_c
run_case_g_new
run_case_g_new2
case_end

case_begin "warnings-accepted-clears-marker" "hooks/workflow-mark/review-tests-handler.js"
run_case_d
case_end

case_begin "fail-closed-and-exit6-gate" "skills/review-tests/scripts/run-codex-review-loop.sh"
run_case_e
run_case_f
run_case_g
run_case_h
case_end

case_begin "warnings-accepted-then-rerun" "hooks/workflow-mark/review-tests-handler.js"
run_case_i
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
