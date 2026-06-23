
# ============================================================================
# L1 unit — github-contents-write.sh (cases 15–18)
# ============================================================================

# Build a stub gh that records calls and returns scripted responses.
# Args: scenario-name
make_gh_stub() {
    local scenario="$1"
    local dir="$TMPDIR_BASE/gh-stub-$scenario"
    mkdir -p "$dir"
    local log="$dir/calls.log"
    : > "$log"
    cat > "$dir/gh" <<EOF
#!/bin/bash
# gh stub for scenario: $scenario
# Records every invocation, replays a scripted sequence.
echo "\$@" >> "$log"
LOG="$log"
SCEN="$scenario"
EOF
    chmod +x "$dir/gh"
    echo "$dir"
}

run_contents_write() {
    local stubdir="$1"; shift
    PATH="$stubdir:$PATH" run_with_timeout 30 bash "$CONTENTS_WRITE_SH" "$@" 2>&1
}

test_l1_15_contents_write_success() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_15_contents_write_success" || return
    local stubdir; stubdir="$(make_gh_stub "ok")"
    # Stub: GET returns sha; PUT returns success.
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q 'api .*-X GET\|api repos/.*/contents/' && ! echo "$cmd" | grep -q '\-X PUT'; then
    echo '{"sha":"abc123"}'
    exit 0
fi
if echo "$cmd" | grep -q '\-X PUT'; then
    echo '{"commit":{"sha":"def456"}}'
    exit 0
fi
exit 0
EOF
    local f="$TMPDIR_BASE/hist-put.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        pass "L1.15 successful PUT with sha: exit 0"
    else
        fail "L1.15 successful PUT: expected exit 0 got $exit_code ($out)"
    fi
}

test_l1_16_contents_write_409_retries() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_16_contents_write_409_retries" || return
    local stubdir; stubdir="$(make_gh_stub "409-retry")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
GET_COUNT_F="$LOG.get_count"
PUT_COUNT_F="$LOG.put_count"
[ -f "$GET_COUNT_F" ] || echo 0 > "$GET_COUNT_F"
[ -f "$PUT_COUNT_F" ] || echo 0 > "$PUT_COUNT_F"
if echo "$cmd" | grep -q '\-X PUT'; then
    n=$(cat "$PUT_COUNT_F"); n=$((n+1)); echo $n > "$PUT_COUNT_F"
    if [ "$n" = "1" ]; then
        echo "HTTP 409 conflict" >&2
        exit 1
    fi
    echo '{"commit":{"sha":"def456"}}'
    exit 0
fi
# GET
n=$(cat "$GET_COUNT_F"); n=$((n+1)); echo $n > "$GET_COUNT_F"
echo "{\"sha\":\"fresh-sha-$n\"}"
exit 0
EOF
    local f="$TMPDIR_BASE/hist-409.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    if [ "$exit_code" = "0" ]; then
        # Verify GET was called at least twice (one for initial, one for refresh on 409).
        local get_n; get_n=$(cat "$stubdir/calls.log.get_count" 2>/dev/null || echo 0)
        if [ "$get_n" -ge 2 ]; then
            pass "L1.16 409 then retry: succeeds with fresh sha (get_count=$get_n)"
        else
            fail "L1.16 409 retry: did not refetch sha (get_count=$get_n)"
        fi
    else
        fail "L1.16 409 then retry: expected exit 0 got $exit_code ($out)"
    fi
}

test_l1_17_contents_write_422_exhausted() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_17_contents_write_422_exhausted" || return
    local stubdir; stubdir="$(make_gh_stub "422-exhausted")"
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q '\-X PUT'; then
    echo "HTTP 422 unprocessable entity" >&2
    exit 1
fi
echo '{"sha":"abc123"}'
exit 0
EOF
    local f="$TMPDIR_BASE/hist-422.md"
    make_valid_history "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    if [ "$exit_code" = "11" ]; then
        if echo "$out" | grep -qi "422\|unprocessable\|exhausted\|retr"; then
            pass "L1.17 422 on all retries: exit 11 with stderr message"
        else
            fail "L1.17 422 exhausted: exit 11 but missing stderr message ($out)"
        fi
    else
        fail "L1.17 422 exhausted: expected exit 11 got $exit_code ($out)"
    fi
}

test_l1_18_contents_write_base64_no_newlines() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_18_contents_write_base64_no_newlines" || return
    local stubdir; stubdir="$(make_gh_stub "base64-check")"
    # Capture the PUT body so we can inspect encoded content.
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q '\-X PUT'; then
    # Detect --input <path> in argv (post-#730 fix). Copy file to put_body.
    input_path=""
    args=( "$@" )
    for ((i=0; i<${#args[@]}; i++)); do
        if [ "${args[i]}" = "--input" ] && (( i+1 < ${#args[@]} )); then
            input_path="${args[i+1]}"
            break
        fi
    done
    if [ -n "$input_path" ] && [ -f "$input_path" ]; then
        cp "$input_path" "$LOG.put_body"
    else
        # Legacy path: dump stdin (gh -F content=@-).
        cat > "$LOG.put_body"
    fi
    echo "$@" >> "$LOG.put_args"
    echo '{"commit":{"sha":"def456"}}'
    exit 0
fi
echo '{"sha":"abc123"}'
exit 0
EOF
    # Use a larger input that would trigger newline-wrapping in base64.
    local f="$TMPDIR_BASE/hist-large.md"
    {
        for i in $(seq 1 50); do
            echo "### Issue #$i (2026-05-31, abcdef$i)"
            echo "Background: filler line $i for base64 width test."
            echo "Changes: more filler content to ensure long base64."
            echo ""
        done
        echo ""
    } > "$f"
    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record issue #1" \
        --branch main)"
    exit_code=$?
    # Check args/body for any base64 content with embedded \n.
    local put_args="$stubdir/calls.log.put_args"
    local put_body="$stubdir/calls.log.put_body"
    if [ ! -f "$put_args" ] && [ ! -f "$put_body" ]; then
        fail "L1.18 base64 newline check: no PUT was issued (exit $exit_code)"
        return
    fi
    # Look for base64 sections (content= or content":") and ensure each is a single line.
    local has_newlines=0
    for ff in "$put_args" "$put_body"; do
        [ -f "$ff" ] || continue
        # Look for base64-like blob with a newline embedded between base64 chars.
        if grep -aP 'content[="][^"]*[A-Za-z0-9+/]\n[A-Za-z0-9+/]' "$ff" >/dev/null 2>&1; then
            has_newlines=1
        fi
    done
    if [ "$has_newlines" = "0" ]; then
        pass "L1.18 base64 content has no embedded newlines"
    else
        fail "L1.18 base64 content contains embedded newlines (macOS tr -d '\\n' missing)"
    fi
}
