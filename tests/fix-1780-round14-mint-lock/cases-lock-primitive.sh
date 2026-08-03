#!/usr/bin/env bash
# Part of tests/fix-1780-round14-mint-lock.sh (rules/coding/file-split.md).
# THE MUTEX ITSELF — hooks/lib/off-clearance-mint-lock.js.
#
# Everything the round-14 HIGH fix rests on is the claim that this module is a
# real mutual-exclusion primitive. If any one of these properties is missing the
# fix is decorative:
#
#   exclusivity  — a second acquire while held must FAIL, not succeed and not hang
#   bounded wait — it must fail within the caller's budget (the shim runs inline
#                  in an interactive PreToolUse hook; an unbounded wait there is
#                  a session freeze, which is why the shim passes 1000ms and the
#                  mint 5s)
#   release      — release must actually free it, or the FIRST real contention
#                  wedges the SID until the 24h transient sweep
#   fail-closed  — a non-EEXIST fault (unwritable/absent dir) must return null
#                  PROMPTLY, not burn the whole budget and not return a lock
#                  object that never existed
#   idempotence  — release(null) and double-release must not throw, because
#                  callers release in a `finally` where a throw would replace the
#                  real error with a bogus one
#
# The lock is deliberately exercised through the module's OWN lockPathFor(), and
# separately against a hard-coded literal, so a rename of the suffix cannot make
# these pass while the on-disk name silently drifts away from the SSOT that
# protects it (that cross-check lives in ./cases-lock-protected.sh).

run_L_lock_primitive() {
    local tmp tn out
    tmp=$(make_tmp); tn=$(node_path "$tmp")

    out=$("$RWT" 40 node -e '
"use strict";
const fs = require("fs"), path = require("path");
const M = require(process.argv[1]);
const dir = process.argv[2];
const tok = path.join(dir, "mintlocksid.off-clearance");
const lp = M.lockPathFor(tok);

// L1 — a fresh acquire succeeds and materializes the lock at the path the
// module itself advertises (both participants derive the SAME name from the
// bare token path; if lockPathFor and the created file ever diverge, two
// processes would take two different locks and both enter the section).
const a = M.acquireMintLock(tok, 200, 20);
console.log("L1_acquired=" + (a ? "yes" : "no"));
console.log("L1_pathmatch=" + (a && a.lockPath === lp ? "yes" : "no"));
console.log("L1_onodisk=" + (fs.existsSync(lp) ? "yes" : "no"));
console.log("L1_suffix=" + (lp === tok + ".mint.lock.tmp" ? "yes" : "no"));

// L2 — EXCLUSIVITY + BOUNDED WAIT. Second acquire while held must return null,
// and only after genuinely waiting out the budget (proving it polls rather than
// giving up instantly, which would make real contention a coin flip).
const t0 = Date.now();
const b = M.acquireMintLock(tok, 300, 20);
const waited = Date.now() - t0;
console.log("L2_second=" + (b ? "acquired" : "null"));
// 240 rather than 300: the bound only has to separate "polled until the budget"
// from "gave up instantly", and Atomics.wait may return marginally early per
// poll. A tighter bound would buy no signal and would flake.
console.log("L2_waited_budget=" + (waited >= 240 ? "yes" : "no"));
console.log("L2_bounded=" + (waited < 5000 ? "yes" : "no"));
console.log("L2_waited_ms=" + waited);

// L3 — release frees BOTH the fd and the on-disk name.
M.releaseMintLock(a);
console.log("L3_released=" + (fs.existsSync(lp) ? "no" : "yes"));

// L4 — and the next acquire immediately succeeds (no wedge).
const t1 = Date.now();
const c = M.acquireMintLock(tok, 1000, 20);
console.log("L4_reacquired=" + (c ? "yes" : "no"));
// Generous vs the 1000ms budget: what must not happen is the acquire BLOCKING
// for the budget (i.e. release did not really free the lock).
console.log("L4_immediate=" + (Date.now() - t1 < 600 ? "yes" : "no"));
M.releaseMintLock(c);

// L5 — idempotence, both spellings. Callers release in `finally`.
let nullRelease = "yes", doubleRelease = "yes";
try { M.releaseMintLock(null); } catch (e) { nullRelease = "no"; }
try { M.releaseMintLock(c); } catch (e) { doubleRelease = "no"; }
console.log("L5_null_noop=" + nullRelease);
console.log("L5_double_noop=" + doubleRelease);

// L5b — releasing a stale handle must NOT delete a lock some OTHER process has
// since taken... this module cannot distinguish that (documented limitation:
// the lock is advisory and single-writer per SID), so what IS asserted is the
// weaker, real contract: the double release above did not throw and did not
// leave a phantom file behind.
console.log("L5_no_phantom=" + (fs.existsSync(lp) ? "no" : "yes"));

// L6 — FAIL-CLOSED FAULT. A token path under a directory that does not exist
// yields ENOENT, not EEXIST. That is not contention, so it must return null
// straight away rather than burn the full budget retrying a call that can never
// succeed (a 5s stall on every mint if it did).
const t2 = Date.now();
const d = M.acquireMintLock(path.join(dir, "no-such-dir", "mintlocksid.off-clearance"), 2000, 20);
const faultMs = Date.now() - t2;
console.log("L6_fault=" + (d ? "acquired" : "null"));
// Well under the 2000ms budget: the point is "did not retry a hopeless call
// until the deadline", not a precise latency figure.
console.log("L6_prompt=" + (faultMs < 1000 ? "yes" : "no"));
console.log("L6_fault_ms=" + faultMs);
' "$LOCK_MOD_NODE" "$tn" 2>&1)

    assert_eq "L1 fresh acquire succeeds"                         "yes"    "$(field L1_acquired "$out")"
    assert_eq "L1 handle path == lockPathFor(tokenPath)"          "yes"    "$(field L1_pathmatch "$out")"
    assert_eq "L1 lock file materialized on disk"                 "yes"    "$(field L1_onodisk "$out")"
    assert_eq "L1 lock name is <token>.mint.lock.tmp (SSOT shape)" "yes"   "$(field L1_suffix "$out")"
    assert_eq "L2 second acquire while held is refused"           "null"   "$(field L2_second "$out")"
    assert_eq "L2 refusal waited out the caller's budget"         "yes"    "$(field L2_waited_budget "$out")"
    assert_eq "L2 wait is bounded (no hang in a PreToolUse hook)" "yes"    "$(field L2_bounded "$out")"
    assert_eq "L3 release removes the lock file"                  "yes"    "$(field L3_released "$out")"
    assert_eq "L4 acquire after release succeeds"                 "yes"    "$(field L4_reacquired "$out")"
    assert_eq "L4 post-release acquire is immediate (no wedge)"   "yes"    "$(field L4_immediate "$out")"
    assert_eq "L5 releaseMintLock(null) is a no-op"               "yes"    "$(field L5_null_noop "$out")"
    assert_eq "L5 double release does not throw"                  "yes"    "$(field L5_double_noop "$out")"
    assert_eq "L5 no phantom lock file left behind"               "yes"    "$(field L5_no_phantom "$out")"
    assert_eq "L6 non-EEXIST fault fails closed (null)"           "null"   "$(field L6_fault "$out")"
    assert_eq "L6 fault returns promptly, not after the budget"   "yes"    "$(field L6_prompt "$out")"

    # L7 — CROSS-PROCESS exclusivity. The in-process cases above share one fd
    # table; a lock that is only exclusive within a process would still let a
    # real mint and a real shim (two OS processes) interleave. A background
    # holder proves the exclusion is enforced by the filesystem.
    local tok_node="$tn/mintlocksid.off-clearance" holder_out contender
    "$RWT" 30 node -e '
const M = require(process.argv[1]);
const l = M.acquireMintLock(process.argv[2], 200, 20);
if (!l) { console.log("HOLDER_FAILED"); process.exit(1); }
// hold across a real process boundary, then release
setTimeout(function () { M.releaseMintLock(l); }, 2500);
console.log("HELD");
' "$LOCK_MOD_NODE" "$tok_node" >"$tmp/holder.log" 2>&1 &
    local holder_pid=$!
    # wait for the holder to actually take it (bounded)
    local i=0
    while [ $i -lt 60 ]; do
        [ -e "$tmp/mintlocksid.off-clearance.mint.lock.tmp" ] && break
        sleep 0.05; i=$((i + 1))
    done
    contender=$("$RWT" 20 node -e '
const M = require(process.argv[1]);
const l = M.acquireMintLock(process.argv[2], 300, 20);
console.log("CONTENDER=" + (l ? "acquired" : "null"));
if (l) M.releaseMintLock(l);
' "$LOCK_MOD_NODE" "$tok_node" 2>&1)
    holder_out=$(cat "$tmp/holder.log" 2>/dev/null)
    assert_eq "L7 a lock held by another PROCESS refuses the contender" \
        "CONTENDER=null" "$(printf '%s' "$contender" | tr -d '\r\n')"
    wait "$holder_pid" 2>/dev/null
    assert_has "L7 background holder really acquired the lock" "HELD" "$holder_out"
    assert_eq  "L7 holder released on exit (lock free again)" "no" \
        "$(exists_str "$tmp/mintlocksid.off-clearance.mint.lock.tmp")"

    rm -rf "$tmp"
}
