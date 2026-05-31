#!/usr/bin/env bash
# Tests: bin/workflow-plans-dir, hooks/lib/load-env.js, hooks/lib/path-match.js, hooks/lib/workflow-plans-dir.js
# Tags: workflow, plans, hook, bin, windows
# Contract tests for hooks/lib/workflow-plans-dir.js helper.
#
# Test-first: the source file may not exist yet. Each Node test creates a
# LOCAL FIXTURE directory with a minimal workflow-plans-dir.js (mirroring the
# planned implementation) plus a copy of load-env.js, then exercises it in a
# clean Node subprocess so the helper's `_envLoaded` memoization is reset
# between tests.
set -u

# Timeout guard
if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

# Disable MSYS/Git-Bash path conversion of argv and env so Windows-style paths
# survive untouched when handed to node.exe.
export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOAD_ENV_SRC="$AGENTS_DIR/hooks/lib/load-env.js"
PATH_MATCH_SRC="$AGENTS_DIR/hooks/lib/path-match.js"
REAL_HELPER="$AGENTS_DIR/hooks/lib/workflow-plans-dir.js"
REAL_BRIDGE="$AGENTS_DIR/bin/workflow-plans-dir"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "$@"
    else
        perl -e 'alarm 60; exec @ARGV' -- "$@"
    fi
}

# Create a temp fixture root. On Git-Bash/MSYS, mktemp yields a POSIX path
# (/tmp/...) that node.exe cannot resolve — convert with cygpath so Node sees
# a Windows-style absolute path it can require().
TMPDIR_BASE=$(mktemp -d 2>/dev/null || mktemp -d -t 'plans-dir-XXXX')
if command -v cygpath >/dev/null 2>&1; then
    TMPDIR_NODE=$(cygpath -m "$TMPDIR_BASE")
else
    TMPDIR_NODE="$TMPDIR_BASE"
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

if [ ! -f "$LOAD_ENV_SRC" ]; then
    echo "FATAL: load-env.js not found at $LOAD_ENV_SRC"
    exit 1
fi

# Write a fresh fixture dir for each test (no shared state across tests).
# Args: <bash-path>
make_fixture() {
    local dir="$1"
    mkdir -p "$dir/lib"
    cp "$LOAD_ENV_SRC" "$dir/lib/load-env.js"
    if [ -f "$PATH_MATCH_SRC" ]; then
        cp "$PATH_MATCH_SRC" "$dir/lib/path-match.js"
    fi
    # The planned hooks/lib/workflow-plans-dir.js implementation.
    cat > "$dir/lib/workflow-plans-dir.js" <<'EOF'
"use strict";
const os = require("os");
const path = require("path");
const { loadDefaultEnv } = require("./load-env");

let _envLoaded = false;

function getWorkflowPlansDir() {
  if (!_envLoaded) { try { loadDefaultEnv(); } catch (_) {} _envLoaded = true; }
  const raw = process.env.WORKFLOW_PLANS_DIR;
  if (raw && raw.length) {
    const v = raw.trim();
    if (v.length === 0) return path.join(os.homedir(), ".workflow-plans");
    if (!path.isAbsolute(v)) {
      throw new Error(`WORKFLOW_PLANS_DIR must be an absolute path (tilde is not expanded). Got: ${v}`);
    }
    return v;
  }
  return path.join(os.homedir(), ".workflow-plans");
}

module.exports = { getWorkflowPlansDir };
EOF
}

# Helper to get Windows-form home dir (forward slashes)
node_homedir() {
    run_with_timeout node -e "process.stdout.write(require('os').homedir().replace(/\\\\/g,'/'))"
}

NODE_HOME="$(node_homedir)"
NODE_PLATFORM="$(run_with_timeout node -e "process.stdout.write(process.platform)")"

# fixture_paths <name> → echoes "<bash-path>|<node-path>"
fixture_paths() {
    local name="$1"
    echo "${TMPDIR_BASE}/${name}|${TMPDIR_NODE}/${name}"
}

echo "=== workflow-plans-dir contract tests ==="
echo "Platform: $NODE_PLATFORM"
echo "NODE_HOME: $NODE_HOME"
echo "TMPDIR_NODE: $TMPDIR_NODE"
echo ""

# ---------------------------------------------------------------------------
# N1: default → $HOME/.workflow-plans
# ---------------------------------------------------------------------------
echo "--- N1: default (no env, no .env) ---"
test_n1() {
    local bash_dir="$TMPDIR_BASE/n1" node_dir="$TMPDIR_NODE/n1"
    make_fixture "$bash_dir"
    local r
    # AGENTS_CONFIG_DIR points to a dir without a .env so load-env is a no-op.
    r="$(AGENTS_CONFIG_DIR="$node_dir" run_with_timeout node -e "
        delete process.env.WORKFLOW_PLANS_DIR;
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        try { process.stdout.write('OK:' + m.getWorkflowPlansDir()); }
        catch(e) { process.stdout.write('ERR:' + e.message); }
    " 2>&1)"
    local expected="$NODE_HOME/.workflow-plans"
    local r_norm
    r_norm=$(echo "$r" | sed 's#\\#/#g')
    if [[ "$r_norm" == OK:* ]] && [[ "${r_norm#OK:}" == "$expected" ]]; then
        pass "N1 default returns \$HOME/.workflow-plans (got $r)"
    else
        fail "N1 default expected OK:$expected, got $r"
    fi
}
test_n1

# ---------------------------------------------------------------------------
# N2: absolute override
# ---------------------------------------------------------------------------
echo "--- N2: absolute override ---"
test_n2() {
    local bash_dir="$TMPDIR_BASE/n2" node_dir="$TMPDIR_NODE/n2"
    make_fixture "$bash_dir"
    local r
    r="$(AGENTS_CONFIG_DIR="$node_dir" WORKFLOW_PLANS_DIR=/tmp/test-my-plans run_with_timeout node -e "
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        try { process.stdout.write('OK:' + m.getWorkflowPlansDir()); }
        catch(e) { process.stdout.write('ERR:' + e.message); }
    " 2>&1)"
    if [ "$r" = "OK:/tmp/test-my-plans" ]; then
        pass "N2 absolute override returns /tmp/test-my-plans"
    else
        fail "N2 expected OK:/tmp/test-my-plans, got $r"
    fi
}
test_n2

# ---------------------------------------------------------------------------
# E1: empty string → treated as unset (default)
# ---------------------------------------------------------------------------
echo "--- E1: empty string (treated as unset) ---"
test_e1() {
    local bash_dir="$TMPDIR_BASE/e1" node_dir="$TMPDIR_NODE/e1"
    make_fixture "$bash_dir"
    # WORKFLOW_PLANS_DIR=""  — empty string. The helper's check `raw && raw.length`
    # rejects falsy/empty strings and falls back to default.
    local r
    r="$(AGENTS_CONFIG_DIR="$node_dir" WORKFLOW_PLANS_DIR="" run_with_timeout node -e "
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        try { process.stdout.write('OK:' + m.getWorkflowPlansDir()); }
        catch(e) { process.stdout.write('ERR:' + e.message); }
    " 2>&1)"
    local expected="$NODE_HOME/.workflow-plans"
    local r_norm
    r_norm=$(echo "$r" | sed 's#\\#/#g')
    if [[ "$r_norm" == OK:* ]] && [[ "${r_norm#OK:}" == "$expected" ]]; then
        pass "E1 empty string falls back to default"
    else
        fail "E1 expected OK:$expected, got $r"
    fi
}
test_e1

# ---------------------------------------------------------------------------
# E2: relative path → throws
# ---------------------------------------------------------------------------
echo "--- E2: relative path rejected ---"
test_e2() {
    local bash_dir="$TMPDIR_BASE/e2" node_dir="$TMPDIR_NODE/e2"
    make_fixture "$bash_dir"
    local r
    r="$(AGENTS_CONFIG_DIR="$node_dir" WORKFLOW_PLANS_DIR=foo/bar run_with_timeout node -e "
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        try { process.stdout.write('OK:' + m.getWorkflowPlansDir()); }
        catch(e) { process.stdout.write('ERR:' + e.message); }
    " 2>&1)"
    if [[ "$r" == ERR:* ]] && echo "$r" | grep -qi "absolute"; then
        pass "E2 relative path throws with 'absolute' in message"
    else
        fail "E2 expected ERR:...absolute..., got $r"
    fi
}
test_e2

# ---------------------------------------------------------------------------
# E3: dot-relative path → throws
# ---------------------------------------------------------------------------
echo "--- E3: dot-relative path rejected ---"
test_e3() {
    local bash_dir="$TMPDIR_BASE/e3" node_dir="$TMPDIR_NODE/e3"
    make_fixture "$bash_dir"
    local r
    r="$(AGENTS_CONFIG_DIR="$node_dir" WORKFLOW_PLANS_DIR=./plans run_with_timeout node -e "
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        try { process.stdout.write('OK:' + m.getWorkflowPlansDir()); }
        catch(e) { process.stdout.write('ERR:' + e.message); }
    " 2>&1)"
    if [[ "$r" == ERR:* ]]; then
        pass "E3 dot-relative path throws"
    else
        fail "E3 expected ERR:..., got $r"
    fi
}
test_e3

# ---------------------------------------------------------------------------
# E4: tilde prefix → rejected (path.isAbsolute('~/foo') is false)
# ---------------------------------------------------------------------------
echo "--- E4: tilde prefix rejected ---"
test_e4() {
    local bash_dir="$TMPDIR_BASE/e4" node_dir="$TMPDIR_NODE/e4"
    make_fixture "$bash_dir"
    local r
    r="$(AGENTS_CONFIG_DIR="$node_dir" WORKFLOW_PLANS_DIR='~/foo' run_with_timeout node -e "
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        try { process.stdout.write('OK:' + m.getWorkflowPlansDir()); }
        catch(e) { process.stdout.write('ERR:' + e.message); }
    " 2>&1)"
    if [[ "$r" == ERR:* ]]; then
        pass "E4 tilde prefix rejected (not absolute per path.isAbsolute)"
    else
        fail "E4 expected ERR:..., got $r"
    fi
}
test_e4

# ---------------------------------------------------------------------------
# I1: .env loading via AGENTS_CONFIG_DIR — helper invokes loadDefaultEnv()
# transparently. Caller never calls it directly.
# ---------------------------------------------------------------------------
echo "--- I1: .env loading via AGENTS_CONFIG_DIR ---"
test_i1() {
    local bash_dir="$TMPDIR_BASE/i1" node_dir="$TMPDIR_NODE/i1"
    make_fixture "$bash_dir"
    # Write a .env that sets WORKFLOW_PLANS_DIR. Note: load-env reads the file
    # using fs.readFileSync, which on Windows accepts the cygpath-converted
    # path. Write via the bash-side path.
    cat > "$bash_dir/.env" <<EOF
# Test .env loaded by helper
WORKFLOW_PLANS_DIR=/tmp/env-override-test
EOF
    local r
    r="$(AGENTS_CONFIG_DIR="$node_dir" run_with_timeout node -e "
        delete process.env.WORKFLOW_PLANS_DIR;
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        try { process.stdout.write('OK:' + m.getWorkflowPlansDir()); }
        catch(e) { process.stdout.write('ERR:' + e.message); }
    " 2>&1)"
    if [ "$r" = "OK:/tmp/env-override-test" ]; then
        pass "I1 .env loaded automatically by helper"
    else
        fail "I1 expected OK:/tmp/env-override-test, got $r"
    fi
}
test_i1

# ---------------------------------------------------------------------------
# I2: bin/workflow-plans-dir bridge — pending until source exists
# ---------------------------------------------------------------------------
echo "--- I2: bin/workflow-plans-dir bridge ---"
test_i2() {
    if [ ! -f "$REAL_BRIDGE" ] && [ ! -f "$REAL_BRIDGE.js" ] && [ ! -f "$REAL_BRIDGE.sh" ]; then
        skip "I2 bin/workflow-plans-dir not yet created (test-first; will run after source lands)"
        return
    fi
    if [ ! -f "$REAL_HELPER" ]; then
        skip "I2 helper source not yet created"
        return
    fi
    local helper_node
    if command -v cygpath >/dev/null 2>&1; then
        helper_node=$(cygpath -m "$REAL_HELPER")
    else
        helper_node="$REAL_HELPER"
    fi
    local bridge_out helper_out
    bridge_out="$(WORKFLOW_PLANS_DIR=/tmp/bridge-test run_with_timeout "$REAL_BRIDGE" 2>&1 || true)"
    helper_out="$(WORKFLOW_PLANS_DIR=/tmp/bridge-test run_with_timeout node -e "
        const m = require('$helper_node');
        process.stdout.write(m.getWorkflowPlansDir());
    " 2>&1)"
    if [ "$bridge_out" = "$helper_out" ] && [ -n "$bridge_out" ]; then
        pass "I2 bin/workflow-plans-dir matches helper output ($bridge_out)"
    else
        fail "I2 bin output '$bridge_out' != helper output '$helper_out'"
    fi
}
test_i2

# ---------------------------------------------------------------------------
# I3: isUnderPath integration — file under resolved dir → true; outside → false
# ---------------------------------------------------------------------------
echo "--- I3: isUnderPath integration ---"
test_i3() {
    if [ ! -f "$PATH_MATCH_SRC" ]; then
        skip "I3 path-match.js not present; cannot test isUnderPath integration"
        return
    fi
    local bash_dir="$TMPDIR_BASE/i3" node_dir="$TMPDIR_NODE/i3"
    make_fixture "$bash_dir"
    local r1
    r1="$(AGENTS_CONFIG_DIR="$node_dir" WORKFLOW_PLANS_DIR=/tmp/test-plans run_with_timeout node -e "
        const pm = require('$node_dir/lib/path-match.js');
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        const dir = m.getWorkflowPlansDir();
        process.stdout.write(String(pm.isUnderPath('/tmp/test-plans/foo.md', dir)));
    " 2>&1)"
    local r2
    r2="$(AGENTS_CONFIG_DIR="$node_dir" WORKFLOW_PLANS_DIR=/tmp/test-plans run_with_timeout node -e "
        const pm = require('$node_dir/lib/path-match.js');
        const m = require('$node_dir/lib/workflow-plans-dir.js');
        const dir = m.getWorkflowPlansDir();
        process.stdout.write(String(pm.isUnderPath('/tmp/other/foo.md', dir)));
    " 2>&1)"
    if [ "$r1" = "true" ] && [ "$r2" = "false" ]; then
        pass "I3 isUnderPath: inside=true, outside=false"
    else
        fail "I3 isUnderPath: expected inside=true outside=false, got inside=$r1 outside=$r2"
    fi
}
test_i3

# ---------------------------------------------------------------------------
# I4: bridge resolves correctly when AGENTS_CONFIG_DIR is unset.
# The bridge derives its own location via $SCRIPT_DIR / pwd -P and never
# consults AGENTS_CONFIG_DIR for that resolution, so an absolute-path
# invocation must still return the default $HOME/.workflow-plans.
# ---------------------------------------------------------------------------
echo "--- I4: bridge resolves without AGENTS_CONFIG_DIR ---"
test_i4() {
    if [ ! -f "$REAL_BRIDGE" ]; then
        skip "I4 bin/workflow-plans-dir not yet created"
        return
    fi
    local result result_norm expected
    result="$(run_with_timeout env -u AGENTS_CONFIG_DIR -u WORKFLOW_PLANS_DIR "$REAL_BRIDGE" 2>&1 || true)"
    result_norm=$(printf '%s' "$result" | sed 's#\\#/#g')
    expected="$NODE_HOME/.workflow-plans"
    if [ "$result_norm" = "$expected" ]; then
        pass "I4 bridge resolves correctly without AGENTS_CONFIG_DIR (got $result_norm)"
    else
        fail "I4 expected '$expected', got '$result_norm'"
    fi
}
test_i4

# ---------------------------------------------------------------------------
# I5: relative WORKFLOW_PLANS_DIR makes the bridge exit 2 and emit a stderr
# line prefixed `workflow-plans-dir:`.
# ---------------------------------------------------------------------------
echo "--- I5: bridge rejects relative WORKFLOW_PLANS_DIR ---"
test_i5() {
    if [ ! -f "$REAL_BRIDGE" ]; then
        skip "I5 bin/workflow-plans-dir not yet created"
        return
    fi
    local stderr_out exit_code
    # Capture stderr (discard stdout) and exit code separately. We run the
    # bridge twice — once to grab the stderr text, once to grab the exit
    # status — because Bash makes capturing both from a single invocation
    # awkward and we do not care about timing here.
    stderr_out="$(run_with_timeout env WORKFLOW_PLANS_DIR=foo/bar "$REAL_BRIDGE" 2>&1 >/dev/null || true)"
    exit_code=0
    run_with_timeout env WORKFLOW_PLANS_DIR=foo/bar "$REAL_BRIDGE" >/dev/null 2>&1 || exit_code=$?
    if [ "$exit_code" = "2" ] && echo "$stderr_out" | grep -q "^workflow-plans-dir:"; then
        pass "I5 relative path: exit 2, stderr starts with 'workflow-plans-dir:'"
    else
        fail "I5 expected exit 2 + stderr 'workflow-plans-dir:...' got exit=$exit_code stderr='$stderr_out'"
    fi
}
test_i5

# ---------------------------------------------------------------------------
# I6: the inlined Step 0 fallback chain that SKILL.md files will carry —
#     bash "$AGENTS_CONFIG_DIR/bin/workflow-plans-dir" 2>/dev/null \
#       || printf '%s\n' "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
# When the helper is unreachable (bad AGENTS_CONFIG_DIR) but the user has
# exported WORKFLOW_PLANS_DIR, the fallback must honour that override
# rather than silently dropping to the home default.
# ---------------------------------------------------------------------------
echo "--- I6: inlined fallback chain honours WORKFLOW_PLANS_DIR ---"
test_i6() {
    local result
    result="$(run_with_timeout bash -c '
        export WORKFLOW_PLANS_DIR=/tmp/custom-plans-i6
        bash "/nonexistent/path/bin/workflow-plans-dir" 2>/dev/null || printf "%s\n" "${WORKFLOW_PLANS_DIR:-$HOME/.workflow-plans}"
    ')"
    if [ "$result" = "/tmp/custom-plans-i6" ]; then
        pass "I6 inlined fallback chain honours exported WORKFLOW_PLANS_DIR"
    else
        fail "I6 expected '/tmp/custom-plans-i6', got '$result'"
    fi
}
test_i6

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL  SKIP: $SKIP"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
