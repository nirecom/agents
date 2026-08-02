# b-background-work.sh — B1-B13: the #1665 background-work primitive (B9 hostile
# session ids, B10 TTL/payload edge table under a frozen clock, B11 expired-marker
# end-to-end, B12 exact 4h TTL arithmetic, B13 malformed/injected START negative
# path). B15 (marker-write I/O fault injection) lives in f-fault-injection.sh
# next to its awaiting-user twin.
# Sourced by tests/feature-1794-stop-guard-exemptions.sh.

BG_START='echo "<<WORKFLOW_BACKGROUND_WORK_START: monitoring a long subagent dispatch>>"'
BG_END='echo "<<WORKFLOW_BACKGROUND_WORK_END: dispatch finished>>"'

# ---------------------------------------------------------------------------
# B1: START sentinel through the real workflow-mark dispatch creates the
#     marker with expires_at in the future
# ---------------------------------------------------------------------------
run_B1() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_mark "$tn" "b1sid" "$BG_START"
    if [ ! -f "$tmp/b1sid.background-work" ]; then
        fail "B1: BACKGROUND_WORK_START did not create <sid>.background-work (rc=$MARK_RC, out=$MARK_OUT)"
        rm -rf "$tmp" 2>/dev/null || true; return
    fi
    out=$(P="$(node_path "$tmp/b1sid.background-work")" "$RWT" 15 node -e "
const m = JSON.parse(require('fs').readFileSync(process.env.P, 'utf8'));
const future = typeof m.expires_at === 'string' && Date.parse(m.expires_at) > Date.now();
process.stdout.write(future && typeof m.set_at === 'string' ? 'OK' : 'BAD:' + JSON.stringify(m));" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "B1: BACKGROUND_WORK_START writes the marker with a future expires_at"
    else
        fail "B1: marker payload wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# B2: END deletes the marker; a second END with no marker is idempotent
# ---------------------------------------------------------------------------
run_B2() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_mark "$tn" "b2sid" "$BG_START"
    run_mark "$tn" "b2sid" "$BG_END"
    if [ -f "$tmp/b2sid.background-work" ]; then
        fail "B2a: BACKGROUND_WORK_END did not remove the marker"
    else
        pass "B2a: BACKGROUND_WORK_END removes the marker"
    fi
    run_mark "$tn" "b2sid" "$BG_END"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$MARK_RC" -eq 0 ]; then
        pass "B2b: a second BACKGROUND_WORK_END with no marker present is idempotent (exit 0)"
    else
        fail "B2b: repeated END was not idempotent (rc=$MARK_RC, out=$MARK_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# B3: expired marker -> isBackgroundWorkInFlight false (TTL fail-CLOSED)
# ---------------------------------------------------------------------------
run_B3() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_bg_marker "$tmp" "b3sid" "-60000"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 15 node -e "
const { isBackgroundWorkInFlight } = require('$_AGENTS_DIR_NODE/hooks/lib/session-markers.js');
process.stdout.write(isBackgroundWorkInFlight('b3sid') ? 'INFLIGHT' : 'NOT_INFLIGHT');" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "NOT_INFLIGHT" ]; then
        pass "B3: an expired expires_at is fail-CLOSED (not in flight)"
    else
        fail "B3: expected NOT_INFLIGHT for a past expires_at; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# B4: missing expires_at, and non-JSON payload -> both not in flight
# ---------------------------------------------------------------------------
run_B4() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_bg_marker "$tmp" "b4-noexp" "none"
    write_bg_marker "$tmp" "b4-badjson" "badjson"
    out=$(CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 15 node -e "
const { isBackgroundWorkInFlight } = require('$_AGENTS_DIR_NODE/hooks/lib/session-markers.js');
const bad = ['b4-noexp', 'b4-badjson'].filter((s) => isBackgroundWorkInFlight(s) !== false);
process.stdout.write(bad.length ? 'BAD:' + bad.join(',') : 'OK');" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "B4: missing expires_at and unparseable payload both fail CLOSED"
    else
        fail "B4: expected both to be not-in-flight; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# B5: valid marker -> real C4 exits 0, no block, and records no finding
# ---------------------------------------------------------------------------
run_B5() {
    local tmp tn ok
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "b5sid"
    write_bg_marker "$tmp" "b5sid" "3600000"
    run_c4 "$tn" "b5sid"
    ok=0
    no_new_finding "$tmp" "b5sid" && ok=1
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C4_RC" -eq 0 ] && [ -z "$C4_OUT" ] && [ "$ok" -eq 1 ]; then
        pass "B5: background-work marker suppresses the C4 block and the finding record"
    else
        fail "B5: expected silent exit 0 with no finding (rc=$C4_RC, out=$C4_OUT, no_finding=$ok)"
    fi
}

# ---------------------------------------------------------------------------
# B6: valid marker -> real next-step reports ACTION=paused / REASON=background-work-in-flight
# ---------------------------------------------------------------------------
run_B6() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "b6sid"
    write_bg_marker "$tmp" "b6sid" "3600000"
    run_next_step "$tn" "b6sid"
    rm -rf "$tmp" 2>/dev/null || true
    if echo "$NS_OUT" | grep -q '^ACTION=paused$' && echo "$NS_OUT" | grep -q 'background-work-in-flight'; then
        pass "B6: next-step returns ACTION=paused with REASON=background-work-in-flight"
    else
        fail "B6: expected paused/background-work-in-flight; out=$(echo "$NS_OUT" | tr '\n' ' ')"
    fi
}

# ---------------------------------------------------------------------------
# B7: sentinel recognition — START/END are both isSentinel and isStrictSentinel;
#     the reasonless near-miss is recognised (LOOKSLIKE) but NOT strict-valid
# ---------------------------------------------------------------------------
run_B7() {
    local out
    out=$("$RWT" 15 node -e "
const p = require('$PATTERNS_NODE');
const start = 'echo \"<<WORKFLOW_BACKGROUND_WORK_START: x work>>\"';
const end = 'echo \"<<WORKFLOW_BACKGROUND_WORK_END: x done>>\"';
const bare = 'echo \"<<WORKFLOW_BACKGROUND_WORK_START>>\"';
const ok = p.isSentinel(start) && p.isStrictSentinel(start) &&
  p.isSentinel(end) && p.isStrictSentinel(end) &&
  p.isSentinel(bare) && !p.isStrictSentinel(bare);
process.stdout.write(ok ? 'OK' : 'BAD');" 2>/dev/null)
    if [ "$out" = "OK" ]; then
        pass "B7: START/END are strict sentinels; the reasonless bare form is LOOKSLIKE-only"
    else
        fail "B7: sentinel registration incomplete; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# B8: cleanupZombies sweeps an 8-day-old .background-work and spares a fresh one
# ---------------------------------------------------------------------------
run_B8() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    write_bg_marker "$tmp" "b8-old" "3600000"
    write_bg_marker "$tmp" "b8-fresh" "3600000"
    age_file "$tmp/b8-old.background-work" 8
    CLAUDE_WORKFLOW_DIR="$tn" "$RWT" 20 node -e "
require('$STATEIO_NODE').cleanupZombies();" >/dev/null 2>&1
    local old_gone=0 fresh_kept=0
    [ ! -f "$tmp/b8-old.background-work" ] && old_gone=1
    [ -f "$tmp/b8-fresh.background-work" ] && fresh_kept=1
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$old_gone" -eq 1 ] && [ "$fresh_kept" -eq 1 ]; then
        pass "B8: cleanupZombies removes an 8-day-old .background-work and keeps a fresh one"
    else
        fail "B8: sweep wrong (old_gone=$old_gone, fresh_kept=$fresh_kept)"
    fi
}

# ---------------------------------------------------------------------------
# B9 (security): hostile session ids never reach the filesystem — same guard,
#     same probe as A7/A7b on the awaiting-user handler (CPR-5). Both the START
#     and the END command path are driven.
# ---------------------------------------------------------------------------
run_B9() {
    local start_out end_out
    start_out=$(hostile_sid_probe \
        "$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/background-work.js" \
        "handleBackgroundWork" ".background-work" "$BG_START")
    end_out=$(hostile_sid_probe \
        "$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/background-work.js" \
        "handleBackgroundWork" ".background-work" "$BG_END")
    if [ "$start_out" = "OK" ]; then
        pass "B9a: handleBackgroundWork START refuses every hostile session id and writes nothing outside the workflow dir"
    else
        fail "B9a: START-side session-id guard leaked; got '${start_out:-<err>}'"
    fi
    if [ "$end_out" = "OK" ]; then
        pass "B9b: the BACKGROUND_WORK_END path carries the identical hostile-session-id guard"
    else
        fail "B9b: END-side session-id guard leaked; got '${end_out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# B10: the full expires_at edge table for isBackgroundWorkInFlight. B3/B4 cover
#      "expired" and "no expires_at / non-JSON"; this pins the boundary itself
#      plus every malformed-payload shape, with two positive rows so an
#      always-false implementation cannot pass the table.
#
#      The clock is FROZEN (`Date.now` monkeypatched to a captured constant
#      before any row is evaluated) so the three boundary rows are exact rather
#      than "a few ms either side of whenever the assertion happened to run":
#        expires_at === now      -> false  (the check is `<=`, not `<`)
#        expires_at === now - 1  -> false
#        expires_at === now + 1  -> true   (the tightest possible live marker)
#      Without the freeze, wall-clock drift between marker creation and the
#      predicate call makes the `now + 1` row flaky and the `=== now` row a
#      tautology, since it would already be in the past by evaluation time.
# ---------------------------------------------------------------------------
run_B10() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/b10-isdir.background-work"
    out=$(TMPD="$tn" CLAUDE_WORKFLOW_DIR="$tn" WORKFLOW_PLANS_DIR="$tn" "$RWT" 20 node -e "
const fs = require('fs'), path = require('path');
const { isBackgroundWorkInFlight } = require('$_AGENTS_DIR_NODE/hooks/lib/session-markers.js');
const dir = process.env.TMPD;
// Freeze the clock: every row below, and every isBackgroundWorkInFlight() call,
// sees exactly this instant. ISO strings carry ms precision, so +/-1ms round-trips.
const now = Date.now();
Date.now = () => now;
if (Date.now() !== now) { process.stdout.write('BAD:clock-freeze-failed'); process.exit(0); }
const w = (sid, raw) => fs.writeFileSync(path.join(dir, sid + '.background-work'), raw);
const j = (sid, obj) => w(sid, JSON.stringify(obj));
const rows = [];
const add = (sid, want) => rows.push([sid, want]);
// --- boundary (frozen clock: exact, not approximate) ---
j('b10-exact', { set_at: new Date(now).toISOString(), expires_at: new Date(now).toISOString() });
add('b10-exact', false);              // expires_at === now -> expired (<=)
if (Date.parse(JSON.parse(fs.readFileSync(path.join(dir, 'b10-exact.background-work'), 'utf8')).expires_at) !== now) {
  process.stdout.write('BAD:boundary-row-not-exactly-now'); process.exit(0);
}
j('b10-1msago', { expires_at: new Date(now - 1).toISOString() });
add('b10-1msago', false);
j('b10-1msfuture', { expires_at: new Date(now + 1).toISOString() });
add('b10-1msfuture', true);           // 1ms past the boundary -> still in flight
j('b10-future', { expires_at: new Date(now + 3600000).toISOString() });
add('b10-future', true);              // positive anchor
j('b10-future-extra', { expires_at: new Date(now + 3600000).toISOString(), junk: [1, 2], reason: null });
add('b10-future-extra', true);        // positive anchor: unknown fields are tolerated
// --- malformed expires_at ---
j('b10-number', { expires_at: now + 3600000 });
add('b10-number', false);             // number, not an ISO string
j('b10-null', { expires_at: null });
add('b10-null', false);
j('b10-nonsense', { expires_at: 'tomorrow-ish' });
add('b10-nonsense', false);           // unparseable -> NaN
j('b10-empty-str', { expires_at: '' });
add('b10-empty-str', false);
j('b10-nested', { expires_at: { at: new Date(now + 3600000).toISOString() } });
add('b10-nested', false);
// --- malformed payload ---
w('b10-emptyfile', '');
add('b10-emptyfile', false);
w('b10-whitespace', '   \n');
add('b10-whitespace', false);
w('b10-jsonnull', 'null');
add('b10-jsonnull', false);
w('b10-jsonstring', JSON.stringify('just a string'));
add('b10-jsonstring', false);
w('b10-jsonnumber', '42');
add('b10-jsonnumber', false);
j('b10-array', [{ expires_at: new Date(now + 3600000).toISOString() }]);
add('b10-array', false);              // array has no own expires_at
w('b10-truncated', '{\"expires_at\": \"' + new Date(now + 3600000).toISOString());
add('b10-truncated', false);          // torn write / partial JSON
// --- filesystem shapes ---
add('b10-absent', false);             // no marker at all
add('b10-isdir', false);              // marker path is a directory (EISDIR on read)
const problems = rows
  .filter(([sid, want]) => isBackgroundWorkInFlight(sid) !== want)
  .map(([sid, want]) => sid + ':want=' + want);
process.stdout.write(problems.length ? 'BAD:' + problems.join(' ') : 'OK');" 2>&1)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "B10: under a frozen clock, expires_at == now and now-1ms are expired while now+1ms is live; every malformed-payload shape fails CLOSED"
    else
        fail "B10: TTL edge table wrong; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# B11: the fail-CLOSED TTL seen through the real C4 hook — an expired marker
#      must NOT exempt the Stop. B5 is the live-marker half of the pair; without
#      this half a predicate stuck at true would still satisfy B5.
# ---------------------------------------------------------------------------
run_B11() {
    local tmp tn
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    seed_started "$tn" "b11sid"
    write_bg_marker "$tmp" "b11sid" "-60000"
    run_c4 "$tn" "b11sid"
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$C4_RC" -eq 2 ] && echo "$C4_OUT" | grep -q '"decision":"block"'; then
        pass "B11: an expired background-work marker does not exempt C4 — the block still fires"
    else
        fail "B11: expected decision:block + exit 2 for an expired marker (rc=$C4_RC, out=$C4_OUT)"
    fi
}

# ---------------------------------------------------------------------------
# B12: the documented TTL is exactly 4 hours — asserted numerically, not as
#      "some future instant" (which B1 already covers and which a 5-minute or
#      40-hour constant would also satisfy). Both timestamps are read back from
#      the marker the REAL workflow-mark dispatch wrote, so this pins the
#      handler's BACKGROUND_WORK_TTL_MS arithmetic end to end:
#        Date.parse(expires_at) - Date.parse(set_at) === 4 * 60 * 60 * 1000
#      A drift in the constant is a user-visible contract change (rules and the
#      sentinel docs both quote "4h"), so it must fail loudly.
# ---------------------------------------------------------------------------
run_B12() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    run_mark "$tn" "b12sid" "$BG_START"
    if [ ! -f "$tmp/b12sid.background-work" ]; then
        fail "B12: BACKGROUND_WORK_START did not create the marker (rc=$MARK_RC, out=$MARK_OUT)"
        rm -rf "$tmp" 2>/dev/null || true; return
    fi
    out=$(P="$(node_path "$tmp/b12sid.background-work")" "$RWT" 15 node -e "
const m = JSON.parse(require('fs').readFileSync(process.env.P, 'utf8'));
const FOUR_HOURS_MS = 4 * 60 * 60 * 1000;
const setAt = Date.parse(m.set_at), expiresAt = Date.parse(m.expires_at);
if (Number.isNaN(setAt) || Number.isNaN(expiresAt)) {
  process.stdout.write('BAD:unparseable set_at=' + m.set_at + ' expires_at=' + m.expires_at);
} else if (expiresAt - setAt !== FOUR_HOURS_MS) {
  process.stdout.write('BAD:ttl=' + (expiresAt - setAt) + 'ms want=' + FOUR_HOURS_MS + 'ms');
} else {
  process.stdout.write('OK');
}" 2>/dev/null)
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ]; then
        pass "B12: the marker's TTL is exactly 4h (expires_at - set_at === 14400000ms)"
    else
        fail "B12: background-work TTL is not exactly 4h; got '${out:-<err>}'"
    fi
}

# ---------------------------------------------------------------------------
# B13 (negative path, real hook): malformed and injected START forms driven
#      through the REAL workflow-mark dispatch — not the regex in isolation.
#      For every rejected form the workflow dir must be left completely empty:
#      no <sid>.background-work, and no <sid>.background-work.tmp residue from a
#      half-finished write-then-rename.
#
#      Rows and why each is the shape it is:
#        bare          — no `: reason` at all; LOOKSLIKE-only, so the handler
#                        reports "malformed" and writes nothing
#        empty-reason  — `: ` with nothing after it; the strict `([^>]+)` group
#                        cannot match, so it degrades to the same malformed path
#        gt-in-reason  — a `>` inside the reason breaks out of the `[^>]+` class,
#                        so the strict form is refused
#        trailing-cmd  — a real sentinel followed by a newline and a second shell
#                        command. The patterns are `^...$` anchored WITHOUT the
#                        `m` flag, so this is not a sentinel at all: an attacker
#                        cannot smuggle an extra command into a sentinel line and
#                        still have the marker written.
#
#      Two rows are deliberately POSITIVE, because the handler's real contract
#      (checked against validateSkipReason rather than assumed) applies the
#      marker even when the reason is refused — "reason rejected, start still
#      applied". They are asserted as containment rows instead:
#        placeholder   — the literal `{reason}` is in SKIP_REASON_DUDS, so the
#                        reason is refused and stored as null, but the marker is
#                        written; nothing else appears in the dir
#        control-chars — SOH/CR inside the reason are NOT refused. What matters
#                        is that they influence only the payload, never the
#                        marker's path: exactly one file, named for the session
#                        id, holding valid JSON with the bytes escaped.
# ---------------------------------------------------------------------------
run_B13() {
    local tmp tn sid cmd leftover failures="" out
    for sid in bare emptyreason gtinreason trailingcmd; do
        case "$sid" in
            bare)          cmd='echo "<<WORKFLOW_BACKGROUND_WORK_START>>"' ;;
            emptyreason)   cmd='echo "<<WORKFLOW_BACKGROUND_WORK_START: >>"' ;;
            gtinreason)    cmd='echo "<<WORKFLOW_BACKGROUND_WORK_START: 5 > 3 subagents>>"' ;;
            trailingcmd)   cmd=$(printf 'echo "<<WORKFLOW_BACKGROUND_WORK_START: real reason here>>"\necho injected') ;;
        esac
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        run_mark "$tn" "b13$sid" "$cmd"
        leftover=$(ls -A "$tmp" 2>/dev/null | tr '\n' ',')
        [ "$MARK_RC" -eq 0 ] || failures="$failures [$sid: hook rc=$MARK_RC]"
        [ -z "$leftover" ] || failures="$failures [$sid: workflow dir not empty: $leftover]"
        rm -rf "$tmp" 2>/dev/null || true
    done
    # positive containment rows: reason refused (or hostile), marker still applied
    for sid in ph ctrl; do
        case "$sid" in
            ph)   cmd='echo "<<WORKFLOW_BACKGROUND_WORK_START: {reason}>>"' ;;
            ctrl) cmd=$(printf 'echo "<<WORKFLOW_BACKGROUND_WORK_START: a\001b\rc long enough>>"') ;;
        esac
        tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
        run_mark "$tn" "b13$sid" "$cmd"
        leftover=$(ls -A "$tmp" 2>/dev/null | tr '\n' ',')
        if [ "$leftover" != "b13$sid.background-work," ]; then
            failures="$failures [$sid: expected exactly b13$sid.background-work, dir holds: ${leftover:-<empty>}]"
            rm -rf "$tmp" 2>/dev/null || true
            continue
        fi
        out=$(WANT="$sid" P="$(node_path "$tmp/b13$sid.background-work")" "$RWT" 15 node -e "
const raw = require('fs').readFileSync(process.env.P, 'utf8');
const m = JSON.parse(raw);
const problems = [];
if (typeof m.expires_at !== 'string') problems.push('no-expires_at');
if (process.env.WANT === 'ph' && m.reason !== null) problems.push('placeholder-reason-stored:' + JSON.stringify(m.reason));
if (process.env.WANT === 'ctrl') {
  if (typeof m.reason !== 'string') problems.push('ctrl-reason-not-string');
  else if (!m.reason.includes('\u0001')) problems.push('ctrl-byte-lost');
  if (/[\u0000-\u001f]/.test(raw)) problems.push('raw-control-byte-unescaped-on-disk');
}
process.stdout.write(problems.length ? 'BAD:' + problems.join(',') : 'OK');" 2>/dev/null)
        [ "$out" = "OK" ] || failures="$failures [$sid: payload wrong: '${out:-<err>}']"
        rm -rf "$tmp" 2>/dev/null || true
    done
    if [ -z "$failures" ]; then
        pass "B13: bare/empty/'>'-bearing/trailing-command START forms write no marker and no .tmp; placeholder and control-char reasons stay contained in the payload of the one expected marker"
    else
        fail "B13: malformed-START negative path wrong;$failures"
    fi
}
