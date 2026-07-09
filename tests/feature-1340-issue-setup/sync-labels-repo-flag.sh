#!/bin/bash
# tests/feature-1340-issue-setup/sync-labels-repo-flag.sh
# Tests: bin/github-issues/sync-labels.sh
# Tags: issue-setup, sync-labels, github-issues, scope:issue-specific
# N/A: secret-leakage — label names/colors are public repo metadata, not secrets; gh owns token handling.
# N/A (C8): adversarial labels.yml names/descriptions — .github/labels.yml is trusted committed config (not attacker input) and its YAML parse is unchanged by #1340 (only --repo added).
# N/A (C5): --repo=VALUE GNU-equals form + flexible flag ordering — the script uses space-separated flags; equals-form is not a supported surface.
#
# Tests for sync-labels.sh --repo OWNER/REPO flag (step 1 of #1340).
# L2: --repo threaded into gh label list, gh label create (CREATE/UPDATE);
#     no-repo backward compat; injection-payload matrix (--repo never reaches gh).
# L1: valid --repo parsed; invalid --repo format rejected.
#
# L3 gap (what this test does NOT catch):
# - Whether --repo actually targets the correct remote repo against a live
#   GitHub API (real network, real label objects).
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# pass / fail / assert_eq / AGENTS_DIR provided by _lib.sh.
TARGET="$AGENTS_DIR/bin/github-issues/sync-labels.sh"

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin"

    # Create a minimal labels.yml fixture
    mkdir -p "$TMP/github"
    cat > "$TMP/github/labels.yml" <<'LABELS_EOF'
- name: "type:task"
  color: "0e8a16"
  description: "Normal task"
- name: "type:incident"
  color: "d73a4a"
  description: "Incident"
LABELS_EOF

    # Create mock gh
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  label\ list*)
    # Return existing labels based on mock config
    EXISTING="${GH_MOCK_EXISTING_LABELS:-[]}"
    printf '%s\n' "$EXISTING"
    exit 0
    ;;
  label\ create\ *--force*)
    # UPDATE path
    exit 0
    ;;
  label\ create\ *)
    # CREATE path
    exit 0
    ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2
    ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"

    export PATH="$TMP/mock-bin:$PATH"
    export MOCK_LOG="$TMP/mock.log"
    : > "$MOCK_LOG"
    export WORKFLOW_PLANS_DIR="$TMP/plans"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        rm -rf "$TMP" 2>/dev/null || true
    fi
    TMP=""
    unset MOCK_LOG WORKFLOW_PLANS_DIR GH_MOCK_EXISTING_LABELS 2>/dev/null || true
}

# ===========================================================================
# T-repo-1: --repo flag is passed to gh label list
# ===========================================================================
setup_mock
# No existing labels → all will be CREATE
export GH_MOCK_EXISTING_LABELS='[]'
bash "$TARGET" --repo "testowner/testrepo" "$TMP/github/labels.yml" >/dev/null 2>&1
RC=$?
# Verify --repo testowner/testrepo appears in gh label list call
LABEL_LIST_WITH_REPO=0
grep -E "^gh label list.*--repo testowner/testrepo" "$MOCK_LOG" 2>/dev/null && LABEL_LIST_WITH_REPO=1
if [ "$RC" = "0" ] && [ "$LABEL_LIST_WITH_REPO" = "1" ]; then
    pass "T-repo-1: --repo threaded into gh label list"
else
    fail "T-repo-1: rc=$RC label_list_with_repo=$LABEL_LIST_WITH_REPO log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-repo-2: --repo flag is passed to gh label create (CREATE path)
# ===========================================================================
setup_mock
# No existing labels → type:task and type:incident will be CREATEd
export GH_MOCK_EXISTING_LABELS='[]'
bash "$TARGET" --repo "myorg/myrepo" "$TMP/github/labels.yml" >/dev/null 2>&1
RC=$?
CREATE_WITH_REPO=0
grep -E "^gh label create.*--repo myorg/myrepo" "$MOCK_LOG" 2>/dev/null | grep -v -- "--force" && CREATE_WITH_REPO=1
if [ "$RC" = "0" ] && [ "$CREATE_WITH_REPO" = "1" ]; then
    pass "T-repo-2: --repo threaded into gh label create (CREATE path)"
else
    fail "T-repo-2: rc=$RC create_with_repo=$CREATE_WITH_REPO log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-repo-3: --repo flag is passed to gh label create --force (UPDATE path)
# ===========================================================================
setup_mock
# Return existing label with different color → UPDATE path
export GH_MOCK_EXISTING_LABELS='[{"name":"type:task","color":"ffffff","description":"Normal task"},{"name":"type:incident","color":"ffffff","description":"Incident"}]'
# Override gh to return tsv format for label list
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  label\ list*)
    # Return TSV format: name\tcolor\tdescription - labels exist but with wrong color -> UPDATE
    printf 'type:task\tffffff\tNormal task\n'
    printf 'type:incident\tffffff\tIncident\n'
    exit 0
    ;;
  label\ create\ *--force*)
    exit 0
    ;;
  label\ create\ *)
    exit 0
    ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2
    ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
: > "$MOCK_LOG"
bash "$TARGET" --repo "orgname/repname" "$TMP/github/labels.yml" >/dev/null 2>&1
RC=$?
UPDATE_WITH_REPO=0
grep -E "^gh label create.*--force.*--repo orgname/repname|^gh label create.*--repo orgname/repname.*--force" "$MOCK_LOG" 2>/dev/null && UPDATE_WITH_REPO=1
if [ "$RC" = "0" ] && [ "$UPDATE_WITH_REPO" = "1" ]; then
    pass "T-repo-3: --repo threaded into gh label create --force (UPDATE path)"
else
    fail "T-repo-3: rc=$RC update_with_repo=$UPDATE_WITH_REPO log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-repo-4: backward compat — no --repo → gh label list called WITHOUT --repo
# ===========================================================================
setup_mock
export GH_MOCK_EXISTING_LABELS='[]'
cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/bin/bash
ARGS="$*"
if [ -n "${MOCK_LOG:-}" ]; then
    printf '%s\n' "gh $ARGS" >> "$MOCK_LOG"
fi
case "$ARGS" in
  label\ list*)
    printf ''
    exit 0
    ;;
  label\ create\ *--force*)
    exit 0
    ;;
  label\ create\ *)
    exit 0
    ;;
  *)
    echo "MOCK GH: no match for args=$ARGS" >&2
    exit 2
    ;;
esac
MOCK_EOF
chmod +x "$TMP/mock-bin/gh"
: > "$MOCK_LOG"
bash "$TARGET" "$TMP/github/labels.yml" >/dev/null 2>&1
RC=$?
# Should NOT have --repo in label list call
LABEL_LIST_WITHOUT_REPO=0
grep -E "^gh label list" "$MOCK_LOG" 2>/dev/null | grep -v -- "--repo" && LABEL_LIST_WITHOUT_REPO=1
if [ "$LABEL_LIST_WITHOUT_REPO" = "1" ]; then
    pass "T-repo-4: no --repo → gh label list called without --repo (backward compat)"
else
    fail "T-repo-4: rc=$RC without_repo=$LABEL_LIST_WITHOUT_REPO log=$(cat "$MOCK_LOG" 2>/dev/null)"
fi
teardown_mock

# ===========================================================================
# T-repo-5 (L1): valid --repo format accepted — gh label list IS called
# (After implementation: --repo is parsed and gh is invoked with it.
#  Currently RED: script treats --repo as labels file path and exits immediately.)
# ===========================================================================
setup_mock
export GH_MOCK_EXISTING_LABELS='[]'
RC=0
bash "$TARGET" --repo "validowner/validrepo" "$TMP/github/labels.yml" >/dev/null 2>&1 || RC=$?
# After implementation: gh label list is called (mock_log is non-empty)
GH_CALLED=0
[ -s "$MOCK_LOG" ] && grep -q "gh label" "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
if [ "$RC" = "0" ] && [ "$GH_CALLED" = "1" ]; then
    pass "T-repo-5 (L1): valid --repo format accepted — gh label list called"
else
    fail "T-repo-5 (L1): rc=$RC gh_called=$GH_CALLED — expected RED (--repo flag not yet implemented)"
fi
teardown_mock

# ===========================================================================
# T-repo-noval (C1 fail-closed): --repo given as the LAST arg with no value →
# non-zero exit AND gh not called. RED now: --repo isn't parsed, so the script
# treats it as the labels-file path (still non-zero, gh not called), and will
# fail-closed on missing value post-implementation.
# ===========================================================================
setup_mock
export GH_MOCK_EXISTING_LABELS='[]'
RC=0
bash "$TARGET" --repo >/dev/null 2>&1 || RC=$?
GH_CALLED=0
[ -s "$MOCK_LOG" ] && grep -q "gh label" "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
if [ "$RC" != "0" ] && [ "$GH_CALLED" = "0" ]; then
    pass "T-repo-noval (C1): --repo with no value → non-zero exit, gh not called (fail-closed)"
else
    fail "T-repo-noval (C1): rc=$RC gh_called=$GH_CALLED (expect non-zero + gh not called)"
fi
teardown_mock

# ===========================================================================
# T-repo-inj: table-driven --repo injection/format matrix.
# Contract (post-implementation): each invalid payload → non-zero exit AND the
# gh mock is NEVER invoked with that payload (grep MOCK_LOG for the raw payload).
# The single valid case (owner/repo) → rc=0 AND gh is called.
# RED now: --repo is not parsed, so invalid payloads fail via "file not found"
# (still rc!=0, gh not called) and the valid case fails (gh not called yet).
# ===========================================================================
run_repo_case() {
    # $1=payload  → sets globals: RC, GH_CALLED, PAYLOAD_IN_LOG
    local payload="$1"
    RC=0
    bash "$TARGET" --repo "$payload" "$TMP/github/labels.yml" >/dev/null 2>&1 || RC=$?
    GH_CALLED=0
    [ -s "$MOCK_LOG" ] && grep -q "gh label" "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
    # Did the attacker payload literally reach a gh invocation?
    PAYLOAD_IN_LOG=0
    if [ -n "$payload" ] && [ -s "$MOCK_LOG" ] \
       && grep -Fq -- "$payload" "$MOCK_LOG" 2>/dev/null; then
        PAYLOAD_IN_LOG=1
    fi
}

# Invalid payloads: each must be REJECTED (rc!=0) and NEVER reach the gh mock.
# Format: name | payload  (surrounding whitespace trimmed; the payload's own
# internal spaces, e.g. "a b/c", are preserved by only stripping the edges).
while IFS='|' read -r name payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    payload="${payload#"${payload%%[![:space:]]*}"}"   # ltrim
    payload="${payload%"${payload##*[![:space:]]}"}"   # rtrim
    setup_mock
    export GH_MOCK_EXISTING_LABELS='[]'
    run_repo_case "$payload"
    if [ "$RC" != "0" ] && [ "$PAYLOAD_IN_LOG" = "0" ]; then
        pass "T-repo-inj[$name]: payload rejected (rc=$RC) and never reached gh mock"
    else
        fail "T-repo-inj[$name]: rc=$RC payload_in_log=$PAYLOAD_IN_LOG — expect rc!=0 + payload absent from gh mock"
    fi
    teardown_mock
done <<TABLE
path-traversal    | ../../etc
leading-dash      | -rf
shell-semicolon   | a/b;rm -rf c
command-subst     | a/b\$(id)
pipe-metachar     | a/b|c
and-metachar      | a/b&&c
embedded-space    | a b/c
single-segment    | noslash
trailing-slash    | owner/
leading-slash     | /repo
three-segments    | a/b/c
TABLE

# Embedded-newline payload (cannot travel through the '|' table cleanly).
setup_mock
export GH_MOCK_EXISTING_LABELS='[]'
run_repo_case "$(printf 'a\nb/c')"
if [ "$RC" != "0" ] && [ "$PAYLOAD_IN_LOG" = "0" ]; then
    pass "T-repo-inj[embedded-newline]: newline payload rejected and never reached gh mock"
else
    fail "T-repo-inj[embedded-newline]: rc=$RC payload_in_log=$PAYLOAD_IN_LOG — expect rc!=0 + payload absent"
fi
teardown_mock

# Empty-string payload (--repo "").
setup_mock
export GH_MOCK_EXISTING_LABELS='[]'
RC=0
bash "$TARGET" --repo "" "$TMP/github/labels.yml" >/dev/null 2>&1 || RC=$?
GH_CALLED=0
[ -s "$MOCK_LOG" ] && grep -q "gh label" "$MOCK_LOG" 2>/dev/null && GH_CALLED=1
if [ "$RC" != "0" ] && [ "$GH_CALLED" = "0" ]; then
    pass "T-repo-inj[empty-string]: empty --repo rejected and gh not called"
else
    fail "T-repo-inj[empty-string]: rc=$RC gh_called=$GH_CALLED — expect rc!=0 + gh not called"
fi
teardown_mock

# ===========================================================================
# T-repo-valid: ACCEPTED valid --repo variants (C9). Each must be accepted
# (rc=0) AND passed through to the gh mock. Format allowed by the plan:
# [A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+ (dots, dashes, underscores, uppercase,
# single-char segments). RED now: --repo is not parsed, so gh is not called.
# ===========================================================================
while IFS='|' read -r name payload; do
    [[ -z "$name" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="${name//[[:space:]]/}"
    payload="${payload#"${payload%%[![:space:]]*}"}"; payload="${payload%"${payload##*[![:space:]]}"}"
    setup_mock
    export GH_MOCK_EXISTING_LABELS='[]'
    run_repo_case "$payload"
    if [ "$RC" = "0" ] && [ "$GH_CALLED" = "1" ]; then
        pass "T-repo-valid[$name]: '$payload' accepted and passed through to gh mock"
    else
        fail "T-repo-valid[$name]: rc=$RC gh_called=$GH_CALLED — expected RED (--repo not yet parsed)"
    fi
    teardown_mock
done <<TABLE
plain          | owner/repo
dots           | my.org/my.repo
dashes         | my-org/my-repo
underscores    | my_org/my_repo
uppercase      | MyOrg/MyRepo
single-char    | a/b
TABLE

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
