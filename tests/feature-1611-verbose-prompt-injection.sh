#!/usr/bin/env bash
# tests/feature-1611-verbose-prompt-injection.sh
# Tests: hooks/lib/model-identity.js, hooks/lib/verbose-prompt.js, hooks/workflow-state/state-io.js, hooks/session-start.js, hooks/post-compact.js
# Tags: hook, model-detection, session-state, prompt-injection, scope:issue-specific, TL2
#
# Issue #1611 — model-conditional prompt hardening.
#
#   detection   layer① SessionStart stdin `model` (the only detection layer)
#   persistence session state file: `session_model` (write-once) + `verbose_prompt`
#   provider    hooks/lib/verbose-prompt.js (pure, no side effects)
#   consumers   SessionStart, PostCompact
#
# Every case runs against a temp CLAUDE_WORKFLOW_DIR / WORKFLOW_PLANS_DIR /
# AGENTS_CONFIG_DIR; the real ~/.claude workflow state is never touched.
#
# TL3 gap (what this test does NOT catch):
# - What the live Claude Code SessionStart payload actually puts in `model`
#   (string / object / absent) for a given backend — only a real session shows it.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh categories: hook-registration, skill-orchestration.

set -uo pipefail

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

MODEL_IDENTITY_JS="$REPO_DIR/hooks/lib/model-identity.js"
VERBOSE_PROMPT_JS="$REPO_DIR/hooks/lib/verbose-prompt.js"
STATE_IO_JS="$REPO_DIR/hooks/workflow-state/state-io.js"
SESSION_START_JS="$REPO_DIR/hooks/session-start.js"
POST_COMPACT_JS="$REPO_DIR/hooks/post-compact.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}

assert_ne() {
    local name="$1" unwanted="$2" got="$3"
    if [ "$unwanted" != "$got" ]; then pass "$name"
    else fail "$name" "value must differ from $(printf '%q' "$unwanted")"; fi
}

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

to_node_path() {
    if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else printf '%s' "$1"; fi
}

# --- isolated fixture roots -------------------------------------------------
TMPROOT="$(mktemp -d)"
trap 'rm -rf "$TMPROOT"' EXIT

WFDIR="$TMPROOT/workflow"
PLANSDIR="$TMPROOT/plans"
CFGDIR="$TMPROOT/config"
PROJDIR="$TMPROOT/project"
mkdir -p "$WFDIR" "$PLANSDIR" "$CFGDIR" "$PROJDIR"

WFDIR_N="$(to_node_path "$WFDIR")"
PLANSDIR_N="$(to_node_path "$PLANSDIR")"
CFGDIR_N="$(to_node_path "$CFGDIR")"
PROJDIR_N="$(to_node_path "$PROJDIR")"

export MI_MOD="$(to_node_path "$MODEL_IDENTITY_JS")"
export VP_MOD="$(to_node_path "$VERBOSE_PROMPT_JS")"
export SIO_MOD="$(to_node_path "$STATE_IO_JS")"

# jsn <expression> [KEY=VAL ...] — evaluate with MI / VP / SIO bound.
# null/undefined → "null"; objects/arrays → JSON; throw → "THREW".
# Ambient VERBOSE_PROMPT_MODELS is always cleared first so
# the developer's own shell cannot colour a result; per-case KEY=VAL wins.
JSN_SCRIPT='
function req(p) { try { return require(p); } catch (e) { return null; } }
const MI = req(process.env.MI_MOD);
const VP = req(process.env.VP_MOD);
const SIO = req(process.env.SIO_MOD);
function fmt(v) {
  if (v === null || v === undefined) return "null";
  if (typeof v === "object") return JSON.stringify(v);
  return String(v);
}
let out;
try { out = eval(process.argv[1]); } catch (e) { out = "THREW"; }
process.stdout.write(fmt(out));
'
jsn() {
    local expr="$1"; shift
    local out
    out="$(run_with_timeout 30 env \
        -u VERBOSE_PROMPT_MODELS \
        CLAUDE_WORKFLOW_DIR="$WFDIR_N" \
        WORKFLOW_PLANS_DIR="$PLANSDIR_N" \
        AGENTS_CONFIG_DIR="$CFGDIR_N" \
        CLAUDE_PROJECT_DIR="$PROJDIR_N" \
        "$@" \
        node -e "$JSN_SCRIPT" "$expr" </dev/null 2>/dev/null)" || out="THREW"
    [ -z "$out" ] && out="EMPTY"
    printf '%s' "$out"
}

# seed_state <sid> <extra-json-object> — write a fresh 14-step state file.
seed_state() {
    local sid="$1" extra="${2:-}"
    [ -z "$extra" ] && extra='{}'
    run_with_timeout 30 env CLAUDE_WORKFLOW_DIR="$WFDIR_N" node -e '
const fs = require("fs"), path = require("path");
const sid = process.argv[1];
const extra = JSON.parse(process.argv[2]);
const STEPS = ["workflow_init","clarify_intent","research","outline","detail",
  "branching_complete","write_tests","review_tests","run_tests","review_security",
  "docs","user_verification","cleanup","pre_final_report_gate"];
const steps = {};
for (const s of STEPS) steps[s] = { status: "pending", updated_at: null };
const state = Object.assign({ version: 1, session_id: sid,
  created_at: new Date().toISOString(), steps }, extra);
fs.writeFileSync(path.join(process.env.CLAUDE_WORKFLOW_DIR, sid + ".json"),
  JSON.stringify(state, null, 2));
' "$sid" "$extra" </dev/null >/dev/null 2>&1
}

state_file() { printf '%s' "$WFDIR/$1.json"; }
state_hash() { if [ -f "$(state_file "$1")" ]; then md5sum "$(state_file "$1")" | cut -d' ' -f1; else printf 'ABSENT'; fi; }

# state_field <sid> <dotted.path> — prints the value, or "null"/"ERR".
state_field() {
    run_with_timeout 30 node -e '
const fs = require("fs");
try {
  const s = JSON.parse(fs.readFileSync(process.argv[1], "utf8"));
  const v = process.argv[2].split(".").reduce((a, k) => (a == null ? a : a[k]), s);
  process.stdout.write(v === undefined || v === null ? "null" : String(v));
} catch (e) { process.stdout.write("ERR"); }
' "$(to_node_path "$(state_file "$1")")" "$2" </dev/null 2>/dev/null || printf 'ERR'
}

# ---------------------------------------------------------------------------
# Cases — sourced fragments (Pattern A split; rules/coding/file-split.md).
# The cases execute at source time, so this order IS the execution order.
# ---------------------------------------------------------------------------
FRAGMENT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/feature-1611-verbose-prompt-injection"
# shellcheck source=tests/feature-1611-verbose-prompt-injection/unit-model-identity.sh
. "$FRAGMENT_DIR/unit-model-identity.sh"
# shellcheck source=tests/feature-1611-verbose-prompt-injection/provider-and-hooks.sh
. "$FRAGMENT_DIR/provider-and-hooks.sh"
# shellcheck source=tests/feature-1611-verbose-prompt-injection/adversarial-and-hygiene.sh
. "$FRAGMENT_DIR/adversarial-and-hygiene.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
