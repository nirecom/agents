# helpers.sh — Shared setup and helper functions for feature-1303-lang-hooks tests.
# Sourced by the dispatch entrypoint; not executable directly.
# Sets: AGENTS_DIR, LANG_INJECT_HOOK, SUBAGENT_START_HOOK, SETTINGS_JSON,
#       TMPDIR_BASE, EMPTY_DIR, EMPTY_DIR_NODE,
#       PASS, FAIL, SKIP counters, pass/fail/skip functions,
#       run_with_timeout, to_node_path, build_state,
#       extract_additional_context, is_valid_hook_output, extract_subagent_ctx.
#
# Env vars are passed directly to node processes (not via .env files) to avoid the
# block-dotenv.js hook that guards .env file reads in this session.

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && (pwd -W 2>/dev/null || pwd))"

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

LANG_INJECT_HOOK="$AGENTS_DIR/hooks/lang-inject.js"
SUBAGENT_START_HOOK="$AGENTS_DIR/hooks/subagent-start.js"
SETTINGS_JSON="$AGENTS_DIR/settings.json"

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

# Windows-compatible tempdir
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    _BASH_WIN_TMPDIR="/${_DRIVE}${_REST}"
    TMPDIR_BASE=$(mktemp -d "${_BASH_WIN_TMPDIR}/feature-1303-hooks.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

EMPTY_DIR="$TMPDIR_BASE/empty"
mkdir -p "$EMPTY_DIR"
EMPTY_DIR_NODE="$(to_node_path "$EMPTY_DIR")"

# Helper: build workflow state fixture.
# Args: <session_id> <workflow_dir> <steps_json>
build_state() {
    local sid="$1" wf_dir="$2" steps_json="$3"
    mkdir -p "$wf_dir"
    local state_json
    state_json=$(node -e "
const steps = {};
const all = ['workflow_init','clarify_intent','research','outline','detail',
             'branching_complete','write_tests','review_tests','run_tests',
             'review_security','docs','user_verification','cleanup','pre_final_report_gate'];
for (const s of all) steps[s] = { status: 'pending', updated_at: null };
const overrides = $steps_json;
for (const [k,v] of Object.entries(overrides)) steps[k] = { status: v, updated_at: null };
const state = { version: 1, session_id: '$sid', created_at: new Date().toISOString(),
                steps, workflow_type: 'wf-code' };
process.stdout.write(JSON.stringify(state, null, 2));
" 2>/dev/null)
    printf '%s' "$state_json" > "$wf_dir/$sid.json"
}

# Extract additionalContext from UserPromptSubmit hook output.
extract_additional_context() {
    local raw="$1"
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  const ctx = (o.hookSpecificOutput || {}).additionalContext || '';
  process.stdout.write(ctx);
} catch (e) { process.stdout.write(''); }
" "$raw" 2>/dev/null
}

# Check output is valid JSON object.
is_valid_hook_output() {
    local raw="$1"
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(typeof o === 'object' && o !== null ? 'yes' : 'no');
} catch (e) { process.stdout.write('no'); }
" "$raw" 2>/dev/null
}

# Extract additionalContext from subagent-start output.
extract_subagent_ctx() {
    local raw="$1"
    node -e "
try {
  const o = JSON.parse(process.argv[1]);
  process.stdout.write(o.additionalContext || '');
} catch (e) { process.stdout.write(''); }
" "$raw" 2>/dev/null
}
