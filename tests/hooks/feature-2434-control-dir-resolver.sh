#!/usr/bin/env bash
# tests/hooks/feature-2434-control-dir-resolver.sh
# Tests: hooks/workflow-state/state-io/control-dir.js, bin/workflow-control-dir
# Tags: feature-2434, control-dir, resolver, path-validation, import-allowlist, scope:issue-specific, pwsh-not-required
#
# #2434 Step 2: every control file is reached through one resolver,
# <wf>/<sid>.control/<name>. This pins its validation (sid via core.js, name via
# its own allowlist), its mkdir policy (writers only), the CLI's exit codes,
# and the import allowlist that keeps readers from bypassing it.
set -uo pipefail

# TL1 — node requires the module; the CLI runs for real against temp dirs.
# The CONTROL_DIR session-facts key is pinned by
# tests/bin/feature-2102-session-facts/contract.sh (C11), not duplicated here.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

MOD="$AGENTS_DIR/hooks/workflow-state/state-io/control-dir.js"
CLI="$AGENTS_DIR/bin/workflow-control-dir"

TMP="$(make_tmp)"
trap 'cd / 2>/dev/null; rm -rf "$TMP"' EXIT
harness_isolate "$TMP"
mkdir -p "$TMP/empty-transcripts"
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMP/empty-transcripts"
cd "$TMP" || exit 1

MOD_N="$(np "$MOD")"
export MOD_N

DRIVER="$TMP/driver.js"
cat > "$DRIVER" <<'JS'
// driver.js <op> <sid> [name] — one resolver call, printed as one line.
const [op, sid, name] = process.argv.slice(2);
let m;
try { m = require(process.env.MOD_N); } catch (e) { console.log("MISSING"); process.exit(0); }
const fwd = (p) => String(p).replace(/\\/g, "/");
try {
  if (op === "dir") console.log(fwd(m.getSessionControlDir(sid)));
  else if (op === "path") console.log(fwd(m.controlPath(sid, name)));
  else if (op === "path-write") console.log(fwd(m.controlPath(sid, name, { forWrite: true })));
  else if (op === "error-class") console.log(typeof m.ControlMigrationError === "function" &&
      new m.ControlMigrationError({ sid: "s", name: "n", legacyPath: "/x", cause: new Error("c") }) instanceof Error
      ? "error-subclass" : "absent");
  else console.log("bad-op");
} catch (e) {
  console.log("THREW");
}
JS

res() { node "$DRIVER" "$@" 2>/dev/null | tr -d '\r'; }
fwd() { printf '%s' "$1" | tr '\\' '/'; }

check() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$2") got=$(printf '%q' "$3")"; fi
}

WF_FWD="$(fwd "$(np "$CLAUDE_WORKFLOW_DIR")")"

[ -f "$MOD" ] || fail "implementation missing: hooks/workflow-state/state-io/control-dir.js"
[ -f "$CLI" ] || fail "implementation missing: bin/workflow-control-dir"

case_begin "session-control-dir-per-sid-shape" "hooks/workflow-state/state-io/control-dir.js"
# One rule for every sid shape the workflow produces (C1): <wf>/<sid>.control.
for SID in 0199a2f1-cafe-4b0d-9c11-deadbeef0001 20260601-120000 \
           0199a2f1-cafe-4b0d-9c11-deadbeef0001-b1 20260509-bundle-a; do
    check "getSessionControlDir($SID) is <wf>/$SID.control" \
        "$WF_FWD/$SID.control" "$(res dir "$SID")"
    check "controlPath($SID, detail-plan-terminal.txt) sits inside it" \
        "$WF_FWD/$SID.control/detail-plan-terminal.txt" "$(res path "$SID" detail-plan-terminal.txt)"
done
# An unknown session (no <sid>.json) still gets a path: the writer creates it.
check "a sid with no workflow state json still resolves" \
    "$WF_FWD/20991231-000000.control" "$(res dir 20991231-000000)"
case_end

case_begin "invalid-sid-is-rejected" "hooks/workflow-state/state-io/control-dir.js"
# The sid grammar is the #2025 C9 path-token alphabet (a dot inside, never
# leading, never '..'); anything else throws before a path is built.
for BAD in "" ".." "../escape" "a/b" 'a\b' ".hidden" "a..b" "a b" "a.b" "-"; do
    got="$(res dir "$BAD")"
    case "$BAD" in
        -) check "the sid '-' is accepted by the grammar (dash is in the class)" "$WF_FWD/-.control" "$got" ;;
        a.b) check "a dotted sid is accepted (#2025 C9)" "$WF_FWD/a.b.control" "$got" ;;
        *) check "getSessionControlDir rejects sid $(printf '%q' "$BAD")" "THREW" "$got" ;;
    esac
done
check "controlPath rejects a traversing sid too" "THREW" "$(res path "../x" detail-plan-terminal.txt)"
case_end

case_begin "control-name-validation" "hooks/workflow-state/state-io/control-dir.js"
# Names follow ^[A-Za-z0-9][A-Za-z0-9._-]*$ with no '..' — a leading dot or
# dash, a separator, or a parent reference is refused.
S="20260601-120001"
for OK in detail-plan-terminal.txt codex-context.detail-plan.built worker-commit-push-2.json handoff.md wt-cleanup-active; do
    check "controlPath accepts the name $OK" "$WF_FWD/$S.control/$OK" "$(res path "$S" "$OK")"
done
for BAD in "" ".." "../x" "a/b" 'a\b' ".hidden" "-rf" "a..b" "a b" 'a$b'; do
    check "controlPath rejects the name $(printf '%q' "$BAD")" "THREW" "$(res path "$S" "$BAD")"
done
case_end

case_begin "mkdir-only-for-writers" "hooks/workflow-state/state-io/control-dir.js"
# A reader must never create another session's empty control dir.
S="20260601-120002"
res path "$S" detail-plan-terminal.txt >/dev/null
check "a read-mode controlPath creates no directory" "absent" \
    "$([ -e "$CLAUDE_WORKFLOW_DIR/$S.control" ] && printf present || printf absent)"
res path-write "$S" detail-plan-terminal.txt >/dev/null
check "a forWrite controlPath creates <sid>.control" "dir" \
    "$([ -d "$CLAUDE_WORKFLOW_DIR/$S.control" ] && printf dir || printf absent)"
check "but not the file itself" "absent" \
    "$([ -e "$CLAUDE_WORKFLOW_DIR/$S.control/detail-plan-terminal.txt" ] && printf present || printf absent)"
check "ControlMigrationError is an exported Error subclass" "error-subclass" "$(res error-class)"
case_end

case_begin "cli-exit-codes-and-output" "bin/workflow-control-dir"
# The bash / prompt face of the same resolver: exit 0 with the path, exit 2
# for an invalid sid or name (with the cause on stderr).
S="20260601-120003"
cli() { bash "$CLI" "$@" 2>"$TMP/cli.err" | tr -d '\r'; }
cli_rc() { bash "$CLI" "$@" >/dev/null 2>"$TMP/cli.err"; printf '%s' "$?"; }

check "--session prints the session's control dir" "$WF_FWD/$S.control" "$(fwd "$(cli --session "$S")")"
check "--file prints the control file's path" \
    "$WF_FWD/$S.control/detail-plan-terminal.txt" "$(fwd "$(cli --session "$S" --file detail-plan-terminal.txt)")"
check "without --for-write nothing is created" "absent" \
    "$([ -e "$CLAUDE_WORKFLOW_DIR/$S.control" ] && printf present || printf absent)"
check "--for-write exits 0" "0" "$(cli_rc --session "$S" --for-write)"
check "--for-write creates the control dir" "dir" \
    "$([ -d "$CLAUDE_WORKFLOW_DIR/$S.control" ] && printf dir || printf absent)"
check "an invalid sid exits 2" "2" "$(cli_rc --session "../escape")"
check "and says why on stderr" "yes" "$([ -s "$TMP/cli.err" ] && printf yes || printf no)"
check "an invalid name exits 2" "2" "$(cli_rc --session "$S" --file "../x")"
check "a missing --session is a usage error, not a path" "nonzero" \
    "$([ "$(cli_rc)" = "0" ] && printf zero || printf nonzero)"
check "no directory was created outside the workflow dir" "absent" \
    "$([ -e "$TMP/escape.control" ] && printf present || printf absent)"
case_end

case_begin "symlinked-control-dir-rejected" "hooks/workflow-state/state-io/control-dir.js"
# A <sid>.control that is a symlink to an outside directory is a traversal: the
# writer path and the CLI must refuse it, and nothing may land outside. The
# detail plan does not spell this out; refusal is the fail-closed reading.
S="20260601-120004"
ESC="$TMP/escape-target"
mkdir -p "$ESC"
MSYS=winsymlinks:nativestrict ln -s "$ESC" "$CLAUDE_WORKFLOW_DIR/$S.control" 2>/dev/null || true
if [ ! -L "$CLAUDE_WORKFLOW_DIR/$S.control" ]; then
    skip "symlinked-control-dir-rejected (platform cannot create a symlink here)"
else
    check "a forWrite controlPath through a symlinked control dir throws" \
        "THREW" "$(res path-write "$S" detail-plan-terminal.txt)"
    check "a read controlPath through a symlinked control dir throws" \
        "THREW" "$(res path "$S" detail-plan-terminal.txt)"
    SYM_RC="$(bash "$CLI" --session "$S" --file detail-plan-terminal.txt --for-write >/dev/null 2>"$TMP/cli.err"; printf '%s' "$?")"
    check "the CLI refuses the symlinked control dir" "nonzero" \
        "$([ "$SYM_RC" = "0" ] && printf zero || printf nonzero)"
    check "the symlink was left in place, not replaced" "link" \
        "$([ -L "$CLAUDE_WORKFLOW_DIR/$S.control" ] && printf link || printf other)"
    check "nothing was created in the outside directory" "0" \
        "$(find "$ESC" -mindepth 1 2>/dev/null | wc -l | tr -d ' ')"
fi
rm -f "$CLAUDE_WORKFLOW_DIR/$S.control" 2>/dev/null || true
case_end

case_begin "plans-dir-import-allowlist" "hooks/workflow-state/state-io/control-dir.js"
# Step 2-4: these readers switch to the control side and drop the plans-dir
# resolver entirely, so none of them can reach a control file by the old path.
for F in hooks/workflow-state/evidence-resolver.js \
         hooks/workflow-state/state-io/review-tests.js \
         hooks/stop-final-report-guard.js \
         hooks/block-memory-direct.js \
         hooks/lib/handoff-artifact.js \
         hooks/lib/worktree-cleanup-marker.js \
         hooks/lib/supervisor-state-writer/shared.js; do
    check "$F no longer imports getWorkflowPlansDir" "0" \
        "$(grep -c 'getWorkflowPlansDir' "$AGENTS_DIR/$F" 2>/dev/null | tr -d ' ')"
done
# issue-close-write-outcome.js read the env var directly rather than importing.
check "bin/issue-close-write-outcome.js no longer reads WORKFLOW_PLANS_DIR" "0" \
    "$(grep -c 'WORKFLOW_PLANS_DIR' "$AGENTS_DIR/bin/issue-close-write-outcome.js" 2>/dev/null | tr -d ' ')"
case_end

echo ""
echo "=== Results: $PASS passed, $FAIL failed, $SKIP skipped ==="
[ "$FAIL" -eq 0 ]
