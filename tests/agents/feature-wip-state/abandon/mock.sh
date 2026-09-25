# Sourced by tests/feature-wip-state/abandon.sh — not executed directly (no shebang).
# Tests: bin/github-issues/wip-state.sh, bin/github-issues/wip-state/cmd-abandon.sh
# Tags: wip-state, github, scope:issue-specific
#
# Verb: abandon <N> — inverse of clear. OPEN-only.
#   OPEN  → Status=Todo (HARD) + fingerprint="" (HARD) + delete lock (only after both writes succeed).
#   CLOSED / gh-error → warn + exit 1, NO mutations.
#   --session-id blocked → exit 2 (verb does not consume a session id).
#   WIP_STATE_TODO_OPTION_ID is used for Status (NOT WIP_STATE_DONE_OPTION_ID).
#
# L3 gap: these cases stub `gh` entirely. The real GitHub Projects v2 item-edit
# API (single-select option write + text-field clear), the auto-close semantics
# of Status transitions on OPEN issues, and real `gh auth` project-scope
# behaviour are NOT exercised here. Only an L3 run against a live project board
# (real `gh`, real issue #N, real Status field) can confirm that Status=Todo on
# an OPEN issue does not trigger GitHub's auto-close/auto-archive workflow and
# that the TODO option id resolves to the correct column. Mock-level assertions
# only prove the helper's control flow and the arguments it passes to `gh`.
# OS-level lock deletion failure (e.g. EACCES on the plans directory) is
# also an L3 gap — it requires real filesystem permission manipulation and
# cannot be reliably reproduced in a mock-only harness.

# ---------------------------------------------------------------------------
# Shared inline mock for abandon state-dependent cases. Emits $GH_MOCK_STATE
# for `issue view --json state`, honors GH_MOCK_FAIL for item-edit writes.
#   GH_MOCK_STATE               OPEN | CLOSED   (state returned by issue view)
#   GH_MOCK_STATE_CHECK_FAIL=1  issue-state-check gh call exits 1
#   GH_MOCK_FAIL                item-edit-status | item-edit-fp
#   GH_MOCK_FP_NO_CHANGES=1     --text clear returns "no changes to make" (rc=1)
#   GH_MOCK_PROJECT_ITEM_ID     item id from resolve_item_id (empty ⇒ not in project)
# ---------------------------------------------------------------------------
mint_abandon_mock() {
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${GH_MOCK_ARGS_LOG:-}" ]; then
    printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
fi
case "$ARGS" in
  issue\ view\ *--json\ state*)
    if [ "${GH_MOCK_STATE_CHECK_FAIL:-}" = "1" ]; then
        exit 1
    fi
    echo "${GH_MOCK_STATE:-OPEN}"
    exit 0 ;;
  auth\ status*)
    if [ "${GH_MOCK_MISSING_PROJECT_SCOPE:-}" = "1" ]; then
      echo "Token scopes: 'repo'"
    else
      echo "Token scopes: 'project', 'repo'"
    fi
    exit 0 ;;
  repo\ view\ *) echo "${GH_MOCK_OWNER_REPO:-nirecom/agents}"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "${GH_MOCK_LINKED_COUNT:-1}"; exit 0 ;;
      *) printf '{"id":"PVT_resolved","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac
    ;;
  api\ graphql\ *) printf '%s\n' "${GH_MOCK_PROJECT_ITEM_ID-PVTI_existing}"; exit 0 ;;
  project\ item-edit\ *--single-select-option-id*)
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-status" ]; then
        echo "error: status item-edit failed" >&2
        exit 1
    fi
    exit 0 ;;
  project\ item-edit\ *--text*)
    if [ "${GH_MOCK_FP_NO_CHANGES:-}" = "1" ]; then
        echo "no changes to make for the item-edit" >&2
        exit 1
    fi
    if [ "${GH_MOCK_FAIL:-}" = "item-edit-fp" ]; then
        echo "error: fingerprint item-edit failed" >&2
        exit 1
    fi
    exit 0 ;;
  *) echo "MOCK GH: no match $ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
}
