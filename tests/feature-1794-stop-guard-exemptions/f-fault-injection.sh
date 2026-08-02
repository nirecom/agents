# f-fault-injection.sh — B15/A11: marker-write I/O fault injection for both
# quiet-layer primitives. Kept together (rather than in b-/a-) because the two
# cases are a CPR-5 symmetric pair: the background-work and awaiting-user
# handlers share one write-then-rename shape, so their failure contracts must be
# read side by side and must never drift apart.
# Sourced by tests/feature-1794-stop-guard-exemptions.sh.

# ---------------------------------------------------------------------------
# B15 (fault injection): the marker write path under real I/O failure. B9 proves
#      hostile session ids never reach the filesystem; this proves a filesystem
#      that REFUSES the write is equally contained. Three failure points:
#        mkdir   — the workflow dir's parent is a regular file (ENOTDIR, no
#                  monkeypatching: a genuinely unusable dir)
#        write   — writeFileSync raises EACCES
#        rename  — renameSync raises EPERM after the tmp was written
#      Contract asserted for all three: signalFatal fires ("Start NOT applied"),
#      and NO live <sid>.background-work ever appears — a failed write must never
#      be mistaken for an in-flight declaration by isBackgroundWorkInFlight.
#      The rename row additionally pins where the residue may live: only a
#      `.tmp`-suffixed file inside the workflow dir, which the 24h `.tmp` rule in
#      zombie-cleanup.js reclaims (verified here by ageing it and sweeping).
#      A fourth row covers the END side: an unlinkable marker (a directory) must
#      also signalFatal rather than silently reporting success.
# ---------------------------------------------------------------------------
run_B15() {
    local tmp tn out
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/wf"
    : > "$tmp/notadir"
    out=$(ROOT="$(node_path "$tmp")" MOD="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/background-work.js" \
        START="$BG_START" END="$BG_END" \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" "$RWT" 20 node -e "
const fs = require('fs'), path = require('path');
const root = process.env.ROOT, wf = path.join(root, 'wf');
const { handleBackgroundWork } = require(process.env.MOD);
const problems = [];
const walk = (d) => {
  let out = [];
  for (const n of fs.readdirSync(d)) {
    const p = path.join(d, n);
    let st; try { st = fs.lstatSync(p); } catch (e) { continue; }
    if (st.isDirectory()) out = out.concat(walk(p)); else out.push(p);
  }
  return out;
};
const drive = (label, cmd, sid) => {
  let fatal = null;
  let handled;
  try { handled = handleBackgroundWork({ cmd, sessionId: sid, pushMessage: () => {}, signalFatal: (m) => { fatal = m; } }); }
  catch (e) { problems.push(label + ':threw(' + e.message + ')'); return; }
  if (handled !== true) problems.push(label + ':sentinel-not-handled');
  if (!fatal) problems.push(label + ':no-fatal-signal');
};
// 1. mkdir failure — the workflow dir sits under a regular file (real ENOTDIR)
process.env.CLAUDE_WORKFLOW_DIR = path.join(root, 'notadir', 'wf');
drive('mkdir', process.env.START, 'b15mkdir');
process.env.CLAUDE_WORKFLOW_DIR = wf;
if (walk(wf).length) problems.push('mkdir:wrote(' + walk(wf).join(',') + ')');
// 2. writeFileSync failure
const realWrite = fs.writeFileSync;
fs.writeFileSync = () => { const e = new Error('denied'); e.code = 'EACCES'; throw e; };
drive('write', process.env.START, 'b15write');
fs.writeFileSync = realWrite;
if (walk(wf).length) problems.push('write:left(' + walk(wf).map((f) => path.basename(f)).join(',') + ')');
// 3. renameSync failure — the tmp exists but never becomes a live marker
const realRename = fs.renameSync;
fs.renameSync = () => { const e = new Error('denied'); e.code = 'EPERM'; throw e; };
drive('rename', process.env.START, 'b15rename');
fs.renameSync = realRename;
for (const f of walk(wf)) {
  const base = path.basename(f);
  if (!base.endsWith('.tmp')) problems.push('rename:live-marker(' + base + ')');
  if (path.dirname(path.resolve(f)) !== path.resolve(wf)) problems.push('rename:escaped(' + base + ')');
}
// no failed write may ever read back as in-flight
const { isBackgroundWorkInFlight } = require('$_AGENTS_DIR_NODE/hooks/lib/session-markers.js');
for (const sid of ['b15mkdir', 'b15write', 'b15rename']) {
  if (isBackgroundWorkInFlight(sid)) problems.push(sid + ':reads-as-in-flight');
}
// 4. END side — an unlinkable marker (directory) must signalFatal, not pass silently
fs.mkdirSync(path.join(wf, 'b15end.background-work'), { recursive: true });
drive('end-unlink', process.env.END, 'b15end');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>&1)
    local swept=1
    if ls "$tmp/wf"/*.tmp >/dev/null 2>&1; then
        for f in "$tmp/wf"/*.tmp; do age_file "$f" 2; done
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" "$RWT" 20 node -e "
require('$STATEIO_NODE').cleanupZombies();" >/dev/null 2>&1
        ls "$tmp/wf"/*.tmp >/dev/null 2>&1 && swept=0
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ] && [ "$swept" -eq 1 ]; then
        pass "B15: mkdir/write/rename/unlink failures all signalFatal, never produce a readable in-flight marker, and leave at most a .tmp inside the workflow dir that the 24h sweep reclaims"
    else
        fail "B15: marker-write fault injection wrong; got '${out:-<err>}' (tmp_swept=$swept)"
    fi
}

# ---------------------------------------------------------------------------
# A11 (fault injection, CPR-5 sibling of B15): the awaiting-user marker write
#     path under real I/O failure. Same three failure points (mkdir / write /
#     rename) and the same contract: signalFatal fires ("Declaration NOT
#     applied"), no failed write ever reads back through isAwaitingUser, and any
#     residue is a `.tmp` confined to the workflow dir. The END row proves the
#     cancel path reports an unlinkable marker as fatal rather than silently
#     claiming success.
# ---------------------------------------------------------------------------
run_A11() {
    local tmp tn out swept=1
    tmp="$(make_tmp)"; tn="$(node_path "$tmp")"
    mkdir -p "$tmp/wf"
    : > "$tmp/notadir"
    out=$(ROOT="$(node_path "$tmp")" MOD="$_AGENTS_DIR_NODE/hooks/workflow-mark/enforce-override-handlers/awaiting-user.js" \
        START="$AU_START" END="$AU_END" \
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" "$RWT" 20 node -e "
const fs = require('fs'), path = require('path');
const root = process.env.ROOT, wf = path.join(root, 'wf');
const { handleAwaitingUser } = require(process.env.MOD);
const problems = [];
const walk = (d) => {
  let out = [];
  for (const n of fs.readdirSync(d)) {
    const p = path.join(d, n);
    let st; try { st = fs.lstatSync(p); } catch (e) { continue; }
    if (st.isDirectory()) out = out.concat(walk(p)); else out.push(p);
  }
  return out;
};
const drive = (label, cmd, sid) => {
  let fatal = null;
  let handled;
  try { handled = handleAwaitingUser({ cmd, sessionId: sid, pushMessage: () => {}, signalFatal: (m) => { fatal = m; } }); }
  catch (e) { problems.push(label + ':threw(' + e.message + ')'); return; }
  if (handled !== true) problems.push(label + ':sentinel-not-handled');
  if (!fatal) problems.push(label + ':no-fatal-signal');
};
process.env.CLAUDE_WORKFLOW_DIR = path.join(root, 'notadir', 'wf');
drive('mkdir', process.env.START, 'a11mkdir');
process.env.CLAUDE_WORKFLOW_DIR = wf;
if (walk(wf).length) problems.push('mkdir:wrote(' + walk(wf).join(',') + ')');
const realWrite = fs.writeFileSync;
fs.writeFileSync = () => { const e = new Error('denied'); e.code = 'EACCES'; throw e; };
drive('write', process.env.START, 'a11write');
fs.writeFileSync = realWrite;
if (walk(wf).length) problems.push('write:left(' + walk(wf).map((f) => path.basename(f)).join(',') + ')');
const realRename = fs.renameSync;
fs.renameSync = () => { const e = new Error('denied'); e.code = 'EPERM'; throw e; };
drive('rename', process.env.START, 'a11rename');
fs.renameSync = realRename;
for (const f of walk(wf)) {
  const base = path.basename(f);
  if (!base.endsWith('.tmp')) problems.push('rename:live-marker(' + base + ')');
  if (path.dirname(path.resolve(f)) !== path.resolve(wf)) problems.push('rename:escaped(' + base + ')');
}
const { isAwaitingUser } = require('$_AGENTS_DIR_NODE/hooks/lib/session-markers.js');
for (const sid of ['a11mkdir', 'a11write', 'a11rename']) {
  if (isAwaitingUser(sid)) problems.push(sid + ':reads-as-declared');
}
fs.mkdirSync(path.join(wf, 'a11end.awaiting-user'), { recursive: true });
drive('end-unlink', process.env.END, 'a11end');
process.stdout.write(problems.length ? 'BAD:' + problems.join(' | ') : 'OK');" 2>&1)
    if ls "$tmp/wf"/*.tmp >/dev/null 2>&1; then
        for f in "$tmp/wf"/*.tmp; do age_file "$f" 2; done
        CLAUDE_WORKFLOW_DIR="$tn/wf" WORKFLOW_PLANS_DIR="$tn/wf" "$RWT" 20 node -e "
require('$STATEIO_NODE').cleanupZombies();" >/dev/null 2>&1
        ls "$tmp/wf"/*.tmp >/dev/null 2>&1 && swept=0
    fi
    rm -rf "$tmp" 2>/dev/null || true
    if [ "$out" = "OK" ] && [ "$swept" -eq 1 ]; then
        pass "A11: mkdir/write/rename/unlink failures all signalFatal, never produce a readable declaration, and leave at most a .tmp inside the workflow dir that the 24h sweep reclaims"
    else
        fail "A11: awaiting-user marker-write fault injection wrong; got '${out:-<err>}' (tmp_swept=$swept)"
    fi
}
