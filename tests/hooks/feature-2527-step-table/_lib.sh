#!/usr/bin/env bash
# Shared helpers for the feature-2527-step-table split suite (sourced, not run).
[ -n "${_S27_LIB_LOADED:-}" ] && return 0
_S27_LIB_LOADED=1

_s27_here="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
__LIB_SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
# shellcheck source=../../lib/harness.sh
source "$__LIB_SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

S27_FIXTURE_JS="$(np "$_s27_here/fixture.js")"
S27_SCRIPT_CHECKOUT_ROOT="$(np "$__LIB_SCRIPT_CHECKOUT_ROOT")"
export S27_SCRIPT_CHECKOUT_ROOT
NEXT_STEP="$__LIB_SCRIPT_CHECKOUT_ROOT/bin/workflow/next-step"

# check <name> <actual> <expected>
check() {
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=[$3] got=[$2]"; fi
}
# check_contains <name> <haystack> <needle>
check_contains() {
  case "$2" in
    *"$3"*) pass "$1" ;;
    *) fail "$1" "missing [$3] in: $(printf '%s' "$2" | head -c 600)" ;;
  esac
}
# check_not_contains <name> <haystack> <needle>
check_not_contains() {
  case "$2" in
    *"$3"*) fail "$1" "unexpected [$3] in: $(printf '%s' "$2" | head -c 600)" ;;
    *) pass "$1" ;;
  esac
}

# s27_setup — isolated state dirs, an AGENTS_MAIN_ROOT holding only an empty .env, and a fixture repo that
# is both the cwd and CLAUDE_PROJECT_DIR (repo-dir-guard sees SAME).
s27_setup() {
  S27_TMP="$(make_tmp)"
  harness_isolate "$S27_TMP"
  export WORKFLOW_STATE_DIR="$(np "$WORKFLOW_STATE_DIR")"
  export WORKFLOW_PLANS_DIR="$(np "$WORKFLOW_PLANS_DIR")"
  mkdir -p "$S27_TMP/cfg"
  : > "$S27_TMP/cfg/.env"
  export AGENTS_MAIN_ROOT="$(np "$S27_TMP/cfg")"
  S27_REPO="$S27_TMP/repo"
  harness_git_init "$S27_REPO"
  S27_REPO_M="$(np "$S27_REPO")"
  export CLAUDE_PROJECT_DIR="$S27_REPO_M"
  export CLAUDE_TRANSCRIPT_BASE_DIR="$(np "$S27_TMP/transcripts")"
  mkdir -p "$S27_TMP/transcripts"
  unset ENFORCE_WORKTREE ENFORCE_WORKTREE_EXCLUDE
  cd "$S27_REPO" || return 1
}

s27_teardown() {
  cd / || true
  [ -n "${S27_TMP:-}" ] && rm -rf "$S27_TMP"
}

# mk_state <spec-json> — writes a state file via fixture.js (see that file).
mk_state() {
  node "$S27_FIXTURE_JS" "$1" || fail "fixture" "fixture.js rejected spec: $1"
}

# S27_PRELUDE — node prelude: req(rel) prints MISSING:<rel> and exits 0 when a
# module is absent, so a not-yet-implemented module fails each case loudly.
S27_PRELUDE='const A = process.env.S27_SCRIPT_CHECKOUT_ROOT;
const req = (p) => { try { return require(A + "/" + p); } catch (e) { console.log("MISSING:" + p + " " + (e && e.code)); process.exit(0); } };
const out = (k, v) => console.log(k + "=" + (typeof v === "string" ? v : JSON.stringify(v)));'

# s27_node <js-body> — runs PRELUDE + body; prints combined stdout/stderr.
s27_node() {
  run_with_timeout 30 node -e "$S27_PRELUDE
$1" 2>&1
}

# field <output> <key> — value of the first "key=..." line; when absent, a
# "<no KEY: ...>" marker carrying the raw head so a red case shows its reason.
field() {
  local v
  v="$(printf '%s\n' "$1" | sed -n "s/^$2=//p" | head -n 1)"
  if [ -z "$v" ] && ! printf '%s\n' "$1" | grep -q "^$2="; then
    v="<no $2: $(printf '%s' "$1" | head -c 300 | tr '\n' ' ')>"
  fi
  printf '%s' "$v"
}

# check_skill <name> <next-step-output> <expected-skill> — on mismatch the
# failure line carries ACTION / REASON / NEXT_HINT so a red case shows why.
check_skill() {
  local got
  got="$(printf '%s\n' "$2" | sed -n 's/^NEXT_SKILL=//p' | head -n 1)"
  if [ "$got" = "$3" ]; then
    pass "$1"
  else
    fail "$1" "want=[$3] got=[$got] ACTION=$(field "$2" ACTION) REASON=$(field "$2" REASON) HINT=$(field "$2" NEXT_HINT | head -c 160)"
  fi
}

# run_next_step <sid> — next-step output (stdout+stderr) from the fixture repo.
run_next_step() {
  run_with_timeout 60 node "$NEXT_STEP" --session "$1" 2>&1
}
