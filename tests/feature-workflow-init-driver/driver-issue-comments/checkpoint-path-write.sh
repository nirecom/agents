#!/bin/bash
# tests/feature-workflow-init-driver/driver-issue-comments/checkpoint-path-write.sh
# Tests: bin/workflow/lib/workflow-init/checkpoint.js, bin/workflow/workflow-init-driver
# Tags: workflow-init, driver, checkpoint, path-separator, win32, fail-closed, scope:issue-specific

# K1-K9 (#2063) — the two unguarded halves of the CHECKPOINT= observable: the
# win32-only separator rewrite in checkpointPath (K1-K3), and the fail-closed arm of
# safeWriteCheckpoint at all four driver call sites (K4-K9).

# TL3 gap: a real agent pasting CHECKPOINT= into a real shell, and permission-based
# (rather than EISDIR) write failures, are not observable here. Mitigated at
# WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category:
# skill-orchestration. Injection seams: ../HARNESS-CONTRACT.md

set -u
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"
require_sut

CKPT_JS="$AGENTS_DIR/bin/workflow/lib/workflow-init/checkpoint.js"

# Force the failure by pre-creating the checkpoint's own path as a DIRECTORY:
# writeCheckpoint's mkdirSync of the parent still succeeds and its writeFileSync
# raises EISDIR — a path the process may traverse but not write, which is the real
# shape of the failure rather than a stubbed throw. Mirrors what checkpointPath()
# computes, without importing it.
break_checkpoint_write() { mkdir -p "$PLANS/$SID-wi-checkpoint.json"; }

# --- K1: the rewrite is applied on win32 and withheld on POSIX ----------------------
# One assertion, two contracts, because they are the two arms of ONE branch
# (`path.sep === "\\"`). Asserting "no backslash" unconditionally would demand that
# POSIX corrupt a legal filename; asserting "unchanged" unconditionally would let the
# win32 rewrite be deleted. The probe picks the arm from path.sep — the predicate the
# source itself branches on — and reports a verdict either way.
K1_OUT="$(node -e '
const path = require("path");
const { checkpointPath } = require(process.argv[1]);
// Segments separated by BACKSLASHES on both platforms: win32 path.join normalizes
// them to separators, POSIX keeps them as ordinary name bytes.
const plansDir = path.sep === "\\" ? "C:\\plans\\wi\\dir" : "/plans\\wi\\dir";
const out = checkpointPath(plansDir, "sid-k1");
const joined = path.join(plansDir, "sid-k1-wi-checkpoint.json");
const win32 = path.sep === "\\";
const verdict = win32
  ? (out.indexOf("\\") === -1 ? "ok" : "backslash-leaked")
  : (out === joined ? "ok" : "rewritten-on-posix");
process.stdout.write("PLATFORM=" + (win32 ? "win32" : "posix") + "\nVERDICT=" + verdict + "\nOUT=" + out + "\n");
' "$CKPT_JS")"
K1_PLATFORM="$(printf '%s\n' "$K1_OUT" | sed -n 's/^PLATFORM=//p')"
K1_VERDICT="$(printf '%s\n' "$K1_OUT" | sed -n 's/^VERDICT=//p')"
K1_PATH="$(printf '%s\n' "$K1_OUT" | sed -n 's/^OUT=//p')"
if [ "$K1_VERDICT" = "ok" ]; then
    pass "K1: checkpointPath honours the win32-only separator rewrite (platform=$K1_PLATFORM)"
else
    fail "K1: platform=$K1_PLATFORM verdict=$K1_VERDICT path='$K1_PATH'"
fi

# --- K2: on win32 the rewrite CONVERTED, it did not merely avoid backslashes --------
# K1's win32 arm is satisfied by a function returning the empty string. This pins that
# every segment the caller supplied survives, joined by forward slashes.
if [ "$K1_PLATFORM" = "win32" ]; then
    case "$K1_PATH" in
        */plans/wi/dir/sid-k1-wi-checkpoint.json) pass "K2: every backslash segment survives as a forward-slash segment" ;;
        *) fail "K2: segments lost or mis-joined: '$K1_PATH'" ;;
    esac
else
    # Not a skip: the POSIX contract is that the path is left ALONE, which K1 asserted.
    pass "K2: (posix) no rewrite is expected, so there is no conversion to verify"
fi

# --- K3: the rewritten path is still a working path for the fs APIs -----------------
# The rewrite serves a shell reader and must not cost the file system. A path that
# reads well but cannot be written or read back is a worse defect than the backslash
# it removed, and nothing else in the suite would notice.
K3_OUT="$(node -e '
const os = require("os");
const fs = require("fs");
const path = require("path");
const { checkpointPath, writeCheckpoint, readCheckpoint } = require(process.argv[1]);
const root = fs.mkdtempSync(path.join(os.tmpdir(), "wid-k3-"));
// Nested + not-yet-existing: writeCheckpoint must mkdir the parents of the value it
// was handed, the operation a broken separator would break first.
const p = checkpointPath(path.join(root, "nested", "deeper"), "sid-k3");
try {
  writeCheckpoint(p, "sid-k3", "write-context", null, { issues: [4200] });
} catch (e) {
  process.stdout.write("write-threw:" + (e.code || e.message) + "\n");
  process.exit(0);
}
const back = readCheckpoint(p);
if (back.error) { process.stdout.write("read-error:" + back.error + "\n"); process.exit(0); }
process.stdout.write(String(back.data.state.issues[0]) + "\n");
' "$CKPT_JS")"
assert_count "K3: a checkpoint written at the rewritten path reads back intact" "4200" "$K3_OUT"

# --- K4: the pipeline-complete write site fails closed ------------------------------
setup_case wid-k4
mock_issue 4400 OPEN "type:task"
set_wip 4400 same
break_checkpoint_write
run_driver '#4400'
assert_kv "K4: an unwritable checkpoint blocks the completed pipeline" ACTION blocked
assert_kv "K4: the block names the checkpoint write as the cause" REASON checkpoint_write_failed
assert_single_action_line "K4: exactly one directive line is emitted"
assert_no_uncaught "K4: the EISDIR never surfaces as an uncaught throw"
teardown_case

# --- K5: the ask write site fails closed --------------------------------------------
# CPR-ORTH: the ask arm writes the checkpoint BEFORE emitting ask_user, so a failure
# there must replace the ask, not accompany it — an ask_user whose checkpoint does not
# exist strands the session with an unresumable CHECKPOINT= value.
setup_case wid-k5
mock_issue 4500 CLOSED "type:task"
break_checkpoint_write
run_driver '#4500'
assert_kv "K5: an unwritable checkpoint blocks the pending ask" ACTION blocked
assert_kv "K5: the block names the checkpoint write as the cause" REASON checkpoint_write_failed
assert_single_action_line "K5: exactly one directive line is emitted"
assert_no_uncaught "K5: the EISDIR never surfaces as an uncaught throw"
teardown_case

# --- K6: the NON_GITHUB write site fails closed -------------------------------------
# The third call site, on the short-circuit path that never enters the phase loop.
setup_case wid-k6
break_checkpoint_write
export NON_GITHUB=1
run_driver
unset NON_GITHUB
assert_kv "K6: an unwritable checkpoint blocks the NON_GITHUB short circuit" ACTION blocked
assert_kv "K6: the block names the checkpoint write as the cause" REASON checkpoint_write_failed
assert_single_action_line "K6: exactly one directive line is emitted"
assert_no_uncaught "K6: the EISDIR never surfaces as an uncaught throw"
teardown_case

# --- K7: the same run with a WRITABLE checkpoint reports done -----------------------
# The classifier counterpart of K4-K6 (test-design.md "Classifier / guard cases"): a
# driver emitting checkpoint_write_failed unconditionally would satisfy all three
# blocked cases. This is the sanctioned input that must NOT be blocked, and the only
# reason K4's fixture can be read as "the pre-created directory did it".
setup_case wid-k7
mock_issue 4700 OPEN "type:task"
set_wip 4700 same
run_driver '#4700'
assert_kv "K7: a writable checkpoint completes the pipeline" ACTION done
K7_CKPT="$(get_kv CHECKPOINT)" || true
if [ -f "$K7_CKPT" ]; then
    pass "K7: the emitted CHECKPOINT= value names a file that exists"
else
    fail "K7: no file at the emitted CHECKPOINT='$K7_CKPT'"
fi
# The end-to-end form of K1: the value an agent pastes into a shell command carries no
# escape character. Unit-level K1 cannot see a driver that rebuilds the path itself.
if [ "$K1_PLATFORM" = "win32" ]; then
    case "$K7_CKPT" in
        *\\*) fail "K7: the emitted CHECKPOINT= value carries a backslash: '$K7_CKPT'" ;;
        *) pass "K7: the emitted CHECKPOINT= value is backslash-free on win32" ;;
    esac
else
    pass "K7: (posix) separators are already shell-safe in the emitted value"
fi
teardown_case

# --- K8: the ordinary `result.blocked` write site fails closed ----------------------
# The fourth safeWriteCheckpoint call site, and the only one whose return value the
# driver discards: it writes the checkpoint fire-and-forget, then reports the phase's
# OWN reason. An agent handed `REASON=sub_issues_fetch_failed` plus a CHECKPOINT= that
# was never persisted resumes against a file that does not exist — the same
# unresumable-session failure K5 exists to prevent, so C18 obliges this site to report
# the write failure that outranks it. Reached via meta-classify (`blocked` without
# `noCheckpoint`), a phase distinct from K4-K7's pipeline-complete/ask/NON_GITHUB arms.
setup_case wid-k8
mock_issue 4800 OPEN "meta"
mock_sub_issues_rc 4800 1
break_checkpoint_write
run_driver '#4800'
assert_kv "K8: an unwritable checkpoint blocks the ordinary blocked arm" ACTION blocked
assert_kv "K8: the block names the checkpoint write as the cause" REASON checkpoint_write_failed
assert_single_action_line "K8: exactly one directive line is emitted"
assert_no_uncaught "K8: the EISDIR never surfaces as an uncaught throw"
teardown_case

# --- K9: the same run with a WRITABLE checkpoint reports the phase's own reason -----
# K7's counterpart for the fourth site (test-design.md "Classifier / guard cases"). It
# pins that the K8 fixture really does drive the driver through the ordinary blocked
# arm, so a red K8 can only mean the discarded return value — never a fixture that
# never reached the site, and never a driver that reports checkpoint_write_failed for
# every block.
setup_case wid-k9
mock_issue 4900 OPEN "meta"
mock_sub_issues_rc 4900 1
run_driver '#4900'
assert_kv "K9: a writable checkpoint reports the phase's own block" ACTION blocked
assert_kv "K9: the reason is the meta-classify failure, not the checkpoint" REASON sub_issues_fetch_failed
K9_CKPT="$(get_kv CHECKPOINT)" || true
if [ -f "$K9_CKPT" ]; then
    pass "K9: the blocked arm persisted the checkpoint it names"
else
    fail "K9: no file at the emitted CHECKPOINT='$K9_CKPT'"
fi
teardown_case

finish
