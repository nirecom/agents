#!/usr/bin/env bash
# tests/hooks/fix-1780-round13-gh-write-marker-gate.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/handle-bash-write.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/enforce-worktree/bash-write-scope/exclude-checks.js, hooks/lib/protected-basenames.js
# Tags: enforce-worktree, gh-write, session-marker, protected-basename, off-clearance, sequenced-command, parse-failure, marker-gate, pretooluse, classifier, security, scope:common, pwsh-not-required, TL2, hook-registration
# TL2: real enforce-worktree.js subprocess. TL3 gap: live PreToolUse dispatch; gh is never spawned.
# Closest-to-action mitigation: bin/check-verification-gate.sh category: hook-registration.
# #1780 "G": `gh pr merge 1 && rm <wf>/<sid>.workflow-off` reached the gh branch's unconditional
# allow; the fix makes _markerHit gate gh-branch entry. B = attacks BLOCK, A = sanctioned gh ALLOW
# (A4/A5 ordinary-basename controls), P = parse failure, X = execute-on-allow resource check.
# Hermetic (rules/test/fixture-isolation.md); crash/timeout/empty are their own verdict tokens.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
GUARD="$_AGENTS_DIR_NODE/hooks/enforce-worktree.js"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
PB_NODE="$_AGENTS_DIR_NODE/hooks/lib/protected-basenames.js"
SID="ghgatesid"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$want got=$got"; fi
}

if [ ! -f "$AGENTS_DIR/hooks/enforce-worktree.js" ]; then
    fail "H0 hooks/enforce-worktree.js missing - every case below is vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H0 enforce-worktree.js present"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t 'ghgate')
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -r -f "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

# --- protected basename SSOT: DERIVED, never hardcoded ----------------------
# A hardcoded copy would silently stop covering a marker kind or token suffix
# added later to hooks/lib/protected-basenames.js.
MARKER_KIND=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).SESSION_MARKER_KINDS[0])" "$PB_NODE" 2>/dev/null)
TOKEN_SUFFIX=$("$RWT" 10 node -e \
    "process.stdout.write(require(process.argv[1]).OFF_CLEARANCE_TOKEN_SUFFIXES[0])" "$PB_NODE" 2>/dev/null)
if [ -z "$MARKER_KIND" ] || [ -z "$TOKEN_SUFFIX" ]; then
    fail "H1 protected-basename SSOT is introspectable (hooks/lib/protected-basenames.js exports)"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 protected-basename SSOT introspected: marker kind=[$MARKER_KIND]"

# --- workflow STATE dir (marker home) + a SEPARATE plans dir -----------------
WFDIR="$TMP/state/workflow"; mkdir -p "$WFDIR"
PLANS="$TMP/plans";          mkdir -p "$PLANS"
WF_N=$(node_path "$WFDIR"); PLANS_N=$(node_path "$PLANS")

# The protected files on disk are keyed to a DIFFERENT session id than the one
# the hook is invoked with. That is not incidental: hooks/lib/session-markers.js
# authorizes on the existence of `<own-sid>.workflow-off`, so pre-creating the
# marker for THIS session would switch WORKFLOW_OFF on and disarm the very guard
# under test — every row would then measure the off-switch instead of the gate.
# hooks/lib/protected-basenames.js anchors on the `.<kind>` basename TAIL and is
# prefix-agnostic, so a foreign-session marker is exactly as protected; tampering
# with another session's clearance state is the same class of attack.
VSID="victimsid"
MARKER="$WFDIR/$VSID.$MARKER_KIND"
TOKEN="$WFDIR/$VSID$TOKEN_SUFFIX"
ORDINARY="$WFDIR/$VSID.json"
MARKER_N="$WF_N/$VSID.$MARKER_KIND"
TOKEN_N="$WF_N/$VSID$TOKEN_SUFFIX"
ORDINARY_N="$WF_N/$VSID.json"

# reset_state: the protected files exist BEFORE every case, so "still on disk
# afterwards" is a meaningful assertion rather than a tautology.
reset_state() {
    printf 'marker-content\n' > "$MARKER"
    printf '{"token":"x"}\n'  > "$TOKEN"
    printf '{"ordinary":1}\n' > "$ORDINARY"
}
reset_state

# --- git fixtures: main checkout + linked worktree on a feature branch -------
MAIN="$TMP/repo"; mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
git -C "$MAIN" config core.hooksPath /dev/null
echo init > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit -q -m initial
WT="$TMP/repo-wt"
git -C "$MAIN" worktree add -q -b feature/gh-marker-gate "$WT" 2>/dev/null

if { [ ! -d "$WT/.git" ] && [ ! -f "$WT/.git" ]; }; then
    fail "H2 linked worktree fixture not created - the allow-path half would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H2 main checkout + linked feature worktree fixtures created"

# --- the gh WRITE vocabulary, verified against the classifier ----------------
# isGhWriteIR() (hooks/lib/bash-write-patterns/patterns.js) is the SSOT and is deliberately
# NARROW; H3 pins that every command word below classifies as a gh write (a non-gh control
# must not), else sections B/A/X are vacuous. `gh issue create` is excluded: its own #713
# skill-context gate blocks from a main checkout first and would mask the measured verdict.
GHW="gh pr merge 1"
GHW_REL="gh release create v1 --notes hi"
GHW_DEL="gh issue delete 1 --yes"
GHW_API="gh api -X POST repos/o/r/issues"

GH_PROBE="$TMP/gh-classify.js"
cat > "$GH_PROBE" <<'GH_EOF'
"use strict";
const agents = process.argv[2];
const { parse } = require(agents + "/hooks/lib/command-ir.js");
const { isGhWriteIR } = require(agents + "/hooks/lib/bash-write-patterns.js");
process.stdout.write(process.argv.slice(3).map((c) => (isGhWriteIR(parse(c)) ? "1" : "0")).join(""));
GH_EOF
GH_CLASS=$("$RWT" 10 node "$GH_PROBE" "$_AGENTS_DIR_NODE" \
    "$GHW" "$GHW_REL" "$GHW_DEL" "$GHW_API" "gh issue view 1" 2>/dev/null)
assert_eq "H3 non-vacuity: the four gh commands used below are Group B gh writes, a read-only gh is not" \
    "11110" "$GH_CLASS"
if [ "$GH_CLASS" != "11110" ]; then
    fail "H3 failed - sections B/A/X below cannot reach the gh-write branch; treat their verdicts as vacuous"
fi

# --- payload builder --------------------------------------------------------
DRV="$TMP/mk-input.js"
cat > "$DRV" <<'DRV_EOF'
"use strict";
const [, , cmd, cwd, sid] = process.argv;
process.stdout.write(JSON.stringify({
  session_id: sid,
  tool_name: "Bash",
  cwd,
  tool_input: { command: cmd, cwd },
}));
DRV_EOF

# run_guard <command> <run-dir> -> block | allow | crash:<rc> | timeout | empty | unrecognized
#
# The run-dir is a REAL process CWD, not just a payload field: getSessionRepoRoots()
# derives session scope from process.cwd(), so standing in the fixture repo is what
# puts it IN SCOPE — which is precisely what makes the pre-fix gh-write branch reach
# its unconditional allow instead of blocking on scope.
run_guard() {
    local cmd="$1" dir="$2" payload out rc
    payload=$("$RWT" 10 node "$DRV" "$cmd" "$(node_path "$dir")" "$SID" 2>/dev/null)
    out=$(cd "$dir" && printf '%s' "$payload" | \
        env -u CLAUDE_CODE_SESSION_ID -u SCRATCHPAD -u DEFAULT_BRANCHES \
            -u ENFORCE_WORKTREE_ADDITIONAL_REPOS -u ENFORCE_WORKTREE_EXTRA_REPOS \
        ENFORCE_WORKTREE=on CLAUDE_WORKFLOW_DIR="$WF_N" WORKFLOW_PLANS_DIR="$PLANS_N" \
        AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
        "$RWT" 25 node "$GUARD" 2>/dev/null)
    rc=$?
    case "$rc" in
        124) printf 'timeout'; return ;;
        0)   ;;
        *)   printf 'crash:%s' "$rc"; return ;;
    esac
    out=$(printf '%s' "$out" | tr -d '\r\n')
    [ -z "$out" ] && { printf 'empty'; return; }
    case "$out" in
        *'"decision":"block"'*) printf 'block' ;;
        '{}')                   printf 'allow' ;;
        *)                      printf 'unrecognized' ;;
    esac
}

# assert_guard <label> <want> <command> <run-dir>
# Pattern 1 rider: whatever the verdict, the protected marker and token must
# still be on disk when the hook returns. The hook is a gate and never executes
# anything, so this row catches a guard that "handles" a marker write by touching
# it itself. Section X does the stronger, execution-based form.
assert_guard() {
    local label="$1" want="$2" cmd="$3" dir="$4" got
    got=$(run_guard "$cmd" "$dir")
    assert_eq "$label" "$want" "$got"
    if [ ! -f "$MARKER" ] || [ ! -f "$TOKEN" ]; then
        fail "$label - PROTECTED RESOURCE GONE: the hook itself removed a marker/token file"
        reset_state
    fi
}

# ===========================================================================
# Section B - a protected-marker write riding inside a gh write must NOT reach the gh
# branch's unconditional allow (pre-fix every row measured ALLOW). Run from the MAIN
# checkout: from a linked worktree enforce-worktree.js is a location guard whose tail
# allows; hooks/block-clearance-token-write.js is the location-independent gate
# (tests/hooks/enforce-protected-marker-write.sh).
# ===========================================================================
assert_guard "B1 gh pr merge && rm marker" \
    block "$GHW && rm $MARKER_N" "$MAIN"
assert_guard "B2 gh pr merge ; rm marker (semicolon separator)" \
    block "$GHW ; rm $MARKER_N" "$MAIN"
assert_guard "B3 gh pr merge || rm marker (or separator)" \
    block "$GHW || rm $MARKER_N" "$MAIN"
assert_guard "B4 gh pr merge && redirect-forge marker" \
    block "$GHW && echo x > $MARKER_N" "$MAIN"
assert_guard "B5 marker segment FIRST, gh segment second (order-independence)" \
    block "echo x > $MARKER_N && $GHW" "$MAIN"
assert_guard "B6 gh pr merge && forge the OFF-clearance token (CPR-ORTH sibling family)" \
    block "$GHW && echo x > $TOKEN_N" "$MAIN"
assert_guard "B7 gh release create && rm marker (a different Group B subcommand)" \
    block "$GHW_REL && rm $MARKER_N" "$MAIN"
assert_guard "B8 gh issue delete && tee-forge marker" \
    block "$GHW_DEL && echo y | tee $MARKER_N" "$MAIN"
assert_guard "B9 gh api -X POST && cp over the marker" \
    block "$GHW_API && cp $ORDINARY_N $MARKER_N" "$MAIN"

# ===========================================================================
# Section A - the SANCTIONED gh-write allow path must still work (Pattern 4).
#
# Without these rows, a regression that simply deleted the gh branch would pass
# section B. A4/A5 are the MECHANISM CONTROL: the same sequenced shape as B4,
# in the same directory, differing only in the target BASENAME — so section B's
# blocks are attributable to the protected-basename gate and to nothing else.
# ===========================================================================
assert_guard "A1 plain gh pr merge from the main checkout is allowed" \
    allow "$GHW" "$MAIN"
assert_guard "A2 plain gh pr merge from a linked feature worktree is allowed" \
    allow "$GHW" "$WT"
assert_guard "A3 plain gh release create from the main checkout is allowed" \
    allow "$GHW_REL" "$MAIN"
assert_guard "A4 control: gh pr merge && write an ORDINARY basename in the same workflow dir" \
    allow "$GHW && echo x > $ORDINARY_N" "$MAIN"
assert_guard "A5 control: gh pr merge && rm an ORDINARY file in the same workflow dir" \
    allow "$GHW && rm $ORDINARY_N" "$MAIN"
reset_state
assert_guard "A6 gh release create whose --notes merely MENTIONS a marker-shaped word" \
    allow "gh release create v1 --notes 'see $VSID.$MARKER_KIND for context'" "$MAIN"

# ===========================================================================
# Section P - PARSE FAILURE, the other half of `_markerHit = parseFailure || markerHit`.
# isGhWriteIR() already rejects parseFailure IRs, so these rows pin the round-5 `!_markerHit`
# guard on the later allow fast-paths, not gh-branch entry. P2 (quote closed) is the
# non-vacuity control: it still blocks, via the marker gate instead.
# ===========================================================================
assert_guard "P1 unclosed quote hiding a marker write is fail-closed" \
    block "$GHW_REL --notes \"hi && rm $MARKER_N" "$MAIN"
assert_guard "P2 control: the same text with the quote CLOSED still blocks (marker target)" \
    block "$GHW_REL --notes \"hi\" && rm $MARKER_N" "$MAIN"
assert_guard "P3 unclosed quote with no marker anywhere is still fail-closed" \
    block "$GHW_REL --notes \"hi && echo x > $ORDINARY_N" "$MAIN"

# ===========================================================================
# Section X - Pattern 1 strong form: the command is EXECUTED only when the hook allowed it,
# then the protected file is checked on disk (`;` lets the marker segment run without a real
# gh; nothing outside $TMP is named). X2 proves the harness really executes on an allow.
# ===========================================================================
exec_if_allowed() {
    local cmd="$1" dir="$2" verdict
    verdict=$(run_guard "$cmd" "$dir")
    if [ "$verdict" = "allow" ]; then
        ( cd "$dir" && bash -c "$cmd" >/dev/null 2>&1 ) || true
    fi
    printf '%s' "$verdict"
}

reset_state
V=$(exec_if_allowed "$GHW ; rm $MARKER_N" "$MAIN")
assert_eq "X1a sequenced gh + marker deletion is blocked" "block" "$V"
if [ -f "$MARKER" ]; then pass "X1b the session marker file still exists on disk"
else fail "X1b PROTECTED RESOURCE DESTROYED: $MARKER was deleted"; fi

reset_state
V=$(exec_if_allowed "$GHW ; rm $ORDINARY_N" "$MAIN")
assert_eq "X2a harness counterweight: the ordinary-basename twin is allowed" "allow" "$V"
if [ -f "$ORDINARY" ]; then
    fail "X2b harness is inert - it did not execute an ALLOWED command, so X1b proves nothing"
else
    pass "X2b harness really executes allowed commands (the ordinary file was removed)"
fi

reset_state
V=$(exec_if_allowed "$GHW ; echo forged > $TOKEN_N" "$MAIN")
assert_eq "X3a sequenced gh + OFF-clearance token forge is blocked" "block" "$V"
if grep -q 'forged' "$TOKEN" 2>/dev/null; then
    fail "X3b PROTECTED RESOURCE OVERWRITTEN: $TOKEN was forged"
else
    pass "X3b the OFF-clearance token content is unchanged"
fi

cleanup_worktree() { git -C "$MAIN" worktree remove --force "$WT" >/dev/null 2>&1 || true; }
cleanup_worktree

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
