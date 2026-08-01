# tests/fix-1679-worker-eval-segment-composition/e2e-tl1-cases.sh
# Tests: hooks/enforce-worktree/main-worktree-allows/worker-script.js, hooks/enforce-worktree.js
# Tags: enforce-worktree, allowlist, security, TL1, TL2, pwsh-not-required, scope:issue-specific
#
# Sourced by tests/fix-1679-worker-eval-segment-composition.sh.
# Contains the E2E1679-* (real hook process assertions) and MU1679-TL1-*
# (direct isAllowedWorkerScriptInvocation() unit) test groups. See the
# entrypoint file's header comment for the full issue background.

# ============================================================================
# E2E — decision + block-reason assertions against the real hook process.
# ============================================================================

test_e2e_cases() {
    echo "=== E2E: real hook process, main worktree on branch main ==="
    local cmd rc

    cmd="$(printf 'cd "%s" && %s && echo "OWNER_REPO=$OWNER_REPO"' "$REPO" "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "E2E1679-1: IN1679-1 through hooks/enforce-worktree.js → exit 0 (RED before fix)" "$rc"

    cmd="$(printf '%s || exit 0; echo "OWNER_REPO=$OWNER_REPO"' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_allow "E2E1679-2: IN1679-2 through hooks/enforce-worktree.js → exit 0 (RED before fix)" "$rc"

    # E2E1679-3 also asserts the block REASON, not just the decision: an
    # adversarial composition must be refused as a main-worktree write, not
    # silently allowed nor blocked for some unrelated reason.
    cmd="$(printf '%s || exit 0\nrm -f README.md' "$(pf_eval "$PF_LITERAL")")"
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

    cmd="$(printf 'export AGENTS_CONFIG_DIR=/evil; %s' "$(pf_eval "$PF_LITERAL")")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "E2E1679-4: AD1679-9 through the real hook → BLOCK" "$rc"

    # See IN1679-5 above: #1673 deleted finalize-worker-overlay.js, so this literal
    # eval-wrapped run-initial.sh form has no ALLOW route left at any segment
    # composition. Retired-capability pin.
    cmd="$(printf 'eval "$(AGENTS_CONFIG_DIR="%s" FINALIZE_SCRIPTS_DIR="%s" MAIN_WORKTREE_PATH="%s" bash "%s/run-initial.sh" "1234" "1234")"' \
        "$ACD" "$SCRIPTS" "$REPO" "$SCRIPTS")"
    rc=0; guard "$cmd" || rc=$?
    assert_block "E2E1679-5: run-initial 2-arg form (S-6) through the real hook → BLOCK — eval path retired (#1673)" "$rc"
}

# =============================================================================
# TL1 — Direct unit tests for companion-segment ENV_MUTATION guard (S-8)
# =============================================================================
# These call isAllowedWorkerScriptInvocation() directly (no subprocess).
# Before fix: env-mutation BLOCK cases are GREEN (existing behavior),
# but benign-companion ALLOW cases that need segmentation are RED (bug not fixed).
# After fix: all GREEN.
#
# Why TL1 in addition to the TL2 rows above: the TL2 driver observes only the
# hook's final decision, which is the OR/AND of several predicates. If
# isAllowedWorkerScriptInvocation itself regressed but some other branch of
# hooks/enforce-worktree.js happened to block (or allow) the same string, TL2
# could not tell the difference. These rows isolate the predicate.
#
# The acd is resolved by hooks/lib/agents-config-dir.js from
# process.env.AGENTS_CONFIG_DIR (marker-validated), so the shared fake-acd
# fixture is passed through env; repoRoot is the shared main worktree, which
# owns one registered linked worktree.

TL1_JS="$TMPDIR_BASE/tl1-worker-script.js"

cat > "$TL1_JS" <<'TL1_EOF'
"use strict";
const assert = require("assert");
const { isAllowedWorkerScriptInvocation } = require(process.env.TL1_WORKER_JS);

const repoRoot = process.env.TL1_REPO;

// Literal (unexpanded) pre-flight eval — exactly what PreToolUse receives.
const PF =
  'eval "$(bash "$AGENTS_CONFIG_DIR/skills/issue-close-finalize/scripts/pre-flight.sh")"';

const cases = [
  // -- ENV_MUTATION companion segments: BLOCK before AND after the fix. ------
  ["MU1679-TL1-1", PF + ' && export AGENTS_CONFIG_DIR=/evil', false,
    "export in companion segment"],
  ["MU1679-TL1-2", PF + ' ; AGENTS_CONFIG_DIR=/evil', false,
    "bare assignment in companion segment"],
  ["MU1679-TL1-3", PF + ' && unset AGENTS_CONFIG_DIR', false,
    "unset in companion segment"],
  ["MU1679-TL1-4", PF + ' && source /tmp/x.sh', false,
    "source in companion segment"],
  ["MU1679-TL1-5", PF + ' && eval "$DYNAMIC"', false,
    "opaque eval in companion segment"],
  ["MU1679-TL1-6", 'export AGENTS_CONFIG_DIR=/evil; ' + PF, false,
    "mutation BEFORE the sanctioned segment"],

  // -- Benign companion segments: ALLOW after the fix. ----------------------
  ["MU1679-TL1-7", 'cd "' + repoRoot + '" && ' + PF + ' && echo "OWNER_REPO=$OWNER_REPO"', true,
    "leading cd + trailing echo companions"],
  ["MU1679-TL1-8", PF + ' || exit 0', true,
    "|| exit 0 tail"],
  ["MU1679-TL1-9", PF, true,
    "no companion segment"],
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
        "AGENTS_CONFIG_DIR=$ACD" \
        "TL1_WORKER_JS=${_AGENTS_DIR_NODE}/hooks/enforce-worktree/main-worktree-allows/worker-script.js" \
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
