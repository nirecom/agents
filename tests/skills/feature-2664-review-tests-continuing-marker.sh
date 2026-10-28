#!/usr/bin/env bash
# tests/skills/feature-2664-review-tests-continuing-marker.sh
# Tests: skills/review-tests/scripts/run-codex-review-loop.sh, bin/lib/codex-review-loop/review-wrapper-control.sh
# Tags: review-tests, review-loop, continuing-marker, fingerprint, warnings-accepted, recovery, scope:issue-specific, pwsh-not-required, TL2
#
# #2664: a review that ends on exit 1 or 5 (round continuing) leaves evidence for the
# WARNINGS_ACCEPTED recovery: <sid>.control/test-review-continuing.txt, line 1 = rc,
# line 2 = review-scope fingerprint. Other exits never write it, the next wrapper start
# removes a stale one, and the terminal guard (2|3|6|7) keeps its own behavior.
# TL3 gap: a real /review-tests run with live codex ending on exit 1 — checked at the
# WORKFLOW_USER_VERIFIED preflight.

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=tests/lib/script-checkout-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/script-checkout-fixture.sh"
SCRIPT_REL="skills/review-tests/scripts/run-codex-review-loop.sh"
RWT="$SCRIPT_CHECKOUT_ROOT/bin/run-with-timeout.sh"
EVIDENCE_N="$(np "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/review-tests-evidence.js")"
SID="sid2664"

PASS=0; FAIL=0; SKIP=0

unset CLAUDE_CODE_SESSION_ID
ISO_ROOT="$(make_tmp)"
readonly ISO_ROOT
trap 'rm -rf "$ISO_ROOT" 2>/dev/null || true' EXIT
mkdir -p "$ISO_ROOT/home"
export HOME="$ISO_ROOT/home" USERPROFILE="$ISO_ROOT/home"
harness_isolate "$ISO_ROOT"
cd "$ISO_ROOT" || exit 1

if ! command -v git >/dev/null 2>&1; then
    skip "git unavailable — cannot exercise the fingerprint line"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 0
fi

# Fake checkout: the real wrapper + bin/lib + evidence.js, stubbed bin entrypoints.
build_fake_config() {
    local fake; fake=$(make_tmp)
    script_checkout_fixture_copy "$fake" bin/lib skills/review-tests/scripts >&2 || return 1
    mkdir -p "$fake/bin" "$fake/hooks/workflow-gate"
    printf '#!/usr/bin/env bash\nexit "${STUB_RC:-0}"\n' > "$fake/bin/run-codex-review-loop"
    printf '#!/usr/bin/env bash\necho NOSTATE\n' > "$fake/bin/resolve-worktree-path"
    printf '#!/usr/bin/env bash\nprintf %s\n' "$SID" > "$fake/bin/resolve-session-id"
    printf '#!/usr/bin/env bash\necho /dev/null\nexit 0\n' > "$fake/bin/resolve-accepted-tradeoffs-file"
    chmod +x "$fake/bin/run-codex-review-loop" "$fake/bin/resolve-worktree-path" \
        "$fake/bin/resolve-session-id" "$fake/bin/resolve-accepted-tradeoffs-file"
    cp "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-gate/review-tests-evidence.js" "$fake/hooks/workflow-gate/review-tests-evidence.js"
    printf '%s' "$fake"
}

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

mk_root() {
    local r; r="$(make_tmp)"
    mkdir -p "$r/wf" "$r/plans" "$r/home"
    printf '%s' "$r"
}
pinned() {
    local r="$1"; shift
    env -u CLAUDE_CODE_SESSION_ID \
        WORKFLOW_STATE_DIR="$(np "$r/wf")" WORKFLOW_PLANS_DIR="$(np "$r/plans")" \
        HOME="$r/home" USERPROFILE="$r/home" "$@"
}

cont_of() { printf '%s' "$1/wf/$SID.control/test-review-continuing.txt"; }
term_of() { printf '%s' "$1/wf/$SID.control/test-review-terminal.txt"; }
line_of() { sed -n "${2}p" "$1" 2>/dev/null; }

# expected_fp <repo> — the review-scope fingerprint through the same SSOT the wrapper uses.
expected_fp() {
    bash "$RWT" 30 node -e 'const r=require(process.argv[1]).computeReviewScopeFingerprint(process.argv[2]); process.stdout.write(r.ok ? String(r.fingerprint||"") : "")' "$EVIDENCE_N" "$(np "$1")" 2>/dev/null
}

# run_loop <root> <fake> <repo> <stub_rc> → prints the wrapper's exit code
run_loop() {
    local root="$1" fake="$2" repo="$3" rc="$4" ec
    ( cd "$repo" && pinned "$root" AGENTS_MAIN_ROOT="$fake" SESSION_ID="$SID" \
        PLANS_DIR="$(np "$root/plans")" CLAUDE_CODE_SESSION_ID="$SID" \
        EXTENSIONS_USED=0 STUB_RC="$rc" "$RWT" 40 bash "$fake/$SCRIPT_REL" >/dev/null 2>&1 )
    ec=$?
    printf '%s' "$ec"
}

# --- (u) rwc_arm_continuing: the library function the wrapper calls ---
run_case_unit() {
    local root out
    root=$(mk_root)
    mkdir -p "$root/wf/$SID.control"
    out="$(pinned "$root" SESSION_ID="$SID" bash -c '
        . "$1" || exit 90
        rwc_resolve test-review review-tests
        declare -F rwc_arm_continuing >/dev/null || { echo NO-FUNCTION; exit 0; }
        rwc_arm_continuing 1 fpunit
        echo "DIR=$CONTROL_DIR"
    ' _ "$SCRIPT_CHECKOUT_ROOT/bin/lib/codex-review-loop/review-wrapper-control.sh" 2>&1)"
    if [ "$out" = "NO-FUNCTION" ]; then
        fail "(u) RED-EXPECTED: review-wrapper-control.sh defines no rwc_arm_continuing"
    elif [ "$(line_of "$(cont_of "$root")" 1)" = "1" ] && [ "$(line_of "$(cont_of "$root")" 2)" = "fpunit" ]; then
        pass "(u) rwc_arm_continuing 1 fpunit writes rc / fingerprint into CONTROL_DIR/test-review-continuing.txt"
    else
        fail "(u) rwc_arm_continuing did not publish rc+fingerprint at ${SID}.control/test-review-continuing.txt (out=$out)"
    fi
    if [ ! -f "$(term_of "$root")" ]; then
        pass "(u2) rwc_arm_continuing does not touch the terminal marker"
    else
        fail "(u2) rwc_arm_continuing wrote the terminal marker"
    fi
    rm -rf "$root" 2>/dev/null || true
}

# --- (a) rc 1 / 5 write the continuing marker, line 2 = current fingerprint ---
run_case_continuing() {
    local rc="$1" root fake repo fp cont
    root=$(mk_root); fake=$(build_fake_config); repo=$(build_repo)
    fp="$(expected_fp "$repo")"
    cont="$(cont_of "$root")"
    run_loop "$root" "$fake" "$repo" "$rc" >/dev/null
    if [ -f "$cont" ] && [ "$(line_of "$cont" 1)" = "$rc" ]; then
        pass "(a$rc) exit $rc writes test-review-continuing.txt with line 1 = $rc"
    else
        fail "(a$rc) RED-EXPECTED: exit $rc left no continuing marker with line 1 = $rc"
    fi
    if [ -n "$fp" ] && [ "$(line_of "$cont" 2)" = "$fp" ]; then
        pass "(a$rc-fp) line 2 is the current review-scope fingerprint"
    else
        fail "(a$rc-fp) RED-EXPECTED: line 2 '$(line_of "$cont" 2)' is not the current fingerprint '$fp'"
    fi
    if [ ! -f "$(term_of "$root")" ]; then
        pass "(a$rc-term) exit $rc still arms no terminal guard (a continuing round is not terminal)"
    else
        fail "(a$rc-term) exit $rc armed the terminal guard"
    fi
    rm -rf "$root" "$fake" "$repo" 2>/dev/null || true
}

# --- (b) other exits never write the continuing marker ---
run_case_not_continuing() {
    local rc="$1" root fake repo
    root=$(mk_root); fake=$(build_fake_config); repo=$(build_repo)
    run_loop "$root" "$fake" "$repo" "$rc" >/dev/null
    if [ ! -f "$(cont_of "$root")" ]; then
        pass "(b$rc) exit $rc writes no continuing marker"
    else
        fail "(b$rc) exit $rc wrote a continuing marker"
    fi
    rm -rf "$root" "$fake" "$repo" 2>/dev/null || true
}

# --- (c) terminal guard unchanged: exit 2 still arms the terminal marker ---
run_case_terminal_kept() {
    local root fake repo
    root=$(mk_root); fake=$(build_fake_config); repo=$(build_repo)
    run_loop "$root" "$fake" "$repo" 2 >/dev/null
    if [ -f "$(term_of "$root")" ] && [ "$(line_of "$(term_of "$root")" 1)" = "2" ]; then
        pass "(c) exit 2 still writes the terminal marker"
    else
        fail "(c) exit 2 no longer writes the terminal marker"
    fi
    rm -rf "$root" "$fake" "$repo" 2>/dev/null || true
}

# --- (d) the next start removes a stale continuing marker ---
run_case_stale_cleared() {
    local root fake repo cont
    root=$(mk_root); fake=$(build_fake_config); repo=$(build_repo)
    cont="$(cont_of "$root")"
    mkdir -p "${cont%/*}"
    printf '1\nstalefp\n' > "$cont"
    run_loop "$root" "$fake" "$repo" 0 >/dev/null
    if [ ! -f "$cont" ]; then
        pass "(d) a new run (exit 0) removes the previous run's continuing marker"
    else
        fail "(d) RED-EXPECTED: the stale continuing marker survived the next wrapper start"
    fi
    rm -rf "$root" "$fake" "$repo" 2>/dev/null || true
}

# --- (e) exit 1 → next round exit 1 is not blocked and replaces the marker ---
run_case_rerun_not_blocked() {
    local root fake repo rc2
    root=$(mk_root); fake=$(build_fake_config); repo=$(build_repo)
    run_loop "$root" "$fake" "$repo" 1 >/dev/null
    rc2=$(run_loop "$root" "$fake" "$repo" 1)
    if [ "$rc2" = "1" ]; then
        pass "(e) re-run after exit 1 is not blocked by the continuing marker (rc=$rc2)"
    else
        fail "(e) re-run after exit 1 gave rc=$rc2, want 1 (continuing marker must not guard)"
    fi
    rm -rf "$root" "$fake" "$repo" 2>/dev/null || true
}

case_begin "rwc-arm-continuing-unit" "bin/lib/codex-review-loop/review-wrapper-control.sh"
run_case_unit
case_end

case_begin "continuing-marker-written-for-rc-1-5" "skills/review-tests/scripts/run-codex-review-loop.sh"
run_case_continuing 1
run_case_continuing 5
case_end

case_begin "continuing-marker-absent-for-other-rc" "skills/review-tests/scripts/run-codex-review-loop.sh"
run_case_not_continuing 0
run_case_not_continuing 2
run_case_not_continuing 4
run_case_not_continuing 6
run_case_terminal_kept
case_end

case_begin "continuing-marker-lifecycle" "skills/review-tests/scripts/run-codex-review-loop.sh"
run_case_stale_cleared
run_case_rerun_not_blocked
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
