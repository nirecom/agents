SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
HOOK_UNIX="$REPO_ROOT/hooks/workflow-gate.js"

# Convert to Windows path for Node.js require
if command -v cygpath >/dev/null 2>&1; then
  HOOK_WIN="$(cygpath -w "$HOOK_UNIX")"
else
  HOOK_WIN="$HOOK_UNIX"
fi

PASS=0
FAIL=0
ERRORS=()

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then
    timeout 120 "$@"
  else
    perl -e 'alarm 120; exec @ARGV' -- "$@"
  fi
}

assert_eq() {
  local name="$1" expected="$2" actual="$3"
  if [ "$expected" = "$actual" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    expected: $expected"
    echo "    actual:   $actual"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

assert_true() {
  local name="$1" actual="$2"
  if [ "$actual" = "true" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected true, got '$actual')"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

assert_false() {
  local name="$1" actual="$2"
  if [ "$actual" = "false" ]; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name (expected false, got '$actual')"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

assert_contains() {
  local name="$1" expected="$2" actual="$3"
  if echo "$actual" | grep -q "$expected"; then
    echo "  PASS: $name"
    PASS=$((PASS + 1))
  else
    echo "  FAIL: $name"
    echo "    expected to contain: $expected"
    echo "    actual: $actual"
    FAIL=$((FAIL + 1))
    ERRORS+=("$name")
  fi
}

# Helper: run Node with HOOK_PATH env var to avoid escaping issues
node_hook() {
  HOOK_PATH="$HOOK_WIN" run_with_timeout node "$@"
}

TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

setup_repo() {
  local dir="$1"
  git -C "$dir" init -q
  git -C "$dir" config user.email "test@example.com"
  git -C "$dir" config user.name "Test User"
}

to_win_path() {
  local p="$1"
  if command -v cygpath >/dev/null 2>&1; then
    cygpath -w "$p"
  else
    echo "$p"
  fi
}
