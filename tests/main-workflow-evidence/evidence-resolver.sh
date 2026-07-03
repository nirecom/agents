# shellcheck shell=bash
# Tests: hooks/workflow-gate.js, hooks/lib/workflow-state/evidence-resolver.js
# Tags: workflow, gate, hook, bin
#
# Case group: evidence-resolver clarify_intent + workflow-gate Tier 2 auto-repair (WS-EV-14..16).
# Sourced by main-workflow-evidence.sh; relies on helpers from common.sh.

run_evidence_resolver_tests() {
    local RESOLVER PLANS_TMP EV14_SID EV14_OUT EV15_SID EV15_OUT SID GATE_INPUT GATE_OUT

    echo ""
    echo "=== WS-EV-14: evidence-resolver clarify_intent — intent.md present → hasCompletionEvidence=true ==="

    # Only run if evidence-resolver.js is implemented
    if [ -f "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
      RESOLVER="$(to_node_path "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js")"
      PLANS_TMP=$(mktemp -d)
      EV14_SID="ev14-$$"
      touch "$PLANS_TMP/${EV14_SID}-intent.md"

      EV14_OUT=$(WORKFLOW_PLANS_DIR="$PLANS_TMP" node -e "
        const r = require('$RESOLVER');
        try { console.log(r.hasCompletionEvidence('clarify_intent', '$EV14_SID') ? 'true' : 'false'); }
        catch(e) { console.log('ERROR: ' + e.message); }
      " 2>/dev/null)

      if [ "$EV14_OUT" = "true" ]; then
        pass "WS-EV-14. evidence-resolver clarify_intent + intent.md present → true"
      else
        fail "WS-EV-14. expected true, got: $EV14_OUT"
      fi
      rm -rf "$PLANS_TMP"
    else
      echo "SKIP: WS-EV-14 (evidence-resolver.js not yet implemented)"
    fi

    echo ""
    echo "=== WS-EV-15: evidence-resolver clarify_intent — intent.md absent → hasCompletionEvidence=false ==="

    if [ -f "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
      RESOLVER="$(to_node_path "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js")"
      PLANS_TMP=$(mktemp -d)
      EV15_SID="ev15-$$"
      # No intent.md created

      EV15_OUT=$(WORKFLOW_PLANS_DIR="$PLANS_TMP" node -e "
        const r = require('$RESOLVER');
        try { console.log(r.hasCompletionEvidence('clarify_intent', '$EV15_SID') ? 'true' : 'false'); }
        catch(e) { console.log('ERROR: ' + e.message); }
      " 2>/dev/null)

      if [ "$EV15_OUT" = "false" ]; then
        pass "WS-EV-15. evidence-resolver clarify_intent + intent.md absent → false"
      else
        fail "WS-EV-15. expected false, got: $EV15_OUT"
      fi
      rm -rf "$PLANS_TMP"
    else
      echo "SKIP: WS-EV-15 (evidence-resolver.js not yet implemented)"
    fi

    echo ""
    echo "=== WS-EV-16: workflow-gate Tier 2 — clarify_intent pending + intent.md present → gate auto-repairs ==="

    if [ -f "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
      PLANS_TMP=$(mktemp -d)
      SID="ev16-$$"
      # workflow_init=complete, clarify_intent=pending, closes_issues populated
      cat > "$WORKFLOW_DIR/${SID}.json" <<'STATEOF'
{"version":1,"closes_issues":[1094],"steps":{"workflow_init":{"status":"complete","updated_at":"2026-04-11T10:00:30.000Z"},"clarify_intent":{"status":"pending","updated_at":null},"research":{"status":"pending","updated_at":null},"outline":{"status":"pending","updated_at":null},"detail":{"status":"pending","updated_at":null},"branching_complete":{"status":"pending","updated_at":null},"write_tests":{"status":"pending","updated_at":null},"review_tests":{"status":"pending","updated_at":null},"run_tests":{"status":"pending","updated_at":null},"review_security":{"status":"pending","updated_at":null},"docs":{"status":"pending","updated_at":null},"user_verification":{"status":"pending","updated_at":null},"cleanup":{"status":"pending","updated_at":null},"pre_final_report_gate":{"status":"pending","updated_at":null}}}
STATEOF
      touch "$PLANS_TMP/${SID}-intent.md"

      GATE_INPUT=$(printf '{"tool_name":"Write","tool_input":{"file_path":"/tmp/test.txt","content":"x"},"session_id":"%s"}' "$SID")
      GATE_OUT=$(WORKFLOW_PLANS_DIR="$PLANS_TMP" CLAUDE_WORKFLOW_DIR="$WORKFLOW_DIR" node "$GATE_HOOK" <<< "$GATE_INPUT" 2>/dev/null)

      if echo "$GATE_OUT" | grep -q '"approve"' || ! echo "$GATE_OUT" | grep -q 'clarify_intent'; then
        pass "WS-EV-16. intent.md present + clarify_intent=pending → gate does not block clarify_intent"
      else
        fail "WS-EV-16. expected gate to pass/not block clarify_intent, got: $GATE_OUT"
      fi
      rm -rf "$PLANS_TMP"
    else
      echo "SKIP: WS-EV-16 (evidence-resolver.js not yet implemented)"
    fi

    echo ""
    echo "=== WS-EV-17: evidence-resolver write_tests — staged tests/ file present → hasCompletionEvidence=true ==="

    if [ -f "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
      RESOLVER="$(to_node_path "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js")"
      EV17_REPO=$(setup_repo)
      EV17_REPO_N=$(to_node_path "$EV17_REPO")
      EV17_SID="ev17-$$"
      mkdir -p "$EV17_REPO/tests"
      echo "test content" > "$EV17_REPO/tests/feature-ev17.sh"
      git -C "$EV17_REPO" add tests/feature-ev17.sh

      EV17_OUT=$(CLAUDE_PROJECT_DIR="$EV17_REPO_N" node -e "
        const r = require('$RESOLVER');
        try { console.log(r.hasCompletionEvidence('write_tests', '$EV17_SID', {repoDir: process.env.CLAUDE_PROJECT_DIR}) ? 'true' : 'false'); }
        catch(e) { console.log('ERROR: ' + e.message); }
      " 2>/dev/null)

      # Hard assertion (symmetric with WS-EV-19): write_tests staged-evidence must be true; the vestigial pre-#1107 soft-pass is removed to close a latent false-green.
      if [ "$EV17_OUT" = "true" ]; then
        pass "WS-EV-17. evidence-resolver write_tests + staged tests/ → true"
      else
        fail "WS-EV-17. expected true (write_tests staged-evidence), got: $EV17_OUT"
      fi
    else
      echo "SKIP: WS-EV-17 (evidence-resolver.js not yet implemented)"
    fi

    echo ""
    echo "=== WS-EV-18: evidence-resolver write_tests — no staged tests/ → hasCompletionEvidence=false ==="

    if [ -f "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
      RESOLVER="$(to_node_path "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js")"
      EV18_REPO=$(setup_repo)
      EV18_REPO_N=$(to_node_path "$EV18_REPO")
      EV18_SID="ev18-$$"
      # No tests/ staged

      EV18_OUT=$(CLAUDE_PROJECT_DIR="$EV18_REPO_N" node -e "
        const r = require('$RESOLVER');
        try { console.log(r.hasCompletionEvidence('write_tests', '$EV18_SID', {repoDir: process.env.CLAUDE_PROJECT_DIR}) ? 'true' : 'false'); }
        catch(e) { console.log('ERROR: ' + e.message); }
      " 2>/dev/null)

      # Soft: 'false' for any reason (no tests staged, or unknown step) → PASS.
      # Only an unexpected 'true' is a hard failure.
      if [ "$EV18_OUT" = "true" ]; then
        fail "WS-EV-18. expected false, got: $EV18_OUT"
      else
        pass "WS-EV-18. evidence-resolver write_tests + no staged tests/ → false (got: $EV18_OUT)"
      fi
    else
      echo "SKIP: WS-EV-18 (evidence-resolver.js not yet implemented)"
    fi

    echo ""
    echo "=== WS-EV-19: evidence-resolver run_tests — staged tests/ present → hasCompletionEvidence=false (sentinel-only after #1215) ==="

    if [ -f "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js" ]; then
      RESOLVER="$(to_node_path "$DOTFILES_DIR/hooks/lib/workflow-state/evidence-resolver.js")"
      EV19_REPO=$(setup_repo)
      EV19_REPO_N=$(to_node_path "$EV19_REPO")
      EV19_SID="ev19-$$"
      mkdir -p "$EV19_REPO/tests"
      echo "test content" > "$EV19_REPO/tests/feature-ev19.sh"
      git -C "$EV19_REPO" add tests/feature-ev19.sh

      EV19_OUT=$(CLAUDE_PROJECT_DIR="$EV19_REPO_N" node -e "
        const r = require('$RESOLVER');
        try { console.log(r.hasCompletionEvidence('run_tests', '$EV19_SID', {repoDir: process.env.CLAUDE_PROJECT_DIR}) ? 'true' : 'false'); }
        catch(e) { console.log('ERROR: ' + e.message); }
      " 2>/dev/null)

      # Hard fail: run_tests must NOT return true when staged tests/ are present.
      # After #1215, run_tests is sentinel-only — hasStagedTestChanges no longer
      # drives run_tests evidence. A 'true' result is a regression of the #1215 fix.
      # Symmetry with WS-EV-17: write_tests→true / run_tests→false (same staged files).
      if [ "$EV19_OUT" = "true" ]; then
        fail "WS-EV-19. run_tests + staged tests/ → expected false (sentinel-only after #1215), got: true"
      else
        pass "WS-EV-19. run_tests + staged tests/ → false (sentinel-only after #1215)"
      fi
    else
      echo "SKIP: WS-EV-19 (evidence-resolver.js not yet implemented)"
    fi
}
