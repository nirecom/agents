# tests/bin/docs-2340-feat-update-docs-readme-md/_lib.sh
# Shared preamble of the docs-2340 entrypoints (#2723 split): skip gates, counters, assertions, fixture builders, group definitions.
# Sourced by tests/bin/docs-2340-feat-update-docs-readme-md{,-gates,-hooks}.sh after they pin the state dirs and set SCRIPT_CHECKOUT_ROOT.

if ! command -v node >/dev/null 2>&1; then
  echo "SKIP: node not available"
  exit 77
fi
if ! command -v git >/dev/null 2>&1; then
  echo "SKIP: git not available"
  exit 77
fi

# counters + assertions
PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

assert_eq() {
  local name="$1" want="$2" got="$3"
  if [ "$want" = "$got" ]; then pass "$name"
  else fail "$name -- want=[$want] got=[$got]"; fi
}
assert_contains() {
  local name="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then pass "$name"
  else fail "$name -- expected [$needle] in: $hay"; fi
}
assert_not_contains() {
  local name="$1" needle="$2" hay="$3"
  if printf '%s' "$hay" | grep -qF -- "$needle"; then fail "$name -- did NOT expect [$needle] in: $hay"
  else pass "$name"; fi
}

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 120 "$@"
  else perl -e 'alarm 120; exec @ARGV' -- "$@"; fi
}
run_node() { run_with_timeout node "$@"; }

# RED gates: a source that does not exist yet fails loudly, never skips.
require_bin() {
  local name="$1" rel="$2"
  if [ -x "$SCRIPT_CHECKOUT_ROOT/$rel" ] || [ -f "$SCRIPT_CHECKOUT_ROOT/$rel" ]; then return 0; fi
  fail "$name: TOOL NOT FOUND: $rel — expected per #2340, not yet implemented (write_code has not run)"
  return 1
}
require_module() {
  local name="$1" rel="$2"
  if [ -f "$SCRIPT_CHECKOUT_ROOT/$rel" ]; then return 0; fi
  fail "$name: MODULE NOT FOUND: $rel — expected per #2340, not yet implemented (write_code has not run)"
  return 1
}

# git doc-repo fixture builders
# REPO_SEQ_FILE persists the counter across command-substitution subshells so
# each $(new_doc_repo) call gets a unique directory (not repo-1 every time).
REPO_SEQ=0
REPO_SEQ_FILE="$TMPDIR_BASE/.repo_seq"
printf '0' > "$REPO_SEQ_FILE"
new_doc_repo() {
  local seq
  seq=$(( $(cat "$REPO_SEQ_FILE") + 1 ))
  printf '%d' "$seq" > "$REPO_SEQ_FILE"
  REPO_SEQ=$seq
  local repo="$TMPDIR_BASE/repo-$seq"
  mkdir -p "$repo"
  git init -q "$repo" >/dev/null 2>&1
  git -C "$repo" config core.hooksPath /dev/null
  git -C "$repo" config user.email "test@example.com"
  git -C "$repo" config user.name "test"
  printf 'baseline\n' > "$repo/.seed"
  git -C "$repo" add .seed >/dev/null 2>&1
  git -C "$repo" commit -q -m baseline >/dev/null 2>&1
  printf '%s' "$repo"
}

# gen_md <path> <n-lines> — an N-line markdown file (heading + filler lines).
gen_md() {
  local path="$1" n="$2" i
  mkdir -p "$(dirname "$path")"
  {
    echo "# Doc"
    for ((i = 2; i <= n; i++)); do echo "filler line $i"; done
  } > "$path"
}

# run_tool <repo> <tool-rel> [args...] — run a bin/ tool with CWD in the repo;
# sets TOOL_OUT and TOOL_RC.
run_tool() {
  local repo="$1" rel="$2"; shift 2
  TOOL_OUT="$(cd "$repo" && run_with_timeout "$SCRIPT_CHECKOUT_ROOT/$rel" "$@" 2>&1)"
  TOOL_RC=$?
}

# group definitions (functions only; each entrypoint runs its own groups)
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/docs-2340-feat-update-docs-readme-md/a-review-doc-size.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/docs-2340-feat-update-docs-readme-md/b-review-doc-heading-order.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/docs-2340-feat-update-docs-readme-md/c-review-doc-gates.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/docs-2340-feat-update-docs-readme-md/d-staged-doc-changes.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/docs-2340-feat-update-docs-readme-md/e-review-docs-checker.sh"
. "$SCRIPT_CHECKOUT_ROOT/tests/bin/docs-2340-feat-update-docs-readme-md/f-v3-to-v4-migration.sh"

docs2340_finish() {
  echo ""
  echo "Total: $PASS passed, $FAIL failed"
  [ "$FAIL" -eq 0 ]
}
