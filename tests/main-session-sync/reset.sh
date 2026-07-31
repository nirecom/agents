# Tests: bin/session-sync.sh
# Tags: bin, git, session-sync, reset, mtime, scope:common
# Part of tests/main-session-sync.sh — sourced by that dispatcher, not run alone.

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
    --claude-dir "$RESET_CLAUDE" --remote-url "$RESET_REMOTE" >/dev/null 2>&1
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
RESET_PROJECTS="$RESET_CLAUDE/projects"
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
#
# Scope note (read before changing these assertions):
#   The `touch -d "$ts" "$f"` call in the reset block was reported as an
#   option-injection sink. That was investigated empirically first: with GNU
#   coreutils `touch`, the argument after `-d` is bound positionally by getopt,
#   so values such as `--reference=<file>`, `-r<file>`, `-t202001010000` and
#   `--date=@0` are all consumed as the *date operand*, rejected with
#   "invalid date format", and leave the file's mtime unchanged. No option
#   injection was demonstrated. The `case "$ts" in -*) ts= ;; esac` guard being
#   added is therefore defense-in-depth, not a vulnerability fix, and the
#   assertions below are a REGRESSION GUARD for that new rejection behavior —
#   they do not claim to demonstrate a blocked exploit.
#
#   Verified against GNU coreutils touch only (Windows Git Bash / MSYS2).
#   BSD/macOS touch has different flag parsing and was not exercised here —
#   a known coverage limitation, not an assumption of universality.
#   Payload matrix: identical to the one pinned for bin/cc-session-mtime in
#   tests/cc-session-mtime.sh. The two `touch -d "$ts" "$f"` sinks are symmetric
#   members of one class (CPR-5), so neither may carry a narrower matrix than the
#   other — a shape rejected in one tool but accepted in the other is exactly the
#   asymmetry this pairing exists to catch.
#
#   Table-driven per skills/_shared/test-design/parser-regex-tests.md.
#   Columns: case-name | timestamp value written into the JSONL row
#     @MARKER@ expands to $DASHY_MARKER — an unrelated pre-existing file the
#     option-shaped value points at, so assertion (4) can prove it stayed intact.
echo "[reset] Dash-leading timestamp payload matrix (#1218 hardening guard)"
DASHY_MARKER="$TMPDIR_BASE/dashy-marker"
printf 'dashy-marker-sentinel\n' > "$DASHY_MARKER"
touch -d "1999-12-31T00:00:00Z" "$DASHY_MARKER" 2>/dev/null || true

while IFS='|' read -r dashy_label dashy_value; do
    dashy_label="${dashy_label//[[:space:]]/}"
    case "$dashy_label" in ''|'#'*) continue ;; esac
    dashy_value="$(printf '%s' "$dashy_value" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
    dashy_value="${dashy_value//@MARKER@/$DASHY_MARKER}"

    DASHY_FILE="$RESET_PROJECTS/dash-$dashy_label.jsonl"
    printf '{"timestamp":"%s","type":"user"}\n' "$dashy_value" > "$DASHY_FILE"
    # Pin a known mtime so any change is detectable (untracked files survive
    # `git reset --hard`, so the file is still there when the sweep reaches it).
    touch -d "2024-06-01T00:00:00Z" "$DASHY_FILE" 2>/dev/null || true
    dashy_before=$(_mtime_of "$DASHY_FILE")
    marker_mtime_before=$(_mtime_of "$DASHY_MARKER")
    marker_body_before=$(cat "$DASHY_MARKER")

    dashy_err="$TMPDIR_BASE/dashy-stderr-$dashy_label.txt"
    exit_code=0
    output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>"$dashy_err") || exit_code=$?
    dashy_after=$(_mtime_of "$DASHY_FILE")
    marker_mtime_after=$(_mtime_of "$DASHY_MARKER")
    marker_body_after=$(cat "$DASHY_MARKER")

    # (1) The sweep must complete — a rejected timestamp is not a fatal error and
    #     must not abort the reset loop before the remaining files are handled.
    if [ "$exit_code" -eq 0 ] && echo "$output" | grep -qi "reset to remote"; then
        pass "dash timestamp [$dashy_label]: reset completes"
    else
        fail "dash timestamp [$dashy_label]: reset aborted (exit=$exit_code, output: $output)"
    fi

    # (2) Regression guard for the new explicit rejection: the guard must announce
    #     that it dropped the value, so a future refactor cannot silently remove
    #     it. RED until the `case "$ts" in -*)` guard + warning land in
    #     bin/session-sync.sh — this is a guard against losing a new rejection
    #     behavior, not a demonstration of a blocked exploit.
    if grep -qiE "warn|skip|ignor|reject|invalid" "$dashy_err" 2>/dev/null; then
        pass "dash timestamp [$dashy_label]: warns on stderr"
    else
        fail "dash timestamp [$dashy_label]: no stderr warning (stderr: $(cat "$dashy_err"))"
    fi

    # (3) The value must never become the target file's mtime.
    if [ "$dashy_before" = "$dashy_after" ]; then
        pass "dash timestamp [$dashy_label]: target mtime unchanged"
    else
        fail "dash timestamp [$dashy_label]: target mtime changed ($dashy_before -> $dashy_after)"
    fi

    # (4) No OTHER file may be disturbed — in particular the file the payload
    #     names via --reference= / -r, neither its mtime nor its content.
    if [ "$marker_mtime_before" = "$marker_mtime_after" ] && [ "$marker_body_before" = "$marker_body_after" ]; then
        pass "dash timestamp [$dashy_label]: the referenced unrelated file is untouched"
    else
        fail "dash timestamp [$dashy_label]: unrelated file changed (mtime $marker_mtime_before -> $marker_mtime_after, body changed=$([ "$marker_body_before" = "$marker_body_after" ] && echo no || echo yes))"
    fi

    rm -f "$DASHY_FILE"
done <<'TABLE'
long-option-with-value | --reference=@MARKER@
short-option-attached  | -r@MARKER@
short-option-t-form    | -t202001010000
long-option-date-epoch | --date=@0
bare-dash              | -
double-dash-terminator | --
TABLE

# --- Edge: Reset discards diverged local commits ---
echo "[reset] Reset discards diverged local"
echo '{"diverged":"data"}' > "$RESET_PROJECTS/diverged.jsonl"
git -C "$RESET_PROJECTS" add . >/dev/null 2>&1
git -C "$RESET_PROJECTS" commit -m "local diverged commit" >/dev/null 2>&1
output=$("$DOTFILES_DIR/bin/session-sync.sh" reset --claude-dir "$RESET_CLAUDE" 2>&1) || true
if [ ! -f "$RESET_PROJECTS/diverged.jsonl" ]; then
    pass "reset discards diverged local file"
else
    fail "reset did not discard diverged local file"
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
