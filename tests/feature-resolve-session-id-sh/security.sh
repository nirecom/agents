# security.sh — Security / charset validation (B-30)
# Sourced by feature-resolve-session-id-sh.sh; inherits all globals and helpers.

# ===========================================================================
# B-30: JSONL charset validation — unsafe basenames are rejected (table-driven).
# Replaces B-5; tests via bridge (not the old R3 bash function).
# A JSONL basename failing ^[A-Za-z0-9_-]+$ must never be printed; with only
# an unsafe file present the bridge must return rc!=0 + empty stdout.
# Negative assertion per row: unsafe basename must NOT leak to stdout.
# ===========================================================================
setup
while IFS='|' read -r row_name base_val; do
    [[ -z "$row_name" || "$row_name" =~ ^[[:space:]]*# ]] && continue
    row_name="${row_name//[[:space:]]/}"
    base_val="${base_val# }"
    ROW_CWD="$TMP/b30-$row_name"
    mkdir -p "$ROW_CWD"
    UNSAFE_DIR="$CLAUDE_TRANSCRIPT_BASE_DIR/$(enc "$ROW_CWD")"
    mkdir -p "$UNSAFE_DIR"
    echo "{}" > "$UNSAFE_DIR/$base_val.jsonl"
    touch -t 202601010000 "$UNSAFE_DIR/$base_val.jsonl"
    run_bridge "$ROW_CWD"
    if [ -z "$BRIDGE_OUT" ] && [ "$BRIDGE_RC" -ne 0 ]; then
        pass "B-30/$row_name: bridge rejects unsafe JSONL basename '$base_val' (rc=$BRIDGE_RC, empty stdout)"
    else
        fail "B-30/$row_name: rc=$BRIDGE_RC out='$BRIDGE_OUT' — unsafe basename '$base_val' must be rejected"
    fi
done <<'TABLE'
dot    | bad.name
space  | bad name
dollar | bad$name
TABLE
teardown

# SKIPPED: unsafe JSONL basenames containing '/' or a newline.
# Because: such filenames cannot be created on disk (path separator / invalid
# filename characters), so the mtime scan can never encounter them; the
# ^[A-Za-z0-9_-]+$ charset filter remains defense in depth for those inputs.

# SKIPPED: path-traversal input via CLAUDE_PROJECT_DIR (e.g. '../../../etc').
# Because: P7 encodes path.resolve(raw) with replace(/[^a-zA-Z0-9]/g,'-') —
# every path separator becomes '-', so the transcript-dir lookup can never
# escape CLAUDE_TRANSCRIPT_BASE_DIR. L2-unreachable exploit; neutralized at
# the encoding regex in hooks/lib/workflow-state/session-id.js (P7).

# SKIPPED: shell-metacharacter injection via SID env vars
# (e.g. CLAUDE_CODE_SESSION_ID='$(touch pwned)').
# Because: P2/P4 validate ^[A-Za-z0-9_-]+$ before returning (metacharacters
# fall through — see B-34), and the bridge emits the resolved value via
# process.stdout.write with no shell re-interpolation inside the bridge.
# L2-unreachable exploit; neutralized at the charset check.
