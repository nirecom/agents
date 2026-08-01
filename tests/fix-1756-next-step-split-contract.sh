#!/usr/bin/env bash
# filename: tests/fix-1756-next-step-split-contract.sh
# Tests: bin/workflow/next-step, bin/workflow/lib/next-step/
# Tags: workflow, next-step, file-split, entrypoint-path, module-wiring, TL1, TL2, scope:common
#
# #1756 (SD-2): bin/workflow/next-step is split into bin/workflow/lib/next-step/*.js.
# Two contracts must hold after the split:
#   H-1  the recovery commands printed to the user must name the ENTRYPOINT
#        (bin/workflow/next-step), not the internal module that happens to build
#        the string. A bare __filename inside lib/ resolves to a non-executable
#        internal module path.
#   Wiring  every require() in the moved code must still resolve. Four of the five
#        lazy requires sit inside try/catch fail-open blocks, so a wrong path is
#        swallowed at runtime and the feature dies silently — only a static check
#        can catch it.
#
# RED: C1-C8, C13, C14 fail against the unsplit sources (lib/next-step/ does not
# exist yet and the entrypoint is still ~700 lines). C9-C12 are behavior contracts
# that must hold both before and after the split.
#
# TL3 gap (what this test does NOT catch):
# - Real CLAUDE_SESSION_ID propagation from a live `claude -p` session into the
#   next-step invocation.
# - A real user copy-pasting the recovery command into their own shell (quoting /
#   PATH resolution of `node` in the host terminal).
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
NEXT_STEP="$AGENTS_DIR/bin/workflow/next-step"
LIB_DIR="$AGENTS_DIR/bin/workflow/lib/next-step"

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

check_eq() {
    local desc="$1" expected="$2" actual="$3"
    if [ "$actual" = "$expected" ]; then pass "$desc"
    else fail "$desc -- expected [$expected] got [$actual]"; fi
}

check_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -e "$needle"; then pass "$desc"
    else fail "$desc -- expected [$needle] in: $haystack"; fi
}

check_not_contains() {
    local desc="$1" needle="$2" haystack="$3"
    if printf '%s' "$haystack" | grep -qF -e "$needle"; then
        fail "$desc -- did NOT expect [$needle] in: $haystack"
    else pass "$desc"; fi
}

# check_file_lacks <desc> <needle> <file> -- like check_not_contains but reports
# the offending line numbers instead of dumping the whole file.
check_file_lacks() {
    local desc="$1" needle="$2" file="$3"
    local hits
    hits=$(grep -nF -e "$needle" "$file" 2>/dev/null | head -3 | cut -d: -f1 | tr '\n' ',' | sed 's/,$//')
    if [ -z "$hits" ]; then pass "$desc"
    else fail "$desc -- found [$needle] at line(s) $hits"; fi
}

# ---------------------------------------------------------------------------
# Windows-compatible tmpdir shared between bash and Node.js
# ---------------------------------------------------------------------------
_NODE_TMPDIR=$(node -e "process.stdout.write(require('os').tmpdir())" 2>/dev/null || echo "")
if [[ "$_NODE_TMPDIR" =~ ^[A-Za-z]: ]]; then
    _DRIVE=$(echo "$_NODE_TMPDIR" | cut -c1 | tr 'A-Z' 'a-z')
    _REST=$(echo "$_NODE_TMPDIR" | cut -c3- | tr '\\' '/')
    TMPDIR_BASE=$(mktemp -d "/${_DRIVE}${_REST}/cctests1756c.XXXXXXXX")
else
    TMPDIR_BASE=$(mktemp -d)
fi
trap 'rm -rf "$TMPDIR_BASE"' EXIT

to_node_path() { echo "$1" | sed 's|^/\([a-zA-Z]\)/|\1:/|'; }
# Normalize a path for cross-platform string comparison: backslash -> slash, lowercase.
norm_path() { printf '%s' "$1" | tr '\\' '/' | tr 'A-Z' 'a-z'; }

WORKFLOW_DIR="$TMPDIR_BASE/workflow-state"
PLANS_DIR="$TMPDIR_BASE/plans"
mkdir -p "$WORKFLOW_DIR" "$PLANS_DIR"
export CLAUDE_WORKFLOW_DIR="$(to_node_path "$WORKFLOW_DIR")"
export WORKFLOW_PLANS_DIR="$(to_node_path "$PLANS_DIR")"

setup_repo() {
    local repo="$TMPDIR_BASE/repo-$RANDOM-$$"
    mkdir -p "$repo"
    git -C "$repo" init -q
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath ""
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial" --no-verify
    echo "$repo"
}

# write_state <sid> <overrides-json>
# overrides-json maps step name -> partial step object. Unnamed steps default to
# pending. plan_approvals is always populated so approval gates never fire (R-9).
write_state() {
    local sid="$1" overrides="$2"
    node -e '
const [sid, overrides, out] = process.argv.slice(1);
const STEPS = ["workflow_init","clarify_intent","research","outline","detail",
  "branching_complete","write_tests","review_tests","run_tests","review_security",
  "docs","user_verification","cleanup","pre_final_report_gate"];
const o = JSON.parse(overrides);
const now = new Date().toISOString();
const steps = {};
for (const s of STEPS) {
  steps[s] = Object.assign({ status: "pending", updated_at: null }, o[s] || {});
  if (steps[s].status !== "pending") steps[s].updated_at = steps[s].updated_at || now;
}
const approval = () => ({ source: "confirm-flag-off", reason: "test fixture",
  artifact_sha256: null, artifact_session_id: sid,
  artifact_hash_status: "not-applicable", recorded_at: now });
const state = { version: 1, session_id: sid, git_branch: "main", is_bugfix: false,
  workflow_type: "wf-code", created_at: now, steps, closes_issues: [1756],
  plan_approvals: { outline: approval(), detail: approval() } };
require("fs").writeFileSync(out, JSON.stringify(state, null, 2), "utf8");
' "$sid" "$overrides" "$(to_node_path "$WORKFLOW_DIR/$sid.json")"
}

raw_step_field() {
    local sid="$1" step="$2" field="$3"
    node -e '
const [f, step, field] = process.argv.slice(1);
try {
  const s = JSON.parse(require("fs").readFileSync(f, "utf8"));
  const v = s.steps && s.steps[step] && s.steps[step][field];
  process.stdout.write(v === undefined || v === null ? "" : String(v));
} catch (e) { process.stdout.write("MISSING"); }
' "$(to_node_path "$WORKFLOW_DIR/$sid.json")" "$step" "$field"
}

run_next_step() { run_with_timeout 120 node "$NEXT_STEP" "$@" 2>/dev/null || true; }

# Full step -> status map as a single comparable string (updated_at deliberately
# excluded: a re-run may refresh the timestamp without changing the state).
steps_status_map() {
    local sid="$1"
    node -e '
const f = process.argv[1];
try {
  const s = JSON.parse(require("fs").readFileSync(f, "utf8"));
  const steps = (s && s.steps) || {};
  process.stdout.write(Object.keys(steps).sort()
    .map((k) => k + "=" + String((steps[k] || {}).status)).join(";"));
} catch (e) { process.stdout.write("MISSING"); }
' "$(to_node_path "$WORKFLOW_DIR/$sid.json")"
}

LIB_DIR_N="$(to_node_path "$LIB_DIR")"

echo "=== fix-1756: next-step split contract (TL1 + TL2) ==="

# ===========================================================================
# (1) Static contract — __filename containment (TL1)
# ===========================================================================
echo ""
echo "--- C1/C2: static containment ---"

if [ ! -d "$LIB_DIR" ]; then
    fail "C1: no __filename outside entrypoint-path.js -- lib dir missing: bin/workflow/lib/next-step/"
    fail "C2: verdict.js references ENTRYPOINT_PATH >=3 times -- lib dir missing: bin/workflow/lib/next-step/"
else
    C1_OFFENDERS=""
    while IFS= read -r f; do
        [ -n "$f" ] || continue
        case "$(basename "$f")" in entrypoint-path.js) continue ;; esac
        if grep -qF '__filename' "$f"; then
            C1_OFFENDERS="$C1_OFFENDERS $(basename "$f")"
        fi
    done <<EOF
$(find "$LIB_DIR" -maxdepth 1 -name '*.js' 2>/dev/null | sort)
EOF
    check_eq "C1: no __filename in lib/next-step/*.js except entrypoint-path.js" \
        "" "$(echo "$C1_OFFENDERS" | sed 's/^ *//')"

    if [ -f "$LIB_DIR/verdict.js" ]; then
        C2_COUNT=$(grep -oF 'ENTRYPOINT_PATH' "$LIB_DIR/verdict.js" 2>/dev/null | wc -l | tr -d ' ')
    else
        C2_COUNT="0 (verdict.js missing)"
    fi
    if [ "$C2_COUNT" -ge 3 ] 2>/dev/null; then
        pass "C2: verdict.js references ENTRYPOINT_PATH >=3 times (got $C2_COUNT)"
    else
        fail "C2: verdict.js references ENTRYPOINT_PATH >=3 times -- got [$C2_COUNT]"
    fi
fi

# ===========================================================================
# (2) Unit contract — ENTRYPOINT_PATH resolution (TL1)
# ===========================================================================
echo ""
echo "--- C3..C6: ENTRYPOINT_PATH resolution ---"

EP_OUT=""
if [ -f "$LIB_DIR/entrypoint-path.js" ]; then
    EP_OUT=$(run_with_timeout 60 node -e '
const m = require(process.argv[1]);
process.stdout.write(String(m.ENTRYPOINT_PATH === undefined ? "" : m.ENTRYPOINT_PATH));
' "$LIB_DIR_N/entrypoint-path.js" 2>/dev/null || echo "")
fi

if [ -z "$EP_OUT" ]; then
    fail "C3: ENTRYPOINT_PATH is an absolute path -- got empty (entrypoint-path.js missing or not exporting it)"
    fail "C4: ENTRYPOINT_PATH points at an existing file -- got empty"
    fail "C5: ENTRYPOINT_PATH basename is next-step -- got empty"
    fail "C6: ENTRYPOINT_PATH equals AGENTS_DIR/bin/workflow/next-step -- got empty"
else
    if printf '%s' "$EP_OUT" | grep -qE '^([A-Za-z]:[\\/]|/)'; then
        pass "C3: ENTRYPOINT_PATH is an absolute path"
    else
        fail "C3: ENTRYPOINT_PATH is an absolute path -- got [$EP_OUT]"
    fi

    EP_SLASH=$(printf '%s' "$EP_OUT" | tr '\\' '/')
    if [ -f "$EP_SLASH" ]; then
        pass "C4: ENTRYPOINT_PATH points at an existing file"
    else
        fail "C4: ENTRYPOINT_PATH points at an existing file -- not found: [$EP_SLASH]"
    fi

    check_eq "C5: ENTRYPOINT_PATH basename is next-step" "next-step" "$(basename "$EP_SLASH")"

    check_eq "C6: ENTRYPOINT_PATH equals AGENTS_DIR/bin/workflow/next-step" \
        "$(norm_path "$(to_node_path "$NEXT_STEP")")" "$(norm_path "$EP_OUT")"
fi

# ===========================================================================
# (3) Wiring contract — every require resolves (TL1)
# ===========================================================================
echo ""
echo "--- C7/C8: module wiring ---"

if [ ! -d "$LIB_DIR" ]; then
    fail "C7: every lib/next-step/*.js can be require()d -- lib dir missing"
    fail "C8: every require() literal in lib/next-step/*.js resolves -- lib dir missing"
else
    C7_OUT=$(run_with_timeout 120 node -e '
const fs = require("fs"), path = require("path");
const dir = process.argv[1];
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".js")).sort();
if (files.length === 0) { process.stdout.write("NO_JS_FILES"); process.exit(0); }
const bad = [];
for (const f of files) {
  try { require(path.join(dir, f)); }
  catch (e) { bad.push(f + ": " + e.message.split("\n")[0]); }
}
process.stdout.write(bad.join(" | "));
' "$LIB_DIR_N" 2>&1 || echo "NODE_CRASH")
    check_eq "C7: every lib/next-step/*.js can be require()d without throwing" "" "$C7_OUT"

    C8_OUT=$(run_with_timeout 120 node -e '
const fs = require("fs"), path = require("path"), Module = require("module");
const dir = process.argv[1];
const files = fs.readdirSync(dir).filter((f) => f.endsWith(".js")).sort();
if (files.length === 0) { process.stdout.write("NO_JS_FILES"); process.exit(0); }
const bad = [];
let seen = 0;
for (const f of files) {
  const full = path.join(dir, f);
  const src = fs.readFileSync(full, "utf8");
  const re = /require\(\s*(["\x27])([^"\x27]+)\1\s*\)/g;
  const req = Module.createRequire(full);
  let m;
  while ((m = re.exec(src)) !== null) {
    seen++;
    try { req.resolve(m[2]); }
    catch (e) { bad.push(f + " -> " + m[2]); }
  }
}
if (seen === 0) { process.stdout.write("NO_REQUIRE_LITERALS_FOUND"); process.exit(0); }
process.stdout.write(bad.join(" | "));
' "$LIB_DIR_N" 2>&1 || echo "NODE_CRASH")
    check_eq "C8: every require() literal in lib/next-step/*.js resolves" "" "$C8_OUT"
fi

# ===========================================================================
# (4) Behavior contract — the printed recovery command actually runs (TL2)
# ===========================================================================
echo ""
echo "--- C9..C12: recovery command is executable ---"

# extract_reset_path <hint> <step> -> the <path> from "node <path> --reset <step>"
extract_reset_path() {
    local hint="$1" step="$2"
    printf '%s' "$hint" | sed -n "s|.*Recovery: node \(.*\) --reset ${step}.*|\1|p"
}

# --- C9/C10: run_tests complete + write_tests pending ---
C9_SID="c9-$(printf '%04x%04x' $RANDOM $RANDOM)"
C9_REPO="$(setup_repo)"
write_state "$C9_SID" '{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"pending"},"review_tests":{"status":"pending"},"run_tests":{"status":"complete"}}'
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
C9_OUT=$(CLAUDE_PROJECT_DIR="$(to_node_path "$C9_REPO")" run_next_step --session "$C9_SID")
eval "$C9_OUT" 2>/dev/null || true
check_eq "C9: run_tests complete + write_tests pending → ACTION=abort" "abort" "${ACTION:-}"
check_contains "C9b: NEXT_HINT offers --reset run_tests" "--reset run_tests" "${NEXT_HINT:-}"

C9_PATH_RAW="$(extract_reset_path "${NEXT_HINT:-}" "run_tests")"
C9_PATH="$(printf '%s' "$C9_PATH_RAW" | tr '\\' '/')"
if [ -n "$C9_PATH" ] && [ -f "$C9_PATH" ]; then
    pass "C9c: the path in the recovery command exists on disk"
else
    fail "C9c: the path in the recovery command exists on disk -- got [$C9_PATH_RAW]"
fi

if [ -n "$C9_PATH" ] && [ -f "$C9_PATH" ]; then
    run_with_timeout 120 node "$C9_PATH" --session "$C9_SID" --reset run_tests >/dev/null 2>&1
    C10_RC=$?
    check_eq "C10: executing the printed recovery command exits 0" "0" "$C10_RC"
    check_eq "C10b: run_tests is pending after the recovery command" \
        "pending" "$(raw_step_field "$C9_SID" "run_tests" "status")"
else
    fail "C10: executing the printed recovery command exits 0 -- no usable path extracted"
    fail "C10b: run_tests is pending after the recovery command -- no usable path extracted"
fi

# --- C11/C12: symmetric pair — review_tests complete + write_tests pending ---
C11_SID="c11-$(printf '%04x%04x' $RANDOM $RANDOM)"
C11_REPO="$(setup_repo)"
write_state "$C11_SID" '{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"pending"},"review_tests":{"status":"complete"},"run_tests":{"status":"pending"}}'
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
C11_OUT=$(CLAUDE_PROJECT_DIR="$(to_node_path "$C11_REPO")" run_next_step --session "$C11_SID")
eval "$C11_OUT" 2>/dev/null || true
check_eq "C11: review_tests complete + write_tests pending → ACTION=abort" "abort" "${ACTION:-}"
check_contains "C11b: NEXT_HINT offers --reset review_tests" "--reset review_tests" "${NEXT_HINT:-}"

C11_PATH_RAW="$(extract_reset_path "${NEXT_HINT:-}" "review_tests")"
C11_PATH="$(printf '%s' "$C11_PATH_RAW" | tr '\\' '/')"
if [ -n "$C11_PATH" ] && [ -f "$C11_PATH" ]; then
    pass "C11c: the path in the recovery command exists on disk"
else
    fail "C11c: the path in the recovery command exists on disk -- got [$C11_PATH_RAW]"
fi

if [ -n "$C11_PATH" ] && [ -f "$C11_PATH" ]; then
    run_with_timeout 120 node "$C11_PATH" --session "$C11_SID" --reset review_tests >/dev/null 2>&1
    C12_RC=$?
    check_eq "C12: executing the printed recovery command exits 0" "0" "$C12_RC"
    check_eq "C12b: review_tests is pending after the recovery command" \
        "pending" "$(raw_step_field "$C11_SID" "review_tests" "status")"
else
    fail "C12: executing the printed recovery command exits 0 -- no usable path extracted"
    fail "C12b: review_tests is pending after the recovery command -- no usable path extracted"
fi

# --- C15/C16: the THIRD recovery path — the generic evidence-backed --mark hint ---
# Reachability (derived from bin/workflow/next-step, not guessed):
#   The generic hint at the `hasEvidence && !isApprovalGatedStep(currentStep)`
#   branch needs a currentStep that (a) hasCompletionEvidence() accepts and
#   (b) reconcileEffectiveState did NOT already resolve to complete. Evidence
#   resolution in effective-state.js only fires on steps whose status is exactly
#   "pending", while the currentStep walk selects anything that is neither
#   complete nor skipped. `docs: in_progress` therefore stays current AND carries
#   evidence (a staged *.md file), which is the reachable shape. `docs` is not an
#   approval-gated step, so the --mark form (not the CONFIRM sentinel form) is
#   emitted. A later complete step (cleanup) supplies the inconsistency.
C15_SID="c15-$(printf '%04x%04x' $RANDOM $RANDOM)"
C15_REPO="$(setup_repo)"
mkdir -p "$C15_REPO/docs"
echo "# notes" > "$C15_REPO/docs/notes.md"
git -C "$C15_REPO" add docs/notes.md
write_state "$C15_SID" '{"workflow_init":{"status":"complete"},"clarify_intent":{"status":"complete"},"research":{"status":"complete"},"outline":{"status":"complete"},"detail":{"status":"complete"},"branching_complete":{"status":"complete"},"write_tests":{"status":"complete"},"review_tests":{"status":"complete"},"run_tests":{"status":"complete"},"review_security":{"status":"complete"},"docs":{"status":"in_progress"},"user_verification":{"status":"pending"},"cleanup":{"status":"complete"}}'
ACTION=""; NEXT_SKILL=""; REASON=""; NEXT_HINT=""
C15_OUT=$(CLAUDE_PROJECT_DIR="$(to_node_path "$C15_REPO")" run_next_step --session "$C15_SID")
eval "$C15_OUT" 2>/dev/null || true
check_eq "C15: docs in_progress with evidence + later complete → ACTION=abort" "abort" "${ACTION:-}"
check_contains "C15b: NEXT_HINT offers the generic --mark docs recovery" "--mark docs complete" "${NEXT_HINT:-}"

C15_PATH_RAW="$(printf '%s' "${NEXT_HINT:-}" | sed -n 's|.*Recovery: node \(.*\) --mark docs.*|\1|p')"
C15_PATH="$(printf '%s' "$C15_PATH_RAW" | tr '\\' '/')"
check_eq "C15c: the --mark hint names the ENTRYPOINT, not an internal lib module" \
    "$(norm_path "$(to_node_path "$NEXT_STEP")")" "$(norm_path "$C15_PATH_RAW")"
if [ -n "$C15_PATH" ] && [ -f "$C15_PATH" ]; then
    pass "C15d: the path in the --mark recovery command exists on disk"
else
    fail "C15d: the path in the --mark recovery command exists on disk -- got [$C15_PATH_RAW]"
fi

if [ -n "$C15_PATH" ] && [ -f "$C15_PATH" ]; then
    run_with_timeout 120 node "$C15_PATH" --session "$C15_SID" --mark docs complete >/dev/null 2>&1
    C16_RC=$?
    check_eq "C16: executing the printed --mark recovery command exits 0" "0" "$C16_RC"
    check_eq "C16b: docs is complete after the recovery command" \
        "complete" "$(raw_step_field "$C15_SID" "docs" "status")"
else
    fail "C16: executing the printed --mark recovery command exits 0 -- no usable path extracted"
    fail "C16b: docs is complete after the recovery command -- no usable path extracted"
fi

# --- C17: idempotency — a human may paste the recovery command twice ---
# Re-runs the exact same extracted command and asserts the whole steps map is
# byte-identical to the post-first-run snapshot (not just the target step).
if [ -n "$C15_PATH" ] && [ -f "$C15_PATH" ] && [ "${C16_RC:-1}" = "0" ]; then
    C17_MAP_BEFORE="$(steps_status_map "$C15_SID")"
    run_with_timeout 120 node "$C15_PATH" --session "$C15_SID" --mark docs complete >/dev/null 2>&1
    C17_RC=$?
    C17_MAP_AFTER="$(steps_status_map "$C15_SID")"
    check_eq "C17: re-running the same --mark recovery command exits 0" "0" "$C17_RC"
    check_eq "C17b: docs still complete after the second run" \
        "complete" "$(raw_step_field "$C15_SID" "docs" "status")"
    check_eq "C17c: no other step status changed between run 1 and run 2" \
        "$C17_MAP_BEFORE" "$C17_MAP_AFTER"
else
    fail "C17: re-running the same --mark recovery command exits 0 -- first run did not succeed"
    fail "C17b: docs still complete after the second run -- first run did not succeed"
    fail "C17c: no other step status changed between run 1 and run 2 -- first run did not succeed"
fi

# ===========================================================================
# (5) Entrypoint contract — dispatch only (TL1)
# ===========================================================================
echo ""
echo "--- C13/C14: entrypoint stays a dispatcher ---"

if [ ! -f "$NEXT_STEP" ]; then
    fail "C13: entrypoint effective line count < 50 -- bin/workflow/next-step missing"
    fail "C14: entrypoint contains no argument-parsing / command-body symbols -- bin/workflow/next-step missing"
else
    EFFECTIVE_LINES=$(grep -vE '^[[:space:]]*$|^[[:space:]]*//|^#!' "$NEXT_STEP" | wc -l | tr -d ' ')
    if [ "$EFFECTIVE_LINES" -lt 50 ]; then
        pass "C13: entrypoint effective line count < 50 (got $EFFECTIVE_LINES)"
    else
        fail "C13: entrypoint effective line count < 50 -- got [$EFFECTIVE_LINES]"
    fi

    check_file_lacks "C14a: entrypoint has no process.stderr.write" "process.stderr.write" "$NEXT_STEP"
    check_file_lacks "C14b: entrypoint has no VALID_STEPS" "VALID_STEPS" "$NEXT_STEP"
    check_file_lacks "C14c: entrypoint has no markStep" "markStep" "$NEXT_STEP"
fi

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
