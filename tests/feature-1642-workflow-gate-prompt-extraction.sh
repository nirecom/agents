#!/usr/bin/env bash
# tests/feature-1642-workflow-gate-prompt-extraction.sh
# Tests: hooks/workflow-gate.js, hooks/workflow-gate/prompt-extraction-gate.js, bin/check-prompt-extraction
# Tags: workflow-gate, hook, gate3, prompt-extraction, scope:issue-specific, scope:feature-1642, layer:TL2
#
# Issue #1642 — Gate 3: workflow-gate.js must hard-block `git commit` when a
# STAGED prompt file carries an un-allowlisted extraction violation.
# Gate 3 delegates to hooks/workflow-gate/prompt-extraction-gate.js, which shells
# out to `bash bin/check-prompt-extraction --staged`.
#
# Fail-closed contract: every infrastructure error blocks. Timeout is the ONLY
# fail-open path (mirrors Gate 2 / code-size-gate.js — CPR-ORTH).
#
# TL3 gap (what this test does NOT catch):
# - Whether the PreToolUse hook actually fires when Claude Code issues a git commit
# - Whether settings.json registers hooks/workflow-gate.js for the Bash tool
# Closest-to-action mitigation: bin/check-verification-gate.sh category: hook-registration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
HOOK_JS="${_AGENTS_DIR_NODE}/hooks/workflow-gate.js"
GATE_MODULE="${AGENTS_DIR}/hooks/workflow-gate/prompt-extraction-gate.js"
GATE_MODULE_NODE="${_AGENTS_DIR_NODE}/hooks/workflow-gate/prompt-extraction-gate.js"
CLI="${AGENTS_DIR}/bin/check-prompt-extraction"

# --- Pre-implementation skip gate -------------------------------------------
if [ ! -f "$GATE_MODULE" ]; then
    echo "SKIP: hooks/workflow-gate/prompt-extraction-gate.js not present yet (issue #1642)"
    exit 77
fi
if [ ! -f "$HOOK_JS" ]; then
    echo "SKIP: hooks/workflow-gate.js not present"
    exit 77
fi
if [ ! -f "$CLI" ]; then
    echo "SKIP: bin/check-prompt-extraction not present yet (issue #1642)"
    exit 77
fi

PASS=0
FAIL=0
SKIP=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1"; SKIP=$((SKIP + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'gate3-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi
}

fresh_workflow_dir() {
    local d="$TMPDIR_BASE/wf-$RANDOM-$$"
    mkdir -p "$d"
    to_node_path "$d"
}

write_complete_state() {
    local wfdir="$1" sid="$2"
    node -e "
const fs = require('fs');
const path = require('path');
const { VALID_STEPS } = require('$_AGENTS_DIR_NODE/hooks/workflow-state.js');
const steps = {};
const now = new Date().toISOString();
for (const s of VALID_STEPS) steps[s] = { status: 'complete', updated_at: now };
const state = { version: 1, session_id: '$sid', created_at: now, steps };
fs.writeFileSync(path.join('$wfdir', '$sid' + '.json'), JSON.stringify(state, null, 2));
"
}

write_workflow_off_marker() {
    local wfdir="$1" sid="$2"
    printf '{"set_at":"2026-01-01T00:00:00Z"}\n' > "$wfdir/$sid.workflow-off"
}

# Plain config dir: no markers -> resolveAgentsConfigDir() falls through to the
# real agents checkout, so the REAL bin/check-prompt-extraction is exercised.
# Also non-git -> isAgentsSessionRepo() fails closed (true), keeping Gate 3 armed.
make_plain_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d"
    to_node_path "$d"
}

# Marker config dir: adopted by resolveAgentsConfigDir(); the fixture owns
# whatever bin/check-prompt-extraction it wants (or none at all).
make_marker_config_dir() {
    local d="$TMPDIR_BASE/cfg-$1"
    mkdir -p "$d/hooks" "$d/bin"
    echo "// stub marker" > "$d/hooks/enforce-worktree.js"
    to_node_path "$d"
}

emit_fence() {
    local n="$1" i
    echo '```bash'
    for ((i = 1; i <= n; i++)); do echo "echo line $i"; done
    echo '```'
}

# setup_repo <name> [with-allowlist]  -> prints node-safe repo path
setup_repo() {
    local name="$1" allowlist="${2:-yes}"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    git -C "$repo" config core.autocrlf false
    mkdir -p "$repo/rules" "$repo/docs"
    echo "init" > "$repo/README.md"
    echo "doc" > "$repo/docs/notes.md"
    if [ "$allowlist" = "yes" ]; then
        printf '# prompt-extraction allowlist\n' > "$repo/.prompt-extraction-allowlist"
        git -C "$repo" add .prompt-extraction-allowlist
    fi
    git -C "$repo" add README.md docs/notes.md
    git -C "$repo" commit -q -m "initial"
    to_node_path "$repo"
}

stage_violation() {
    local repo="$1"
    mkdir -p "$repo/rules"
    { echo "# Bloated rule"; echo ""; emit_fence 12; } > "$repo/rules/bloated.md"
    git -C "$repo" add rules/bloated.md
}

stage_clean() {
    local repo="$1"
    mkdir -p "$repo/rules"
    { echo "# Lean rule"; echo ""; echo "One short sentence."; } > "$repo/rules/lean.md"
    git -C "$repo" add rules/lean.md
}

json_quote() {
    node -e 'process.stdout.write(JSON.stringify(process.argv[1]))' "$1"
}

build_commit_payload() {
    local sid="$1" repo="$2"
    printf '{"session_id":%s,"tool_name":"Bash","tool_input":{"command":%s}}' \
        "$(json_quote "$sid")" "$(json_quote "git -C $repo commit -m \"test\"")"
}

HOOK_OUT=""
HOOK_RC=0
run_hook() {
    local payload="$1" wfdir="$2" cfg="$3"; shift 3
    HOOK_RC=0
    HOOK_OUT="$(printf '%s' "$payload" | run_with_timeout 60 \
        env -u CLAUDE_ENV_FILE \
        "AGENTS_CONFIG_DIR=$cfg" \
        "CLAUDE_WORKFLOW_DIR=$wfdir" \
        "$@" \
        node "$HOOK_JS" 2>&1)" || HOOK_RC=$?
}

# ---------------------------------------------------------------------------
# Direct module driver.
#
# The module's public entrypoint is discovered by shape rather than by name so
# the test does not hard-code an implementation detail: the first exported
# function is invoked with the repo dir.
# Prints a JSON verdict on stdout.
# ---------------------------------------------------------------------------
MOD_OUT=""
MOD_RC=0
run_gate_module() {
    local repo="$1" cfg="$2"; shift 2
    MOD_RC=0
    MOD_OUT="$(run_with_timeout 60 \
        env -u CLAUDE_ENV_FILE "AGENTS_CONFIG_DIR=$cfg" "$@" \
        node -e "
const mod = require('$GATE_MODULE_NODE');
const key = Object.keys(mod).find((k) => typeof mod[k] === 'function');
if (!key) { console.log(JSON.stringify({error:'no exported function'})); process.exit(0); }
let r;
try { r = mod[key](process.argv[1]); } catch (e) { r = { action: 'threw', reason: String(e && e.message) }; }
console.log(JSON.stringify(r === undefined ? { action: 'undefined' } : r));
" "$repo" 2>&1)" || MOD_RC=$?
}

assert_approve() {
    local label="$1"
    if [ "$HOOK_RC" -ne 0 ]; then fail "$label: hook crashed rc=$HOOK_RC" "$HOOK_OUT"; return 1; fi
    if printf '%s\n' "$HOOK_OUT" | grep -q '"decision":"approve"'; then
        pass "$label"
    else
        fail "$label: expected approve" "$HOOK_OUT"
    fi
}

assert_block() {
    local label="$1" needle="${2:-}"
    if [ "$HOOK_RC" -ne 0 ]; then fail "$label: hook crashed rc=$HOOK_RC" "$HOOK_OUT"; return 1; fi
    if ! printf '%s\n' "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "$label: expected block" "$HOOK_OUT"
        return 1
    fi
    if [ -n "$needle" ] && ! printf '%s\n' "$HOOK_OUT" | grep -qi -- "$needle"; then
        fail "$label: block reason missing '$needle'" "$HOOK_OUT"
        return 1
    fi
    pass "$label"
}

assert_mod_block() {
    local label="$1"
    if printf '%s\n' "$MOD_OUT" | grep -q '"action":"block"'; then
        pass "$label"
    else
        fail "$label: expected {\"action\":\"block\"}" "$MOD_OUT"
    fi
}

assert_mod_ok() {
    local label="$1"
    if printf '%s\n' "$MOD_OUT" | grep -qE '"action":"(ok|undefined)"'; then
        pass "$label"
    else
        fail "$label: expected ok" "$MOD_OUT"
    fi
}

# ============================================================================
# Tests
# ============================================================================

# T01: gate module, staged violation -> block with a HARD: line in the reason.
t01_module_blocks_violation() {
    local repo; repo="$(setup_repo r1)"
    local cfg; cfg="$(make_plain_config_dir c1)"
    stage_violation "$repo"
    run_gate_module "$repo" "$cfg"
    assert_mod_block "T01: gate module blocks a staged extraction violation"
    if printf '%s\n' "$MOD_OUT" | grep -q "HARD:"; then
        pass "T01: block reason carries a HARD: line from the CLI"
    else
        fail "T01: block reason has no HARD: line" "$MOD_OUT"
    fi
}

# T02: gate module, clean staged set -> ok.
t02_module_ok_when_clean() {
    local repo; repo="$(setup_repo r2)"
    local cfg; cfg="$(make_plain_config_dir c2)"
    stage_clean "$repo"
    run_gate_module "$repo" "$cfg"
    assert_mod_ok "T02: gate module returns ok for a clean staged set"
}

# T03: full workflow-gate.js commit payload, staged violation -> block.
t03_hook_blocks_violation() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate3003"
    local repo; repo="$(setup_repo r3)"
    local cfg; cfg="$(make_plain_config_dir c3)"
    write_complete_state "$wfdir" "$sid"
    stage_violation "$repo"
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_block "T03: workflow-gate.js blocks the commit" "bloated.md"
}

# T04: the block reason must contain a COLUMN-0 "HARD:" line.
#      Guards the C11 filter — l.startsWith("HARD:"), not "  HARD:".
t04_hard_line_unindented() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate3004"
    local repo; repo="$(setup_repo r4)"
    local cfg; cfg="$(make_plain_config_dir c4)"
    write_complete_state "$wfdir" "$sid"
    stage_violation "$repo"
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    if ! printf '%s\n' "$HOOK_OUT" | grep -q '"decision":"block"'; then
        fail "T04: expected block before checking the HARD: filter" "$HOOK_OUT"
        return
    fi
    # The reason is JSON-encoded, so the newline before HARD: is the literal \n.
    if printf '%s\n' "$HOOK_OUT" | grep -qE '(\\n|^)HARD:'; then
        pass "T04: block reason carries an unindented HARD: line"
    else
        fail "T04: no column-0 HARD: line found in the block reason" "$HOOK_OUT"
    fi
}

# T05: CLI binary missing in the adopted config dir -> fail closed (block).
t05_cli_missing_blocks() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate3005"
    local repo; repo="$(setup_repo r5)"
    local cfg; cfg="$(make_marker_config_dir c5)"   # markers, no bin/check-prompt-extraction
    write_complete_state "$wfdir" "$sid"
    stage_clean "$repo"
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_block "T05: missing check-prompt-extraction -> fail-closed block" "check-prompt-extraction" || return
    if printf '%s\n' "$HOOK_OUT" | grep -qiE "install|recover|resolve|AGENTS_CONFIG_DIR"; then
        pass "T05: block reason carries recovery guidance"
    else
        fail "T05: block reason lacks recovery guidance" "$HOOK_OUT"
    fi
}

# T06: bash not on PATH -> fail closed (block), never fail open.
t06_bash_missing_blocks() {
    local gitdir nodedir restricted probe
    gitdir="$(dirname "$(command -v git 2>/dev/null)")"
    nodedir="$(dirname "$(command -v node 2>/dev/null)")"
    if [ -z "$gitdir" ] || [ -z "$nodedir" ]; then
        skip "T06: cannot locate git/node to build a restricted PATH"
        return
    fi
    if command -v cygpath >/dev/null 2>&1; then
        restricted="$(cygpath -w "$gitdir");$(cygpath -w "$nodedir")"
    else
        restricted="$gitdir:$nodedir"
    fi
    probe="$(env "PATH=$restricted" node -e "
const {spawnSync}=require('child_process');
const r=spawnSync('bash',['-c','echo hi']);
process.stdout.write(r.error?String(r.error.code):'FOUND');
" 2>/dev/null)"
    if [ "$probe" != "ENOENT" ]; then
        skip "T06: bash still reachable under restricted PATH on this host (probe=$probe)"
        return
    fi
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate3006"
    local repo; repo="$(setup_repo r6)"
    local cfg; cfg="$(make_plain_config_dir c6)"
    write_complete_state "$wfdir" "$sid"
    stage_clean "$repo"
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg" "PATH=$restricted"
    assert_block "T06: bash missing -> fail-closed block" "prompt"
}

# T07: CLI timeout is the ONLY fail-open path -> ok / approve.
t07_timeout_fail_open() {
    local repo; repo="$(setup_repo r7)"
    local cfg; cfg="$(make_marker_config_dir c7)"
    printf '#!/usr/bin/env bash\nsleep 30\nexit 1\n' > "$TMPDIR_BASE/cfg-c7/bin/check-prompt-extraction"
    chmod +x "$TMPDIR_BASE/cfg-c7/bin/check-prompt-extraction"
    stage_violation "$repo"
    run_gate_module "$repo" "$cfg"
    assert_mod_ok "T07: CLI timeout -> fail open (only permitted fail-open path)"
}

# T08: .workflow-off marker bypasses Gate 3 entirely.
t08_workflow_off_bypass() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate3008"
    local repo; repo="$(setup_repo r8)"
    local cfg; cfg="$(make_plain_config_dir c8)"
    write_workflow_off_marker "$wfdir" "$sid"
    stage_violation "$repo"
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "T08: .workflow-off marker -> approve (Gate 3 bypassed)"
}

# T09: repo without .prompt-extraction-allowlist -> gate does not apply.
t09_non_agents_repo_skipped() {
    local wfdir; wfdir="$(fresh_workflow_dir)"
    local sid="gate3009"
    local repo; repo="$(setup_repo r9 no)"   # no .prompt-extraction-allowlist
    local cfg; cfg="$(make_plain_config_dir c9)"
    write_complete_state "$wfdir" "$sid"
    stage_violation "$repo"
    run_hook "$(build_commit_payload "$sid" "$repo")" "$wfdir" "$cfg"
    assert_approve "T09: repo with no .prompt-extraction-allowlist -> Gate 3 skipped"
}

run_all() {
    t01_module_blocks_violation
    t02_module_ok_when_clean
    t03_hook_blocks_violation
    t04_hard_line_unindented
    t05_cli_missing_blocks
    t06_bash_missing_blocks
    t07_timeout_fail_open
    t08_workflow_off_bypass
    t09_non_agents_repo_skipped
}

run_all

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
