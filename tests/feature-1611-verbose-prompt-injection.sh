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
echo "=== preconditions (new modules) ==="
# ---------------------------------------------------------------------------

for f in "$MODEL_IDENTITY_JS" "$VERBOSE_PROMPT_JS"; do
    rel="${f#$REPO_DIR/}"
    if [ -f "$f" ]; then pass "X-exists-$rel"
    else fail "X-exists-$rel" "not implemented yet"; fi
done

# ---------------------------------------------------------------------------
echo ""
echo "=== A: extractModelIdFromHookInput (layer① shape tolerance) ==="
# ---------------------------------------------------------------------------

run_table() {
    local name expr want
    while IFS='@' read -r name expr want; do
        name="$(printf '%s' "$name" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        [ -z "$name" ] && continue
        case "$name" in '#'*) continue ;; esac
        want="$(printf '%s' "$want" | sed -e 's/^[[:space:]]*//' -e 's/[[:space:]]*$//')"
        assert_eq "$name" "$want" "$(jsn "$expr")"
    done
}

run_table <<'TABLE'
A01-model-string      @ MI.extractModelIdFromHookInput({model: 'claude-opus-4-8'})                          @ claude-opus-4-8
A02-model-object-id   @ MI.extractModelIdFromHookInput({model: {id: 'deepseek-v4-flash'}})                  @ deepseek-v4-flash
A03-id-beats-display  @ MI.extractModelIdFromHookInput({model: {id: 'ds4-x', display_name: 'DS4 Flash'}})   @ ds4-x
A04-display-name-only @ MI.extractModelIdFromHookInput({model: {display_name: 'DS4 Flash'}})                @ DS4 Flash
A05-model-absent      @ MI.extractModelIdFromHookInput({session_id: 's'})                                   @ null
A06-model-number      @ MI.extractModelIdFromHookInput({model: 42})                                         @ null
A07-input-null        @ MI.extractModelIdFromHookInput(null)                                                @ null
A08-input-not-object  @ MI.extractModelIdFromHookInput('claude-opus-4-8')                                   @ null
A09-empty-id-falls-back @ MI.extractModelIdFromHookInput({model: {id: '', display_name: 'DS4'}})            @ DS4
A10-empty-object      @ MI.extractModelIdFromHookInput({model: {}})                                         @ null
TABLE

# ---------------------------------------------------------------------------
echo ""
echo "=== B: resolveModelId (layer① only) ==="
# ---------------------------------------------------------------------------

resolve() {
    local expr='(function(){ const r = MI.resolveModelId('"$1"'); return r ? (r.id + ":" + r.source) : null; })()'
    shift
    jsn "$expr" "$@"
}

assert_eq "B01-hook-input-wins-source" "claude-opus-4-8:hook-input" \
    "$(resolve "{model: 'claude-opus-4-8'}")"
assert_eq "B04-no-hook-input-is-null" "null" \
    "$(resolve "{session_id: 's'}")"
assert_eq "B06-malformed-input-fail-open" "null" \
    "$(resolve "undefined")"

# ---------------------------------------------------------------------------
echo ""
echo "=== C: recordSessionModel (write-once + verbose_prompt decision) ==="
# ---------------------------------------------------------------------------

record() {
    # record <sid> <model-id> <source> [KEY=VAL ...] → "<recorded>:<verbosePrompt>"
    local sid="$1" mid="$2" src="$3"; shift 3
    local expr='(function(){ const r = SIO.recordSessionModel('"'$sid'"', { modelId: '"'$mid'"', source: '"'$src'"' }); return r ? (String(r.recorded) + ":" + String(r.verbosePrompt)) : null; })()'
    jsn "$expr" "$@"
}

seed_state "sid-c01"
assert_eq "C01-first-write-recorded" "true:false" "$(record sid-c01 claude-opus-4-8 hook-input)"
assert_eq "C01b-id-persisted"     "claude-opus-4-8" "$(state_field sid-c01 session_model.id)"
assert_eq "C01c-source-persisted" "hook-input"      "$(state_field sid-c01 session_model.source)"
assert_ne "C01d-recorded-at-set"  "null"            "$(state_field sid-c01 session_model.recorded_at)"

# write-once: the second (later-layer) record must not overwrite the first.
assert_eq "C02-second-write-refused" "false:false" "$(record sid-c01 deepseek-v4-flash self-report)"
assert_eq "C02b-id-unchanged"        "claude-opus-4-8" "$(state_field sid-c01 session_model.id)"

# readState injects a non-persistent skip_judgment view; writing it back would
# pollute the state file permanently.
if grep -q 'skip_judgment' "$(state_file sid-c01)"; then
    fail "C03-skip-judgment-not-persisted" "skip_judgment leaked into the state file"
else
    pass "C03-skip-judgment-not-persisted"
fi

seed_state "sid-c04"
assert_eq "C04-keyword-hit-sets-flag" "true:true" \
    "$(record sid-c04 deepseek-v4-flash hook-input 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
assert_eq "C04b-flag-persisted" "true" "$(state_field sid-c04 verbose_prompt)"

seed_state "sid-c05"
assert_eq "C05-keyword-miss-clears-flag" "true:false" \
    "$(record sid-c05 claude-opus-4-8 hook-input 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
assert_eq "C05b-flag-persisted-false" "false" "$(state_field sid-c05 verbose_prompt)"

seed_state "sid-c06"
assert_eq "C06-feature-unset-no-flag" "true:false" "$(record sid-c06 deepseek-v4-flash hook-input)"
assert_eq "C06b-flag-false" "false" "$(state_field sid-c06 verbose_prompt)"

# no pre-existing state file → the setter creates one (mirrors recordComplexityEvaluation).
rm -f "$(state_file sid-c07)"
assert_eq "C07-creates-missing-state" "true:false" "$(record sid-c07 claude-opus-4-8 env)"
assert_eq "C07b-state-file-written" "claude-opus-4-8" "$(state_field sid-c07 session_model.id)"

# The plan's SessionStart integration passes resolveModelId's own return shape
# ({id, source}) straight into the setter, so that shape must record too.
seed_state "sid-c08"
C08_EXPR='(function(){ const r = SIO.recordSessionModel("sid-c08", { id: "deepseek-v4-flash", source: "hook-input" }); return r ? String(r.recorded) : null; })()'
assert_eq "C08-accepts-resolveModelId-shape" "true" "$(jsn "$C08_EXPR")"
assert_eq "C08b-id-persisted" "deepseek-v4-flash" "$(state_field sid-c08 session_model.id)"

# ---------------------------------------------------------------------------
echo ""
echo "=== D: getVerbosePromptInjection (read-only provider) ==="
# ---------------------------------------------------------------------------

vp_text() { local e='VP.VERBOSE_PROMPT_TEXT'; jsn "$e"; }
VP_TEXT="$(vp_text)"

VP_TEXT_OK=1
case "$VP_TEXT" in
    ""|EMPTY|THREW|null)
        fail "D00-text-constant-exported" "VERBOSE_PROMPT_TEXT is not exported (module not implemented yet)"
        # Sentinel that can never equal a real result — keeps every downstream
        # comparison honestly red instead of accidentally matching "THREW".
        VP_TEXT="<<VERBOSE_PROMPT_TEXT-UNAVAILABLE>>"
        VP_TEXT_OK=0
        ;;
    *)  pass "D00-text-constant-exported" ;;
esac

inject() {
    local e="VP.getVerbosePromptInjection('$1')"; shift
    jsn "$e" "$@"
}

seed_state "sid-d01" '{"verbose_prompt":true}'
assert_eq "D01-flag-true-returns-text" "$VP_TEXT" "$(inject sid-d01)"

seed_state "sid-d02" '{"verbose_prompt":false}'
assert_eq "D02-flag-false-returns-null" "null" "$(inject sid-d02)"

seed_state "sid-d03"
assert_eq "D03-flag-absent-returns-null" "null" "$(inject sid-d03)"

assert_eq "D04-no-state-file-returns-null" "null" "$(inject sid-d04-never-created)"

printf 'not json {{{' > "$WFDIR/sid-d05.json"
assert_eq "D05-corrupt-state-returns-null" "null" "$(inject sid-d05)"

D06_EXPR='VP.getVerbosePromptInjection("../../etc/passwd")'
assert_eq "D06-invalid-sid-returns-null" "null" "$(jsn "$D06_EXPR")"

D07_EXPR='VP.getVerbosePromptInjection(null)'
assert_eq "D07-null-sid-returns-null" "null" "$(jsn "$D07_EXPR")"

# The provider is pure: reading must not mutate the state file.
D08_BEFORE="$(state_hash sid-d01)"
inject sid-d01 >/dev/null
assert_eq "D08-provider-has-no-side-effect" "$D08_BEFORE" "$(state_hash sid-d01)"

# ---------------------------------------------------------------------------
echo ""
echo "=== G: SessionStart integration ==="
# ---------------------------------------------------------------------------

# hook_out <hook-js> <stdin-json> [KEY=VAL ...] → raw stdout
hook_out() {
    local hook="$1" stdin_json="$2"; shift 2
    printf '%s' "$stdin_json" | run_with_timeout 60 env \
        -u VERBOSE_PROMPT_MODELS -u CLAUDE_ENV_FILE \
        CLAUDE_WORKFLOW_DIR="$WFDIR_N" \
        WORKFLOW_PLANS_DIR="$PLANSDIR_N" \
        AGENTS_CONFIG_DIR="$CFGDIR_N" \
        CLAUDE_PROJECT_DIR="$PROJDIR_N" \
        "$@" \
        node "$hook" 2>/dev/null
}

contains() { case "$2" in *"$1"*) return 0 ;; *) return 1 ;; esac; }

seed_state "sid-g01" '{"verbose_prompt":true}'
G01="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g01"}')"
if contains "$VP_TEXT" "$G01"; then pass "G01-flag-true-injects-line"
else fail "G01-flag-true-injects-line" "additionalContext lacks the hardening line"; fi

seed_state "sid-g02" '{"verbose_prompt":false}'
G02="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g02"}')"
if contains "$VP_TEXT" "$G02"; then fail "G02-flag-false-omits-line" "hardening line injected despite verbose_prompt:false"
else pass "G02-flag-false-omits-line"; fi

# Record-then-inject in one run: stdin carries `model`, the flag is decided and
# the line must already appear in this very SessionStart's additionalContext.
seed_state "sid-g03"
G03="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g03","model":{"id":"deepseek-v4-flash","display_name":"DS4"}}' 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
if contains "$VP_TEXT" "$G03"; then pass "G03-layer1-record-then-inject"
else fail "G03-layer1-record-then-inject" "hardening line absent on the recording turn"; fi
assert_eq "G03b-source-is-hook-input" "hook-input" "$(state_field sid-g03 session_model.source)"

# No model in stdin, feature enabled → nothing to key off of: no flag armed,
# no hardening line, and no session_model recorded.
seed_state "sid-g04"
G04="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g04"}' 'VERBOSE_PROMPT_MODELS=deepseek;qwen')"
if contains "$VP_TEXT" "$G04"; then fail "G04-no-model-no-injection" "hardening line injected without a hook-input model"
else pass "G04-no-model-no-injection"; fi
assert_eq "G04b-nothing-recorded" "null" "$(state_field sid-g04 session_model.id)"

# Feature disabled → zero context growth.
seed_state "sid-g05"
G05="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-g05","model":"claude-opus-4-8"}')"
if contains "$VP_TEXT" "$G05"; then fail "G05-feature-off-adds-nothing" "hardening line injected with the feature disabled"
else pass "G05-feature-off-adds-nothing"; fi

# The hook must still emit valid JSON on the record-then-inject path.
G07="$(printf '%s' "$G03" | run_with_timeout 30 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
  try { JSON.parse(s); process.stdout.write("ok"); } catch (e) { process.stdout.write("bad"); }
});' 2>/dev/null)"
assert_eq "G07-output-is-valid-json" "ok" "$G07"

# ---------------------------------------------------------------------------
echo ""
echo "=== H: PostCompact integration (read-only consumer) ==="
# ---------------------------------------------------------------------------

seed_state "sid-h01" '{"verbose_prompt":true}'
H01_BEFORE="$(state_hash sid-h01)"
H01="$(hook_out "$POST_COMPACT_JS" '{"session_id":"sid-h01"}')"
if contains "$VP_TEXT" "$H01"; then pass "H01-flag-true-injects-line"
else fail "H01-flag-true-injects-line" "additionalContext lacks the hardening line"; fi
assert_eq "H01b-state-file-unchanged" "$H01_BEFORE" "$(state_hash sid-h01)"

seed_state "sid-h02" '{"verbose_prompt":false}'
H02="$(hook_out "$POST_COMPACT_JS" '{"session_id":"sid-h02"}')"
if contains "$VP_TEXT" "$H02"; then fail "H02-flag-false-omits-line" "hardening line injected despite verbose_prompt:false"
else pass "H02-flag-false-omits-line"; fi

# PostCompact must neither resolve nor persist: a `model` in stdin changes nothing.
seed_state "sid-h03"
H03_BEFORE="$(state_hash sid-h03)"
H03="$(hook_out "$POST_COMPACT_JS" '{"session_id":"sid-h03","model":{"id":"deepseek-v4-flash"}}' 'VERBOSE_PROMPT_MODELS=deepseek')"
assert_eq "H03-no-persistence-on-compaction" "$H03_BEFORE" "$(state_hash sid-h03)"
if contains "$VP_TEXT" "$H03"; then fail "H03b-no-injection-without-flag" "injected without a recorded flag"
else pass "H03b-no-injection-without-flag"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== J: adversarial session IDs ==="
# ---------------------------------------------------------------------------
#
# The session id reaches two places that build paths or spawn work from it:
# the read-only provider and SessionStart's own state handling. A traversal /
# metacharacter / control-character id must never create a file outside
# CLAUDE_WORKFLOW_DIR and must never reach a shell.

snapshot_outside_wfdir() {
    find "$TMPROOT" -mindepth 1 -not -path "$WFDIR" -not -path "$WFDIR/*" 2>/dev/null | LC_ALL=C sort
}
J_SNAPSHOT_BEFORE="$(snapshot_outside_wfdir)"

EVIL_TRAVERSAL='../../pwned-traversal'
EVIL_SHELL="a;touch $TMPROOT/pwned-semicolon;b"
EVIL_SUBSHELL="\$(touch $TMPROOT/pwned-subshell)"
EVIL_CONTROL="$(printf 'a\001b')"
EVIL_NEWLINE="$(printf 'a\nb')"

# evil_state_path <evil-sid> — print the raw, unsanitized path a state file
# for <evil-sid> would resolve to via path.join(WFDIR, sid + ".json"): the
# exact join formula getStatePath()/seed_state() use, with no validation.
evil_state_path() {
    run_with_timeout 30 node -e '
const path = require("path");
process.stdout.write(path.join(process.argv[2], process.argv[1] + ".json"));
' "$1" "$WFDIR_N" 2>/dev/null
}

j_idx=0
for evil in "$EVIL_TRAVERSAL" "$EVIL_SHELL" "$EVIL_SUBSHELL" "$EVIL_CONTROL" "$EVIL_NEWLINE"; do
    j_idx=$((j_idx + 1))

    # Seed a legitimate-looking state file (verbose_prompt: true) at the exact
    # location readState() would resolve to for this id if SESSION_ID_VALID_RE
    # were broken (seed_state uses the same unsanitized path.join formula as
    # getStatePath()). Without this, a "null" result is trivially true because
    # no file exists yet — it proves nothing about id-validation actually
    # rejecting the id. With the file present, "null" can only come from the
    # isUsableSessionId()/SESSION_ID_VALID_RE gate refusing to look it up.
    evil_path="$(evil_state_path "$evil")"
    seed_state "$evil" '{"verbose_prompt":true}'

    # Provider must refuse, never build a path from it — even with a seeded
    # verbose_prompt:true file sitting at the resolved location.
    assert_eq "J01-$j_idx-provider-returns-null" "null" \
        "$(jsn "VP.getVerbosePromptInjection(process.env.EVIL_SID)" \
              "EVIL_SID=$evil")"

    # Clean up immediately: the traversal id resolves outside $TMPROOT (which
    # the top-level trap does not clean), and any leftover file here would
    # also corrupt the J04/J05 outside-workflow-dir canary checks below.
    [ -n "$evil_path" ] && rm -f "$evil_path" 2>/dev/null
done

# SessionStart with an adversarial session_id must still emit valid JSON.
TMPROOT_FWD="$(printf '%s' "$TMPROOT" | sed 's#\\#/#g')"
J_STDIN_TRAVERSAL='{"session_id":"../../pwned-traversal"}'
J_STDIN_CONTROL='{"session_id":"ab"}'
J_STDIN_SHELL="{\"session_id\":\"a;touch $TMPROOT_FWD/pwned-hookshell;b\"}"

j_idx=0
for stdin_json in "$J_STDIN_TRAVERSAL" "$J_STDIN_CONTROL" "$J_STDIN_SHELL"; do
    j_idx=$((j_idx + 1))
    J_OUT="$(hook_out "$SESSION_START_JS" "$stdin_json" 'VERBOSE_PROMPT_MODELS=deepseek')"
    J_VALID="$(printf '%s' "$J_OUT" | run_with_timeout 30 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
  try { JSON.parse(s); process.stdout.write("ok"); } catch (e) { process.stdout.write("bad"); }
});' 2>/dev/null)"
    assert_eq "J03-$j_idx-sessionstart-emits-valid-json" "ok" "$J_VALID"
done

# No command was executed and no file escaped the workflow directory.
for canary in pwned-semicolon pwned-subshell pwned-hookshell pwned-traversal; do
    if [ -e "$TMPROOT/$canary" ] || [ -e "$TMPROOT/../$canary" ]; then
        fail "J04-no-canary-$canary" "an adversarial session id produced $canary — command or path injection"
    else
        pass "J04-no-canary-$canary"
    fi
done

if [ "$J_SNAPSHOT_BEFORE" = "$(snapshot_outside_wfdir)" ]; then
    pass "J05-nothing-written-outside-workflow-dir"
else
    fail "J05-nothing-written-outside-workflow-dir" \
        "path set changed: $(diff <(printf '%s\n' "$J_SNAPSHOT_BEFORE") <(snapshot_outside_wfdir) | tr '\n' ' ')"
fi

# ---------------------------------------------------------------------------
echo ""
echo "=== K: state-write failure and atomic-write hygiene ==="
# ---------------------------------------------------------------------------
#
# CLAUDE_WORKFLOW_DIR is pointed at a regular file, so every open/mkdir beneath
# it fails with ENOTDIR. Both consumers must fail open, and neither may leave a
# half-written temp file behind (writeState uses tmp+rename).

BROKEN_WFDIR="$TMPROOT/not-a-directory"
printf 'this is a file, not a directory\n' > "$BROKEN_WFDIR"
BROKEN_WFDIR_N="$(to_node_path "$BROKEN_WFDIR")"

K02_OUT="$(hook_out "$SESSION_START_JS" '{"session_id":"sid-k02","model":"deepseek-v4-flash"}' \
    'VERBOSE_PROMPT_MODELS=deepseek' "CLAUDE_WORKFLOW_DIR=$BROKEN_WFDIR_N")"
K02_VALID="$(printf '%s' "$K02_OUT" | run_with_timeout 30 node -e '
let s = ""; process.stdin.on("data", (d) => (s += d)).on("end", () => {
  try { JSON.parse(s); process.stdout.write("ok"); } catch (e) { process.stdout.write("bad"); }
});' 2>/dev/null)"
assert_eq "K02-sessionstart-valid-json-on-unwritable-dir" "ok" "$K02_VALID"
if contains "$VP_TEXT" "$K02_OUT"; then
    fail "K02b-no-injection-when-state-unwritable" "injected although the flag could never be persisted"
else
    pass "K02b-no-injection-when-state-unwritable"
fi

assert_eq "K03-broken-dir-not-clobbered" "this is a file, not a directory" "$(cat "$BROKEN_WFDIR")"

# Atomic-write hygiene across every successful write performed above.
LEFTOVER="$(find "$WFDIR" -name '*.tmp*' 2>/dev/null | LC_ALL=C sort | tr '\n' ' ')"
if [ -z "$LEFTOVER" ]; then pass "K04-no-leftover-tmp-files"
else fail "K04-no-leftover-tmp-files" "found: $LEFTOVER"; fi

# ---------------------------------------------------------------------------
echo ""
echo "=== I: single source of the injected text (CPR-2 drift check) ==="
# ---------------------------------------------------------------------------

case "$VP_TEXT_OK" in
    0)
        fail "I01-text-defined-once" "VERBOSE_PROMPT_TEXT unavailable (module not implemented yet)"
        ;;
    *)
        HITS="$(grep -rlF "$VP_TEXT" "$REPO_DIR" \
            --exclude-dir=.git --exclude-dir=node_modules --exclude-dir=tests 2>/dev/null | sort -u)"
        COUNT="$(printf '%s\n' "$HITS" | grep -c . || true)"
        if [ "$COUNT" = "1" ] && [ "$(basename "$HITS")" = "verbose-prompt.js" ]; then
            pass "I01-text-defined-once"
        else
            fail "I01-text-defined-once" "want exactly hooks/lib/verbose-prompt.js, got: $(printf '%s' "$HITS" | tr '\n' ' ')"
        fi
        ;;
esac

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
