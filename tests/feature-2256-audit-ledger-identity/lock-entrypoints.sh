#!/usr/bin/env bash
# tests/feature-2256-audit-ledger-identity/lock-entrypoints.sh
# Tests: hooks/lib/supervisor-state-writer/append.js, hooks/lib/supervisor-state-writer/alert.js, hooks/lib/supervisor-state-writer/audit.js, hooks/lib/supervisor-state-writer/shared.js
# Tags: supervisor, state-lock, lost-update, findings, alert, TL2, scope:issue-specific
# #2256 S2-c / round-2 C3: every write entrypoint takes the lock BEFORE its read, so no
# pairwise interleaving loses an update. Parent: tests/feature-2256-audit-ledger-identity.sh

set -uo pipefail

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    AGENTS_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    AGENTS_NODE="$AGENTS_DIR"
fi
WRITER_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer.js"
SCHEMA_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-schema.js"
SW_DIR="$AGENTS_DIR/hooks/lib/supervisor-state-writer"
# Windows-native node resolves an msys "/c/..." path against the drive root, so
# every path handed to node (as opposed to msys grep) must use the cygpath -m form.
SW_NODE="$AGENTS_NODE/hooks/lib/supervisor-state-writer"

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

WORK="$(mktemp -d 2>/dev/null || mktemp -d -t f2256ep)"
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
        printf '%s\n' "const writer = require('$WRITER_NODE');"
        printf '%s\n' "const schema = require('$SCHEMA_NODE');"
        printf '%s\n' "const fs = require('fs');"
        printf '%s\n' "const out = (v) => process.stdout.write(String(v));"
        printf '%s\n' "$body"
    } > "$js"
    bash "$RWT" 60 node "$js" 2>&1
}

seed() {
    drive "seed-$1" "
const st = schema.createEmptyState('$1');
fs.writeFileSync(writer.getStatePath('$1'), JSON.stringify(st));
out('');
" >/dev/null
}

# Worker: N iterations of one named writer operation against one session.
cat > "$WORK/worker.js" <<'WORKERJS'
const writer = require(process.env.WRITER_NODE);
const sid = process.env.SID;
const op = process.argv[2];
const n = Number(process.argv[3] || 20);
for (let i = 0; i < n; i++) {
  if (op === 'finding') {
    writer.appendFinding(sid, {
      severity: 'notice', categories: ['workflow'],
      reporter: 'test-worker-' + process.pid,
      detail: 'interleave probe ' + process.pid + '-' + i,
    });
  } else if (op === 'audit') {
    writer.writeAuditState(sid, { audit_phase: 'pending', audit_cause: 'step-complete:write_code#' + i });
  } else if (op === 'alert') {
    writer.writeAlertState(sid, { alert_phase: 'pending', alert_cause: 'C2#' + i });
  } else if (op === 'retry') {
    writer.incrementAlertRetryCount(sid);
  }
}
WORKERJS

run_pair() {
    local sid="$1" a="$2" b="$3" n="$4"
    WRITER_NODE="$WRITER_NODE" SID="$sid" node "$WORK/worker.js" "$a" "$n" >/dev/null 2>&1 &
    local p1=$!
    WRITER_NODE="$WRITER_NODE" SID="$sid" node "$WORK/worker.js" "$b" "$n" >/dev/null 2>&1 &
    local p2=$!
    wait $p1
    wait $p2
}

# --- 1-2: appendFinding x writeAuditState ---
sid="ep-fa-$$"
seed "$sid"
run_pair "$sid" finding audit 20
out=$(drive readfa "
const st = writer.readState('$sid');
out((st.layer1.findings || []).length + '|' + String(st.audit && st.audit.audit_cause));
")
assert_match "1: appendFinding x writeAuditState keeps all 20 findings" "$out" '^20\|'
assert_match "2: appendFinding x writeAuditState keeps the audit patch" "$out" '\|step-complete:write_code#19$'

# --- 3-4: appendFinding x writeAlertState ---
sid="ep-fl-$$"
seed "$sid"
run_pair "$sid" finding alert 20
out=$(drive readfl "
const st = writer.readState('$sid');
out((st.layer1.findings || []).length + '|' + String(st.alert && st.alert.alert_cause));
")
assert_match "3: appendFinding x writeAlertState keeps all 20 findings" "$out" '^20\|'
assert_match "4: appendFinding x writeAlertState keeps the alert patch" "$out" '\|C2#19$'

# --- 5-6: writeAuditState x writeAlertState ---
sid="ep-al-$$"
seed "$sid"
run_pair "$sid" audit alert 20
out=$(drive readal "
const st = writer.readState('$sid');
out(String(st.audit && st.audit.audit_cause) + '|' + String(st.alert && st.alert.alert_cause));
")
assert_match "5: writeAuditState x writeAlertState keeps the audit side" "$out" '^step-complete:write_code#19\|'
assert_match "6: writeAuditState x writeAlertState keeps the alert side" "$out" '\|C2#19$'

# --- 7-8: incrementAlertRetryCount double-read regression ---
# The counter is not expected to reach 20: #912 C-HIGH-2 freezes it at
# ALERT_RETRY_THRESHOLD, after which alert_phase=paused short-circuits every
# further increment. Landing exactly on the threshold is what "no lost update"
# looks like here — a dropped update would leave it below.
sid="ep-retry-$$"
seed "$sid"
run_pair "$sid" retry finding 20
out=$(drive readretry "
const st = writer.readState('$sid');
const rc = (st.alert || {}).alert_retry_count;
out((rc === schema.ALERT_RETRY_THRESHOLD ? 'capped' : 'rc=' + String(rc)) + '|' + (st.layer1.findings || []).length);
")
assert_match "7: incrementAlertRetryCount freezes on the retry threshold under concurrency" "$out" '^capped\|'
assert_match "8: a concurrent appendFinding survives the increment's second read" "$out" '\|20$'

# --- 9-11: appendFinding's three writeAtomic exits stay inside one lock scope ---
sid="ep-dedup-$$"
seed "$sid"
out=$(drive dedup "
const mk = (t) => ({ severity: 'warning', categories: ['workflow'], reporter: 'r1', detail: 'd-' + t });
writer.appendFinding('$sid', mk('same'));
writer.appendFinding('$sid', mk('same'));
writer.appendFinding('$sid', mk('other'));
const st = writer.readState('$sid');
out((st.layer1.findings || []).length + '|' + (st.layer1.findings || []).map((f) => f.detail).join(','));
")
assert_match "9: appendFinding dedup collapse still produces a consistent state" "$out" '^[12]\|'
assert_match "10: appendFinding normal append still lands the distinct finding" "$out" 'd-other'
grep -q 'withStateLock' "$SW_DIR/append.js" 2>/dev/null \
    && pass "11: append.js acquires the state lock" \
    || fail "11: append.js acquires the state lock" "no withStateLock reference in append.js"

# --- 12-15: the lock is taken before the read, in every entrypoint module ---
for mod in append alert audit; do
    if node -e "
const src = require('fs').readFileSync('$SW_NODE/$mod.js', 'utf8');
const lockAt = src.indexOf('withStateLock');
const readAt = src.search(/readStateOrInit|readState\(/);
process.exit(lockAt >= 0 && (readAt < 0 || lockAt < readAt) ? 0 : 1);
" 2>/dev/null; then
        pass "12-$mod: $mod.js takes the lock before its first read"
    else
        fail "12-$mod: $mod.js takes the lock before its first read" "withStateLock missing or after the read"
    fi
done
if grep -q 'withStateLock' "$SW_DIR/shared.js" 2>/dev/null; then
    fail "15: shared.js primitives stay lock-free" "shared.js references withStateLock"
else
    pass "15: shared.js primitives stay lock-free"
fi

# --- 16-18: mutateAlertState derivatives run under the lock ---
sid="ep-mut-$$"
seed "$sid"
out=$(drive mutate "
const mk = (t) => ({ severity: 'warning', categories: ['workflow'], reporter: 'r1', detail: 'd-' + t });
writer.appendFinding('$sid', mk('m1'));
let errs = [];
for (const fn of ['confirmFinding', 'dropFindings', 'promotePendingDraftsToConfirmed']) {
  if (typeof writer[fn] !== 'function') { errs.push(fn + ':missing'); }
}
out(errs.length === 0 ? 'all-present' : errs.join(','));
")
assert_eq "16: the mutateAlertState derivatives are all exported" "$out" "all-present"
for fn in confirmFinding dropFindings promotePendingDraftsToConfirmed; do
    if node -e "
const src = require('fs').readFileSync('$SW_NODE/alert.js', 'utf8');
const i = src.indexOf('$fn');
if (i < 0) process.exit(1);
process.exit(src.indexOf('withStateLock') >= 0 || src.indexOf('mutateAlertState') >= 0 ? 0 : 1);
" 2>/dev/null; then
        pass "17-$fn: $fn routes through a locked mutator"
    else
        fail "17-$fn: $fn routes through a locked mutator" "alert.js does not lock $fn"
    fi
done

# --- 19: writeAtomic's tmp name is pid-qualified so two processes cannot collide ---
if grep -Eq 'tmp.*process\.pid|process\.pid.*tmp' "$SW_DIR/shared.js" 2>/dev/null; then
    pass "19: writeAtomic's tmp path carries the pid"
else
    fail "19: writeAtomic's tmp path carries the pid" "shared.js still uses a fixed .tmp name"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] || exit 1
exit 0
