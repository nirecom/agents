# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, reset, mtime, scope:common
# Part of tests/bin/main-session-sync.sh — sourced by that dispatcher, not run alone.

echo ""
echo "=== session-sync.sh reset tests ==="

# --- Normal: Reset fetches remote files into working tree ---
echo "[reset] Reset fetches remote files"
RESET_REMOTE="$TMPDIR_BASE/reset-remote.git"
git init --bare "$RESET_REMOTE" >/dev/null 2>&1
# Seed remote with a file from "another machine"
RESET_SEED="$TMPDIR_BASE/reset-seed"
git init "$RESET_SEED" >/dev/null 2>&1
_git_prepare_repo "$RESET_SEED"
git -C "$RESET_SEED" checkout -b main >/dev/null 2>&1
echo '{"seed":"data"}' > "$RESET_SEED/seed-session.jsonl"
printf '* text eol=lf\n' > "$RESET_SEED/.gitattributes"
git -C "$RESET_SEED" add . >/dev/null 2>&1
git -C "$RESET_SEED" commit -m "seed from other machine" >/dev/null 2>&1
git -C "$RESET_SEED" remote add origin "$RESET_REMOTE" >/dev/null 2>&1
git -C "$RESET_SEED" push -u origin main >/dev/null 2>&1
# Init fresh machine (plumbing only), then reset
RESET_CLAUDE="$TMPDIR_BASE/reset-test/.claude"
mkdir -p "$RESET_CLAUDE"
"$DOTFILES_DIR/install/linux/session-sync-init.sh" \
    --claude-dir "$RESET_CLAUDE" --no-remote >/dev/null 2>&1
RESET_PROJECTS="$RESET_CLAUDE/projects"
# Local-path remotes are no longer accepted by the installer allowlist (#1773).
git -C "$RESET_PROJECTS" remote add origin "$RESET_REMOTE" >/dev/null 2>&1
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
if [ -f "$RESET_PROJECTS/seed-session.jsonl" ]; then
    pass "reset fetches remote file into working tree"
else
    fail "reset did not fetch remote file"
fi

# --- Normal: Push works after reset (bidirectional) ---
echo "[reset] Push after reset"
echo '{"local":"data"}' > "$RESET_PROJECTS/local-session.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$RESET_CLAUDE" 2>&1)
if echo "$output" | grep -qi "pushed"; then
    pass "push succeeds after reset"
else
    fail "push failed after reset (output: $output)"
fi

# --- Edge: Reset is idempotent ---
echo "[reset] Reset idempotent"
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
if echo "$output" | grep -qi "reset to remote"; then
    pass "reset idempotent"
else
    fail "reset idempotent failed (output: $output)"
fi

# --- Edge: Reset succeeds when local history.jsonl is absent ---
echo "[reset] Reset succeeds when local history.jsonl is absent"
# Seed remote with .history.jsonl so it exists after fetch+hard-reset
HIST_ABSENT_SEED="$TMPDIR_BASE/hist-absent-seed"
git clone "$RESET_REMOTE" "$HIST_ABSENT_SEED" >/dev/null 2>&1
_git_prepare_repo "$HIST_ABSENT_SEED"
echo '{"display":"remote","sessionId":"absent-test","timestamp":1}' > "$HIST_ABSENT_SEED/.history.jsonl"
git -C "$HIST_ABSENT_SEED" add . >/dev/null 2>&1
git -C "$HIST_ABSENT_SEED" commit -m "seed history for absent test" >/dev/null 2>&1
git -C "$HIST_ABSENT_SEED" push >/dev/null 2>&1
# Remove local history.jsonl to trigger the bug
rm -f "$RESET_CLAUDE/history.jsonl"
exit_code=0
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || exit_code=$?
if [ $exit_code -eq 0 ] && echo "$output" | grep -qi "reset to remote"; then
    pass "reset succeeds when local history.jsonl is absent"
else
    fail "reset failed when local history.jsonl absent (exit=$exit_code, output: $output)"
fi
if [ -f "$RESET_CLAUDE/history.jsonl" ] && grep -q "absent-test" "$RESET_CLAUDE/history.jsonl"; then
    pass "reset creates history.jsonl from remote when local is absent"
else
    fail "reset did not create history.jsonl from remote (content: $(cat "$RESET_CLAUDE/history.jsonl" 2>/dev/null || echo 'missing'))"
fi

# --- Edge: Reset succeeds when .jsonl file has no timestamp field ---
echo "[reset] Reset succeeds with .jsonl missing timestamp field"
# Create a .jsonl file in the reset environment with no timestamp field
echo '{"sessionId":"no-ts","type":"text"}' > "$RESET_PROJECTS/no-timestamp.jsonl"
git -C "$RESET_PROJECTS" add . >/dev/null 2>&1
git -C "$RESET_PROJECTS" commit -m "add no-timestamp session" >/dev/null 2>&1
git -C "$RESET_PROJECTS" push >/dev/null 2>&1
exit_code=0
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || exit_code=$?
if [ $exit_code -eq 0 ] && echo "$output" | grep -qi "reset to remote"; then
    pass "reset succeeds with .jsonl missing timestamp field"
else
    fail "reset failed with no-timestamp .jsonl (exit=$exit_code, output: $output)"
fi

# --- Edge: reset restores mtime from last timestamp row when tail is metadata-only ---
echo "[reset] reset restores mtime from last timestamp row when tail is metadata-only"
# Create a .jsonl with: T1 line, T2 line (most recent real entry), then metadata-only tail
echo '{"timestamp":"2024-01-01T10:00:00.000Z","type":"user","text":"hello"}' > "$RESET_PROJECTS/has-metadata-tail.jsonl"
echo '{"timestamp":"2024-01-01T12:30:00.000Z","type":"assistant","text":"world"}' >> "$RESET_PROJECTS/has-metadata-tail.jsonl"
echo '{"ai-title":"test session","mode":"auto"}' >> "$RESET_PROJECTS/has-metadata-tail.jsonl"
git -C "$RESET_PROJECTS" add has-metadata-tail.jsonl >/dev/null 2>&1
git -C "$RESET_PROJECTS" commit -m "add has-metadata-tail session" >/dev/null 2>&1
git -C "$RESET_PROJECTS" push >/dev/null 2>&1
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
actual_mtime=$(stat -c %Y "$RESET_PROJECTS/has-metadata-tail.jsonl" 2>/dev/null || stat -f %m "$RESET_PROJECTS/has-metadata-tail.jsonl" 2>/dev/null || echo "0")
expected_mtime=$(date -d "2024-01-01T12:30:00.000Z" +%s 2>/dev/null || echo "")
if [ -n "$expected_mtime" ] && [ "$actual_mtime" -eq "$expected_mtime" ]; then
    pass "reset restores mtime from last timestamp row when tail is metadata-only"
else
    fail "reset mtime wrong: expected epoch $expected_mtime (2024-01-01T12:30:00.000Z), got $actual_mtime (should not be from head-1 or metadata line)"
fi

# --- Edge: reset tolerates a dash-leading timestamp value (#1218, S2-d) ---
# Scope: regression guard for the `case "$ts" in -*) ts= ;; esac` defense-in-depth
# guard, NOT a demonstrated exploit — GNU `touch -d` binds the next argument
# positionally, so option-shaped values are rejected as dates. GNU coreutils only
# (Git Bash / MSYS2); BSD/macOS flag parsing is a known coverage gap.
# Payload matrix pinned identical to bin/cc-session-mtime's in
# tests/bin/cc-session-mtime.sh — symmetric sinks of one class (CPR-ORTH).
# Table-driven per skills/_shared/test-design/parser-regex-tests.md. Columns:
# case-name | timestamp value written into the JSONL row; @MARKER@ expands to
# $DASHY_MARKER, a pre-existing file assertion (4) proves untouched.
echo "[reset] Dash-leading timestamp payload matrix (#1218 hardening guard)"
# _rs_mtime_rejected — the engine's mtimeRejected counter (number or {count}), 0 when absent.
_rs_mtime_rejected() {
    node -e 'try{const s=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));const v=s.mtimeRejected;process.stdout.write(String(typeof v==="number"?v:(v&&v.count)||0))}catch(e){process.stdout.write("0")}' \
        "$RESET_PROJECTS/.git/agents-session-sync-state.json"
}
DASHY_SEED="$TMPDIR_BASE/dashy-seed"
git clone -q "$RESET_REMOTE" "$DASHY_SEED" >/dev/null 2>&1
_git_prepare_repo "$DASHY_SEED"
DASHY_MARKER="$TMPDIR_BASE/dashy-marker"
printf 'dashy-marker-sentinel\n' > "$DASHY_MARKER"
touch -d "1999-12-31T00:00:00Z" "$DASHY_MARKER" 2>/dev/null || true

while IFS='|' read -r dashy_label dashy_value; do
    dashy_label="${dashy_label//[[:space:]]/}"
    case "$dashy_label" in ''|'#'*) continue ;; esac
    dashy_value="$(printf '%s' "$dashy_value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    dashy_value="${dashy_value//@MARKER@/$DASHY_MARKER}"

    # #2658: the engine's apply path is the sink now. Seed the row through the
    # remote so reset writes the file itself; a rejected value leaves the write
    # time as the mtime, stays silent, and is counted in the state file.
    git -C "$DASHY_SEED" fetch -q origin >/dev/null 2>&1
    git -C "$DASHY_SEED" reset -q --hard origin/main >/dev/null 2>&1
    printf '{"timestamp":"%s","type":"user"}\n' "$dashy_value" > "$DASHY_SEED/dash-$dashy_label.jsonl"
    git -C "$DASHY_SEED" add . >/dev/null 2>&1
    git -C "$DASHY_SEED" commit -qm "seed dash $dashy_label" >/dev/null 2>&1
    git -C "$DASHY_SEED" push -q origin HEAD:main >/dev/null 2>&1
    DASHY_FILE="$RESET_PROJECTS/dash-$dashy_label.jsonl"
    rm -f "$DASHY_FILE"
    rejected_before=$(_rs_mtime_rejected)
    marker_mtime_before=$(_mtime_of "$DASHY_MARKER")
    marker_body_before=$(cat "$DASHY_MARKER")
    dashy_start=$(date +%s)

    dashy_err="$TMPDIR_BASE/dashy-stderr-$dashy_label.txt"
    exit_code=0
    output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>"$dashy_err") || exit_code=$?
    dashy_after=$(_mtime_of "$DASHY_FILE")
    rejected_after=$(_rs_mtime_rejected)
    marker_mtime_after=$(_mtime_of "$DASHY_MARKER")
    marker_body_after=$(cat "$DASHY_MARKER")

    # (1) The sweep must complete — a rejected timestamp is not a fatal error and
    #     must not abort the reset before the remaining files are handled.
    if [ "$exit_code" -eq 0 ] && echo "$output" | grep -qi "reset to remote" && [ -f "$DASHY_FILE" ]; then
        pass "dash timestamp [$dashy_label]: reset completes and writes the file"
    else
        fail "dash timestamp [$dashy_label]: reset aborted or file missing (exit=$exit_code, output: $output)"
    fi

    # (2) The apply path rejects silently and counts the rejection (#2658). Git's own
    #     fetch progress may reach stderr; a report about this row may not.
    if ! grep -qiE "warn:|touch:|dash-$dashy_label" "$dashy_err" && [ "$rejected_after" -gt "$rejected_before" ]; then
        pass "dash timestamp [$dashy_label]: silent rejection counted in mtimeRejected"
    else
        fail "dash timestamp [$dashy_label]: mtimeRejected $rejected_before -> $rejected_after, stderr: $(cat "$dashy_err")"
    fi

    # (3) The value must never become the target file's mtime: it keeps the write time.
    if [ "$dashy_after" -ge $((dashy_start - 5)) ]; then
        pass "dash timestamp [$dashy_label]: target mtime is the write time"
    else
        fail "dash timestamp [$dashy_label]: target mtime moved to $dashy_after (reset started at $dashy_start)"
    fi

    # (4) No OTHER file may be disturbed — in particular the file the payload
    #     names via --reference= / -r, neither its mtime nor its content.
    if [ "$marker_mtime_before" = "$marker_mtime_after" ] && [ "$marker_body_before" = "$marker_body_after" ]; then
        pass "dash timestamp [$dashy_label]: the referenced unrelated file is untouched"
    else
        fail "dash timestamp [$dashy_label]: unrelated file changed (mtime $marker_mtime_before -> $marker_mtime_after, body changed=$([ "$marker_body_before" = "$marker_body_after" ] && echo no || echo yes))"
    fi
done <<'TABLE'
long-option-with-value | --reference=@MARKER@
short-option-attached  | -r@MARKER@
short-option-t-form    | -t202001010000
long-option-date-epoch | --date=@0
bare-dash              | -
double-dash-terminator | --
TABLE

# --- Edge (#2658): Reset keeps diverged local data and does not push ---
echo "[reset] Reset keeps diverged local data"
echo '{"diverged":"data"}' > "$RESET_PROJECTS/diverged.jsonl"
git -C "$RESET_PROJECTS" add . >/dev/null 2>&1
git -C "$RESET_PROJECTS" commit -m "local diverged commit" >/dev/null 2>&1
echo '{"untracked":"local-only"}' > "$RESET_PROJECTS/reset-local-only.jsonl"
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
if [ -f "$RESET_PROJECTS/diverged.jsonl" ] && [ -f "$RESET_PROJECTS/reset-local-only.jsonl" ]; then
    pass "reset keeps the locally committed and the untracked local-only file"
else
    fail "reset dropped local data (diverged=$([ -f "$RESET_PROJECTS/diverged.jsonl" ] && echo kept || echo LOST), local-only=$([ -f "$RESET_PROJECTS/reset-local-only.jsonl" ] && echo kept || echo LOST), output: $output)"
fi
if git -C "$RESET_REMOTE" cat-file -e main:diverged.jsonl 2>/dev/null \
    || git -C "$RESET_REMOTE" cat-file -e main:reset-local-only.jsonl 2>/dev/null; then
    fail "reset pushed local data to the remote (reset must never push)"
else
    pass "reset does not push"
fi

# --- Edge (#2658): Reset restores a locally deleted file that the remote has ---
echo "[reset] Reset restores a locally deleted remote file"
rm -f "$RESET_PROJECTS/seed-session.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1 || true
if [ -f "$RESET_PROJECTS/seed-session.jsonl" ] && grep -q '"seed"' "$RESET_PROJECTS/seed-session.jsonl"; then
    pass "reset restores the remote copy of a locally deleted file"
else
    fail "reset did not restore seed-session.jsonl"
fi

# --- Edge (#2658): a non-jsonl file differing from the remote keeps both versions ---
echo "[reset] Reset puts remote at the path and local into a sync-conflict sibling"
git -C "$DASHY_SEED" fetch -q origin >/dev/null 2>&1
git -C "$DASHY_SEED" reset -q --hard origin/main >/dev/null 2>&1
printf 'remote\n' > "$DASHY_SEED/reset-note.md"
git -C "$DASHY_SEED" add . >/dev/null 2>&1
git -C "$DASHY_SEED" commit -qm "seed reset-note" >/dev/null 2>&1
git -C "$DASHY_SEED" push -q origin HEAD:main >/dev/null 2>&1
printf 'local\n' > "$RESET_PROJECTS/reset-note.md"
"$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1 || true
rs_siblings=$(find "$RESET_PROJECTS" -maxdepth 1 -name 'reset-note.sync-conflict-*.md' 2>/dev/null)
rs_sibling_count=$(printf '%s' "$rs_siblings" | grep -c . || true)
if [ "$(cat "$RESET_PROJECTS/reset-note.md" 2>/dev/null)" = "remote" ] && [ "$rs_sibling_count" -eq 1 ] \
    && [ "$(cat "$rs_siblings" 2>/dev/null)" = "local" ]; then
    pass "reset keeps remote at the path and local content in one sync-conflict sibling"
else
    fail "reset conflict: path=$(cat "$RESET_PROJECTS/reset-note.md" 2>/dev/null), siblings=$rs_sibling_count ($rs_siblings)"
fi

# --- Edge (#2658): pull / reset never overwrite a locally edited plan ---
# Lives here, not in plans.sh: that file is a multi-path part the marker gate freezes.
echo "[plans] Pull and reset keep a locally edited plan"
RS_PLANS_LOCAL="$TMPDIR_BASE/reset-plans-local"
mkdir -p "$RS_PLANS_LOCAL"
git -C "$DASHY_SEED" fetch -q origin >/dev/null 2>&1
git -C "$DASHY_SEED" reset -q --hard origin/main >/dev/null 2>&1
mkdir -p "$DASHY_SEED/plans"
printf 'synced plan\n' > "$DASHY_SEED/plans/rs-edited.md"
git -C "$DASHY_SEED" add . >/dev/null 2>&1
git -C "$DASHY_SEED" commit -qm "seed plan" >/dev/null 2>&1
git -C "$DASHY_SEED" push -q origin HEAD:main >/dev/null 2>&1
WORKFLOW_PLANS_DIR="$RS_PLANS_LOCAL" "$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1 || true
if [ "$(cat "$RS_PLANS_LOCAL/rs-edited.md" 2>/dev/null)" = "synced plan" ]; then
    pass "pull copies a plan that PLANS_DIR lacks"
else
    fail "pull did not copy plans/rs-edited.md into PLANS_DIR"
fi
printf 'edited locally\n' > "$RS_PLANS_LOCAL/rs-edited.md"
WORKFLOW_PLANS_DIR="$RS_PLANS_LOCAL" "$DOTFILES_DIR/bin/session-sync.sh" pull --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1 || true
rs_after_pull=$(cat "$RS_PLANS_LOCAL/rs-edited.md" 2>/dev/null)
WORKFLOW_PLANS_DIR="$RS_PLANS_LOCAL" "$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1 || true
rs_after_reset=$(cat "$RS_PLANS_LOCAL/rs-edited.md" 2>/dev/null)
if [ "$rs_after_pull" = "edited locally" ] && [ "$rs_after_reset" = "edited locally" ]; then
    pass "pull and reset keep the locally edited plan"
else
    fail "local plan edit overwritten (after pull: $rs_after_pull, after reset: $rs_after_reset)"
fi

# --- Normal: Push copies history.jsonl into sync area ---
echo "[history] Push copies history.jsonl"
echo '{"display":"test","project":"test","sessionId":"h1"}' > "$RESET_CLAUDE/history.jsonl"
echo '{"new":"trigger"}' > "$RESET_PROJECTS/trigger.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" push --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1
if [ -f "$RESET_PROJECTS/.history.jsonl" ]; then
    pass "push copies history.jsonl into sync area"
else
    fail "push did not copy history.jsonl"
fi

# --- Normal: Reset merges remote history.jsonl with local ---
echo "[history] Reset merges history.jsonl"
# Seed remote with .history.jsonl containing a remote entry
HIST_SEED="$TMPDIR_BASE/hist-seed"
git clone "$RESET_REMOTE" "$HIST_SEED" >/dev/null 2>&1
_git_prepare_repo "$HIST_SEED"
echo '{"display":"remote","sessionId":"r1","timestamp":1000}' > "$HIST_SEED/.history.jsonl"
git -C "$HIST_SEED" add . >/dev/null 2>&1
git -C "$HIST_SEED" commit -m "add history" >/dev/null 2>&1
git -C "$HIST_SEED" push >/dev/null 2>&1
# Create local-only entry
echo '{"display":"local","sessionId":"l1","timestamp":2000}' > "$RESET_CLAUDE/history.jsonl"
"$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" >/dev/null 2>&1 || true
if grep -q "r1" "$RESET_CLAUDE/history.jsonl" && grep -q "l1" "$RESET_CLAUDE/history.jsonl"; then
    pass "reset merges remote and local history"
else
    fail "reset did not merge history (content: $(cat "$RESET_CLAUDE/history.jsonl"))"
fi

# --- Error: Reset when not initialized ---
echo "[reset] Not initialized"
RESET_NOTINIT="$TMPDIR_BASE/reset-notinit/.claude"
mkdir -p "$RESET_NOTINIT/projects"
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_NOTINIT" 2>&1) || true
if echo "$output" | grep -qi "not initialized"; then
    pass "reset error when not initialized"
else
    fail "reset no error for uninitialized (output: $output)"
fi
