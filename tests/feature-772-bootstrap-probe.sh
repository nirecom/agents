#!/usr/bin/env bash
# filename: tests/feature-772-bootstrap-probe.sh
# Tests: hooks/lib/bootstrap-state.js
# Tags: bootstrap, probe, session-start, new-repo
#
# Tests the pre-bootstrap detection probe for issue #772.
# The probe wraps `git ls-remote` and classifies the result.
#
# RED contract (C4): bootstrap mode is only triggered for an authenticated empty
# remote. Auth/network/timeout/not-found/spawn failures must NOT trigger bootstrap.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
PROBE_LIB="$AGENTS_DIR/hooks/lib/bootstrap-state.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# --- Existence gate ---------------------------------------------------------
if [ ! -f "$PROBE_LIB" ]; then
    echo "FAIL: precondition missing — hooks/lib/bootstrap-state.js (TDD: write source next)"
    echo ""
    echo "Results: 0 passed, 1 failed (expected RED — source not yet implemented)"
    exit 1
fi

# Convert Windows-style backslash path to Node-compatible forward-slash path.
to_node_path() {
    echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'
}
PROBE_LIB_NODE="$(to_node_path "$PROBE_LIB")"

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir shared between bash and Node.js
# (mktemp -d on MSYS returns /tmp/... which Node on Windows can't resolve)
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/cctests772probe.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# --- Mock git harness -------------------------------------------------------
# Each test creates a tmpdir with a fake `git` shell script, prepends it to PATH,
# then invokes the probe. The probe uses spawnSync internally so PATH is honored.

setup_mock_git() {
    MOCK_DIR="$(mktemp -d "${TMPDIR_BASE}/mock.XXXXXXXX")"
    # On Windows, Node spawnSync needs a Windows-executable. Use a .cmd wrapper
    # that delegates to bash + the underlying .sh script. On POSIX, MOCK_GIT
    # points directly to the script.
    MOCK_GIT_SH="$MOCK_DIR/git.sh"
    : > "$MOCK_GIT_SH"
    chmod +x "$MOCK_GIT_SH"
    if [[ "$(uname -s)" =~ ^(MINGW|MSYS|CYGWIN) ]] || [ -n "${OS:-}" ] && [ "${OS:-}" = "Windows_NT" ]; then
        MOCK_GIT="$MOCK_DIR/git.cmd"
        # Resolve the .sh path to Windows native form (c:\... ) for cmd to pass to bash.
        local sh_win
        sh_win="$(to_node_path "$MOCK_GIT_SH" | tr '/' '\\')"
        cat > "$MOCK_GIT" <<EOF
@echo off
"C:\\Program Files\\Git\\usr\\bin\\bash.exe" "$sh_win" %*
EOF
    else
        MOCK_GIT="$MOCK_GIT_SH"
    fi
    OLD_PATH="$PATH"
    export PATH="$MOCK_DIR:$PATH"
    FAKE_REPO="$(mktemp -d "${TMPDIR_BASE}/repo.XXXXXXXX")"
    # Make it look like a git repo so resolution works (not strictly required since
    # the mock git ignores cwd, but harmless).
    mkdir -p "$FAKE_REPO/.git"
}

teardown_mock_git() {
    export PATH="$OLD_PATH"
    [ -n "${MOCK_DIR:-}" ] && [ -d "$MOCK_DIR" ] && rm -rf "$MOCK_DIR"
    [ -n "${FAKE_REPO:-}" ] && [ -d "$FAKE_REPO" ] && rm -rf "$FAKE_REPO"
    unset MOCK_DIR MOCK_GIT FAKE_REPO OLD_PATH
}

# Write a mock git that prints stdout/stderr and exits with the given code.
write_mock_git() {
    local stdout_str="$1" stderr_str="$2" exit_code="$3"
    cat > "$MOCK_GIT_SH" <<EOF
#!/usr/bin/env bash
printf '%s' "$stdout_str"
printf '%s' "$stderr_str" >&2
exit $exit_code
EOF
    chmod +x "$MOCK_GIT_SH"
}

# Write a mock git that sleeps longer than the timeout.
write_mock_git_sleep() {
    local sleep_secs="$1"
    cat > "$MOCK_GIT_SH" <<EOF
#!/usr/bin/env bash
sleep $sleep_secs
exit 0
EOF
    chmod +x "$MOCK_GIT_SH"
}

# Invoke probe. Args: <repo_path> [<git_path_override>] [<timeout_ms>]
# Stores JSON output in $PROBE_OUT.
run_probe() {
    local repo="$1"
    local git_override="${2:-}"
    local timeout_ms="${3:-2000}"
    local repo_node
    repo_node="$(to_node_path "$repo")"
    local git_arg=""
    if [ -n "$git_override" ]; then
        local git_node
        git_node="$(to_node_path "$git_override")"
        git_arg=", gitPath: '$git_node'"
    fi
    PROBE_OUT="$(NODE_NO_WARNINGS=1 run_with_timeout 10 node --no-deprecation -e "
// Node 20+ refuses to spawn .cmd/.bat without shell:true (CVE-2024-27980).
// Monkey-patch spawnSync so the probe lib can target our .cmd mock wrapper
// on Windows without modifying production code.
const cp = require('child_process');
const origSpawnSync = cp.spawnSync;
cp.spawnSync = function (cmd, args, options) {
  if (process.platform === 'win32' && typeof cmd === 'string' && /\.(cmd|bat)\$/i.test(cmd)) {
    const opts = Object.assign({}, options, { shell: true });
    return origSpawnSync(cmd, args, opts);
  }
  return origSpawnSync(cmd, args, options);
};
// Re-require fresh so the patched spawnSync is captured by the module closure.
delete require.cache[require.resolve('$PROBE_LIB_NODE')];
const m = require('$PROBE_LIB_NODE');
const fn = m.isRemoteInPreBootstrap || m.probe || m.default;
if (typeof fn !== 'function') {
  console.error('export missing: isRemoteInPreBootstrap');
  process.exit(2);
}
const opts = { remote: 'origin', timeoutMs: $timeout_ms$git_arg };
const result = fn('$repo_node', opts);
if (result && typeof result.then === 'function') {
  result.then(r => { console.log(JSON.stringify(r)); }).catch(e => {
    console.error(e.message || String(e));
    process.exit(1);
  });
} else {
  console.log(JSON.stringify(result));
}
" 2>&1)" || true
}

# Extract a JSON field from $PROBE_OUT via node.
# PROBE_OUT may contain extraneous lines (e.g. Node deprecation warnings).
# Find the last line that parses as JSON.
json_field() {
    local field="$1"
    node -e "
const out = process.argv[1] || '';
const lines = out.split(/\r?\n/).filter(Boolean);
for (let i = lines.length - 1; i >= 0; i--) {
  try {
    const j = JSON.parse(lines[i]);
    if (j && typeof j === 'object' && Object.prototype.hasOwnProperty.call(j, process.argv[2])) {
      const v = j[process.argv[2]];
      if (v === undefined || v === null) { console.log(''); }
      else { console.log(String(v)); }
      process.exit(0);
    }
  } catch (e) { /* skip */ }
}
console.log('');
" "$PROBE_OUT" "$field" 2>/dev/null || echo ""
}

# ============================================================================
# Normal cases
# ============================================================================

# P1: empty remote (ls-remote returns empty stdout, exit 0) → preBootstrap=true, classification="empty-repo"
setup_mock_git
write_mock_git "" "" 0
run_probe "$FAKE_REPO" "$MOCK_GIT"
PRE="$(json_field preBootstrap)"
CLS="$(json_field classification)"
if [ "$PRE" = "true" ] && [ "$CLS" = "empty-repo" ]; then
    pass "P1: empty remote → preBootstrap=true, classification=empty-repo"
else
    fail "P1: expected preBootstrap=true classification=empty-repo, got pre=$PRE cls=$CLS out=$PROBE_OUT"
fi
teardown_mock_git

# P2: normal remote with default branch ref → preBootstrap=false, classification="ok"
setup_mock_git
write_mock_git "$(printf 'ref: refs/heads/main\tHEAD\nabc1234567890abc\tHEAD')" "" 0
run_probe "$FAKE_REPO" "$MOCK_GIT"
PRE="$(json_field preBootstrap)"
CLS="$(json_field classification)"
if [ "$PRE" = "false" ] && [ "$CLS" = "ok" ]; then
    pass "P2: normal remote with refs → preBootstrap=false, classification=ok"
else
    fail "P2: expected preBootstrap=false classification=ok, got pre=$PRE cls=$CLS out=$PROBE_OUT"
fi
teardown_mock_git

# ============================================================================
# Fail-closed cases (C4 spec)
# ============================================================================

# P3: auth failure → classification=auth, preBootstrap=false
setup_mock_git
write_mock_git "" "fatal: Authentication failed for 'https://github.com/owner/repo.git/'" 128
run_probe "$FAKE_REPO" "$MOCK_GIT"
PRE="$(json_field preBootstrap)"
CLS="$(json_field classification)"
if [ "$PRE" = "false" ] && [ "$CLS" = "auth" ]; then
    pass "P3: auth failure → preBootstrap=false, classification=auth"
else
    fail "P3: expected preBootstrap=false classification=auth, got pre=$PRE cls=$CLS out=$PROBE_OUT"
fi
teardown_mock_git

# P4: network failure → classification=network, preBootstrap=false
setup_mock_git
write_mock_git "" "fatal: unable to access 'https://github.com/owner/repo.git/': Could not resolve host: github.com" 128
run_probe "$FAKE_REPO" "$MOCK_GIT"
PRE="$(json_field preBootstrap)"
CLS="$(json_field classification)"
if [ "$PRE" = "false" ] && [ "$CLS" = "network" ]; then
    pass "P4: network failure → preBootstrap=false, classification=network"
else
    fail "P4: expected preBootstrap=false classification=network, got pre=$PRE cls=$CLS out=$PROBE_OUT"
fi
teardown_mock_git

# P5: timeout (mock sleeps 3s, timeoutMs=500) → classification=timeout, preBootstrap=false
setup_mock_git
write_mock_git_sleep 3
run_probe "$FAKE_REPO" "$MOCK_GIT" 500
PRE="$(json_field preBootstrap)"
CLS="$(json_field classification)"
if [ "$PRE" = "false" ] && [ "$CLS" = "timeout" ]; then
    pass "P5: timeout → preBootstrap=false, classification=timeout"
else
    fail "P5: expected preBootstrap=false classification=timeout, got pre=$PRE cls=$CLS out=$PROBE_OUT"
fi
teardown_mock_git

# P6: repository not found → classification=not-found, preBootstrap=false
setup_mock_git
write_mock_git "" "remote: Repository not found.
fatal: repository 'https://github.com/owner/repo.git/' not found" 128
run_probe "$FAKE_REPO" "$MOCK_GIT"
PRE="$(json_field preBootstrap)"
CLS="$(json_field classification)"
if [ "$PRE" = "false" ] && [ "$CLS" = "not-found" ]; then
    pass "P6: repository not found → preBootstrap=false, classification=not-found"
else
    fail "P6: expected preBootstrap=false classification=not-found, got pre=$PRE cls=$CLS out=$PROBE_OUT"
fi
teardown_mock_git

# P7: spawn error (git path is /nonexistent/git) → classification=spawn-error, preBootstrap=false
setup_mock_git
run_probe "$FAKE_REPO" "/nonexistent/path/to/git-binary"
PRE="$(json_field preBootstrap)"
CLS="$(json_field classification)"
if [ "$PRE" = "false" ] && [ "$CLS" = "spawn-error" ]; then
    pass "P7: spawn error → preBootstrap=false, classification=spawn-error"
else
    fail "P7: expected preBootstrap=false classification=spawn-error, got pre=$PRE cls=$CLS out=$PROBE_OUT"
fi
teardown_mock_git

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
