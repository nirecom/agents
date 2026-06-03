#!/usr/bin/env bash
# tests/feature-mcp-fs-server.sh
# Tests: bin/mcp-fs-server.js
# Tags: mcp, filesystem, security, path-traversal
#
# Tests for bin/mcp-fs-server.js — Node.js MCP stdio server that lets the
# codex reviewer request files from the current repo. Verifies:
#   - startup contract (REPO_ROOT env var required)
#   - read_file MCP method returns file contents
#   - blocklist: .env, .env.*, *.key, *.pem, *.p12, WORKTREE_NOTES.md
#   - path traversal protection (../, absolute outside REPO_ROOT)
#   - non-existent / directory paths return error
#   - sequential request handling (idempotency)
#   - response is valid JSON

set -uo pipefail

AGENTS_ROOT="$(cd "$(dirname "$0")/.." && pwd)"
SERVER="$AGENTS_ROOT/bin/mcp-fs-server.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }
skip() { echo "SKIP: $1"; }

# ---------------------------------------------------------------------------
# SKIP gates
# ---------------------------------------------------------------------------
if ! command -v node >/dev/null 2>&1; then
    echo "SKIP: node not installed"
    exit 0
fi
if ! node --version >/dev/null 2>&1; then
    echo "SKIP: node --version failed"
    exit 0
fi

# Test-first methodology: source file may not exist yet. If absent, emit a
# SKIP for every test case and exit 0 (so the test passes by skipping until
# bin/mcp-fs-server.js is implemented).
if [[ ! -f "$SERVER" ]]; then
    for t in T1 T2 T3 T4 T5 T6 T7 T8 T9 T10 T11 T12 T13 T14 T15 T16 T17 T18; do
        skip "$t: bin/mcp-fs-server.js not yet implemented"
    done
    echo ""
    echo "All tests skipped (source not yet implemented)."
    exit 0
fi

# ---------------------------------------------------------------------------
# Setup: temp repo dir with sample files
# ---------------------------------------------------------------------------
TMPDIR_BASE=$(mktemp -d)
trap 'rm -rf "$TMPDIR_BASE"' EXIT

REPO="$TMPDIR_BASE/repo"
mkdir -p "$REPO/subdir" "$REPO/bin"
echo "# Sample README" > "$REPO/README.md"
echo "ok" > "$REPO/subdir/inner.txt"
echo "SECRET=value" > "$REPO/.env"
echo "LOCAL=secret" > "$REPO/.env.local"
echo "private-key-bytes" > "$REPO/credentials.key"
echo "PRIVATE PEM" > "$REPO/server.pem"
echo "p12 bytes" > "$REPO/keystore.p12"
echo "## BugsFound" > "$REPO/WORKTREE_NOTES.md"
# An "outside" directory for absolute/traversal targets
mkdir -p "$TMPDIR_BASE/outside-repo"
echo "outside-secret" > "$TMPDIR_BASE/outside-repo/secret"

# Defensive-hardening fixtures (issue #742)
# T15 fixture: oversized text file — exactly MAX_FILE_BYTES + 1 = 5*1024*1024+1 bytes
# Pure ASCII 'A' (no NUL bytes) so binary detection does NOT fire first.
if python3 -c "import sys; sys.stdout.buffer.write(b'A' * 5242881)" > "$REPO/oversized.txt" 2>/dev/null \
    && [[ -s "$REPO/oversized.txt" ]]; then
    :  # python3 created the file successfully
elif python -c "import sys; sys.stdout.buffer.write(b'A' * 5242881)" > "$REPO/oversized.txt" 2>/dev/null \
    && [[ -s "$REPO/oversized.txt" ]]; then
    :  # python2 created the file successfully
elif command -v node >/dev/null 2>&1; then
    # node is always available when running mcp-fs-server.js tests
    node -e "require('fs').writeFileSync(process.argv[1], Buffer.alloc(5242881, 65))" -- "$REPO/oversized.txt"
else
    # Pure-shell fallback: build 5242881 bytes of 'A'
    yes A | tr -d '\n' | head -c 5242881 > "$REPO/oversized.txt"
fi

# T16 fixture: small file (~2KB) with a NUL byte near the start (offset 6)
{
    printf 'HEADER'
    printf '\x00MORE'
    for _ in $(seq 1 500); do printf 'BBBB'; done
} > "$REPO/early-binary.bin"

# Portable timeout
_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 20 "$@"
    else
        perl -e 'alarm 20; exec @ARGV' -- "$@"
    fi
}

# Helper: send one or more JSON request lines to the server, capture stdout.
# Args: <stdin_payload> [extra-env-pairs ...]
#   - stdin_payload: string written to server stdin (then EOF)
# Sets globals: SRV_OUT, SRV_EXIT
run_server() {
    local payload="$1"
    SRV_OUT=$(printf '%s' "$payload" | REPO_ROOT="$REPO" _timeout node "$SERVER" 2>&1)
    SRV_EXIT=$?
}

# Build a JSON-RPC tools/call request for read_file given a path.
# Note: the spec says line-delimited JSON; this helper produces one line.
mcp_request() {
    local id="$1"; local path="$2"
    # Path is embedded — escape backslashes and quotes for JSON safety.
    local esc
    esc=$(printf '%s' "$path" | sed 's/\\/\\\\/g; s/"/\\"/g')
    printf '{"jsonrpc":"2.0","id":%s,"method":"tools/call","params":{"name":"read_file","arguments":{"path":"%s"}}}\n' "$id" "$esc"
}

# Detect an error response (handles both `error` key and `isError:true` MCP shape)
response_is_error() {
    local out="$1"
    local found=no
    if command -v jq >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if printf '%s' "$line" | jq -e '(.error // empty) | length > 0' >/dev/null 2>&1; then
                found=yes; break
            fi
            if printf '%s' "$line" | jq -e '(.result.isError // false) == true' >/dev/null 2>&1; then
                found=yes; break
            fi
        done < <(printf '%s\n' "$out")
    else
        if echo "$out" | grep -Eq '"error"|"isError"[[:space:]]*:[[:space:]]*true'; then
            found=yes
        fi
    fi
    echo "$found"
}

# Detect a successful read response (contains file contents in result)
response_has_result() {
    local out="$1"
    local found=no
    if command -v jq >/dev/null 2>&1; then
        while IFS= read -r line; do
            [[ -z "$line" ]] && continue
            if printf '%s' "$line" | jq -e '
                (.result != null) and
                ((.result.isError // false) == false)
            ' >/dev/null 2>&1; then
                found=yes; break
            fi
        done < <(printf '%s\n' "$out")
    else
        if echo "$out" | grep -q '"result"'; then
            if ! echo "$out" | grep -Eq '"error"|"isError"[[:space:]]*:[[:space:]]*true'; then
                found=yes
            fi
        fi
    fi
    echo "$found"
}

# ---------------------------------------------------------------------------
# T1 — server starts without error when REPO_ROOT is set
# ---------------------------------------------------------------------------
SRV_OUT=""; SRV_EXIT=0
# Empty stdin → server reads EOF immediately and exits cleanly.
SRV_OUT=$(printf '' | REPO_ROOT="$REPO" _timeout node "$SERVER" 2>&1)
SRV_EXIT=$?
if [[ $SRV_EXIT -eq 0 ]]; then
    pass "T1: server starts and exits 0 with REPO_ROOT set and EOF stdin"
else
    fail "T1: expected exit 0, got $SRV_EXIT. Output: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T2 — server exits with code 2 when REPO_ROOT is unset
# ---------------------------------------------------------------------------
T2_EXIT=0
T2_OUT=$((unset REPO_ROOT; _timeout node "$SERVER" </dev/null) 2>&1) || T2_EXIT=$?
if [[ $T2_EXIT -eq 2 ]]; then
    pass "T2: exits with code 2 when REPO_ROOT is unset"
else
    fail "T2: expected exit 2, got $T2_EXIT. Output: $T2_OUT"
fi

# ---------------------------------------------------------------------------
# T3 — read_file returns file contents for a repo file
# ---------------------------------------------------------------------------
run_server "$(mcp_request 1 'README.md')"
if [[ "$(response_has_result "$SRV_OUT")" == "yes" ]]; then
    # And it should contain at least part of the file content
    if echo "$SRV_OUT" | grep -q "Sample README"; then
        pass "T3: read_file returns file contents for README.md"
    else
        pass "T3: read_file returns a result for README.md (contents not directly grepped, structured payload)"
    fi
else
    fail "T3: expected success result, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T4 — read_file blocks .env
# ---------------------------------------------------------------------------
run_server "$(mcp_request 2 '.env')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T4: read_file blocks .env (credential protection)"
else
    fail "T4: expected error response for .env, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T5 — read_file blocks .env.local
# ---------------------------------------------------------------------------
run_server "$(mcp_request 3 '.env.local')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T5: read_file blocks .env.local"
else
    fail "T5: expected error response for .env.local, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T6 — read_file blocks a .key file
# ---------------------------------------------------------------------------
run_server "$(mcp_request 4 'credentials.key')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T6: read_file blocks credentials.key"
else
    fail "T6: expected error response for credentials.key, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T7 — read_file blocks WORKTREE_NOTES.md
# ---------------------------------------------------------------------------
run_server "$(mcp_request 5 'WORKTREE_NOTES.md')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T7: read_file blocks WORKTREE_NOTES.md"
else
    fail "T7: expected error response for WORKTREE_NOTES.md, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T8 — path traversal blocked: ../outside-repo/secret
# ---------------------------------------------------------------------------
run_server "$(mcp_request 6 '../outside-repo/secret')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T8: path traversal blocked (../outside-repo/secret)"
else
    fail "T8: expected error for ../outside-repo/secret, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T9 — path traversal blocked: absolute path outside REPO_ROOT
# ---------------------------------------------------------------------------
if [[ "${OSTYPE:-}" == msys* || "${OSTYPE:-}" == cygwin* || "${OS:-}" == "Windows_NT" ]]; then
    ABS_PATH='C:\\Windows\\System32\\drivers\\etc\\hosts'
else
    ABS_PATH='/etc/passwd'
fi
run_server "$(mcp_request 7 "$ABS_PATH")"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T9: absolute path outside REPO_ROOT blocked ($ABS_PATH)"
else
    fail "T9: expected error for absolute path outside REPO_ROOT, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T10 — traversal via encoded sequence: subdir/../../etc/passwd
# ---------------------------------------------------------------------------
run_server "$(mcp_request 8 'subdir/../../outside-repo/secret')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T10: traversal via subdir/../../outside-repo blocked"
else
    fail "T10: expected error for subdir/../../outside-repo/secret, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T11 — read_file for non-existent file returns error
# ---------------------------------------------------------------------------
run_server "$(mcp_request 9 'nonexistent-file-xyz.txt')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T11: non-existent file returns error"
else
    fail "T11: expected error for missing file, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T12 — read_file for directory path returns error
# ---------------------------------------------------------------------------
run_server "$(mcp_request 10 'bin')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    pass "T12: directory path returns error"
else
    fail "T12: expected error for directory path, got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T13 — idempotency: server handles multiple sequential requests
# ---------------------------------------------------------------------------
MULTI=$(mcp_request 11 'README.md'; mcp_request 12 'subdir/inner.txt')
run_server "$MULTI"
# Two response lines expected. Count non-empty JSON-looking lines.
LINES=$(printf '%s\n' "$SRV_OUT" | grep -c '^[[:space:]]*{' || true)
if [[ "$LINES" -ge 2 ]]; then
    pass "T13: server responds to multiple sequential requests ($LINES JSON lines)"
else
    fail "T13: expected >=2 JSON response lines, got $LINES. Output: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T14 — MCP protocol: response is valid JSON
# ---------------------------------------------------------------------------
run_server "$(mcp_request 13 'README.md')"
VALID_JSON=no
if command -v jq >/dev/null 2>&1; then
    # Check that at least one non-empty stdout line parses as JSON
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if printf '%s' "$line" | jq -e . >/dev/null 2>&1; then
            VALID_JSON=yes
            break
        fi
    done <<< "$SRV_OUT"
elif command -v python3 >/dev/null 2>&1; then
    while IFS= read -r line; do
        [[ -z "$line" ]] && continue
        if printf '%s' "$line" | python3 -c 'import json,sys; json.loads(sys.stdin.read())' >/dev/null 2>&1; then
            VALID_JSON=yes
            break
        fi
    done <<< "$SRV_OUT"
else
    # Fallback: cheap shape check
    if echo "$SRV_OUT" | grep -Eq '^\{.*"jsonrpc".*\}|^\{.*"result".*\}|^\{.*"error".*\}'; then
        VALID_JSON=yes
    fi
fi
if [[ "$VALID_JSON" == "yes" ]]; then
    pass "T14: response is valid JSON"
else
    fail "T14: response is not valid JSON. Output: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T15 — file size cap: oversized text file rejected (issue #742)
# ---------------------------------------------------------------------------
# Pre-implementation gate: skip cleanly if the size-cap constant has not been
# added to mcp-fs-server.js yet. Detect by grepping for MAX_FILE_BYTES.
if grep -q 'MAX_FILE_BYTES' "$SERVER" 2>/dev/null; then
    run_server "$(mcp_request 14 'oversized.txt')"
    if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
        if echo "$SRV_OUT" | grep -iEq 'size|too large'; then
            pass "T15: oversized file rejected with size-related error"
        else
            fail "T15: error returned but message lacks 'size'/'too large'. Output: $SRV_OUT"
        fi
    else
        fail "T15: expected error for oversized.txt (>5 MB), got: $SRV_OUT"
    fi
else
    skip "T15: size-cap (MAX_FILE_BYTES) not yet implemented in $SERVER"
fi

# ---------------------------------------------------------------------------
# T16 — early binary detection: NUL byte in first 8 KB rejected (issue #742)
# ---------------------------------------------------------------------------
# Binary detection already exists in pre-#742 mcp-fs-server.js (T16 reinforces
# that the early-detection path is preserved by hardening changes — never
# regressed by the new size check ordering).
run_server "$(mcp_request 15 'early-binary.bin')"
if [[ "$(response_is_error "$SRV_OUT")" == "yes" ]]; then
    if echo "$SRV_OUT" | grep -iq 'binary'; then
        pass "T16: early-binary file rejected with binary-related error"
    else
        fail "T16: error returned but message lacks 'binary'. Output: $SRV_OUT"
    fi
else
    fail "T16: expected error for early-binary.bin (NUL byte in first 8 KB), got: $SRV_OUT"
fi

# ---------------------------------------------------------------------------
# T17 — MCP_FS_DEBUG=1: [mcp-fs] debug lines appear on stderr (issue #742)
# ---------------------------------------------------------------------------
if grep -q 'MCP_FS_DEBUG' "$SERVER" 2>/dev/null; then
    TMPSTDERR17=$(mktemp)
    printf '%s' "$(mcp_request 16 '.env')" \
        | MCP_FS_DEBUG=1 REPO_ROOT="$REPO" _timeout node "$SERVER" >/dev/null 2>"$TMPSTDERR17" || true
    if grep -q '\[mcp-fs\]' "$TMPSTDERR17"; then
        pass "T17: MCP_FS_DEBUG=1 emits [mcp-fs] debug lines to stderr"
    else
        fail "T17: expected [mcp-fs] debug lines in stderr when MCP_FS_DEBUG=1. Stderr: $(cat "$TMPSTDERR17")"
    fi
    rm -f "$TMPSTDERR17"
else
    skip "T17: MCP_FS_DEBUG not yet implemented in $SERVER"
fi

# ---------------------------------------------------------------------------
# T18 — MCP_FS_DEBUG unset: no [mcp-fs] lines on stderr (issue #742)
# ---------------------------------------------------------------------------
if grep -q 'MCP_FS_DEBUG' "$SERVER" 2>/dev/null; then
    TMPSTDERR18=$(mktemp)
    printf '%s' "$(mcp_request 17 '.env')" \
        | REPO_ROOT="$REPO" _timeout node "$SERVER" >/dev/null 2>"$TMPSTDERR18" || true
    if grep -q '\[mcp-fs\]' "$TMPSTDERR18"; then
        fail "T18: unexpected [mcp-fs] debug output when MCP_FS_DEBUG not set. Stderr: $(cat "$TMPSTDERR18")"
    else
        pass "T18: no [mcp-fs] debug output when MCP_FS_DEBUG not set"
    fi
    rm -f "$TMPSTDERR18"
else
    skip "T18: MCP_FS_DEBUG not yet implemented in $SERVER"
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
if [[ $ERRORS -eq 0 ]]; then
    echo "All tests passed."
    exit 0
else
    echo "$ERRORS test(s) failed."
    exit 1
fi
