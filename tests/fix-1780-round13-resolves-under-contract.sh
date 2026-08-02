#!/usr/bin/env bash
# tests/fix-1780-round13-resolves-under-contract.sh
# Tests: hooks/lib/path-containment.js
# Tags: path-containment, resolves-under, symlink, fail-direction, on-unknown, classifier, security, workflow-dir, scope:common, pwsh-not-required, TL1
#
# TL3 gap (what this test does NOT catch):
# - Real NTFS reparse-point / junction semantics on a Windows volume without
#   developer mode: when `ln -s` cannot produce a real symlink here, the two
#   unresolvable-fixture sections SKIP loudly instead of asserting. The
#   `onUnknown` contract itself is still fully asserted through the
#   non-string / empty-string routes, which need no filesystem support.
# - A case-insensitive volume's effect on the resolvable rows (covered by
#   tests/fix-1780-round4-case-fold-probe.sh and by the case_* rows of
#   tests/enforce-protected-marker-write/cases-round5-containment.sh).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: pwsh-required.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780, codex security scanner "C")
#
# hooks/lib/path-containment.js `resolvesUnder()` is consulted from two OPPOSITE
# directions:
#
#   PERMISSION direction (hooks/enforce-worktree/bash-write-scope/marker-gate.js)
#     containment GRANTS leniency -> "cannot prove" must mean DENY the shortcut.
#   DETECTION direction (hooks/block-off-clearance-write/bash-target-context.js)
#     containment ARMS a block     -> "cannot prove" must mean ARM the block.
#
# The function used to answer a single hardcoded `false` for "cannot prove"
# (an unresolvable path, or a symlink chain that trips MAX_SYMLINK_HOPS and makes
# realResolve() throw). That was correct for the permission direction and
# silently FAIL-OPEN for the detection direction: an attacker-crafted circular
# symlink ancestor of a glob write target forces realResolve() to throw, the
# qualifier never arms, and the write proceeds unscrutinised.
#
# The fix makes the fail direction a REQUIRED, EXPLICIT parameter
# (`opts.onUnknown`, boolean) instead of an implicit constant (CPR-8).
#
# WHAT IS ASSERTED HERE (all three halves of the contract):
#   (1) the parameter is MANDATORY - a missing or non-boolean `onUnknown`
#       throws, so no future caller can silently inherit a fail direction;
#   (2) on an UNPROVABLE input the return value is `onUnknown` VERBATIM -
#       asserted for BOTH boolean values on the SAME input, which is the only
#       shape that can catch a re-hardcoded constant (Pattern 4);
#   (3) on a PROVABLE input `onUnknown` is inert - a genuine descendant answers
#       true and a genuine non-descendant answers false under both settings, so
#       the new parameter cannot be mistaken for a general override.
#
# Pattern 2 (attack-scenario structure): the loop_* / deep_* rows reproduce the
# vulnerable precondition (an ancestor directory the resolver cannot resolve),
# execute the containment question, and assert the DETECTION answer is "arm the
# block". Against the pre-fix single-`false` shape, loop_onUnknown_true and
# deep_onUnknown_true fail.
#
# HERMETICITY (rules/test/fixture-isolation.md): everything lives in a mktemp
# tree, the process CWD is that temp tree (never the repo), and no workflow
# state dir is involved - path-containment.js reads no env and no config, so no
# CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR pinning is applicable here. Inherited
# session ids are unset anyway so a future dependency cannot silently appear.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
SRC="$AGENTS_DIR/hooks/lib/path-containment.js"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$want got=$got"; fi
}

if [ ! -f "$SRC" ]; then
    fail "H0 hooks/lib/path-containment.js missing - every case below is vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H0 hooks/lib/path-containment.js present"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t 'rsunder')
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -r -f "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

# ── fixture tree ────────────────────────────────────────────────────────────
# parent/            the "parent" of every containment question
# parent/inside/     a genuine descendant           -> resolvable, true
# outside/           a genuine non-descendant       -> resolvable, false
# parent/loopA <-> parent/loopB  circular pair      -> realResolve() throws
# parent/hop0 -> hop1 -> ... -> hop44 -> nowhere    -> exceeds MAX_SYMLINK_HOPS
PARENT="$TMP/parent"; mkdir -p "$PARENT/inside" "$TMP/outside"

# _try_symlink <target> <linkpath>: plain `ln -s` degrades to a COPY on Git
# Bash/MSYS, which would silently make the unresolvable fixtures resolvable and
# assert nothing, so the result is verified with -L and the nativestrict variant
# is retried. Same helper shape as
# tests/enforce-protected-marker-write/cases-round5-containment.sh.
_try_symlink() {
    ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    rm -r -f "$2" 2>/dev/null
    MSYS=winsymlinks:nativestrict ln -s "$1" "$2" 2>/dev/null; [ -L "$2" ] && return 0
    return 1
}

LOOP_DIR="$PARENT/loopA"
_try_symlink "$PARENT/loopB" "$PARENT/loopA" && _try_symlink "$PARENT/loopA" "$PARENT/loopB"

# A LINEAR chain longer than MAX_SYMLINK_HOPS ending at a nonexistent tail: the
# OS cannot short-circuit it (the final target never exists), so realResolve()
# must walk it link by link and trip its own hop cap. Built back-to-front.
DEEP_DIR="$PARENT/hop0"
_deep_ok=yes
_try_symlink "$PARENT/nowhere" "$PARENT/hop44" || _deep_ok=no
if [ "$_deep_ok" = yes ]; then
    _i=43
    while [ "$_i" -ge 0 ]; do
        _try_symlink "$PARENT/hop$((_i + 1))" "$PARENT/hop$_i" || { _deep_ok=no; break; }
        _i=$((_i - 1))
    done
fi

# ── probe ───────────────────────────────────────────────────────────────────
PROBE="$TMP/probe.js"
cat > "$PROBE" <<'PROBE_EOF'
"use strict";
// argv: <agentsDir> <parentDir> <insideDir> <outsideDir> <loopDir> <deepDir>
// Prints `key=value` lines. Every value is either a literal (true/false/number),
// `throw:<msg>`, or one of the throw-classification tokens below.
const path = require("path");
const [agentsDir, parentDir, insideDir, outsideDir, loopDir, deepDir] = process.argv.slice(2);
const pc = require(path.join(agentsDir, "hooks", "lib", "path-containment.js"));

const out = [];
function emit(key, fn) {
  let v;
  try { v = fn(); } catch (e) { v = "throw:" + (e && e.message ? e.message : String(e)); }
  out.push(key + "=" + v);
}
// classify a call that is EXPECTED to throw the programmer-contract error.
// "throw-onUnknown" is the only accepted token: a generic crash (e.g. a TypeError
// from somewhere else) must not be able to satisfy the mandatory-parameter rows.
function threw(fn) {
  try {
    fn();
    return "no-throw";
  } catch (e) {
    const m = (e && e.message) ? String(e.message) : String(e);
    return /onUnknown/.test(m) ? "throw-onUnknown" : "throw-other";
  }
}
function unresolvable(p) {
  try { pc.realResolve(p); return false; } catch (_) { return true; }
}

emit("max_hops", () => pc.MAX_SYMLINK_HOPS);

// (1) MANDATORY PARAMETER - missing key, or any non-boolean value, throws.
out.push("c_no_opts=" + threw(() => pc.resolvesUnder(insideDir, parentDir)));
out.push("c_undefined_opts=" + threw(() => pc.resolvesUnder(insideDir, parentDir, undefined)));
out.push("c_null_opts=" + threw(() => pc.resolvesUnder(insideDir, parentDir, null)));
out.push("c_empty_opts=" + threw(() => pc.resolvesUnder(insideDir, parentDir, {})));
out.push("c_allowEqual_only=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { allowEqual: true })));
out.push("c_string_true=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: "true" })));
out.push("c_string_false=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: "false" })));
out.push("c_number_one=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: 1 })));
out.push("c_number_zero=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: 0 })));
out.push("c_null_value=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: null })));
out.push("c_undefined_value=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: undefined })));
out.push("c_boxed_boolean=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: new Boolean(true) })));
// The two well-formed spellings must NOT throw - otherwise every row below
// would be satisfied by a function that simply always throws.
out.push("c_ok_true=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: true })));
out.push("c_ok_false=" + threw(() => pc.resolvesUnder(insideDir, parentDir, { onUnknown: false })));

// (2a) UNPROVABLE via a symlink chain realResolve() cannot resolve.
// The fixture's viability is reported rather than assumed: on a host without
// real symlinks these two are false and the bash side SKIPs instead of passing
// vacuously.
emit("loop_unresolvable", () => unresolvable(loopDir));
emit("deep_unresolvable", () => unresolvable(deepDir));
emit("loop_onUnknown_true", () => pc.resolvesUnder(loopDir, parentDir, { allowEqual: true, onUnknown: true }));
emit("loop_onUnknown_false", () => pc.resolvesUnder(loopDir, parentDir, { allowEqual: true, onUnknown: false }));
emit("deep_onUnknown_true", () => pc.resolvesUnder(deepDir, parentDir, { allowEqual: true, onUnknown: true }));
emit("deep_onUnknown_false", () => pc.resolvesUnder(deepDir, parentDir, { allowEqual: true, onUnknown: false }));
// The PARENT side of the comparison is unresolvable (symmetric member, CPR-5).
emit("loopparent_onUnknown_true", () => pc.resolvesUnder(insideDir, loopDir, { allowEqual: true, onUnknown: true }));
emit("loopparent_onUnknown_false", () => pc.resolvesUnder(insideDir, loopDir, { allowEqual: true, onUnknown: false }));

// (2b) UNPROVABLE via input SHAPE - needs no filesystem support, so these rows
// assert the same both-direction property on every host.
emit("nonstring_child_true", () => pc.resolvesUnder(null, parentDir, { onUnknown: true }));
emit("nonstring_child_false", () => pc.resolvesUnder(null, parentDir, { onUnknown: false }));
emit("nonstring_parent_true", () => pc.resolvesUnder(insideDir, 42, { onUnknown: true }));
emit("nonstring_parent_false", () => pc.resolvesUnder(insideDir, 42, { onUnknown: false }));
emit("emptychild_true", () => pc.resolvesUnder("", parentDir, { onUnknown: true }));
emit("emptychild_false", () => pc.resolvesUnder("", parentDir, { onUnknown: false }));
emit("emptyparent_true", () => pc.resolvesUnder(insideDir, "", { onUnknown: true }));
emit("emptyparent_false", () => pc.resolvesUnder(insideDir, "", { onUnknown: false }));
emit("undefchild_true", () => pc.resolvesUnder(undefined, parentDir, { onUnknown: true }));
emit("undefchild_false", () => pc.resolvesUnder(undefined, parentDir, { onUnknown: false }));

// (3) PROVABLE inputs - onUnknown must be inert in BOTH settings.
emit("inside_true", () => pc.resolvesUnder(insideDir, parentDir, { onUnknown: true }));
emit("inside_false", () => pc.resolvesUnder(insideDir, parentDir, { onUnknown: false }));
emit("outside_true", () => pc.resolvesUnder(outsideDir, parentDir, { onUnknown: true }));
emit("outside_false", () => pc.resolvesUnder(outsideDir, parentDir, { onUnknown: false }));
// allowEqual still decides the self-containment case, not onUnknown.
emit("equal_allowEqual_on_true", () => pc.resolvesUnder(parentDir, parentDir, { allowEqual: true, onUnknown: true }));
emit("equal_allowEqual_on_false", () => pc.resolvesUnder(parentDir, parentDir, { allowEqual: true, onUnknown: false }));
emit("equal_allowEqual_off_true", () => pc.resolvesUnder(parentDir, parentDir, { allowEqual: false, onUnknown: true }));
emit("equal_allowEqual_off_false", () => pc.resolvesUnder(parentDir, parentDir, { allowEqual: false, onUnknown: false }));
// A nonexistent-but-LEXICALLY-resolvable tail is PROVABLE (realResolve walks up
// to the deepest existing ancestor), so it must not be swept into "unknown".
emit("ghost_inside_true", () => pc.resolvesUnder(path.join(parentDir, "no", "such", "f.txt"), parentDir, { onUnknown: true }));
emit("ghost_inside_false", () => pc.resolvesUnder(path.join(parentDir, "no", "such", "f.txt"), parentDir, { onUnknown: false }));
emit("ghost_outside_true", () => pc.resolvesUnder(path.join(outsideDir, "no", "such", "f.txt"), parentDir, { onUnknown: true }));
emit("ghost_outside_false", () => pc.resolvesUnder(path.join(outsideDir, "no", "such", "f.txt"), parentDir, { onUnknown: false }));

process.stdout.write(out.join("\n") + "\n");
PROBE_EOF

# Neutral CWD: run from the temp tree, never the repo (rules/test/fixture-isolation.md).
OUT=$(cd "$TMP" && env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
    "$RWT" 30 node "$(node_path "$PROBE")" \
        "$_AGENTS_DIR_NODE" \
        "$(node_path "$PARENT")" \
        "$(node_path "$PARENT/inside")" \
        "$(node_path "$TMP/outside")" \
        "$(node_path "$LOOP_DIR")" \
        "$(node_path "$DEEP_DIR")" 2>/dev/null)

if [ -z "$OUT" ]; then
    fail "H1 probe produced no output (crash/timeout) - the whole file would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 probe ran"

kv() { local line; line=$(printf '%s\n' "$OUT" | grep -m1 "^$1=") || true; printf '%s' "${line#*=}"; }
expect() { assert_eq "$1 == $2" "$2" "$(kv "$1")"; }

# ===========================================================================
# Section C - the fail direction is a MANDATORY, EXPLICIT parameter.
#
# This is the structural half of the fix: a caller that does not state its own
# direction cannot compile-by-accident into whichever constant the SSOT happened
# to pick. Every malformed spelling must raise the SAME programmer-contract
# error (matched on the parameter name, so an unrelated crash cannot satisfy the
# row), and the two well-formed spellings must not raise at all.
# ===========================================================================
expect max_hops 40
for k in c_no_opts c_undefined_opts c_null_opts c_empty_opts c_allowEqual_only \
         c_string_true c_string_false c_number_one c_number_zero \
         c_null_value c_undefined_value c_boxed_boolean; do
    expect "$k" throw-onUnknown
done
expect c_ok_true no-throw
expect c_ok_false no-throw

# ===========================================================================
# Section U - UNPROVABLE input returns `onUnknown` VERBATIM (Pattern 4).
#
# Both boolean values are asserted on the SAME input. A single-direction test
# would still pass against the pre-fix hardcoded `false`; only the pair can
# fail it. `onUnknown:true` is the DETECTION direction (arm the block) and is
# the row that fails against pre-fix code.
#
# U1 - the attacker-crafted route: an ancestor the resolver cannot resolve.
# ===========================================================================
LOOP_OK=$(kv loop_unresolvable)
DEEP_OK=$(kv deep_unresolvable)

if [ "$LOOP_OK" = true ]; then
    pass "U1-fixture circular symlink pair is genuinely unresolvable by realResolve()"
    expect loop_onUnknown_true true
    expect loop_onUnknown_false false
    expect loopparent_onUnknown_true true
    expect loopparent_onUnknown_false false
else
    skip "U1 circular-symlink rows - no real symlink available here (Windows without developer mode / MSYS winsymlinks); the contract is still asserted by Section U2, verify U1 on a POSIX host"
fi

if [ "$DEEP_OK" = true ]; then
    pass "U1-fixture >MAX_SYMLINK_HOPS chain is genuinely unresolvable by realResolve()"
    expect deep_onUnknown_true true
    expect deep_onUnknown_false false
else
    skip "U1 hop-cap rows - the >40-hop chain fixture could not be built (no real symlinks here); verify on a POSIX host"
fi

# U2 - the shape route: non-string and empty-string operands. No filesystem
# support needed, so these rows hold the both-direction contract up on EVERY
# host, including one where U1 skipped.
expect nonstring_child_true true
expect nonstring_child_false false
expect nonstring_parent_true true
expect nonstring_parent_false false
expect emptychild_true true
expect emptychild_false false
expect emptyparent_true true
expect emptyparent_false false
expect undefchild_true true
expect undefchild_false false

# ===========================================================================
# Section P - PROVABLE input: `onUnknown` is inert.
#
# The CPR-5 counterpart of Section U. Without these rows, `onUnknown:true` could
# degenerate into "always true" (blocking every glob everywhere) and still pass
# Section U - which is exactly the false-positive over-block failure mode the
# fix must not introduce.
# ===========================================================================
expect inside_true true
expect inside_false true
expect outside_true false
expect outside_false false
expect ghost_inside_true true
expect ghost_inside_false true
expect ghost_outside_true false
expect ghost_outside_false false
# allowEqual keeps owning the self-containment answer under both settings.
expect equal_allowEqual_on_true true
expect equal_allowEqual_on_false true
expect equal_allowEqual_off_true false
expect equal_allowEqual_off_false false

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
