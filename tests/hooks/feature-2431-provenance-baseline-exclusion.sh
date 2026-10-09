#!/usr/bin/env bash
# tests/hooks/feature-2431-provenance-baseline-exclusion.sh
# Tests: hooks/workflow-run-tests/provenance-identity.js, hooks/lib/baseline-checkout-marker.js
# Tags: TL1, TL2, scope:issue-specific
# TDD stage-7: baseline-checkout-marker.js absent until impl; provenance-identity.js
# must be updated to call isBaselineCheckout() before marked-worktree tests pass.
# TL3 gap: real worktree add/remove; no real claude -p session.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

command -v node >/dev/null 2>&1 || { echo "SKIP: node not found"; exit 77; }
command -v git  >/dev/null 2>&1 || { echo "SKIP: git not found";  exit 77; }

TMPD="$(make_tmp)"
trap 'rm -rf "$TMPD"' EXIT
harness_isolate "$TMPD"
unset CLAUDE_CODE_SESSION_ID 2>/dev/null || true

AGENTS_WIN="$(np "$SCRIPT_CHECKOUT_ROOT")"
MARKER_JS="$SCRIPT_CHECKOUT_ROOT/hooks/lib/baseline-checkout-marker.js"
PROVENANCE_JS="$AGENTS_WIN/hooks/workflow-run-tests/provenance-identity.js"

# Create a real git repo with two commits so we can add a worktree.
MAIN_REPO="$TMPD/main"
harness_git_init "$MAIN_REPO"
git -C "$MAIN_REPO" config user.email test@example.com
git -C "$MAIN_REPO" config user.name "Test"
printf 'init\n' > "$MAIN_REPO/file.txt"
git -C "$MAIN_REPO" add file.txt
git -C "$MAIN_REPO" commit -q -m "init"

LINKED_WT="$TMPD/linked-wt"
git -C "$MAIN_REPO" worktree add --detach "$LINKED_WT" HEAD 2>/dev/null
mkdir -p "$LINKED_WT/tests"

# Also create a separate repo for the garbage-.git tests.
GARBAGE_REPO="$TMPD/garbage"
mkdir -p "$GARBAGE_REPO"
printf 'gitdir: /nonexistent/path/that/does/not/exist\n' > "$GARBAGE_REPO/.git"

MAIN_WIN="$(np "$MAIN_REPO")"
LINKED_WIN="$(np "$LINKED_WT")"
GARBAGE_WIN="$(np "$GARBAGE_REPO")"

# Helper: call isBaselineCheckout(root) via node, returns "true"/"false"/"ERR:..."
is_baseline_checkout() {
    run_with_timeout 30 node -e '
try {
  var m=require(process.argv[1]);
  if(typeof m.isBaselineCheckout!=="function"){
    process.stdout.write("ERR:isBaselineCheckout-not-exported");process.exit(0);
  }
  process.stdout.write(String(m.isBaselineCheckout(process.argv[2])));
}
catch(e){process.stdout.write("ERR:"+e.message.split("\n")[0])}
' "$(np "$MARKER_JS")" "$1" 2>/dev/null || echo "ERR:crashed"
}

# Helper: resolve admin dir (gitdir) from a linked worktree's .git file.
get_gitdir() {
    run_with_timeout 10 node -e '
var path=require("path"),fs=require("fs");
try {
  var gf=path.join(process.argv[1],".git");
  var st=fs.statSync(gf);
  if(!st.isFile()){process.stdout.write("");process.exit(0)}
  var m=/^\s*gitdir:\s*(.+?)\s*$/m.exec(fs.readFileSync(gf,"utf8"));
  if(!m){process.stdout.write("");process.exit(0)}
  process.stdout.write(path.resolve(process.argv[1],m[1]));
}
catch(e){process.stdout.write("")}
' "$1" 2>/dev/null || echo ""
}

# ============================================================================
case_begin "baseline-checkout-marker" "hooks/lib/baseline-checkout-marker.js"
# ============================================================================

echo ""
echo "=== baseline-checkout-marker ==="

# B0: module must export isBaselineCheckout; guard against missing module.
_b0=$(run_with_timeout 30 node -e '
try {
  var m=require(process.argv[1]);
  process.stdout.write(typeof m.isBaselineCheckout==="function"?"ok":"ERR:not-function");
}
catch(e){process.stdout.write("ERR:"+e.message.split("\n")[0])}
' "$(np "$MARKER_JS")" 2>/dev/null || echo "ERR:crashed")
case "$_b0" in
    ok) pass "B0/module-exports-isBaselineCheckout" ;;
    *)  fail "B0/module-exports-isBaselineCheckout" "$_b0" ;;
esac

# Verify linked worktree was created (has .git FILE, not directory).
if [ -f "$LINKED_WT/.git" ]; then
    pass "B-setup/linked-wt-has-git-file"
else
    fail "B-setup/linked-wt-has-git-file" "git worktree add may have failed"
fi

LINKED_GITDIR="$(get_gitdir "$LINKED_WIN")"

# B1: isBaselineCheckout returns false for unmarked linked worktree.
_b1=$(is_baseline_checkout "$LINKED_WIN")
case "$_b1" in
    false) pass "B1/unmarked-linked-worktree-is-false" ;;
    ERR:*) fail "B1/unmarked-linked-worktree-is-false" "$_b1" ;;
    *)     fail "B1/unmarked-linked-worktree-is-false" "got $_b1" ;;
esac

# B2: isBaselineCheckout returns false for main worktree (.git is a directory).
_b2=$(is_baseline_checkout "$MAIN_WIN")
case "$_b2" in
    false) pass "B2/main-worktree-git-dir-is-false" ;;
    ERR:*) fail "B2/main-worktree-git-dir-is-false" "$_b2" ;;
    *)     fail "B2/main-worktree-git-dir-is-false" "got $_b2" ;;
esac

# B3: isBaselineCheckout returns false (not throws) for garbage .git file.
_b3=$(is_baseline_checkout "$GARBAGE_WIN")
case "$_b3" in
    false) pass "B3/garbage-git-file-is-false-no-throw" ;;
    ERR:*) fail "B3/garbage-git-file-is-false-no-throw" "$_b3" ;;
    *)     fail "B3/garbage-git-file-is-false-no-throw" "got $_b3" ;;
esac

# B4: CLI `node baseline-checkout-marker.js mark <root>` writes the marker.
run_with_timeout 30 node "$(np "$MARKER_JS")" mark "$LINKED_WIN" 2>/dev/null || true
if [ -n "$LINKED_GITDIR" ] && [ -f "$LINKED_GITDIR/agents-baseline-checkout" ]; then
    pass "B4/mark-cli-writes-marker-file"
else
    fail "B4/mark-cli-writes-marker-file" "marker not found in $LINKED_GITDIR"
fi

# B5: isBaselineCheckout returns true for marked linked worktree.
_b5=$(is_baseline_checkout "$LINKED_WIN")
case "$_b5" in
    true)  pass "B5/marked-linked-worktree-is-true" ;;
    ERR:*) fail "B5/marked-linked-worktree-is-true" "$_b5" ;;
    *)     fail "B5/marked-linked-worktree-is-true" "got $_b5" ;;
esac

# B6: marker disappears after git worktree remove.
git -C "$MAIN_REPO" worktree remove "$LINKED_WT" 2>/dev/null || true
if [ -n "$LINKED_GITDIR" ] && [ ! -f "$LINKED_GITDIR/agents-baseline-checkout" ]; then
    pass "B6/marker-gone-after-worktree-remove"
elif [ -n "$LINKED_GITDIR" ] && [ -f "$LINKED_GITDIR/agents-baseline-checkout" ]; then
    fail "B6/marker-gone-after-worktree-remove" "marker still present after worktree remove"
else
    # LINKED_GITDIR empty means get_gitdir failed — skip, not a marker issue
    skip "B6/marker-gone-after-worktree-remove"
fi

case_end

# ============================================================================
case_begin "provenance-baseline-exclusion" "hooks/workflow-run-tests/provenance-identity.js"
# ============================================================================

echo ""
echo "=== provenance-baseline-exclusion ==="

# P2 fixture: a throwaway repo carrying a copy of the provenance module and its
# deps, checked out as a linked worktree. The marker is only ever written into
# this fixture's gitdir (under $TMPD, removed by the EXIT trap) — never into the
# developer's real agents worktree.
PROV_MAIN="$TMPD/prov-main"
PROV_WT="$TMPD/prov-wt"
harness_git_init "$PROV_MAIN"
git -C "$PROV_MAIN" config user.email test@example.com
git -C "$PROV_MAIN" config user.name "Test"
mkdir -p "$PROV_MAIN/hooks/lib" "$PROV_MAIN/hooks/workflow-run-tests" "$PROV_MAIN/tests"
cp "$SCRIPT_CHECKOUT_ROOT/hooks/workflow-run-tests/provenance-identity.js" "$PROV_MAIN/hooks/workflow-run-tests/"
cp "$SCRIPT_CHECKOUT_ROOT/hooks/lib/baseline-checkout-marker.js" "$SCRIPT_CHECKOUT_ROOT/hooks/lib/checkout-identity.js" "$SCRIPT_CHECKOUT_ROOT/hooks/lib/path-normalize.js" "$PROV_MAIN/hooks/lib/"
printf '#!/usr/bin/env bash\n' > "$PROV_MAIN/tests/run-all.sh"
git -C "$PROV_MAIN" add -A
git -C "$PROV_MAIN" commit -q -m "prov fixture"
git -C "$PROV_MAIN" worktree add --detach "$PROV_WT" HEAD >/dev/null 2>&1
cleanup_prov_fixture() {
    git -C "$PROV_MAIN" worktree remove --force "$PROV_WT" >/dev/null 2>&1 || true
    rm -rf "$TMPD"
}
trap cleanup_prov_fixture EXIT
PROV_WT_WIN="$(np "$PROV_WT")"
PROV_WT_JS="$PROV_WT_WIN/hooks/workflow-run-tests/provenance-identity.js"

verify_emitter() {
    # verify_emitter <emitter> <claimed-path> <cwd> [module] → run-all|worker-dispatch|(none)|ERR:...
    run_with_timeout 30 node -e '
try {
  var m=require(process.argv[1]);
  if(typeof m.verifyEmitterIdentity!=="function"){
    process.stdout.write("ERR:not-exported");process.exit(0);
  }
  process.stdout.write(m.verifyEmitterIdentity(process.argv[2],process.argv[3],process.argv[4])?
    process.argv[2] : "(none)");
}
catch(e){process.stdout.write("ERR:"+e.message.split("\n")[0])}
' "${4:-$PROVENANCE_JS}" "$1" "$2" "$3" 2>/dev/null || echo "ERR:crashed"
}

# P0: module loads and exports verifyEmitterIdentity (smoke test).
_p0=$(run_with_timeout 30 node -e '
try {
  var m=require(process.argv[1]);
  process.stdout.write(typeof m.verifyEmitterIdentity==="function"?"ok":"ERR:not-exported");
}
catch(e){process.stdout.write("ERR:"+e.message.split("\n")[0])}
' "$PROVENANCE_JS" 2>/dev/null || echo "ERR:crashed")
case "$_p0" in
    ok) pass "P0/module-loads-ok" ;;
    *)  fail "P0/module-loads-ok" "$_p0" ;;
esac

# P1 control: current agents worktree (unmarked) run-all.sh IS a trusted emitter.
_p1=$(verify_emitter "run-all" "$AGENTS_WIN/tests/run-all.sh" "$AGENTS_WIN")
case "$_p1" in
    run-all) pass "P1/control-agents-run-all-trusted" ;;
    "(none)") fail "P1/control-agents-run-all-trusted" "returned (none) — control failed" ;;
    ERR:*)   fail "P1/control-agents-run-all-trusted" "$_p1" ;;
    *)       fail "P1/control-agents-run-all-trusted" "got $_p1" ;;
esac

# P2 control: the unmarked fixture worktree's run-all.sh IS trusted by its own module copy.
_p2c=$(verify_emitter "run-all" "$PROV_WT_WIN/tests/run-all.sh" "$PROV_WT_WIN" "$PROV_WT_JS")
case "$_p2c" in
    run-all) pass "P2-control/unmarked-fixture-run-all-trusted" ;;
    *)       fail "P2-control/unmarked-fixture-run-all-trusted" "got $_p2c" ;;
esac

# P2: once marked, the fixture worktree's run-all.sh must NOT be trusted.
PROV_GITDIR="$(get_gitdir "$PROV_WT_WIN")"
run_with_timeout 30 node "$(np "$MARKER_JS")" mark "$PROV_WT_WIN" 2>/dev/null || true
if [ -n "$PROV_GITDIR" ] && [ -f "$PROV_GITDIR/agents-baseline-checkout" ]; then
    _p2=$(verify_emitter "run-all" "$PROV_WT_WIN/tests/run-all.sh" "$PROV_WT_WIN" "$PROV_WT_JS")
    case "$_p2" in
        "(none)") pass "P2/marked-worktree-run-all-not-trusted" ;;
        run-all)  fail "P2/marked-worktree-run-all-not-trusted" \
                      "got run-all; isBaselineCheckout not called in provenance-identity.js" ;;
        ERR:*)    fail "P2/marked-worktree-run-all-not-trusted" "$_p2" ;;
        *)        fail "P2/marked-worktree-run-all-not-trusted" "got $_p2" ;;
    esac
else
    fail "P2/marked-worktree-run-all-not-trusted" "fixture marker not written in '$PROV_GITDIR'"
fi

# P2-iso: the real agents worktree must never carry the marker after this test.
AGENTS_REAL_GITDIR="$(get_gitdir "$AGENTS_WIN")"
if [ -n "$AGENTS_REAL_GITDIR" ] && [ -f "$AGENTS_REAL_GITDIR/agents-baseline-checkout" ]; then
    fail "P2-iso/real-worktree-unmarked" "marker present in $AGENTS_REAL_GITDIR"
else
    pass "P2-iso/real-worktree-unmarked"
fi

# P3: marker read failure must not cause verifyEmitterIdentity to throw.
# Simulate read failure by pointing at a directory with a garbage .git file
# (isBaselineCheckout must return false, not throw).
_p3=$(verify_emitter "run-all" "$AGENTS_WIN/tests/run-all.sh" "$GARBAGE_WIN")
case "$_p3" in
    ERR:*) fail "P3/marker-read-failure-no-throw" "got exception: $_p3" ;;
    *)     pass "P3/marker-read-failure-no-throw" ;;
esac

case_end

# ============================================================================
case_begin "provenance-baseline-exclusion-sibling-module" "hooks/workflow-run-tests/provenance-identity.js"
# ============================================================================

# P2x: the module lives in the MAIN checkout and the emitter in a sibling linked worktree, so
# the only root that can vouch is cwdRoot. A fresh worktree, because P2 already marked PROV_WT.
PROV_WT2="$TMPD/prov-wt2"
git -C "$PROV_MAIN" worktree add --detach "$PROV_WT2" HEAD >/dev/null 2>&1
PROV_WT2_WIN="$(np "$PROV_WT2")"
PROV_MAIN_JS="$(np "$PROV_MAIN")/hooks/workflow-run-tests/provenance-identity.js"

# P2x-control: unmarked, the sibling is accepted as cwdRoot (so P2x below is not vacuous).
_p2xc=$(verify_emitter "run-all" "$PROV_WT2_WIN/tests/run-all.sh" "$PROV_WT2_WIN" "$PROV_MAIN_JS")
case "$_p2xc" in
    run-all) pass "P2x-control/unmarked-sibling-trusted-via-cwd-root" ;;
    *)       fail "P2x-control/unmarked-sibling-trusted-via-cwd-root" "got $_p2xc" ;;
esac

# P2x: once the sibling is marked, cwdRoot is skipped and the main module's own root does not match.
PROV_WT2_GITDIR="$(get_gitdir "$PROV_WT2_WIN")"
run_with_timeout 30 node "$(np "$MARKER_JS")" mark "$PROV_WT2_WIN" 2>/dev/null || true
if [ -n "$PROV_WT2_GITDIR" ] && [ -f "$PROV_WT2_GITDIR/agents-baseline-checkout" ]; then
    _p2x=$(verify_emitter "run-all" "$PROV_WT2_WIN/tests/run-all.sh" "$PROV_WT2_WIN" "$PROV_MAIN_JS")
    case "$_p2x" in
        "(none)") pass "P2x/marked-sibling-not-trusted-by-main-module" ;;
        *)        fail "P2x/marked-sibling-not-trusted-by-main-module" "got $_p2x" ;;
    esac
else
    fail "P2x/marked-sibling-not-trusted-by-main-module" "fixture marker not written in '$PROV_WT2_GITDIR'"
fi

case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
