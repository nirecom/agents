# tests/hooks/fix-1679-worker-eval-segment-composition/e2e-tl1-cases.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, allowlist, security, TL1, TL2, pwsh-not-required, scope:issue-specific
#
# Sourced by tests/hooks/fix-1679-worker-eval-segment-composition.sh.
# E2E1679-* = decision + block-reason assertions against the real hook process;
# MU1679-TL1-* = isAllowedWorkerScriptInvocation() called directly.

test_e2e_cases() {
    echo "=== E2E: real hook process, main worktree on branch main ==="
    local cmd rc

    cmd="$(printf 'cd "%s" && %s && echo "OWNER_REPO=$OWNER_REPO"' "$REPO" "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "E2E1679-1: IN1679-1 through hooks/enforce-worktree.js → exit 0 (RED before fix)" "$rc"

    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "E2E1679-2: IN1679-2 through hooks/enforce-worktree.js → exit 0 (RED before fix)" "$rc"

    # E2E1679-3 also asserts the block REASON, not just the decision: an
    # adversarial composition must be refused as a main-worktree write, not
    # silently allowed nor blocked for some unrelated reason.
    cmd="$(printf '%s || exit 0\nrm -f README.md' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "E2E1679-3: AD1679-1 through the real hook → BLOCK" "$rc"
    if [ "$rc" -eq 1 ]; then
        if echo "$GUARD_OUT" | grep -q "main worktree"; then
            pass "E2E1679-3-reason: block reason mentions 'main worktree'"
        else
            fail "E2E1679-3-reason: block reason lacks 'main worktree' (out: $GUARD_OUT)"
        fi
    else
        fail "E2E1679-3-reason: not blocked, reason unassertable (rc=$rc)"
    fi

    cmd="$(printf 'export AGENTS_MAIN_ROOT=/evil; %s' "$(pf_eval "$PF_RESOLVED")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "E2E1679-4: AD1679-9 through the real hook → BLOCK" "$rc"

    # See IN1679-5 above: #1673 deleted finalize-worker-overlay.js, so this literal
    # eval-wrapped run-initial.sh form has no ALLOW route left at any segment
    # composition. Retired-capability pin.
    cmd="$(printf 'eval "$(AGENTS_MAIN_ROOT="%s" FINALIZE_SCRIPTS_DIR="%s" TARGET_MAIN_ROOT="%s" bash "%s/run-initial.sh" "1234" "1234")"' \
        "$GUARD_CHECKOUT" "$SCRIPTS" "$REPO" "$SCRIPTS")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "E2E1679-5: run-initial 2-arg form (S-6) through the real hook → BLOCK — eval path retired (#1673)" "$rc"
}

# =============================================================================
# TL1 — isAllowedWorkerScriptInvocation() called directly (no subprocess), so the
# predicate is isolated from every other branch of hooks/enforce-worktree.js: TL2
# sees only the hook's final decision. The predicate resolves its checkout from the
# module's own location (#2561), so the pre-flight path names this checkout and no
# environment variable is passed; repoRoot is the shared main worktree.
# =============================================================================

TL1_JS="$TMPDIR_BASE/tl1-worker-script.js"

cat > "$TL1_JS" <<'TL1_EOF'
"use strict";
const assert = require("assert");
const { isAllowedWorkerScriptInvocation } = require(process.env.TL1_WORKER_JS);

const repoRoot = process.env.TL1_REPO;

// The literal absolute path of the pre-flight script in the predicate's own checkout.
const PF = 'eval "$(bash "' + process.env.TL1_PREFLIGHT + '")"';
// The unexpanded form — what PreToolUse receives when the prompt names a variable.
const PF_VARIABLE =
  'eval "$(bash "$AGENTS_MAIN_ROOT/skills/issue-close-finalize/scripts/pre-flight.sh")"';

const cases = [
  // -- ENV_MUTATION companion segments: BLOCK before AND after the fix. ------
  ["MU1679-TL1-1", PF + ' && export AGENTS_MAIN_ROOT=/evil', false,
    "export in companion segment"],
  ["MU1679-TL1-2", PF + ' ; AGENTS_MAIN_ROOT=/evil', false,
    "bare assignment in companion segment"],
  ["MU1679-TL1-3", PF + ' && unset AGENTS_MAIN_ROOT', false,
    "unset in companion segment"],
  ["MU1679-TL1-4", PF + ' && source /tmp/x.sh', false,
    "source in companion segment"],
  ["MU1679-TL1-5", PF + ' && eval "$DYNAMIC"', false,
    "opaque eval in companion segment"],
  ["MU1679-TL1-6", 'export AGENTS_MAIN_ROOT=/evil; ' + PF, false,
    "mutation BEFORE the sanctioned segment"],

  // -- Benign companion segments: ALLOW after the fix. ----------------------
  ["MU1679-TL1-7", 'cd "' + repoRoot + '" && ' + PF + ' && echo "OWNER_REPO=$OWNER_REPO"', true,
    "leading cd + trailing echo companions"],
  ["MU1679-TL1-8", PF + ' || exit 0', true,
    "|| exit 0 tail"],
  ["MU1679-TL1-9", PF, true,
    "no companion segment"],

  // -- Unexpanded variable path: never rewritten, so never sanctioned (#2561). --
  ["MU1679-TL1-10", PF_VARIABLE, false,
    "unexpanded variable path"],
];

// The bash side parses one TAB-delimited record per line, so every detail
// string is flattened first — Node's AssertionError message is multi-line.
const flat = (s) => String(s).replace(/\s+/g, " ").trim();
const emit = (status, label, detail) =>
  console.log([status, label, flat(detail)].join("\t"));

for (const [label, cmd, expected, why] of cases) {
  let actual;
  try {
    actual = isAllowedWorkerScriptInvocation(cmd, repoRoot);
  } catch (e) {
    emit("NG", label, why + " -> THREW " + e.message);
    continue;
  }
  try {
    assert.strictEqual(
      actual, expected,
      why + " -> expected " + expected + ", got " + actual
    );
    emit("OK", label, why + " -> " + (expected ? "ALLOW" : "BLOCK"));
  } catch (e) {
    emit("NG", label, e.message);
  }
}
TL1_EOF

test_tl1_cases() {
    echo "=== TL1: isAllowedWorkerScriptInvocation() called directly ==="
    local out rc=0
    out="$(run_with_timeout 30 env \
        "TL1_WORKER_JS=${_SCRIPT_CHECKOUT_ROOT_NODE}/hooks/enforce-worktree/main-worktree-allows/worker-script.js" \
        "TL1_PREFLIGHT=$PF_RESOLVED" \
        "TL1_REPO=$REPO" \
        node "$TL1_JS" 2>&1)" || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "MU1679-TL1: runner crashed (rc=$rc; out: $out)"
        return
    fi
    local status label detail
    while IFS=$'\t' read -r status label detail; do
        [ -z "${status:-}" ] && continue
        case "$status" in
            OK) pass "$label: $detail" ;;
            NG) fail "$label: $detail" ;;
            *)  fail "MU1679-TL1: unparsable runner line: $status $label $detail" ;;
        esac
    done <<< "$out"
}
