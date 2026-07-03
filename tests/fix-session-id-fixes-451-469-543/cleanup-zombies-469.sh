# cleanup-zombies-469.sh — #469 cleanupZombies extension tests (B1..B6).
# Sourced by fix-session-id-fixes-451-469-543.sh; inherits globals and helpers.

# === #469 cleanupZombies extension ===

run_cleanup_node() {
    local wfdir="$1"
    local days="${2:-7}"
    (cd "$AGENTS_DIR" && CLAUDE_WORKFLOW_DIR="$wfdir" node -e "
const wf = require('./hooks/lib/workflow-state/state-io.js');
wf.cleanupZombies($days);
" 2>/dev/null) || true
}

backdate_file() {
    local f="$1" days="$2"
    touch -d "$days days ago" "$f" 2>/dev/null \
        || touch -t "$(date -v-${days}d +%Y%m%d%H%M 2>/dev/null \
            || date -d "$days days ago" +%Y%m%d%H%M 2>/dev/null \
            || echo '202001010000')" "$f" 2>/dev/null \
        || true
}

mtime_age_ms() {
    node -e "try{const s=require('fs').statSync('$1');console.log(Date.now()-s.mtimeMs)}catch(e){console.log(0)}" 2>/dev/null || echo 0
}

# B1
B1_DIR="$AGENTS_DIR/tests/.tmp-b1-$$"
mkdir -p "$B1_DIR"
B1_FILE="$B1_DIR/sid-stale.workflow-off"
echo "stale" > "$B1_FILE"
backdate_file "$B1_FILE" 14
run_cleanup_node "$B1_DIR" 7
if [ ! -f "$B1_FILE" ]; then
    pass "B1: stale (14-day-old) .workflow-off deleted by cleanupZombies"
else
    DIFF=$(mtime_age_ms "$B1_FILE")
    if [ "${DIFF:-0}" -lt 86400000 ]; then
        echo "SKIP: B1 backdate failed on this platform (age=$DIFF ms)"
    else
        fail "B1: stale .workflow-off was NOT deleted (age=$DIFF ms)"
    fi
fi
rm -rf "$B1_DIR" 2>/dev/null || true

# B2
B2_DIR="$AGENTS_DIR/tests/.tmp-b2-$$"
mkdir -p "$B2_DIR"
B2_FILE="$B2_DIR/sid-stale.worktree-off"
echo "stale" > "$B2_FILE"
backdate_file "$B2_FILE" 14
run_cleanup_node "$B2_DIR" 7
if [ ! -f "$B2_FILE" ]; then
    pass "B2: stale (14-day-old) .worktree-off deleted by cleanupZombies"
else
    DIFF=$(mtime_age_ms "$B2_FILE")
    if [ "${DIFF:-0}" -lt 86400000 ]; then
        echo "SKIP: B2 backdate failed on this platform (age=$DIFF ms)"
    else
        fail "B2: stale .worktree-off was NOT deleted (age=$DIFF ms)"
    fi
fi
rm -rf "$B2_DIR" 2>/dev/null || true

# B3
B3_DIR="$AGENTS_DIR/tests/.tmp-b3-$$"
mkdir -p "$B3_DIR"
B3_FILE="$B3_DIR/sid-fresh.workflow-off"
echo "fresh" > "$B3_FILE"
run_cleanup_node "$B3_DIR" 7
if [ -f "$B3_FILE" ]; then
    pass "B3: fresh .workflow-off preserved by cleanupZombies"
else
    fail "B3: fresh .workflow-off was incorrectly deleted"
fi
rm -rf "$B3_DIR" 2>/dev/null || true

# B4
B4_DIR="$AGENTS_DIR/tests/.tmp-b4-$$"
mkdir -p "$B4_DIR"
B4_FILE="$B4_DIR/sid-fresh.worktree-off"
echo "fresh" > "$B4_FILE"
run_cleanup_node "$B4_DIR" 7
if [ -f "$B4_FILE" ]; then
    pass "B4: fresh .worktree-off preserved by cleanupZombies"
else
    fail "B4: fresh .worktree-off was incorrectly deleted"
fi
rm -rf "$B4_DIR" 2>/dev/null || true

# B5
B5_DIR="$AGENTS_DIR/tests/.tmp-b5-$$"
mkdir -p "$B5_DIR"
B5_FILE="$B5_DIR/stale-sid.json"
cat > "$B5_FILE" <<'JSON'
{
  "version": 1,
  "session_id": "stale-sid",
  "created_at": "2020-01-01T00:00:00.000Z",
  "steps": {
    "workflow_init": { "status": "pending", "updated_at": "2020-01-01T00:00:00.000Z" }
  }
}
JSON
run_cleanup_node "$B5_DIR" 7
if [ ! -f "$B5_FILE" ]; then
    pass "B5: regression — stale .json deleted by cleanupZombies"
else
    fail "B5: stale .json was NOT deleted (existing behavior broken)"
fi
rm -rf "$B5_DIR" 2>/dev/null || true

# B6
B6_DIR="$AGENTS_DIR/tests/.tmp-b6-$$"
mkdir -p "$B6_DIR"
B6_FILE="$B6_DIR/stale.json.tmp"
touch "$B6_FILE"
backdate_file "$B6_FILE" 2
run_cleanup_node "$B6_DIR" 7
if [ ! -f "$B6_FILE" ]; then
    pass "B6: regression — stale .tmp deleted by cleanupZombies"
else
    DIFF=$(mtime_age_ms "$B6_FILE")
    if [ "${DIFF:-0}" -lt 86400000 ]; then
        echo "SKIP: B6 backdate failed on this platform"
    else
        fail "B6: stale .tmp was NOT deleted (existing behavior broken)"
    fi
fi
rm -rf "$B6_DIR" 2>/dev/null || true
