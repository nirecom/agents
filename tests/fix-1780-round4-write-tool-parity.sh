#!/usr/bin/env bash
# tests/fix-1780-round4-write-tool-parity.sh
# Tests: hooks/enforce-worktree.js, hooks/lib/write-tools.js, hooks/enforce-worktree/handle-edit-write.js, hooks/enforce-worktree/handle-bash-write.js, settings.json
# Tags: worktree, enforce-worktree, write-tools, tool-parity, notebookedit, editfiles, runcommands, runinterminal, pretooluse, security, scope:issue-specific, pwsh-not-required, TL2, hook-registration
# TL3 gap (what this test does NOT catch):
# - That Claude Code actually dispatches PreToolUse for editFiles / NotebookEdit /
#   runInTerminal / runCommands and delivers the payload shapes assumed here. The
#   hook is a node subprocess fed synthetic JSON; section R asserts the settings.json
#   registration STATICALLY only, so a matcher the host parses differently would
#   still pass here.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
#
# ---------------------------------------------------------------------------
# WHAT THIS FILE DEFENDS (#1780 round-4 H-2)
#
# enforce-worktree.js was written against FOUR tool names (Bash/Edit/Write/
# MultiEdit) and settings.json registered it on the same four. But the write
# surface is two CLASSES, enumerated in hooks/lib/write-tools.js:
#
#   edit-write : Edit, Write, MultiEdit, editFiles, NotebookEdit
#   command    : Bash, runInTerminal, runCommands
#
# editFiles, NotebookEdit, runInTerminal and runCommands therefore bypassed
# main-worktree and protected-branch enforcement OUTRIGHT — not a weaker check, no
# check at all. A guard that covers one member of a class and not its siblings is
# a bypass, not a partial guard (CPR-ORTH).
#
# THE ASSERTION IS PARITY, NOT "BLOCK". Each case runs the SAME payload semantics
# through a sibling and through the already-covered reference member (Edit for
# edit-write, Bash for command), and asserts the two verdicts are EQUAL as well as
# equal to the expected one. A hook that started blocking everything would fail
# the allow half; a hook that stopped blocking would fail the block half.
#
# Two payload shapes are covered per edit-write sibling, because both reach the
# hook in the wild: the single top-level target (file_path / notebook_path) and
# the BATCHED `edits[]` form that editFiles and NotebookEdit also use.
#
# NOTE (verified, pre-existing, do NOT "fix"): for the command class the hook
# reads the working directory from tool_input.cwd, not from the top-level `cwd` —
# identical for Bash and its siblings. Fixtures here set tool_input.cwd, and the
# hook process is additionally started IN the repo so process.cwd() agrees; the
# property under test is tool-name recognition, not cwd resolution.
#
# HERMETICITY: throwaway git repos under a temp dir, a throwaway session id, and
# CLAUDE_WORKFLOW_DIR pointed at a temp dir so no real session-override marker can
# switch enforcement off underneath the assertions. CLAUDE_SESSION_ID /
# CLAUDE_CODE_SESSION_ID are unset per invocation for the same reason.
# ---------------------------------------------------------------------------

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"; else _AGENTS_DIR_NODE="$AGENTS_DIR"; fi
GUARD="$_AGENTS_DIR_NODE/hooks/enforce-worktree.js"
WRITE_TOOLS="$_AGENTS_DIR_NODE/hooks/lib/write-tools.js"
SETTINGS="$_AGENTS_DIR_NODE/settings.json"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0; SKIP=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }
node_path() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"; else fail "$name - want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

if [ ! -f "$AGENTS_DIR/hooks/enforce-worktree.js" ]; then
    fail "H0 hooks/enforce-worktree.js missing - every case below is vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H0 enforce-worktree.js present"

TMP=$(mktemp -d 2>/dev/null || mktemp -d -t 'wtparity')
WF=$(node_path "$TMP/wfdir"); mkdir -p "$TMP/wfdir"
cleanup() { chmod -R u+w "$TMP" 2>/dev/null; rm -r -f "$TMP" 2>/dev/null; return 0; }
trap cleanup EXIT

# ── fixtures: a main checkout, a linked worktree on a feature branch, and a
# linked worktree on a PROTECTED branch name ────────────────────────────────
MAIN="$TMP/repo"
mkdir -p "$MAIN"
git -C "$MAIN" init -q -b main
git -C "$MAIN" config user.email "test@example.com"
git -C "$MAIN" config user.name "Test"
git -C "$MAIN" config core.hooksPath /dev/null
echo init > "$MAIN/README.md"
git -C "$MAIN" add README.md
git -C "$MAIN" commit -q -m initial
WT="$TMP/repo-wt"
git -C "$MAIN" worktree add -q -b feature/parity "$WT" 2>/dev/null
WTP="$TMP/repo-wt-protected"
git -C "$MAIN" worktree add -q -b master "$WTP" 2>/dev/null

# Native-form paths for every payload target. On Windows the shell hands out
# MSYS `/tmp/...` paths, which Node's fs/git resolution cannot follow — an
# unresolvable target would make the guard fail closed and the block cases would
# pass for the WRONG reason (and the allow cases would go false-green).
MAIN_N=$(node_path "$MAIN"); WT_N=$(node_path "$WT"); WTP_N=$(node_path "$WTP")

if [ ! -d "$WT/.git" ] && [ ! -f "$WT/.git" ]; then
    fail "H1 linked worktree fixture not created at $WT - allow cases would be vacuous"
    echo ""; echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"; exit 1
fi
pass "H1 main checkout + linked worktree fixtures created"

# ── payload builder ─────────────────────────────────────────────────────────
# Written to a file rather than inlined so the shapes read as data. `shape` is
# "single" (top-level target key) or "batch" (the `edits[]` array form).
DRV="$TMP/mk-input.js"
cat > "$DRV" <<'DRV_EOF'
"use strict";
const [, , tool, target, cwd, shape] = process.argv;
const EDIT_WRITE = ["Edit", "Write", "MultiEdit", "editFiles", "NotebookEdit"];
let ti;
if (EDIT_WRITE.indexOf(tool) !== -1) {
  // NotebookEdit names its target `notebook_path`; the rest use `file_path`.
  const key = tool === "NotebookEdit" ? "notebook_path" : "file_path";
  ti = shape === "batch" ? { edits: [{ [key]: target }] } : { [key]: target };
} else {
  // Command class. runCommands carries an ARRAY: the write is placed at index 2
  // so a joined-text-only reader cannot pass this by accident.
  ti = tool === "runCommands"
    ? { commands: ["git status", "npm test", target], cwd }
    : { command: target, cwd };
}
process.stdout.write(JSON.stringify({ session_id: "wtparitysid", tool_name: tool, cwd, tool_input: ti }));
DRV_EOF

# run_guard <tool> <target> <run-dir> <shape> -> block | allow | crash:<rc> | timeout | empty | unrecognized
run_guard() {
    local tool="$1" target="$2" dir="$3" shape="$4" payload out rc
    payload=$("$RWT" 10 node "$DRV" "$tool" "$target" "$(node_path "$dir")" "$shape" 2>/dev/null)
    out=$(cd "$dir" && printf '%s' "$payload" | env -u CLAUDE_SESSION_ID -u CLAUDE_CODE_SESSION_ID \
        ENFORCE_WORKTREE=on CLAUDE_WORKFLOW_DIR="$WF" WORKFLOW_PLANS_DIR="$WF" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
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

EDIT_WRITE_SIBLINGS="Write MultiEdit editFiles NotebookEdit"
COMMAND_SIBLINGS="runInTerminal runCommands"

# ===========================================================================
# Section M - main worktree: every write-capable tool must BLOCK.
# The reference verdicts are computed first; every sibling is compared to them.
# ===========================================================================
REF_EDIT=$(run_guard Edit "$MAIN_N/notes.txt" "$MAIN" single)
assert_eq "M0 reference: Edit in the main worktree blocks" "block" "$REF_EDIT"
REF_BASH=$(run_guard Bash "echo x > $MAIN_N/notes.txt" "$MAIN" single)
assert_eq "M0 reference: Bash write in the main worktree blocks" "block" "$REF_BASH"

for t in $EDIT_WRITE_SIBLINGS; do
    got=$(run_guard "$t" "$MAIN_N/notes.txt" "$MAIN" single)
    assert_eq "M1 $t (single target) matches Edit in the main worktree" "$REF_EDIT" "$got"
done
# Batched `edits[]`: the shape belongs to the CLASS, not to MultiEdit. Gating the
# batch branch on the tool NAME let a batched editFiles/NotebookEdit fall through
# to the single-path branch, which found no target and allowed the write.
for t in MultiEdit editFiles NotebookEdit; do
    got=$(run_guard "$t" "$MAIN_N/notes.txt" "$MAIN" batch)
    assert_eq "M2 $t (batched edits[]) matches Edit in the main worktree" "$REF_EDIT" "$got"
done
for t in $COMMAND_SIBLINGS; do
    got=$(run_guard "$t" "echo x > $MAIN_N/notes.txt" "$MAIN" single)
    assert_eq "M3 $t matches Bash in the main worktree" "$REF_BASH" "$got"
done

# ===========================================================================
# Section A - FALSE POSITIVES: from inside a linked worktree on a feature branch
# (the normal working mode) every sibling must ALLOW. Without this section the
# M-block would pass against a hook that blocks every unfamiliar tool name, which
# is its own outage.
# ===========================================================================
AREF_EDIT=$(run_guard Edit "$WT_N/notes.txt" "$WT" single)
assert_eq "A0 reference: Edit inside a linked worktree on a feature branch allows" "allow" "$AREF_EDIT"
AREF_BASH=$(run_guard Bash "echo x > $WT_N/notes.txt" "$WT" single)
assert_eq "A0 reference: Bash write inside a linked worktree allows" "allow" "$AREF_BASH"

for t in $EDIT_WRITE_SIBLINGS; do
    got=$(run_guard "$t" "$WT_N/notes.txt" "$WT" single)
    assert_eq "A1 $t (single target) matches Edit inside a linked worktree" "$AREF_EDIT" "$got"
done
for t in MultiEdit editFiles NotebookEdit; do
    got=$(run_guard "$t" "$WT_N/notes.txt" "$WT" batch)
    assert_eq "A2 $t (batched edits[]) matches Edit inside a linked worktree" "$AREF_EDIT" "$got"
done
for t in $COMMAND_SIBLINGS; do
    got=$(run_guard "$t" "echo x > $WT_N/notes.txt" "$WT" single)
    assert_eq "A3 $t matches Bash inside a linked worktree" "$AREF_BASH" "$got"
done

# ===========================================================================
# Section P - the OTHER block reason: a protected branch inside a linked
# worktree. It is a separate code path from the main-checkout branch above, so
# sibling parity has to be asserted there too (CPR-ORTH) - a tool recognized by one
# path and not the other is still a bypass.
# ===========================================================================
if [ ! -d "$WTP" ]; then
    skip "P protected-branch worktree fixture unavailable"
else
    PREF_EDIT=$(run_guard Edit "$WTP_N/notes.txt" "$WTP" single)
    assert_eq "P0 reference: Edit on a protected branch in a linked worktree blocks" "block" "$PREF_EDIT"
    PREF_BASH=$(run_guard Bash "echo x > $WTP_N/notes.txt" "$WTP" single)
    assert_eq "P0 reference: Bash write on a protected branch in a linked worktree blocks" "block" "$PREF_BASH"
    for t in $EDIT_WRITE_SIBLINGS; do
        got=$(run_guard "$t" "$WTP_N/notes.txt" "$WTP" single)
        assert_eq "P1 $t matches Edit on a protected branch" "$PREF_EDIT" "$got"
    done
    for t in $COMMAND_SIBLINGS; do
        got=$(run_guard "$t" "echo x > $WTP_N/notes.txt" "$WTP" single)
        assert_eq "P2 $t matches Bash on a protected branch" "$PREF_BASH" "$got"
    done
fi

# ===========================================================================
# Section R - REGISTRATION. All of the above is unreachable if settings.json does
# not fire the hook for a tool: PreToolUse matching happens in the host, before
# any of this hook's code runs. So the matcher is asserted against the same SSOT
# the runtime branches on (hooks/lib/write-tools.js), as a SET - order and
# spelling of the alternation must cover exactly the 8 names, no more, no fewer.
# ===========================================================================
RDRV="$TMP/check-registration.js"
cat > "$RDRV" <<'RDRV_EOF'
"use strict";
const s = require(process.argv[2]);
const wt = require(process.argv[3]);
const expected = wt.EDIT_WRITE_TOOL_NAMES.concat(wt.COMMAND_TOOL_NAMES);
const entries = (s.hooks && s.hooks.PreToolUse) || [];
const entry = entries.find((e) =>
  (e.hooks || []).some((h) => String(h.command || "").includes("enforce-worktree.js")));
if (!entry) { process.stdout.write("NOT-REGISTERED"); process.exit(0); }
const listed = String(entry.matcher || "").split("|").map((x) => x.trim()).filter(Boolean);
const missing = expected.filter((n) => listed.indexOf(n) === -1);
const extra = listed.filter((n) => expected.indexOf(n) === -1);
process.stdout.write(JSON.stringify({
  count: listed.length,
  missing,
  extra,
  matcherEqualsSsot: String(entry.matcher || "") === wt.TOOL_MATCHER,
}));
RDRV_EOF
if [ ! -f "$AGENTS_DIR/settings.json" ]; then
    skip "R settings.json not found"
else
    reg=$("$RWT" 15 node "$RDRV" "$SETTINGS" "$WRITE_TOOLS" 2>/dev/null)
    assert_eq "R1 settings.json registers enforce-worktree.js for exactly the 8 write-tool names" \
        '{"count":8,"missing":[],"extra":[],"matcherEqualsSsot":true}' "$reg"
fi

# R2 - the SSOT itself: the classes must still name all 8 tools. If a name is
# dropped here, R1 keeps passing (both sides shrink together) while the guard
# silently stops covering that tool - so the list is pinned literally.
cls=$("$RWT" 10 node -e '
const wt = require(process.argv[1]);
process.stdout.write(JSON.stringify(wt.EDIT_WRITE_TOOL_NAMES) + "|" + JSON.stringify(wt.COMMAND_TOOL_NAMES));
' "$WRITE_TOOLS" 2>/dev/null)
assert_eq "R2 write-tools.js SSOT still enumerates both full classes" \
    '["Edit","Write","MultiEdit","editFiles","NotebookEdit"]|["Bash","runInTerminal","runCommands"]' "$cls"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
