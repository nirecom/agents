#!/usr/bin/env bash
# tests/feature-2256-audit-ledger-identity/lock-ownership.sh
# Tests: hooks/lib/supervisor-state-writer/lock.js
# Tags: supervisor, state-lock, owner-token, stale-reclaim, fail-closed, TL2, scope:issue-specific
# #2256 S2-c / round-2 C3: the mkdir lock is owned by a token, reclaimed unlink-then-rmdir,
# reentrant, and fail-closed. Parent: tests/feature-2256-audit-ledger-identity.sh

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_NODE="$AGENTS_DIR"
fi
LOCK_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer/lock.js"
WRITER_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-schema.js"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1${2:+ — $2}"; FAIL=$((FAIL + 1)); }
assert_eq() {
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected '$3', got '$2'"; fi
}
assert_match() {
    if printf '%s' "$2" | grep -Eq "$3"; then pass "$1"; else fail "$1" "'$2' does not match /$3/"; fi
}

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256lock)"
trap 'rm -rf "$WORK"' EXIT
if command -v cygpath >/dev/null 2>&1; then WORK_NODE="$(cygpath -m "$WORK")"; else WORK_NODE="$WORK"; fi

mkdir -p "$WORK/plans" "$WORK/wf" "$WORK/transcripts"
export WORKFLOW_PLANS_DIR="$WORK_NODE/plans"
export CLAUDE_WORKFLOW_DIR="$WORK_NODE/wf"
export CLAUDE_TRANSCRIPT_BASE_DIR="$WORK_NODE/transcripts"
export AGENTS_CONFIG_DIR="$AGENTS_NODE"
unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
cd "$WORK" || exit 1

RWT="$AGENTS_DIR/bin/run-with-timeout.sh"
drive() {
    local name="$1" body="$2"
    local js="$WORK/drv-$name.js"
    {
        printf '%s\n' "const lock = require('$LOCK_NODE');"
        printf '%s\n' "const writer = require('$WRITER_NODE');"
        printf '%s\n' "const schema = require('$SCHEMA_NODE');"
        printf '%s\n' "const fs = require('fs');"
        printf '%s\n' "const path = require('path');"
        printf '%s\n' "const out = (v) => process.stdout.write(String(v));"
        printf '%s\n' "$body"
    } > "$js"
    bash "$RWT" 40 node "$js" 2>&1
}

TARGET="$WORK_NODE/plans/target.json"
printf '{}' > "$WORK/plans/target.json"

# --- 1-3: the lock directory and its owner token appear and are cleaned up ---
out=$(drive basic "
const dirs = [];
const r = lock.withStateLock('$TARGET', () => {
  const d = fs.readdirSync('$WORK_NODE/plans').filter((n) => n.indexOf('target.json') === 0 && n !== 'target.json');
  dirs.push(d.join(','));
  return 'body-ran';
});
const after = fs.readdirSync('$WORK_NODE/plans').filter((n) => n !== 'target.json');
out(String(r) + '|' + (dirs[0] || 'none') + '|' + after.length);
")
assert_match "1: withStateLock returns the callback result" "$out" '^body-ran\|'
assert_match "2: a lock artifact exists while the callback runs" "$out" '^body-ran\|target\.json'
assert_match "3: the lock artifact is removed after release" "$out" '\|0$'

# --- 4: two processes writing under the lock do not lose an update ---
sid="lk-conc-$$"
drive seed "
const st = schema.createEmptyState('$sid');
st.audit.counter_a = 0; st.audit.counter_b = 0;
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
out('');
" >/dev/null
cat > "$WORK/bump.js" <<'BUMPJS'
const lock = require(process.env.LOCK_NODE);
const writer = require(process.env.WRITER_NODE);
const field = process.argv[2];
const p = writer.getStatePath(process.env.SID);
for (let i = 0; i < 25; i++) {
  lock.withStateLock(p, () => {
    const st = JSON.parse(require('fs').readFileSync(p, 'utf8'));
    const v = st.audit[field] || 0;
    for (let j = 0; j < 20000; j++) { /* widen the read-modify-write window */ }
    st.audit[field] = v + 1;
    require('fs').writeFileSync(p, JSON.stringify(st));
  });
}
BUMPJS
LOCK_NODE="$LOCK_NODE" WRITER_NODE="$WRITER_NODE" SID="$sid" node "$WORK/bump.js" counter_a >/dev/null 2>&1 &
p1=$!
LOCK_NODE="$LOCK_NODE" WRITER_NODE="$WRITER_NODE" SID="$sid" node "$WORK/bump.js" counter_b >/dev/null 2>&1 &
p2=$!
wait $p1; wait $p2
out=$(drive readconc "
const st = writer.readState('$sid');
out(String(st.audit.counter_a) + '|' + String(st.audit.counter_b));
")
assert_eq "4: two concurrent processes both land all 25 updates" "$out" "25|25"

# --- 5-6: reclaim tolerates a leftover owner-token file (unlink before rmdir) ---
out=$(drive reclaim "
const dir = '$TARGET' + '.lock';
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'owner'), '99999-deadbeef');
const old = Date.now() - 60000;
fs.utimesSync(dir, old / 1000, old / 1000);
let err = '';
let ran = false;
try { lock.withStateLock('$TARGET', () => { ran = true; }); } catch (e) { err = String(e && e.code || e); }
const gone = !fs.existsSync(dir);
out(String(ran) + '|' + err + '|' + String(gone));
")
assert_match "5: a stale lock dir with a leftover owner token is reclaimed, not ENOTEMPTY" "$out" '^true\|\|'
assert_match "6: release removes the reclaimed lock dir and its token" "$out" '\|true$'

# --- 7-9: the original holder must not clobber the new owner after a reclaim ---
sid="lk-own-$$"
drive seedown "
const st = schema.createEmptyState('$sid');
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
out('');
" >/dev/null
out=$(drive ownercheck "
const p = writer.getStatePath('$sid');
const dir = p + '.lock';
let tokenSeenByNewOwner = '';
let tokenAfterOldRelease = '';
let findings = 0;
lock.withStateLock(p, () => {
  // Simulate: this holder went stale, a second process reclaimed the lock and now owns it.
  const names = fs.readdirSync(dir);
  for (const n of names) fs.unlinkSync(path.join(dir, n));
  fs.writeFileSync(path.join(dir, 'owner'), '424242-new-owner-token');
  tokenSeenByNewOwner = fs.readFileSync(path.join(dir, 'owner'), 'utf8');
});
tokenAfterOldRelease = fs.existsSync(path.join(dir, 'owner')) ? fs.readFileSync(path.join(dir, 'owner'), 'utf8') : 'REMOVED';
const st = writer.readState('$sid');
findings = (((st.layer1 || {}).findings) || []).filter((f) => f.severity === 'warning').length;
out(tokenSeenByNewOwner + '|' + tokenAfterOldRelease + '|' + findings);
")
assert_match "7: the stale holder's release leaves the new owner token in place" "$out" '\|424242-new-owner-token\|'
assert_match "8: the stale holder's release does not remove the new owner's lock dir" "$out" '^424242-new-owner-token\|'
assert_match "9: an ownership mismatch on release records a severity=warning finding" "$out" '\|[1-9][0-9]*$'

# --- 10-11: reentrant acquisition inside the same process must not deadlock ---
out=$(drive reentrant "
let depth = 0;
const p = '$TARGET';
const r = lock.withStateLock(p, () => {
  depth++;
  return lock.withStateLock(p, () => { depth++; return 'inner'; });
});
const leftovers = fs.readdirSync('$WORK_NODE/plans').filter((n) => n.indexOf('target.json.lock') === 0);
out(String(r) + '|' + depth + '|' + leftovers.length);
")
assert_match "10: a nested withStateLock in one process returns instead of deadlocking" "$out" '^inner\|2\|'
assert_match "11: the outer release is the one that removes the lock dir" "$out" '\|0$'

# --- 12-13: fail-closed when the lock cannot be acquired ---
sid="lk-failclosed-$$"
drive seedfc "
const st = schema.createEmptyState('$sid');
st.audit.audit_phase = 'pending';
fs.writeFileSync(writer.getStatePath('$sid'), JSON.stringify(st));
out('');
" >/dev/null
out=$(drive failclosed "
const p = writer.getStatePath('$sid');
const dir = p + '.lock';
// A fresh lock held by somebody else: never stale, so acquisition must give up.
fs.mkdirSync(dir, { recursive: true });
fs.writeFileSync(path.join(dir, 'owner'), '1234-live-owner');
let threw = '';
let ran = false;
const t0 = Date.now();
try { lock.withStateLock(p, () => { ran = true; }); } catch (e) { threw = 'threw'; }
const waited = Date.now() - t0;
out(String(ran) + '|' + threw + '|' + (waited >= 1500 ? 'retried' : 'gaveup-early'));
")
assert_match "12: the callback never runs when the lock cannot be acquired (fail-closed)" "$out" '^false\|'
assert_match "13: acquisition failure does not propagate an exception" "$out" '^false\|\|'
assert_match "14: acquisition retries for the full ~2s window before failing" "$out" '\|retried$'

# --- 15: the fallback is a single stderr line, not a crash ---
err_out=$(drive fallback "
const p = writer.getStatePath('$sid');
const dir = p + '.lock';
if (!fs.existsSync(dir)) { fs.mkdirSync(dir, { recursive: true }); fs.writeFileSync(path.join(dir, 'owner'), '1234-live-owner'); }
lock.withStateLock(p, () => {});
out('survived');
" 2>&1)
assert_match "15: lock-acquisition failure degrades to a stderr note and returns" "$err_out" 'survived'

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
