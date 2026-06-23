
# ============================================================================
# L1 unit — #730 large-file --input regression (cases 46–48)
# ============================================================================
# Issue #730: blob/PUT creation must use `gh api --input <file>` not
# `-f content=$B64` (the latter blows up ARG_MAX for files > ~32 KiB on
# Windows / msys). These tests assert that the captured invocation reads the
# JSON payload from a temp file rather than from an inline argv argument.

test_l1_46_git_data_blob_uses_input_json() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_46_git_data_blob_uses_input_json" || return
    local tmpf stubdir
    tmpf="$TMPDIR_BASE/l1-46-large.b64"
    # Generate 50 KB file (well above msys/Windows ARG_MAX for inline -f content=).
    head -c 51200 /dev/urandom | base64 | tr -d '\n' > "$tmpf"

    stubdir="$(make_gh_stub_git_data_ok "l1-46-input")"

    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "large" \
        --file "docs/history.md=$tmpf")"
    exit_code=$?
    if [ "$exit_code" != "0" ]; then
        fail "L1.46 #730: git-data-write with large file: expected exit 0 got $exit_code ($out)"
        rm -f "$tmpf"
        return
    fi

    # Blob body should have been captured by the stub (only possible if --input was used).
    local blob_body="$stubdir/calls.log.blob_body_1"
    if [ ! -f "$blob_body" ]; then
        fail "L1.46 #730: blob body not captured — source still uses -f content= (no --input)"
        rm -f "$tmpf"
        return
    fi

    local ok=1
    if ! grep -q '"encoding"' "$blob_body"; then
        fail "L1.46 #730: blob body missing \"encoding\" field"
        ok=0
    fi
    if ! grep -q '"content"' "$blob_body"; then
        fail "L1.46 #730: blob body missing \"content\" field"
        ok=0
    fi
    if [ "$ok" = "1" ]; then
        pass "L1.46 #730: blob create uses --input JSON (contains encoding + content)"
    fi

    rm -f "$tmpf"
}

test_l1_47_git_data_no_inline_content_in_invocations() {
    require_file "$GIT_DATA_WRITE_SH" "test_l1_47_git_data_no_inline_content_in_invocations" || return
    local tmpf stubdir
    tmpf="$TMPDIR_BASE/l1-47-large.b64"
    head -c 51200 /dev/urandom | base64 | tr -d '\n' > "$tmpf"

    stubdir="$(make_gh_stub_git_data_ok "l1-47-regression")"
    local out exit_code
    out="$(run_git_data_write "$stubdir" \
        --owner test --repo demo \
        --branch main \
        --message "large" \
        --file "docs/history.md=$tmpf")"
    exit_code=$?

    # calls.log records every gh invocation's argv (first line of stub appends `"$@"`).
    local calls_log="$stubdir/calls.log"
    if [ ! -f "$calls_log" ]; then
        fail "L1.47 #730: no calls.log captured (exit=$exit_code)"
        rm -f "$tmpf"
        return
    fi

    # Look at the blob-creation invocation specifically.
    local blob_calls
    blob_calls=$(grep 'git/blobs' "$calls_log" 2>/dev/null || true)
    if [ -z "$blob_calls" ]; then
        fail "L1.47 #730: no git/blobs call recorded (exit=$exit_code)"
        rm -f "$tmpf"
        return
    fi

    local violation=0
    # Old broken pattern: -f content=<base64>
    if echo "$blob_calls" | grep -E -- '-f[[:space:]]+content=' >/dev/null 2>&1; then
        fail "L1.47 #730: found '-f content=' in blob invocation (should use --input)"
        violation=1
    fi
    # Interim broken pattern: --raw-field content=@FILE (gh @-prefix does not expand here)
    if echo "$blob_calls" | grep -E -- '--raw-field[[:space:]]+content=@' >/dev/null 2>&1; then
        fail "L1.47 #730: found '--raw-field content=@' in blob invocation (broken @FILE pattern)"
        violation=1
    fi
    if [ "$violation" = "0" ]; then
        pass "L1.47 #730: no inline content= in blob gh invocations"
    fi

    rm -f "$tmpf"
}

test_l1_48_contents_write_uses_input_json() {
    require_file "$CONTENTS_WRITE_SH" "test_l1_48_contents_write_uses_input_json" || return
    local stubdir; stubdir="$(make_gh_stub "l1-48-input")"
    # Same stub shape as L1.18: detect --input <path>, copy to put_body.
    cat >> "$stubdir/gh" <<'EOF'
cmd="$*"
if echo "$cmd" | grep -q '\-X PUT'; then
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
        cat > "$LOG.put_body"
    fi
    echo "$@" >> "$LOG.put_args"
    echo '{"commit":{"sha":"def456"}}'
    exit 0
fi
echo '{"sha":"abc123"}'
exit 0
EOF

    # Large file that overflows ARG_MAX on Windows when passed inline.
    local f="$TMPDIR_BASE/l1-48-large.b64"
    head -c 51200 /dev/urandom | base64 | tr -d '\n' > "$f"

    local out exit_code
    out="$(run_contents_write "$stubdir" \
        --owner test --repo demo \
        --path docs/history.md \
        --file "$f" \
        --message "docs(history): record large update" \
        --branch main)"
    exit_code=$?
    if [ "$exit_code" != "0" ]; then
        fail "L1.48 #730: contents-write with large file: expected exit 0 got $exit_code ($out)"
        rm -f "$f"
        return
    fi

    local put_body="$stubdir/calls.log.put_body"
    if [ ! -f "$put_body" ] || [ ! -s "$put_body" ]; then
        fail "L1.48 #730: PUT body not captured (source still uses -f content=, no --input)"
        rm -f "$f"
        return
    fi

    local ok=1
    for field in '"message"' '"branch"' '"content"'; do
        if ! grep -q "$field" "$put_body"; then
            fail "L1.48 #730: PUT body missing field $field"
            ok=0
        fi
    done

    # Regression: no -f content= in the PUT call args.
    local put_args="$stubdir/calls.log.put_args"
    if [ -f "$put_args" ]; then
        if grep -E -- '-f[[:space:]]+content=' "$put_args" >/dev/null 2>&1; then
            fail "L1.48 #730: found '-f content=' in PUT invocation (should use --input)"
            ok=0
        fi
    fi

    if [ "$ok" = "1" ]; then
        pass "L1.48 #730: PUT uses --input JSON (contains message + branch + content)"
    fi

    rm -f "$f"
}
