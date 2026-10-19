# #2430 ORed-trigger table T3. Sourced by ../feat-progress-pressure.sh after legacy-2218-lib.sh;
# run_T3 is called inside its own case block.

# T3 — #2430 ORed triggers: 2MiB of growth, or 60 min with any growth, halved
# to 1MiB / 30 min while a risk newer than the baseline is live; a request
# restores the defaults. Time is injected as `now` and the sidecar / risk file
# are planted with epoch-ms timestamps, so no row sleeps. The flush-mark rows
# were retired with the flush mark (#2594).
run_T3() {
    l2218_require_module "$L2218_LIB" || return 0
    local tmp results name desc got
    tmp="$(make_tmp)"
    cat > "$tmp/t3.js" <<'JS'
const fs = require('fs');
const P = require(process.env.AGENTS + '/hooks/lib/progress-pressure.js');
const D = process.env.TMPD, W = D + '/wf';
const KiB = 1024, MiB = 1024 * KiB, MIN = 60000, t0 = Date.parse('2026-01-01T00:00:00Z'), B0 = 1 * MiB;
const ms = (v) => new Date(v).getTime();
const ctl = (sid, name) => { fs.mkdirSync(W + '/' + sid + '.control', { recursive: true }); return W + '/' + sid + '.control/' + name; };
const put = (sid, name, obj) => fs.writeFileSync(ctl(sid, name), typeof obj === 'string' ? obj : JSON.stringify(obj));
const side = (sid) => { try { return JSON.parse(fs.readFileSync(ctl(sid, 'progress-pressure.json'), 'utf8')); } catch (e) { return null; } };
// ev(sid, {size, now, base, risk}) — plant the fixture and evaluate once.
const ev = (sid, o) => {
  if (o.base) put(sid, 'progress-pressure.json', { baseline_bytes: o.base[0], baseline_at: o.base[1] });
  if (o.risk !== undefined) put(sid, 'handoff-risk.json', typeof o.risk === 'string' ? o.risk : { last_risk_at: o.risk, source: 'gate-block' });
  const t = D + '/' + sid + '.jsonl';
  if (o.size !== undefined) fs.writeFileSync(t, Buffer.alloc(o.size, 120));
  return P.computePressureSignal({ sid, transcriptPath: t, now: o.now });
};
const results = [];
const check = (name, fn) => {
  const bad = [];
  try { fn(bad); } catch (e) { bad.push('THREW:' + e.message); }
  results.push(name + ' ' + (bad.length ? 'BAD:' + bad.join(' | ') : 'OK'));
};
const want = (bad, label, sig, fire, trigger) => {
  if (!sig || sig.shouldNudge !== fire) bad.push(label + ':want-fire=' + fire + ':' + JSON.stringify(sig));
  else if (fire && sig.trigger !== trigger) bad.push(label + ':trigger=' + String(sig.trigger) + ',want=' + trigger);
};
const small = 100 * KiB;
check('elapsed-60min-boundary', (bad) => {
  want(bad, '59:59', ev('e1', { base: [B0, t0], size: B0 + small, now: t0 + 60 * MIN - 1000 }), false);
  const s = ev('e2', { base: [B0, t0], size: B0 + small, now: t0 + 60 * MIN });
  want(bad, '60:00', s, true, 'elapsed');
  if (s && s.riskActive !== false) bad.push('riskActive:' + String(s && s.riskActive));
});
check('no-growth-never-fires', (bad) => {
  want(bad, '120:00-zero-increment', ev('z1', { base: [B0, t0], size: B0, now: t0 + 120 * MIN }), false);
});
check('risk-resets-the-timer', (bad) => {
  const s = ev('r1', { base: [B0, t0], risk: t0 + 50 * MIN, size: B0 + small, now: t0 + 70 * MIN });
  want(bad, '70:00-after-risk-at-50', s, false);
  if (s && s.riskActive !== true) bad.push('riskActive:' + String(s.riskActive));
  if (s && s.msSinceTimer !== 20 * MIN) bad.push('msSinceTimer:' + String(s.msSinceTimer));
});
check('risk_halves_elapsed_to_30min', (bad) => {
  want(bad, '79:59', ev('r2', { base: [B0, t0], risk: t0 + 50 * MIN, size: B0 + small, now: t0 + 80 * MIN - 1000 }), false);
  want(bad, '80:00', ev('r3', { base: [B0, t0], risk: t0 + 50 * MIN, size: B0 + small, now: t0 + 80 * MIN }), true, 'elapsed');
});
check('risk_halves_increment_to_1MiB', (bad) => {
  want(bad, 'risk-1MiB', ev('h1', { base: [B0, t0], risk: t0 + MIN, size: B0 + MiB, now: t0 + 2 * MIN }), true, 'bytes');
  want(bad, 'risk-1MiB-1', ev('h2', { base: [B0, t0], risk: t0 + MIN, size: B0 + MiB - 1, now: t0 + 2 * MIN }), false);
  want(bad, 'no-risk-1MiB', ev('h3', { base: [B0, t0], size: B0 + MiB, now: t0 + 2 * MIN }), false);
});
check('risk_older_than_baseline_is_ignored', (bad) => {
  const s = ev('o1', { base: [B0, t0], risk: t0 - 10 * MIN, size: B0 + MiB, now: t0 + 2 * MIN });
  want(bad, 'no-halving', s, false);
  if (s && s.riskActive !== false) bad.push('riskActive:' + String(s.riskActive));
  want(bad, 'timer-from-baseline', ev('o2', { base: [B0, t0], risk: t0 - 10 * MIN, size: B0 + small, now: t0 + 60 * MIN - 1000 }), false);
});
check('nudge-restores-defaults', (bad) => {
  want(bad, 'fire-under-risk', ev('n1', { base: [B0, t0], risk: t0 + MIN, size: B0 + MiB, now: t0 + 2 * MIN }), true, 'bytes');
  want(bad, 'next-1MiB', ev('n1', { size: B0 + 2 * MiB, now: t0 + 3 * MIN }), false);
  want(bad, 'next-31min', ev('n1', { now: t0 + 33 * MIN }), false);
});
check('risk_does_not_move_baseline_bytes', (bad) => {
  const s = ev('b1', { base: [B0, t0], risk: t0 + 5 * MIN, size: B0 + small, now: t0 + 6 * MIN });
  want(bad, 'quiet', s, false);
  if (s && s.bytesSince !== small) bad.push('bytesSince:' + String(s.bytesSince));
  const sc = side('b1');
  if (!sc || sc.baseline_bytes !== B0 || ms(sc.baseline_at) !== t0) bad.push('sidecar-moved:' + JSON.stringify(sc));
});
check('corrupt-risk-reads-as-none', (bad) => {
  const s = ev('c1', { base: [B0, t0], risk: '{ not json', size: B0 + MiB, now: t0 + 2 * MIN });
  want(bad, 'garbage', s, false);
  if (s && s.riskActive !== false) bad.push('riskActive:' + String(s.riskActive));
  fs.mkdirSync(ctl('c2', 'handoff-risk.json'));
  want(bad, 'directory', ev('c2', { base: [B0, t0], size: B0 + MiB, now: t0 + 2 * MIN }), false);
});
check('trigger-table-is-ored', (bad) => {
  if (!Array.isArray(P.TRIGGERS)) { bad.push('TRIGGERS-not-exported'); return; }
  const probe = { name: 'probe', fires: () => true };
  P.TRIGGERS.push(probe);
  try {
    want(bad, 'probe', ev('x1', { base: [B0, t0], size: B0 + small, now: t0 + MIN }), true, 'probe');
  } finally { P.TRIGGERS.splice(P.TRIGGERS.indexOf(probe), 1); }
  want(bad, 'probe-removed', ev('x2', { base: [B0, t0], size: B0 + small, now: t0 + MIN }), false);
});
check('flush-mark-is-not-read', (bad) => {
  // A leftover #2430 flush mark (bytes at the current size, newer than the baseline) must not
  // move the baseline any more: 2MiB since the baseline still fires.
  put('m1', 'handoff-flush-mark.json', { bytes: B0 + 2 * MiB, at: t0 + MIN });
  want(bad, 'leftover-mark', ev('m1', { base: [B0, t0], size: B0 + 2 * MiB, now: t0 + 2 * MIN }), true, 'bytes');
});
process.stdout.write(results.join('\n') + '\n');
JS
    results="$(l2218_run_js "$tmp" "$(np "$tmp")/t3.js")"
    rm -rf "$tmp" 2>/dev/null || true
    while IFS='|' read -r name desc; do
        got="$(printf '%s\n' "$results" | grep -E "^$name " | head -n 1)"
        got="${got#"$name "}"
        if [ "$got" = "OK" ]; then pass "T3 $name: $desc"; else fail "T3 $name: $desc — ${got:-<no row; output: ${results:0:300}>}"; fi
    done <<'ROWS'
elapsed-60min-boundary|59:59 is quiet, 60:00 fires with trigger 'elapsed'
no-growth-never-fires|120 min with a zero increment stays quiet
risk-resets-the-timer|a risk at +50 restarts the timer, so +70 is quiet
risk_halves_elapsed_to_30min|after a risk, 29:59 is quiet and 30:00 fires
risk_halves_increment_to_1MiB|a live risk fires at 1MiB but not 1MiB-1; without risk 1MiB is quiet
risk_older_than_baseline_is_ignored|a risk before the baseline neither halves nor restarts the timer
nudge-restores-defaults|a request under risk restores 2MiB / 60 min
risk_does_not_move_baseline_bytes|a risk leaves baseline_bytes where it was
corrupt-risk-reads-as-none|an unreadable risk file counts as no risk and does not throw
trigger-table-is-ored|an added trigger is ORed with the built-in ones
flush-mark-is-not-read|a leftover handoff-flush-mark.json no longer moves the baseline (#2594)
ROWS
}
