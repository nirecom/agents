#!/usr/bin/env bash
# Contract tests for bin/migrate-plans-dir.js.
#
# Test-first: the source may not exist yet. Each test creates a temp HOME with
# a fixture .claude/plans/ tree, writes a local fixture copy of
# migrate-plans-dir.js (mirroring the planned implementation) into a fixture
# location, and runs it under a controlled HOME / USERPROFILE so os.homedir()
# returns the temp dir.
set -u

if [ -z "${_TIMEOUT_WRAPPED:-}" ]; then
    export _TIMEOUT_WRAPPED=1
    if command -v timeout >/dev/null 2>&1; then
        exec timeout 120 bash "$0" "$@"
    else
        exec perl -e 'alarm 120; exec @ARGV' -- bash "$0" "$@"
    fi
fi

export MSYS_NO_PATHCONV=1
export MSYS2_ARG_CONV_EXCL="*"

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LOAD_ENV_SRC="$AGENTS_DIR/hooks/lib/load-env.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 60 "$@"
    else
        perl -e 'alarm 60; exec @ARGV' -- "$@"
    fi
}

# Temp dir with cygpath conversion for Node-passable paths.
TMPDIR_BASE=$(mktemp -d 2>/dev/null || mktemp -d -t 'migrate-plans-XXXX')
if command -v cygpath >/dev/null 2>&1; then
    TMPDIR_NODE=$(cygpath -m "$TMPDIR_BASE")
else
    TMPDIR_NODE="$TMPDIR_BASE"
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# Build a per-test fixture: a fake HOME containing .claude/plans and
# .workflow-plans (controlled by WORKFLOW_PLANS_DIR), plus a fixture
# migrate-plans-dir.js that mirrors the planned implementation.
# Args: <name>
# Echoes "<bash-home>|<node-home>|<bash-script>|<node-script>"
make_fixture() {
    local name="$1"
    local bash_home="$TMPDIR_BASE/$name/home"
    local node_home="$TMPDIR_NODE/$name/home"
    local bash_bin_dir="$TMPDIR_BASE/$name/bin"
    local node_bin_dir="$TMPDIR_NODE/$name/bin"
    local bash_lib_dir="$TMPDIR_BASE/$name/hooks/lib"
    local node_lib_dir="$TMPDIR_NODE/$name/hooks/lib"
    mkdir -p "$bash_home" "$bash_bin_dir" "$bash_lib_dir"
    cp "$LOAD_ENV_SRC" "$bash_lib_dir/load-env.js"
    # Helper module — fixture copy of hooks/lib/workflow-plans-dir.js
    cat > "$bash_lib_dir/workflow-plans-dir.js" <<'EOF'
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
    # The planned bin/migrate-plans-dir.js implementation. The fixture lives
    # at <root>/bin/migrate-plans-dir.js and requires
    # ../hooks/lib/workflow-plans-dir, mirroring the real layout exactly.
    cat > "$bash_bin_dir/migrate-plans-dir.js" <<'EOF'
#!/usr/bin/env node
"use strict";
const fs = require("fs");
const os = require("os");
const path = require("path");
const { getWorkflowPlansDir } = require("../hooks/lib/workflow-plans-dir");

const SRC = path.resolve(path.join(os.homedir(), ".claude", "plans"));
let DST;
try { DST = path.resolve(getWorkflowPlansDir()); }
catch (e) { console.error(`migrate-plans-dir: ${e.message}`); process.exit(2); }

const srcWithSep = SRC + path.sep;
if ((DST + path.sep).toLowerCase().startsWith(srcWithSep.toLowerCase()) || DST === SRC) {
  console.error(`migrate-plans-dir: destination ${DST} is inside source ${SRC}; aborting`);
  process.exit(2);
}

try { fs.accessSync(SRC); }
catch { console.log(`no-op: ${SRC} does not exist`); process.exit(0); }

fs.mkdirSync(DST, { recursive: true });

function bytesEqual(a, b) {
  const sa = fs.statSync(a), sb = fs.statSync(b);
  if (sa.size !== sb.size) return false;
  return Buffer.compare(fs.readFileSync(a), fs.readFileSync(b)) === 0;
}

const actions = [];
function walk(srcDir, dstDir) {
  fs.mkdirSync(dstDir, { recursive: true });
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const s = path.join(srcDir, entry.name);
    const d = path.join(dstDir, entry.name);
    if (entry.isDirectory()) { walk(s, d); continue; }
    if (!entry.isFile()) continue;
    if (fs.existsSync(d)) {
      if (bytesEqual(s, d)) { actions.push({ src: s, dst: d, kind: "skip-identical" }); }
      else {
        console.error(`migrate-plans-dir: conflict — ${d} exists with different content; aborting (source preserved)`);
        process.exit(3);
      }
    } else { actions.push({ src: s, dst: d, kind: "copy" }); }
  }
}
walk(SRC, DST);

for (const a of actions) {
  if (a.kind === "copy") fs.copyFileSync(a.src, a.dst);
}

function verify(srcDir, dstDir) {
  for (const entry of fs.readdirSync(srcDir, { withFileTypes: true })) {
    const s = path.join(srcDir, entry.name);
    const d = path.join(dstDir, entry.name);
    if (entry.isDirectory()) { verify(s, d); continue; }
    if (!entry.isFile()) continue;
    if (!fs.existsSync(d) || !bytesEqual(s, d)) {
      console.error(`migrate-plans-dir: verification failed for ${s}; source preserved`);
      process.exit(4);
    }
  }
}
verify(SRC, DST);

fs.rmSync(SRC, { recursive: true, force: true });
const skipped = actions.filter(a => a.kind === "skip-identical").length;
console.log(`migrated ${SRC} → ${DST} (${actions.length} entries; ${skipped} identical)`);
EOF
    echo "${bash_home}|${node_home}|${bash_bin_dir}/migrate-plans-dir.js|${node_bin_dir}/migrate-plans-dir.js"
}

# Run a fixture script with a controlled HOME. On Windows, os.homedir() reads
# USERPROFILE, so override both. WORKFLOW_PLANS_DIR override (if any) is set
# by caller via 4th arg.
# Args: <node-home> <node-script> <workflow-plans-dir-or-empty>
# Echoes: "exit=$N|stdout=...|stderr=..."
run_migrate() {
    local node_home="$1" node_script="$2" wpd="${3:-}"
    local out err exit_code=0
    local tmp_out tmp_err
    tmp_out=$(mktemp); tmp_err=$(mktemp)
    if [ -n "$wpd" ]; then
        WORKFLOW_PLANS_DIR="$wpd" HOME="$node_home" USERPROFILE="$node_home" \
            run_with_timeout node "$node_script" >"$tmp_out" 2>"$tmp_err" || exit_code=$?
    else
        unset WORKFLOW_PLANS_DIR
        HOME="$node_home" USERPROFILE="$node_home" \
            run_with_timeout node "$node_script" >"$tmp_out" 2>"$tmp_err" || exit_code=$?
    fi
    out=$(cat "$tmp_out"); err=$(cat "$tmp_err")
    rm -f "$tmp_out" "$tmp_err"
    printf 'exit=%s|stdout=%s|stderr=%s' "$exit_code" "$out" "$err"
}

echo "=== migrate-plans-dir contract tests ==="
echo "TMPDIR_NODE: $TMPDIR_NODE"
echo ""

# ---------------------------------------------------------------------------
# M1: normal migration — SRC has files + drafts/ → all copied, SRC removed
# ---------------------------------------------------------------------------
echo "--- M1: normal migration ---"
test_m1() {
    local paths fixture_home node_home node_script
    paths=$(make_fixture "m1")
    fixture_home=$(echo "$paths" | cut -d'|' -f1)
    node_home=$(echo "$paths" | cut -d'|' -f2)
    node_script=$(echo "$paths" | cut -d'|' -f4)
    # Seed SRC with files
    mkdir -p "$fixture_home/.claude/plans/drafts"
    echo "intent content" > "$fixture_home/.claude/plans/foo-intent.md"
    echo "outline content" > "$fixture_home/.claude/plans/foo-outline.md"
    echo "draft content" > "$fixture_home/.claude/plans/drafts/foo-draft.md"
    # Run with WORKFLOW_PLANS_DIR pointing to a sibling dir
    local wpd_bash="$fixture_home/.workflow-plans"
    local wpd_node
    if command -v cygpath >/dev/null 2>&1; then
        wpd_node=$(cygpath -m "$wpd_bash")
    else
        wpd_node="$wpd_bash"
    fi
    local result
    result=$(run_migrate "$node_home" "$node_script" "$wpd_node")
    local exit_code
    exit_code=$(echo "$result" | sed 's/^exit=\([0-9]*\).*/\1/')
    if [ "$exit_code" != "0" ]; then
        fail "M1 expected exit 0, got: $result"
        return
    fi
    # Verify DST has all files
    if [ -f "$wpd_bash/foo-intent.md" ] \
        && [ -f "$wpd_bash/foo-outline.md" ] \
        && [ -f "$wpd_bash/drafts/foo-draft.md" ]; then
        if [ ! -d "$fixture_home/.claude/plans" ]; then
            pass "M1 files copied and SRC removed"
        else
            fail "M1 SRC not removed"
        fi
    else
        fail "M1 DST missing expected files: $(ls -R "$wpd_bash" 2>&1 || true)"
    fi
}
test_m1

# ---------------------------------------------------------------------------
# M2: idempotency (identical file already at DST) → exit 0, skip-identical
# ---------------------------------------------------------------------------
echo "--- M2: idempotency (identical bytes) ---"
test_m2() {
    local paths fixture_home node_home node_script
    paths=$(make_fixture "m2")
    fixture_home=$(echo "$paths" | cut -d'|' -f1)
    node_home=$(echo "$paths" | cut -d'|' -f2)
    node_script=$(echo "$paths" | cut -d'|' -f4)
    mkdir -p "$fixture_home/.claude/plans"
    mkdir -p "$fixture_home/.workflow-plans"
    echo "same content" > "$fixture_home/.claude/plans/file.md"
    echo "same content" > "$fixture_home/.workflow-plans/file.md"
    local wpd_bash="$fixture_home/.workflow-plans"
    local wpd_node
    if command -v cygpath >/dev/null 2>&1; then
        wpd_node=$(cygpath -m "$wpd_bash")
    else
        wpd_node="$wpd_bash"
    fi
    local result exit_code stdout
    result=$(run_migrate "$node_home" "$node_script" "$wpd_node")
    exit_code=$(echo "$result" | sed 's/^exit=\([0-9]*\).*/\1/')
    stdout=$(echo "$result" | sed -n 's/.*|stdout=\([^|]*\)|.*/\1/p')
    if [ "$exit_code" = "0" ] && echo "$result" | grep -q "identical"; then
        pass "M2 idempotent (identical bytes accepted): $stdout"
    else
        fail "M2 expected exit 0 with 'identical' in output, got: $result"
    fi
}
test_m2

# ---------------------------------------------------------------------------
# M3: conflict (different content at DST) → non-zero, SRC preserved, stderr
#     contains "conflict"
# ---------------------------------------------------------------------------
echo "--- M3: conflict (different content) ---"
test_m3() {
    local paths fixture_home node_home node_script
    paths=$(make_fixture "m3")
    fixture_home=$(echo "$paths" | cut -d'|' -f1)
    node_home=$(echo "$paths" | cut -d'|' -f2)
    node_script=$(echo "$paths" | cut -d'|' -f4)
    mkdir -p "$fixture_home/.claude/plans"
    mkdir -p "$fixture_home/.workflow-plans"
    echo "SRC content" > "$fixture_home/.claude/plans/conflict.md"
    echo "DIFFERENT DST content" > "$fixture_home/.workflow-plans/conflict.md"
    local wpd_bash="$fixture_home/.workflow-plans"
    local wpd_node
    if command -v cygpath >/dev/null 2>&1; then
        wpd_node=$(cygpath -m "$wpd_bash")
    else
        wpd_node="$wpd_bash"
    fi
    local result exit_code
    result=$(run_migrate "$node_home" "$node_script" "$wpd_node")
    exit_code=$(echo "$result" | sed 's/^exit=\([0-9]*\).*/\1/')
    if [ "$exit_code" != "0" ] && echo "$result" | grep -qi "conflict"; then
        if [ -f "$fixture_home/.claude/plans/conflict.md" ]; then
            pass "M3 conflict exits non-zero, SRC preserved"
        else
            fail "M3 conflict exits non-zero but SRC removed (must preserve)"
        fi
    else
        fail "M3 expected non-zero exit with 'conflict' in stderr, got: $result"
    fi
}
test_m3

# ---------------------------------------------------------------------------
# M4: DST inside SRC → exit 2 before any I/O
# ---------------------------------------------------------------------------
echo "--- M4: DST inside SRC ---"
test_m4() {
    local paths fixture_home node_home node_script
    paths=$(make_fixture "m4")
    fixture_home=$(echo "$paths" | cut -d'|' -f1)
    node_home=$(echo "$paths" | cut -d'|' -f2)
    node_script=$(echo "$paths" | cut -d'|' -f4)
    mkdir -p "$fixture_home/.claude/plans"
    echo "preserve me" > "$fixture_home/.claude/plans/file.md"
    # WORKFLOW_PLANS_DIR is a subdir of SRC.
    local wpd_bash="$fixture_home/.claude/plans/nested-dst"
    local wpd_node
    if command -v cygpath >/dev/null 2>&1; then
        wpd_node=$(cygpath -m "$wpd_bash")
    else
        wpd_node="$wpd_bash"
    fi
    local result exit_code
    result=$(run_migrate "$node_home" "$node_script" "$wpd_node")
    exit_code=$(echo "$result" | sed 's/^exit=\([0-9]*\).*/\1/')
    if [ "$exit_code" = "2" ]; then
        # SRC must be untouched
        if [ -f "$fixture_home/.claude/plans/file.md" ] && [ ! -d "$wpd_bash" ]; then
            pass "M4 DST inside SRC → exit 2, SRC untouched, DST not created"
        else
            fail "M4 exit 2 but I/O happened anyway"
        fi
    else
        fail "M4 expected exit 2, got: $result"
    fi
}
test_m4

# ---------------------------------------------------------------------------
# M5: no source → exit 0, stdout contains "no-op"
# ---------------------------------------------------------------------------
echo "--- M5: no source dir ---"
test_m5() {
    local paths fixture_home node_home node_script
    paths=$(make_fixture "m5")
    fixture_home=$(echo "$paths" | cut -d'|' -f1)
    node_home=$(echo "$paths" | cut -d'|' -f2)
    node_script=$(echo "$paths" | cut -d'|' -f4)
    # Intentionally no .claude/plans/ in fixture_home.
    local wpd_bash="$fixture_home/.workflow-plans"
    local wpd_node
    if command -v cygpath >/dev/null 2>&1; then
        wpd_node=$(cygpath -m "$wpd_bash")
    else
        wpd_node="$wpd_bash"
    fi
    local result exit_code
    result=$(run_migrate "$node_home" "$node_script" "$wpd_node")
    exit_code=$(echo "$result" | sed 's/^exit=\([0-9]*\).*/\1/')
    if [ "$exit_code" = "0" ] && echo "$result" | grep -q "no-op"; then
        pass "M5 missing SRC → exit 0 with 'no-op'"
    else
        fail "M5 expected exit 0 with 'no-op', got: $result"
    fi
}
test_m5

# ---------------------------------------------------------------------------
# M6: idempotent re-run after successful migration → exit 0, 'no-op'
# ---------------------------------------------------------------------------
echo "--- M6: idempotent re-run after success ---"
test_m6() {
    local paths fixture_home node_home node_script
    paths=$(make_fixture "m6")
    fixture_home=$(echo "$paths" | cut -d'|' -f1)
    node_home=$(echo "$paths" | cut -d'|' -f2)
    node_script=$(echo "$paths" | cut -d'|' -f4)
    mkdir -p "$fixture_home/.claude/plans"
    echo "migrate me" > "$fixture_home/.claude/plans/once.md"
    local wpd_bash="$fixture_home/.workflow-plans"
    local wpd_node
    if command -v cygpath >/dev/null 2>&1; then
        wpd_node=$(cygpath -m "$wpd_bash")
    else
        wpd_node="$wpd_bash"
    fi
    # First run — should succeed and remove SRC
    local result1 exit1
    result1=$(run_migrate "$node_home" "$node_script" "$wpd_node")
    exit1=$(echo "$result1" | sed 's/^exit=\([0-9]*\).*/\1/')
    if [ "$exit1" != "0" ]; then
        fail "M6 first migration failed: $result1"
        return
    fi
    # Second run — SRC is gone, should be no-op
    local result2 exit2
    result2=$(run_migrate "$node_home" "$node_script" "$wpd_node")
    exit2=$(echo "$result2" | sed 's/^exit=\([0-9]*\).*/\1/')
    if [ "$exit2" = "0" ] && echo "$result2" | grep -q "no-op"; then
        pass "M6 re-run after success → exit 0 with 'no-op'"
    else
        fail "M6 second run expected exit 0 with 'no-op', got: $result2"
    fi
}
test_m6

echo ""
echo "=== Summary ==="
echo "PASS: $PASS  FAIL: $FAIL"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
