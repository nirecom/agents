#!/usr/bin/env bash
# tests/fix-1361-review-loop-terminal-guard.sh
# Tests: skills/review-tests/scripts/run-codex-review-loop.sh, hooks/lib/workflow-state/state-io.js, hooks/workflow-mark/review-tests-handler.js
# Tags: review-tests, review-loop, terminal-guard, fingerprint, staged-tests, scope:issue-specific, pwsh-not-required, TL2
#
# #1361: after run-codex-review-loop.sh returns a terminal exit code (1/2), a caller
# that re-invokes the script (tests UNCHANGED) must be blocked (exit 6) instead of
# silently restarting ROUND=1. The real reset seam is the staged-tests fingerprint
# (same computeStagedTestsToken SSOT as the gate's stale-review check), NOT the dead
# invalidateReviewTests() function. A fingerprint MISMATCH (tests re-edited) auto-clears
# the terminal marker; a fingerprint COMPUTATION FAILURE keeps the marker (fail-CLOSED).
#
# TL3 gap (what this test does NOT catch):
# - The script firing under a real /review-tests Skill invocation with the real
#   bin/run-codex-review-loop (codex subprocess) and a real session-bound worktree.
# - Real resolve-worktree-path session-state resolution (here stubbed to NOSTATE).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
SCRIPT="$AGENTS_DIR/skills/review-tests/scripts/run-codex-review-loop.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
make_tmp() { mktemp -d 2>/dev/null || mktemp -d -t '1361'; }

if ! command -v git >/dev/null 2>&1; then
    skip "git unavailable — cannot exercise fingerprint seam"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi

# NOTE (detail plan): invalidateReviewTests() is DEAD (no runtime callers) — it is
# intentionally NOT the reset seam. The real anchor is the staged-tests fingerprint.

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
    chmod +x "$fake/bin/run-codex-review-loop" "$fake/bin/resolve-worktree-path"
    if [ "$with_evidence" = "yes" ]; then
        cp "$AGENTS_DIR/hooks/workflow-gate/review-tests-evidence.js" "$fake/hooks/workflow-gate/review-tests-evidence.js"
    fi
    printf '%s' "$fake"
}

# --- Build a git repo with a staged tests/ file ---
build_repo() {
    local repo; repo=$(make_tmp)
    git -C "$repo" init -q 2>/dev/null
    git -C "$repo" config user.email t@example.com
    git -C "$repo" config user.name t
    mkdir -p "$repo/tests"
    echo "echo hi" > "$repo/tests/foo.sh"
    git -C "$repo" add tests/foo.sh 2>/dev/null
    printf '%s' "$repo"
}

TERMINAL_SUFFIX="-test-review-terminal.txt"

# run_loop <plans_dir> <fake_config> <repo> <stub_rc> → prints exit code
run_loop() {
    local plans="$1" fake="$2" repo="$3" rc="$4" ec
    ( cd "$repo" && AGENTS_CONFIG_DIR="$fake" SESSION_ID="sid1361" PLANS_DIR="$plans" \
        EXTENSIONS_USED=0 STUB_RC="$rc" "$RWT" 40 bash "$SCRIPT" >/dev/null 2>&1 )
    ec=$?
    printf '%s' "$ec"
}

# ===================== (a) terminal exit → marker + re-invoke blocked =====================
run_case_a() {
    local plans fake repo term rc1 rc2
    plans=$(make_tmp); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$plans/sid1361$TERMINAL_SUFFIX"
    rc1=$(run_loop "$plans" "$fake" "$repo" 2)   # terminal ESCALATE
    if [ -f "$term" ]; then
        pass "(a1) terminal exit 2 writes ${term##*/} (rc+fingerprint marker)"
    else
        fail "(a1) RED-EXPECTED (guard absent): terminal marker not written after exit 2"
    fi
    # re-invoke with tests UNCHANGED → must be blocked with exit 6
    rc2=$(run_loop "$plans" "$fake" "$repo" 2)
    if [ "$rc2" = "6" ]; then
        pass "(a2) re-invoke with unchanged tests → exit 6 (REINVOKE_AFTER_TERMINAL)"
    else
        fail "(a2) RED-EXPECTED (guard absent): re-invoke after terminal exit gave rc=$rc2, want 6"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (b) success terminal (exit 0) writes NO marker ======================
run_case_b() {
    local plans fake repo term
    plans=$(make_tmp); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$plans/sid1361$TERMINAL_SUFFIX"
    run_loop "$plans" "$fake" "$repo" 0 >/dev/null
    if [ ! -f "$term" ]; then
        pass "(b) exit 0 (COMPLETE) does NOT write terminal marker — clean re-review not blocked"
    else
        fail "(b) exit 0 must not create terminal marker (would wrongly block a fresh review)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (c) real restart: fingerprint change auto-clears (sanctioned pass) ==
run_case_c() {
    local plans fake repo term rc2
    plans=$(make_tmp); fake=$(build_fake_config yes); repo=$(build_repo)
    term="$plans/sid1361$TERMINAL_SUFFIX"
    run_loop "$plans" "$fake" "$repo" 2 >/dev/null   # create marker
    # legitimately re-edit + re-stage tests → fingerprint MISMATCH
    echo "echo changed" >> "$repo/tests/foo.sh"
    git -C "$repo" add tests/foo.sh 2>/dev/null
    rc2=$(run_loop "$plans" "$fake" "$repo" 1)
    # CPR-5 sanctioned-pass counterpart of (a2): a genuine restart must NOT be blocked (exit != 6)
    if [ "$rc2" != "6" ]; then
        pass "(c) tests re-edited (fingerprint mismatch) → NOT blocked (rc=$rc2 != 6)"
    else
        fail "(c) legitimate restart wrongly blocked with exit 6 (over-blocking)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

# ===================== (d) WARNINGS_ACCEPTED handler clears terminal marker ===============
run_case_d() {
    local plans term out
    plans=$(make_tmp)
    local plans_node
    if command -v cygpath >/dev/null 2>&1; then plans_node="$(cygpath -m "$plans")"; else plans_node="$plans"; fi
    term="$plans/sidD$TERMINAL_SUFFIX"
    printf '2\nabc123\n' > "$term"   # pre-existing terminal marker
    out=$(WORKFLOW_PLANS_DIR="$plans_node" CLAUDE_WORKFLOW_DIR="$plans_node" "$RWT" 20 node -e "
const handler = require('$_AGENTS_DIR_NODE/hooks/workflow-mark/review-tests-handler.js');
const msgs = [];
handler.handle({
  cmd: 'echo \"<<WORKFLOW_REVIEW_TESTS_WARNINGS_ACCEPTED: accept coverage gap for now>>\"',
  sessionId: 'sidD',
  pushMessage: (m) => msgs.push(m),
  signalFatal: () => {},
  repoCwd: process.cwd(),
});
process.stdout.write('OK');
" 2>/dev/null) || true
    if [ ! -f "$term" ]; then
        pass "(d) WARNINGS_ACCEPTED handler clears the terminal marker (real call site)"
    else
        fail "(d) RED-EXPECTED (clearReviewTestsTerminalMarker not wired): marker survived WARNINGS_ACCEPTED"
    fi
    rm -rf "$plans" 2>/dev/null || true
}

# ===================== (e) fingerprint COMPUTATION FAILURE keeps marker + exit 6 ==========
run_case_e() {
    local plans fake repo term rc2
    plans=$(make_tmp)
    # fake config WITHOUT evidence.js → fingerprint node -e require fails → compute failure
    fake=$(build_fake_config no)
    repo=$(build_repo)
    term="$plans/sid1361$TERMINAL_SUFFIX"
    # pre-seed a terminal marker as if a prior terminal exit happened
    printf '2\ndeadbeefcafebabe\n' > "$term"
    # re-invoke with STUB_RC=2 (so a naive pass-through would be 2, not 6)
    rc2=$(run_loop "$plans" "$fake" "$repo" 2)
    if [ "$rc2" = "6" ] && [ -f "$term" ]; then
        pass "(e) fingerprint compute failure → exit 6 + marker retained (fail-CLOSED)"
    else
        fail "(e) RED-EXPECTED (fail-CLOSED guard absent): rc=$rc2 (want 6), marker present=$([ -f "$term" ] && echo yes || echo no)"
    fi
    rm -rf "$plans" "$fake" "$repo" 2>/dev/null || true
}

run_case_a
run_case_b
run_case_c
run_case_d
run_case_e

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
