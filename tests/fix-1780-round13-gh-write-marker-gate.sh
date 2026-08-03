#!/usr/bin/env bash
# tests/fix-1780-round13-gh-write-marker-gate.sh
# Tests: hooks/enforce-worktree.js, hooks/enforce-worktree/handle-bash-write.js, hooks/enforce-worktree/bash-write-scope.js, hooks/enforce-worktree/bash-write-scope/marker-gate.js, hooks/enforce-worktree/bash-write-scope/exclude-checks.js, hooks/lib/protected-basenames.js
# Tags: enforce-worktree, gh-write, session-marker, protected-basename, off-clearance, sequenced-command, parse-failure, marker-gate, pretooluse, classifier, security, scope:common, pwsh-not-required, TL2, hook-registration
#
# LAYER NOTE: same reasoning as tests/enforce-worktree-off-clearance-state-matrix.sh —
# this drives hooks/enforce-worktree.js as a real PreToolUse SUBPROCESS with piped
# stdin. Per rules/test.md the TL3 prefix is reserved for RUN_TL3-gated real
# `claude -p` seams, so this is filed TL2 and named without the prefix.
#
# TL3 gap (what this test does NOT catch):
# - Claude Code actually dispatching PreToolUse to this hook inside a live
#   session (registration itself is asserted statically in
#   tests/fix-1780-round4-write-tool-parity.sh section R).
# - A real `gh` binary being present: the hook classifies the command TEXT and
#   never spawns gh, so gh's own behaviour is out of scope here by construction.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780, codex security scanner "G")
#
# hooks/enforce-worktree/handle-bash-write.js has a Group B gh-write branch whose
# tail is an UNCONDITIONAL `done()` — an allow. gh writes are GitHub operations,
# not local file writes, so session scope was considered sufficient for them.
#
# The classifier that routes into that branch, isGhWriteIR()
# (hooks/lib/bash-write-patterns/patterns.js), declares the WHOLE command a gh
# write as soon as ANY segment matches. So a SEQUENCED command:
#
#     gh pr merge 1 && rm <workflowDir>/<sid>.workflow-off
#
# entered the gh branch on the strength of its first segment and reached that
# unconditional allow, while its SECOND segment forged/destroyed a protected
# session-marker file. `bashTargetsHitProtectedMarker()` — the centralized gate
# that every OTHER allow path already defers to — was computed AFTER the branch
# and never consulted on this route.
#
# hooks/lib/session-markers.js authorizes purely on a marker file's EXISTENCE, so
# one such write grants the session full WORKFLOW_OFF / WORKTREE_OFF clearance;
# a deletion is the symmetric half (clearing a marker mid-session is state
# tampering on the same file class).
#
# THE FIX asserted here: `_markerHit` (marker hit OR parse failure) is computed
# BEFORE the branch and gates entry to it — `if (!_markerHit && isGhWriteCommand(ir))`
# — so a marker hit falls through to the same fail-closed enforcement every other
# allow path already defers to.
#
# ATTACK-SCENARIO STRUCTURE (Pattern 2). Preconditions: a real main checkout, a
# real session marker file on disk in a pinned workflow dir, the repo in session
# scope (so the gh branch's own session-scope check would NOT have blocked and
# the pre-fix verdict really is ALLOW). Action: the sequenced tool call. Assert:
# BLOCKED, and — Pattern 1 — the marker file is still on disk afterwards,
# verified by actually EXECUTING the command whenever the hook allowed it
# (section X), so the assertion is about the protected resource and not merely
# about an exit code.
#
# BOTH DIRECTIONS (Pattern 4). Section A pins the sanctioned allow path: a plain
# gh write, and a sequenced gh write whose second segment writes an ORDINARY
# basename in the very same workflow dir. A4 is the mechanism control — identical
# command shape, only the basename differs — so a block in section B can only
# have come from the protected-basename gate, and an over-blocking regression
# that simply stopped allowing gh writes cannot pass both sections.
#
# HERMETICITY (rules/test/fixture-isolation.md): throwaway git repos under a
# temp dir with core.hooksPath disabled; CLAUDE_WORKFLOW_DIR and
# WORKFLOW_PLANS_DIR BOTH pinned (dual-pin) at DISTINCT temp dirs; process CWD is
# always a fixture dir, never this repo; CLAUDE_SESSION_ID /
# CLAUDE_CODE_SESSION_ID / SCRATCHPAD / DEFAULT_BRANCHES /
# ENFORCE_WORKTREE_ADDITIONAL_REPOS unset per invocation so no inherited marker,
# scratchpad allow, branch override or scope widening can decide an assertion.
#
# ASSERTION CONTRACT (inherited from tests/enforce-worktree-off-clearance-state-matrix.sh):
# enforce-worktree.js always exits 0 and prints either `{}` (allow) or a
# `"decision":"block"` object. A crash, timeout or empty output is its OWN
# verdict token — never folded into "allow".
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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
# isGhWriteIR() (hooks/lib/bash-write-patterns/patterns.js) is the SSOT for
# "Group B gh write", and its set is deliberately NARROW: pr merge, issue
# delete/create, repo delete, release create|delete|edit|upload, and gh api with
# a mutating method. Read-ish commands such as `gh issue comment` are NOT in it,
# so a test built on them would never enter the branch under test and would
# assert nothing about this fix. H3 below pins that premise: every command word
# used in sections B/A/X must classify as a gh write, and a non-gh control must
# not — otherwise the sections are declared vacuous rather than silently passing.
#
# `gh issue create` is excluded on purpose: it carries its own #713
# skill-context gate that blocks from a main checkout before the session-scope
# check, which would mask the verdict this file measures.
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
        env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID -u SCRATCHPAD -u DEFAULT_BRANCHES \
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
# Section B - a protected-marker write RIDING ALONG inside a gh write must NOT
# reach the gh branch's unconditional allow.
#
# Every row here is a sequenced command whose gh segment is entirely legitimate
# and whose sibling segment targets a protected basename in the workflow dir.
# The run dir is the MAIN checkout: that is where the fall-through lands on a
# real block (from a linked feature worktree enforce-worktree.js is a LOCATION
# guard whose tail allows — see the section-K comment in
# tests/enforce-worktree-off-clearance-state-matrix.sh — which is exactly why
# hooks/block-clearance-token-write.js exists as the location-independent gate,
# covered by tests/enforce-protected-marker-write.sh).
#
# Pre-fix, every row below measured ALLOW.
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
assert_guard "B6 gh pr merge && forge the OFF-clearance token (CPR-5 sibling family)" \
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
# Section P - PARSE FAILURE is the other half of `_markerHit`.
#
# hooks/lib/command-ir.js parse() sets parseFailure on an unclosed quote span,
# and `_markerHit = parseFailure || bashTargetsHitProtectedMarker(targets)`.
# SCOPE NOTE, stated rather than glossed: isGhWriteIR() itself already returns
# false when `ir.parseFailure === true`, so the parse-failure disjunct cannot be
# what keeps an unparseable command out of the gh branch — it is the round-5
# `!_markerHit` guard on the LATER allow fast-paths (universal target allow /
# Bug1 / Bug2) that these rows pin. They are kept here because they cover the
# same `_markerHit` expression this fix hoisted, and because an unparseable
# command is exactly the state in which nothing can be vouched for. P2 is the
# non-vacuity control: the SAME text with the quote closed parses fine, and the
# block then comes from the marker gate instead.
# ===========================================================================
assert_guard "P1 unclosed quote hiding a marker write is fail-closed" \
    block "$GHW_REL --notes \"hi && rm $MARKER_N" "$MAIN"
assert_guard "P2 control: the same text with the quote CLOSED still blocks (marker target)" \
    block "$GHW_REL --notes \"hi\" && rm $MARKER_N" "$MAIN"
assert_guard "P3 unclosed quote with no marker anywhere is still fail-closed" \
    block "$GHW_REL --notes \"hi && echo x > $ORDINARY_N" "$MAIN"

# ===========================================================================
# Section X - Pattern 1 in its strong form: the protected resource itself.
#
# The hook is a PreToolUse gate, so a verdict alone proves nothing about the
# file. Here the command is EXECUTED whenever (and only when) the hook allowed
# it — the same thing Claude Code would do with that verdict — and the marker is
# then checked on disk. A `;` separator is used so the marker-deleting segment
# runs even though the fixture host has no real `gh` binary; nothing outside
# $TMP is ever named.
#
# X2 is the counterweight: the identical mechanism applied to an ORDINARY file
# proves the harness really does execute on an allow, so X1's surviving marker
# cannot be explained by the harness silently doing nothing.
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
