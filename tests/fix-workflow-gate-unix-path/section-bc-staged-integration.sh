# L3 gap (what this section does NOT catch):
# - That hasStagedTestChanges / hasStagedDocChanges correctly operates against the real
#   Claude Code working tree (not a fixture git repo) under a live hook dispatch
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight via bin/check-verification-gate.sh category: hook-registration
# ============================================================
# Section B: hasStagedTestChanges / hasStagedDocChanges integration
# ============================================================
echo ""
echo "=== B. hasStagedTestChanges / hasStagedDocChanges integration tests ==="


# I1: tests/foo.sh staged -> hasStagedTestChanges = true
REPO1="$TMPDIR_BASE/repo1"
mkdir -p "$REPO1"
setup_repo "$REPO1"
mkdir -p "$REPO1/tests"
echo "# test" > "$REPO1/tests/foo.sh"
git -C "$REPO1" add "tests/foo.sh"
REPO1_WIN="$(to_win_path "$REPO1")"

result=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO1_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedTestChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedTestChanges(process.env.REPO_DIR)));
EOF
)
assert_true "I1: tests/foo.sh staged -> hasStagedTestChanges=true" "$result"

# I2: docs/ops.md staged -> hasStagedDocChanges = true
REPO2="$TMPDIR_BASE/repo2"
mkdir -p "$REPO2"
setup_repo "$REPO2"
mkdir -p "$REPO2/docs"
echo "# ops" > "$REPO2/docs/ops.md"
git -C "$REPO2" add "docs/ops.md"
REPO2_WIN="$(to_win_path "$REPO2")"

result=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO2_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedDocChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedDocChanges(process.env.REPO_DIR)));
EOF
)
assert_true "I2: docs/ops.md staged -> hasStagedDocChanges=true" "$result"

# I3: src/main.js only -> both false
REPO3="$TMPDIR_BASE/repo3"
mkdir -p "$REPO3"
setup_repo "$REPO3"
mkdir -p "$REPO3/src"
echo "// main" > "$REPO3/src/main.js"
git -C "$REPO3" add "src/main.js"
REPO3_WIN="$(to_win_path "$REPO3")"

result_test=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO3_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedTestChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedTestChanges(process.env.REPO_DIR)));
EOF
)
result_doc=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="$REPO3_WIN" run_with_timeout node --input-type=module <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedDocChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedDocChanges(process.env.REPO_DIR)));
EOF
)
assert_false "I3: src/main.js only -> hasStagedTestChanges=false" "$result_test"
assert_false "I3: src/main.js only -> hasStagedDocChanges=false" "$result_doc"

# ============================================================
# Section C: error handling
# ============================================================
echo ""
echo "=== C. error handling tests ==="

# Er1: nonexistent cwd -> false + stderr warning
STDERR_TMP="$TMPDIR_BASE/stderr_er1.txt"
result=$(HOOK_PATH="$HOOK_WIN" REPO_DIR="/nonexistent/path/that/does/not/exist" \
  run_with_timeout node --input-type=module 2>"$STDERR_TMP" <<'EOF'
import { createRequire } from 'module';
const require = createRequire(import.meta.url);
const { hasStagedTestChanges } = require(process.env.HOOK_PATH);
process.stdout.write(String(hasStagedTestChanges(process.env.REPO_DIR)));
EOF
)
stderr_out=$(cat "$STDERR_TMP")

assert_false "Er1: nonexistent cwd -> hasStagedTestChanges=false" "$result"
assert_contains "Er1: nonexistent cwd -> stderr warning contains 'workflow-gate'" "workflow-gate" "$stderr_out"
