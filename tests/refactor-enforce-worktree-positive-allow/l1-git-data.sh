
# ============================================================================
# L1 unit — github-git-data-write.sh (cases 19–23)
# ============================================================================

run_git_data_write() {
    local stubdir="$1"; shift
    PATH="$stubdir:$PATH" run_with_timeout 30 bash "$GIT_DATA_WRITE_SH" "$@" 2>&1
}

# Make a stub that always succeeds for git data API.
make_gh_stub_git_data_ok() {
    local scenario="$1"
    local stubdir; stubdir="$(make_gh_stub "$scenario")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
# Categorise calls.
LOG_ORDER="$LOG.order"
if echo "$cmd" | grep -q 'git/blobs'; then
    # Detect --input <path> in argv (post-#730 fix). Copy file to per-blob body.
    input_path=""
    args=( "$@" )
    for ((i=0; i<${#args[@]}; i++)); do
        if [ "${args[i]}" = "--input" ] && (( i+1 < ${#args[@]} )); then
            input_path="${args[i+1]}"
            break
        fi
    done
    if [ -n "$input_path" ] && [ -f "$input_path" ]; then
        # Increment per-stub blob counter using a file (each invocation is a
        # fresh subshell; in-memory counters don't persist).
        BLOB_COUNTER="$LOG.blob_n"
        if [ -f "$BLOB_COUNTER" ]; then
            n=$(cat "$BLOB_COUNTER")
        else
            n=0
        fi
        n=$((n + 1))
        echo "$n" > "$BLOB_COUNTER"
        cp "$input_path" "$LOG.blob_body_$n"
    fi
    echo "blobs" >> "$LOG_ORDER"
    echo '{"sha":"blob-sha-'"$RANDOM"'"}'
    exit 0
fi
if echo "$cmd" | grep -q 'git/trees'; then
    # Capture body for inspection.
    cat > "$LOG.tree_body" 2>/dev/null || true
    echo "trees" >> "$LOG_ORDER"
    echo '{"sha":"tree-sha-1"}'
    exit 0
fi
if echo "$cmd" | grep -q 'git/commits'; then
    echo "commits" >> "$LOG_ORDER"
    echo '{"sha":"commit-sha-1"}'
    exit 0
fi
if echo "$cmd" | grep -q 'git/refs\|git/ref/'; then
    echo "refs" >> "$LOG_ORDER"
    echo '{"ref":"refs/heads/main","object":{"sha":"commit-sha-1"}}'
    exit 0
fi
echo '{}'
exit 0
EOF
    echo "$stubdir"
}

test_l1_19_git_data_call_order_single_file() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_19_git_data_call_order_single_file" || return
    local stubdir; stubdir="$(make_gh_stub_git_data_ok "order-single")"
    local f="$TMPDIR_BASE/single.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "docs(history): record issue #1" \
        --file "docs/history.md=$f")"
    exit_code=$?
    local order_file="$stubdir/calls.log.order"
    if [ ! -f "$order_file" ]; then
        fail "L1.19 call order: no order log (exit $exit_code, out=$out)"
        return
    fi
    # Expected: blobs → trees → commits → refs
    local actual; actual="$(tr '\n' ',' < "$order_file" | sed 's/,$//')"
    if [ "$actual" = "blobs,trees,commits,refs" ]; then
        pass "L1.19 single-file call order: blobs → trees → commits → refs"
    else
        fail "L1.19 single-file: expected blobs,trees,commits,refs got '$actual'"
    fi
}

test_l1_20_git_data_blobs_before_tree() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_20_git_data_blobs_before_tree" || return
    local stubdir; stubdir="$(make_gh_stub_git_data_ok "blobs-before-tree")"
    local f1="$TMPDIR_BASE/m1.md" f2="$TMPDIR_BASE/m2.md" f3="$TMPDIR_BASE/m3.md"
    echo "file 1" > "$f1"; echo "file 2" > "$f2"; echo "file 3" > "$f3"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "multi" \
        --file "a.md=$f1" --file "b.md=$f2" --file "c.md=$f3")"
    exit_code=$?
    local order_file="$stubdir/calls.log.order"
    if [ ! -f "$order_file" ]; then
        fail "L1.20 multi-file call order: no order log (exit $exit_code)"
        return
    fi
    # Count blobs lines before the first trees line.
    local blob_count=0
    local tree_seen=0
    while IFS= read -r line; do
        if [ "$tree_seen" = "0" ] && [ "$line" = "blobs" ]; then
            blob_count=$((blob_count + 1))
        fi
        if [ "$line" = "trees" ]; then
            tree_seen=1
        fi
    done < "$order_file"
    if [ "$blob_count" = "3" ]; then
        pass "L1.20 3 files: all 3 blobs created before tree POST"
    else
        fail "L1.20 expected 3 blobs before tree, got $blob_count"
    fi
}

test_l1_21_git_data_tree_entry_payload() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_21_git_data_tree_entry_payload" || return
    local stubdir; stubdir="$(make_gh_stub_git_data_ok "tree-payload")"
    local f="$TMPDIR_BASE/payload.md"
    echo "content" > "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "msg" \
        --file "docs/x.md=$f")"
    exit_code=$?
    local tree_body="$stubdir/calls.log.tree_body"
    if [ ! -f "$tree_body" ]; then
        # Alternative: payload may be embedded in args; check args log instead.
        local args="$stubdir/calls.log"
        if grep -q '"mode":"100644"' "$args" 2>/dev/null && grep -q '"type":"blob"' "$args" 2>/dev/null; then
            pass "L1.21 tree entry has mode 100644 + type blob (in args)"
            return
        fi
        fail "L1.21 tree payload not captured (no body file, no args match)"
        return
    fi
    local mode_ok=0 type_ok=0
    if grep -q '"mode"[[:space:]]*:[[:space:]]*"100644"' "$tree_body"; then mode_ok=1; fi
    if grep -q '"type"[[:space:]]*:[[:space:]]*"blob"' "$tree_body"; then type_ok=1; fi
    if [ "$mode_ok" = "1" ] && [ "$type_ok" = "1" ]; then
        pass "L1.21 tree entry has mode 100644 + type blob"
    else
        fail "L1.21 tree entry: mode_ok=$mode_ok type_ok=$type_ok"
    fi
}

test_l1_22_git_data_ref_patch_422_exhausted() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_22_git_data_ref_patch_422_exhausted" || return
    local stubdir; stubdir="$(make_gh_stub "ref-422-exhausted")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q 'git/blobs'; then
    echo '{"sha":"blob1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/trees'; then
    echo '{"sha":"tree1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/commits'; then
    echo '{"sha":"commit1"}'; exit 0
fi
if echo "$cmd" | grep -q '\-X GET.*git/ref/'; then
    echo '{"object":{"sha":"parent-'"$RANDOM"'"}}'
    exit 0
fi
if echo "$cmd" | grep -q '\-X PATCH.*git/refs'; then
    echo "HTTP 422" >&2; exit 1
fi
echo '{}'; exit 0
EOF
    local f="$TMPDIR_BASE/ref422.md"
    echo "x" > "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "msg" \
        --file "docs/x.md=$f")"
    exit_code=$?
    if [ "$exit_code" = "11" ]; then
        pass "L1.22 ref PATCH 422 on all 3 retries: exit 11"
    else
        fail "L1.22 expected exit 11 got $exit_code ($out)"
    fi
}

test_l1_23_git_data_ref_patch_422_then_success() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_23_git_data_ref_patch_422_then_success" || return
    local stubdir; stubdir="$(make_gh_stub "ref-422-then-ok")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
LOG_PATCH="$LOG.patch_count"
LOG_GET="$LOG.get_ref_count"
[ -f "$LOG_PATCH" ] || echo 0 > "$LOG_PATCH"
[ -f "$LOG_GET" ] || echo 0 > "$LOG_GET"
if echo "$cmd" | grep -q 'git/blobs'; then
    echo '{"sha":"blob1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/trees'; then
    echo '{"sha":"tree1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/commits'; then
    echo '{"sha":"commit1"}'; exit 0
fi
if echo "$cmd" | grep -q 'git/ref/' && ! echo "$cmd" | grep -q '\-X PATCH'; then
    n=$(cat "$LOG_GET"); n=$((n+1)); echo $n > "$LOG_GET"
    echo "{\"object\":{\"sha\":\"parent-$n\"}}"; exit 0
fi
if echo "$cmd" | grep -q '\-X PATCH'; then
    n=$(cat "$LOG_PATCH"); n=$((n+1)); echo $n > "$LOG_PATCH"
    if [ "$n" = "1" ]; then
        echo "HTTP 422" >&2; exit 1
    fi
    echo '{"ref":"refs/heads/main"}'; exit 0
fi
echo '{}'; exit 0
EOF
    local f="$TMPDIR_BASE/ref422ok.md"
    echo "x" > "$f"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "msg" \
        --file "docs/x.md=$f")"
    exit_code=$?
    local get_n; get_n=$(cat "$stubdir/calls.log.get_ref_count" 2>/dev/null || echo 0)
    if [ "$exit_code" = "0" ] && [ "$get_n" -ge 2 ]; then
        pass "L1.23 422 once then retry with fresh parent: exit 0 (get_ref called $get_n times)"
    else
        fail "L1.23 422-then-ok: exit=$exit_code get_ref=$get_n ($out)"
    fi
}
