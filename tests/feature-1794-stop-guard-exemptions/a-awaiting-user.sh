# a-awaiting-user.sh — A1-A10: the #1685 awaiting-user primitive (no TTL,
# consumed on read by C4). A10 covers precedence masking — the marker must not be
# consumed while an earlier-precedence exemption wins. A11 (marker-write I/O
# fault injection) lives in f-fault-injection.sh next to its background-work
# twin. Sourced by tests/feature-1794-stop-guard-exemptions.sh.

AU_START='echo "<<WORKFLOW_AWAITING_USER: waiting for the user to pick an option>>"'
AU_END='echo "<<WORKFLOW_AWAITING_USER_END: user replied>>"'

# ---------------------------------------------------------------------------
# A1: sentinel through the real workflow-mark dispatch creates the marker.
#     Payload carries reason + set_at and MUST NOT carry expires_at (no TTL).
# ---------------------------------------------------------------------------
run_A1() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_mark "$tn" "a1sid" "$AU_START"
    if [ ! -f "$tmp/a1sid.awaiting-user" ]; then
        fail "A1: AWAITING_USER did not create <sid>.awaiting-user (rc=$MARK_RC, out=$MARK_OUT)"
        rm -rf "$tmp" 2>/dev/null || true; return
    fi
    out=$(P="$(node_path "$tmp/a1sid.awaiting-user")" "$RWT" 15 node -e "
const m = JSON.parse(require('fs').readFileSync(process.env.P, 'utf8'));
const ok = typeof m.reason === 'string' && m.reason.length > 0 &&
  typeof m.set_at === 'string' && !('expires_at' in m);
process.stdout.write(ok ? 'OK' : 'BAD:' + JSON.stringify(m));" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "A1: AWAITING_USER writes {reason,set_at} with NO expires_at (TTL-free primitive)"
    else
        fail "A1: marker payload wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# A2: with the marker present, C4 exits 0, does not block, records no finding
# ---------------------------------------------------------------------------
run_A2() {
    local tmp tn ok
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "a2sid"
    run_mark "$tn" "a2sid" "$AU_START"
    run_c4 "$tn" "a2sid"
    ok=0
    no_new_finding "$tmp" "a2sid" && ok=1
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] && [ "$ok" -eq 1 ]; then
        pass "A2: awaiting-user marker suppresses the C4 block and the finding record"
    else
        fail "A2: expected silent exit 0 with no finding (rc=$C4_RC, out=$C4_OUT, no_finding=$ok)"
    fi
}

# ---------------------------------------------------------------------------
# A3 (consume-on-read proof): first C4 run is exempt AND deletes the marker;
#     an immediate second run on the same session blocks. Single-turn semantics.
# ---------------------------------------------------------------------------
run_A3() {
    local tmp tn first_rc first_out gone
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "a3sid"
    run_mark "$tn" "a3sid" "$AU_START"
    run_c4 "$tn" "a3sid"; first_rc="$C4_RC"; first_out="$C4_OUT"
    gone=0
    [ ! -f "$tmp/a3sid.awaiting-user" ] && gone=1
    run_c4 "$tn" "a3sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$first_rc" -eq 0 ] && [ -z "$first_out" ]; then
        pass "A3a: first C4 run is exempt (silent exit 0)"
    else
        fail "A3a: expected silent exit 0 on the first run (rc=$first_rc, out=$first_out)"
    fi
    if [ "$gone" -eq 1 ]; then
        pass "A3b: the marker file is consumed (deleted) by that first C4 run"
    else
        fail "A3b: marker survived the C4 run — consume-on-read did not happen"
    fi
    if [ "$C4_RC" -eq 2 ] && echo "$C4_OUT" | grep -q '"decision":"block"'; then
        pass "A3c: the second C4 run blocks — the exemption does not apply twice"
    else
        fail "A3c: expected decision:block + exit 2 on the second run (rc=$C4_RC, out=$C4_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# A4: AWAITING_USER_END deletes the marker; repeating it is idempotent
# ---------------------------------------------------------------------------
run_A4() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_mark "$tn" "a4sid" "$AU_START"
    run_mark "$tn" "a4sid" "$AU_END"
    if [ -f "$tmp/a4sid.awaiting-user" ]; then
        fail "A4a: AWAITING_USER_END did not remove the marker"
    else
        pass "A4a: AWAITING_USER_END removes the marker"
    fi
    run_mark "$tn" "a4sid" "$AU_END"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$MARK_RC" -eq 0 ]; then
        pass "A4b: a second AWAITING_USER_END with no marker present is idempotent (exit 0)"
    else
        fail "A4b: repeated END was not idempotent (rc=$MARK_RC, out=$MARK_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# A5: sentinel recognition for AWAITING_USER / AWAITING_USER_END + near-miss
# ---------------------------------------------------------------------------
run_A5() {
    local out
    out=$("$RWT" 15 node -e "
const p = require('$PATTERNS_NODE');
const start = 'echo \"<<WORKFLOW_AWAITING_USER: need an answer>>\"';
const end = 'echo \"<<WORKFLOW_AWAITING_USER_END: answered>>\"';
const bare = 'echo \"<<WORKFLOW_AWAITING_USER>>\"';
const ok = p.isSentinel(start) && p.isStrictSentinel(start) &&
  p.isSentinel(end) && p.isStrictSentinel(end) &&
  p.isSentinel(bare) && !p.isStrictSentinel(bare);
process.stdout.write(ok ? 'OK' : 'BAD');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "A5: AWAITING_USER/_END are strict sentinels; the reasonless form is LOOKSLIKE-only"
    else
        fail "A5: sentinel registration incomplete; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# A6: cleanupZombies sweeps an 8-day-old .awaiting-user and spares a fresh one
# ---------------------------------------------------------------------------
run_A6() {
    local tmp tn old_gone=0 fresh_kept=0
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_mark "$tn" "a6-old" "$AU_START"
    run_mark "$tn" "a6-fresh" "$AU_START"
    age_file "$tmp/a6-old.awaiting-user" 8
    CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 20 node -e "
require('$STATEIO_NODE').cleanupZombies();" >/dev/null 2>&1
    [ ! -f "$tmp/a6-old.awaiting-user" ] && old_gone=1
    [ -f "$tmp/a6-fresh.awaiting-user" ] && fresh_kept=1
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$old_gone" -eq 1 ] && [ "$fresh_kept" -eq 1 ]; then
        pass "A6: cleanupZombies removes an 8-day-old .awaiting-user and keeps a fresh one"
    else
        fail "A6: sweep wrong (old_gone=$old_gone, fresh_kept=$fresh_kept)"
    fi
}

# ---------------------------------------------------------------------------
# A7 (security): hostile session ids never reach the filesystem. The marker path
#     is built by string concatenation onto the workflow dir, so a session id
#     carrying `../`, a path separator, an absolute path or a NUL byte would
#     otherwise write outside it. Every hostile id must be refused with a fatal
#     signal and write nothing anywhere under the fixture root.
# ---------------------------------------------------------------------------
run_A7() {
    local out
    out=$(hostile_sid_probe \
        "$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/awaiting-user.js" \
        "handleAwaitingUser" ".awaiting-user" "$AU_START")
    if [ "$out" = "OK" ]; then
        pass "A7: handleAwaitingUser refuses every hostile session id and writes nothing outside the workflow dir"
    else
        fail "A7: session-id guard leaked; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# A7b (security, END side — CPR-5): the cancel path builds the same path from
#     the same session id and must carry the same guard.
# ---------------------------------------------------------------------------
run_A7b() {
    local out
    out=$(hostile_sid_probe \
        "$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/awaiting-user.js" \
        "handleAwaitingUser" ".awaiting-user" "$AU_END")
    if [ "$out" = "OK" ]; then
        pass "A7b: the AWAITING_USER_END path carries the identical hostile-session-id guard"
    else
        fail "A7b: END-side session-id guard leaked; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# A8 (fail-open): consumeAwaitingUser is documented to never throw. Three
#     unlink-failure shapes are exercised — the marker already gone (ENOENT
#     race), unlinkSync raising a permission error, and the marker path being a
#     directory (real EPERM/EISDIR, no monkeypatching). None may throw, and the
#     invalid-sid early return must stay silent too.
# ---------------------------------------------------------------------------
run_A8() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/a8-dir.awaiting-user"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
const fs = require('fs');
const sm = require('$_AGENTS_DIR_NODE/hooks/lib/session-markers.js');
const problems = [];
const noThrow = (label, fn) => {
  try { const r = fn(); if (r !== undefined) problems.push(label + ':returned-' + String(r)); }
  catch (e) { problems.push(label + ':threw(' + (e && e.code ? e.code : e.message) + ')'); }
};
// 1. marker absent (already consumed by a concurrent Stop)
noThrow('enoent', () => sm.consumeAwaitingUser('a8-absent'));
// 2. marker path is a directory -> unlinkSync raises EPERM/EISDIR for real
noThrow('isdir', () => sm.consumeAwaitingUser('a8-dir'));
if (!sm.isAwaitingUser('a8-dir')) problems.push('isdir:marker-vanished');
// 3. hostile / invalid sid -> silent early return, no throw, no fs touch
for (const bad of ['../../evil', 'a/b', '', '   ', 'a\\u0000b']) {
  noThrow('badsid[' + JSON.stringify(bad) + ']', () => sm.consumeAwaitingUser(bad));
}
// 4. unlinkSync itself failing with a permission error
const realUnlink = fs.unlinkSync;
fs.unlinkSync = () => { const e = new Error('denied'); e.code = 'EACCES'; throw e; };
noThrow('eacces', () => sm.consumeAwaitingUser('a8-perm'));
fs.unlinkSync = realUnlink;
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "A8: consumeAwaitingUser never throws — ENOENT, EACCES, a directory marker and hostile sids all fail open"
    else
        fail "A8: consumeAwaitingUser is not fail-open; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# A9 (fail-open, end-to-end): the same unlink failure seen through the real C4
#     hook. A marker that cannot be consumed must still exempt this Stop and
#     must not surface as a crash — exit 0, no output, empty stderr.
# ---------------------------------------------------------------------------
run_A9() {
    local tmp tn rc out errf err
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "a9sid"
    mkdir -p "$tmp/a9sid.awaiting-user"
    errf="$(mktemp)"
    out=$(echo '{"stop_hook_active":false,"session_id":"a9sid","transcript_path":""}' \
        | CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" AGENTS_CONFIG_DIR="$_AGENTS_DIR_NODE" \
          "$RWT" 25 node "$(node_path "$GUARD_C4")" 2>"$errf")
    rc=$?
    err="$(cat "$errf" 2>/dev/null)"
    rm -f "$errf" 2>/dev/null || true
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$rc" -eq 0 ] && [ -z "$out" ] && [ -z "$err" ]; then
        pass "A9: C4 stays exempt and silent (exit 0, empty stderr) when the marker cannot be consumed"
    else
        fail "A9: expected a silent fail-open C4 (rc=$rc, out=$out, stderr=$err)"
    fi
}

# ---------------------------------------------------------------------------
# A10 (precedence masking — the consume side effect must not fire while masked):
#     `awaiting-user` is the only C4_EXEMPTIONS row whose predicate MUTATES state
#     (it deletes the marker the moment it decides). firstExemption is
#     first-match-wins, so when an EARLIER row (workflow-off, next-step-paused,
#     pre-workflow-init, background-work) already holds, the awaiting-user
#     predicate must never be evaluated — and therefore the declaration must
#     survive intact and still be spendable on a LATER Stop.
#
#     Without this pair, a refactor that evaluated all predicates before picking
#     a winner (or that hoisted the consume out of the predicate) would burn the
#     user's single-turn declaration on a Stop it never actually covered — the
#     user then gets a spurious C4 block on the turn they were waiting for.
#
#     A10a — unit half: for each of the four earlier rows, drive firstExemption
#            with that row true AND isAwaitingUser true, and assert the earlier
#            id wins with the consume spy NEVER called; then flip the earlier row
#            off and assert awaiting-user wins WITH the spy called exactly once.
#     A10b — end-to-end half through the real C4 hook: both a live
#            background-work marker and an awaiting-user marker on disk.
#              run 1 -> exempt, awaiting-user marker STILL PRESENT (untouched)
#              (clear background-work)
#              run 2 -> exempt, awaiting-user marker NOW CONSUMED
#              run 3 -> blocks (nothing left to spend)
# ---------------------------------------------------------------------------
run_A10() {
    local out tmp tn present_after_mask consumed_after_clear
    # --- A10a: unit precedence, consume spy ---
    out=$("$RWT" 20 node -e "
const { firstExemption } = require('$_AGENTS_DIR_NODE/hooks/stop-premature-stop-guard.js');
const problems = [];
// baseline: only awaiting-user holds
const base = () => ({
  isWorkflowOff: () => false, isNextStepPaused: () => false, isWorkflowStarted: () => true,
  isBackgroundWorkInFlight: () => false, isAwaitingUser: () => true,
});
const earlier = [
  ['workflow-off',      (d) => { d.isWorkflowOff = () => true; }],
  ['next-step-paused',  (d) => { d.isNextStepPaused = () => true; }],
  ['pre-workflow-init', (d) => { d.isWorkflowStarted = () => false; }],
  ['background-work',   (d) => { d.isBackgroundWorkInFlight = () => true; }],
];
for (const [id, arm] of earlier) {
  const deps = base();
  let consumed = 0;
  deps.consumeAwaitingUser = () => { consumed += 1; };
  arm(deps);
  const hit = firstExemption('session', { sid: 's' }, deps, []);
  if (hit !== id) problems.push(id + ':winner=' + hit);
  if (consumed !== 0) problems.push(id + ':consumed-while-masked(' + consumed + ')');
}
// unmasked: awaiting-user wins and consumes exactly once
const deps = base();
let consumed = 0;
deps.consumeAwaitingUser = () => { consumed += 1; };
const hit = firstExemption('session', { sid: 's' }, deps, []);
if (hit !== 'awaiting-user') problems.push('unmasked:winner=' + hit);
if (consumed !== 1) problems.push('unmasked:consumed=' + consumed);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "A10a: every earlier-precedence row wins WITHOUT evaluating the awaiting-user predicate (consume never fires while masked)"
    else
        fail "A10a: precedence/consume-masking broken; got '${out:-<err>}'"
    fi

    # --- A10b: the same masking through the real C4 hook ---
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "a10sid"
    write_bg_marker "$tmp" "a10sid" "3600000"
    run_mark "$tn" "a10sid" "$AU_START"
    if [ ! -f "$tmp/a10sid.awaiting-user" ] || [ ! -f "$tmp/a10sid.background-work" ]; then
        fail "A10b: setup failed — both markers must exist before the first Stop"
        rm -rf "$tmp" 2>/dev/null || true; return
    fi
    # run 1: background-work wins; awaiting-user must be untouched
    run_c4 "$tn" "a10sid"
    present_after_mask=0
    [ -f "$tmp/a10sid.awaiting-user" ] && present_after_mask=1
    if [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] && [ "$present_after_mask" -eq 1 ]; then
        pass "A10b: with background-work also in flight, C4 is exempt and the awaiting-user marker survives unconsumed"
    else
        fail "A10b: expected silent exit 0 with the marker intact (rc=$C4_RC, out=$C4_OUT, marker_present=$present_after_mask)"
    fi
    # run 2: clear the masking exemption -> the declaration is now spent
    rm -f "$tmp/a10sid.background-work"
    run_c4 "$tn" "a10sid"
    consumed_after_clear=0
    [ ! -f "$tmp/a10sid.awaiting-user" ] && consumed_after_clear=1
    if [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] && [ "$consumed_after_clear" -eq 1 ]; then
        pass "A10c: once the masking exemption clears, the SAME declaration still exempts the next Stop and is consumed then"
    else
        fail "A10c: expected the unmasked run to exempt and consume (rc=$C4_RC, out=$C4_OUT, consumed=$consumed_after_clear)"
    fi
    # run 3: nothing left -> the block returns
    run_c4 "$tn" "a10sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C4_RC" -eq 2 ] && echo "$C4_OUT" | grep -q '"decision":"block"'; then
        pass "A10d: the third Stop blocks — the declaration was spent exactly once across the masked/unmasked sequence"
    else
        fail "A10d: expected decision:block + exit 2 on the third run (rc=$C4_RC, out=$C4_OUT)"
    fi
}
