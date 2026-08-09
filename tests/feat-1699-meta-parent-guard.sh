#!/usr/bin/env bash
# tests/feat-1699-meta-parent-guard.sh
# Tests: bin/github-issues/lib/require-meta-parent.sh, bin/github-issues/issue-create-dispatch.sh, bin/github-issues/issue-create-preflight.sh, bin/github-issues/lib/meta-parent-body.sh, bin/github-issues/issue-create.sh, bin/github-issues/sync-labels.sh
# Tags: issue-create, dispatch, meta-parent, guard, labels, preflight, sync-labels, no-delete, tmpfile, permissions, scope:issue-specific, pwsh-not-required, TL2
# TL3 gap (what this test does NOT catch):
# - Real GitHub semantics: whether `meta` + `Group: ` on a live issue actually make it
#   an acceptable sub-issue parent, and whether a real partial failure leaves the same
#   intermediate state the mock reproduces. Every gh call here is mocked.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: skill-orchestration.
#
# Dispatcher for the split suite. Sections live in feat-1699-meta-parent-guard/ and
# share the gh mock below, because all four exercise the same seam (the dispatcher's
# argv → gh call sequence) and a per-section mock would drift between them.
#
# Why a guard at all: `sub-of` attaches a NEWLY CREATED issue under a parent. If the
# parent turns out to be unusable, the issue already exists and cannot be un-created —
# the failure mode is an orphan issue plus a human cleanup. So the eligibility question
# has to be answered BEFORE the first `gh issue create`, and "no issue was created" is
# asserted on every rejection path in this file rather than only the exit code.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH="$AGENTS_DIR/bin/github-issues/issue-create-dispatch.sh"
GUARD="$AGENTS_DIR/bin/github-issues/lib/require-meta-parent.sh"
PREFLIGHT="$AGENTS_DIR/bin/github-issues/issue-create-preflight.sh"
RWT="$AGENTS_DIR/bin/run-with-timeout.sh"

PASS=0; FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1 — $2"; FAIL=$((FAIL + 1)); }

# Canonical body: issue-create.sh enforces the Background/Changes schema before any
# gh call, so a body that fails validation would abort for the wrong reason.
CANONICAL_BODY="Background: test\nChanges: test"

TMP=""

setup_mock() {
    TMP="$(mktemp -d)"
    mkdir -p "$TMP/mock-bin" "$TMP/calls"
    cat > "$TMP/mock-bin/gh" <<'MOCK_EOF'
#!/usr/bin/env bash
ARGS="$*"
[ -n "${GH_MOCK_ARGS_LOG:-}" ] && printf '%s\n' "$ARGS" >> "$GH_MOCK_ARGS_LOG"
# One file per call, one argv element per line. The args log alone cannot answer
# "which flags did the FIRST create carry" once a body contains newlines.
if [ -n "${GH_MOCK_CALL_DIR:-}" ]; then
    _CN="$GH_MOCK_CALL_DIR/.counter"
    _N=0; [ -f "$_CN" ] && _N=$(cat "$_CN")
    _N=$((_N + 1)); printf '%s' "$_N" > "$_CN"
    printf '%s\n' "$@" > "$GH_MOCK_CALL_DIR/call-$(printf '%03d' "$_N").args"
fi

_jq_expr() {
    local prev=""
    for a in "$@"; do
        [ "$prev" = "--jq" ] && { printf '%s' "$a"; return; }
        prev="$a"
    done
}

case "$ARGS" in
  auth\ status*)
    echo "Token scopes: 'gist', 'project', 'read:org', 'repo'"; exit 0 ;;

  issue\ view\ *--json\ labels,title*|issue\ view\ *--json\ title,labels*)
    # The guard's single lookup. One call must answer both structural questions.
    if [ "${GH_MOCK_VIEW_FAIL:-0}" = "1" ]; then
        # GH_MOCK_VIEW_FAIL_MSG lets a case control the failing client's diagnostic text.
        # Real `gh` writes far more than one line here (with GH_DEBUG=api it writes the
        # whole HTTP exchange, Authorization header included), so the shape of this output
        # is part of the contract, not incidental.
        printf '%s\n' "${GH_MOCK_VIEW_FAIL_MSG:-error: gh issue view failed (simulated)}" >&2
        exit 1
    fi
    # A SUCCESSFUL call whose payload cannot be parsed. This is a different failure from
    # GH_MOCK_VIEW_FAIL: rc=0, so the caller's `if !` never fires and the only defence
    # left is the guard's own true/false validation.
    if [ -n "${GH_MOCK_VIEW_GARBAGE:-}" ]; then
        printf '%s\n' "$GH_MOCK_VIEW_GARBAGE"; exit 0
    fi
    NUM=$(printf '%s' "$ARGS" | awk '{print $3}')
    eval "LBL=\${GH_MOCK_LABELS_${NUM}:-}"
    eval "TTL=\${GH_MOCK_TITLE_${NUM}:-plain title}"
    JL=""
    IFS=',' read -ra _LA <<< "$LBL"
    for l in "${_LA[@]:-}"; do
        [ -z "$l" ] && continue
        [ -n "$JL" ] && JL="$JL,"
        JL="$JL{\"name\":\"$l\"}"
    done
    JSON="{\"labels\":[$JL],\"title\":\"$TTL\"}"
    EXPR="$(_jq_expr "$@")"
    if [ -n "$EXPR" ] && command -v jq >/dev/null 2>&1; then
        printf '%s' "$JSON" | jq -r "$EXPR"
    else
        printf '%s\n' "$JSON"
    fi
    exit 0 ;;

  label\ list\ *--json\ name,color,description*)
    # sync-labels.sh three-way diff input (TSV).
    if [ "${GH_MOCK_LABEL_LIST_FAIL:-0}" = "1" ]; then
        echo "error: gh label list failed (simulated)" >&2; exit 1
    fi
    IFS=',' read -ra _LA <<< "${GH_MOCK_REPO_LABELS:-type:task}"
    for l in "${_LA[@]:-}"; do [ -n "$l" ] && printf '%s\t%s\t%s\n' "$l" "ffffff" ""; done
    exit 0 ;;
  label\ list*)
    if [ "${GH_MOCK_LABEL_LIST_FAIL:-0}" = "1" ]; then
        echo "error: gh label list failed (simulated)" >&2; exit 1
    fi
    IFS=',' read -ra _LA <<< "${GH_MOCK_REPO_LABELS:-type:task}"
    for l in "${_LA[@]:-}"; do [ -n "$l" ] && printf '%s\n' "$l"; done
    exit 0 ;;
  label\ create*)
    if [ "${GH_MOCK_LABEL_CREATE_FAIL:-0}" = "1" ]; then
        echo "error: label create failed (simulated)" >&2; exit 1
    fi
    exit 0 ;;
  label\ delete*) exit 0 ;;

  issue\ create\ *)
    if [ "${GH_MOCK_CREATE_FAIL:-0}" = "1" ]; then
        echo "error: issue create failed (simulated)" >&2; exit 1
    fi
    # Fail from the Nth create onward. make-parent creates two issues in sequence, and
    # only a per-call cursor can express "the parent succeeded, the child did not" —
    # the state in which a real meta parent is already live on GitHub.
    if [ -n "${GH_MOCK_CREATE_FAIL_FROM:-}" ]; then
        _CC="${GH_MOCK_CREATE_COUNTER:?GH_MOCK_CREATE_COUNTER required with GH_MOCK_CREATE_FAIL_FROM}"
        _CI=0; [ -f "$_CC" ] && _CI=$(cat "$_CC")
        _CI=$((_CI + 1)); printf '%s' "$_CI" > "$_CC"
        if [ "$_CI" -ge "$GH_MOCK_CREATE_FAIL_FROM" ]; then
            echo "error: issue create #${_CI} failed (simulated)" >&2; exit 1
        fi
    fi
    if [ -n "${GH_MOCK_ISSUE_NUMS:-}" ]; then
        CURSOR="${GH_MOCK_CREATE_CURSOR:?GH_MOCK_CREATE_CURSOR required with GH_MOCK_ISSUE_NUMS}"
        IDX=0; [ -f "$CURSOR" ] && IDX=$(cat "$CURSOR")
        IFS=',' read -ra NUMS <<< "$GH_MOCK_ISSUE_NUMS"
        NUM="${NUMS[$IDX]:-9999}"
        echo $((IDX + 1)) > "$CURSOR"
    else
        NUM="${GH_MOCK_NEW_ISSUE_NUM:-9999}"
    fi
    echo "https://github.com/nirecom/agents/issues/${NUM}"
    exit 0 ;;

  # reopen-with-update.sh call set. Only `gh issue reopen` is fatal there; the body/label/
  # comment steps are WARN+continue. They are answered anyway so a reopen run produces no
  # incidental stderr that a case might mistake for the failure it is looking for.
  issue\ reopen\ *)
    if [ "${GH_MOCK_REOPEN_FAIL:-0}" = "1" ]; then
        echo "error: gh issue reopen failed (simulated)" >&2; exit 1
    fi
    exit 0 ;;
  issue\ view\ *--json\ body*) echo ""; exit 0 ;;
  issue\ edit\ *) exit 0 ;;
  issue\ comment\ *) exit 0 ;;

  api\ graphql\ *databaseId*)
    if [ "${GH_MOCK_GRAPHQL_DBID_FAIL:-0}" = "1" ]; then
        echo "error: graphql request failed" >&2; exit 1
    fi
    NUM=$(printf '%s' "$ARGS" | sed 's/.*issue(number: \([0-9]*\)).*/\1/')
    echo "${NUM}000"; exit 0 ;;

  api\ *-X\ POST*sub_issues*)
    if [ -n "${GH_MOCK_SUBISSUE_FAIL_FROM:-}" ]; then
        AC="${GH_MOCK_SUBISSUE_CURSOR:?GH_MOCK_SUBISSUE_CURSOR required}"
        N=0; [ -f "$AC" ] && N=$(cat "$AC")
        N=$((N + 1)); echo "$N" > "$AC"
        if [ "$N" -ge "$GH_MOCK_SUBISSUE_FAIL_FROM" ]; then
            echo "error: sub-issue attach #${N} failed" >&2; exit 1
        fi
    fi
    exit 0 ;;

  api\ graphql\ *issue\(number:\ *parent\ \{\ number\ \}*) echo ""; exit 0 ;;
  api\ repos/*/issues/*\ --jq*) echo ""; exit 0 ;;

  repo\ view\ *nameWithOwner*|repo\ view\ *--json\ owner,name*)
    echo "${GH_MOCK_SLUG:-nirecom/agents}"; exit 0 ;;

  project\ item-add*) echo "PVTI_mock_item_id"; exit 0 ;;
  project\ item-edit*) exit 0 ;;
  issue\ view\ *createdAt*) echo "2026-05-15"; exit 0 ;;
  issue\ view\ *--json\ url*)
    NUM=$(printf '%s' "$ARGS" | awk '{print $3}')
    echo "https://github.com/nirecom/agents/issues/${NUM}"; exit 0 ;;
  api\ graphql\ *projectsV2*)
    case "$ARGS" in
      *"| length"*) echo "1"; exit 0 ;;
      *) printf '{"id":"PVT_mock","number":1,"ownerLogin":"nirecom"}\n'; exit 0 ;;
    esac ;;
  api\ graphql\ *fields*|api\ graphql\ *projectId*)
    case "$ARGS" in
      *"hasNextPage"*) echo "false"; exit 0 ;;
      *"endCursor"*)   echo ""; exit 0 ;;
      *) echo "PVTF_mock"; exit 0 ;;
    esac ;;
  api\ graphql\ *projectItems*) echo ""; exit 0 ;;

  *) echo "MOCK GH: no match for args=$ARGS" >&2; exit 2 ;;
esac
MOCK_EOF
    chmod +x "$TMP/mock-bin/gh"
    export PATH="$TMP/mock-bin:$PATH"
    export GH_MOCK_ARGS_LOG="$TMP/gh-args.log"
    export GH_MOCK_CALL_DIR="$TMP/calls"
    export GH_MOCK_CREATE_CURSOR="$TMP/create-cursor"
    export GH_MOCK_CREATE_COUNTER="$TMP/create-counter"
    export GH_MOCK_SUBISSUE_CURSOR="$TMP/attach-cursor"
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
    : > "$GH_MOCK_ARGS_LOG"
}

teardown_mock() {
    [ -n "${TMP:-}" ] && [ -d "$TMP" ] && rm -rf "$TMP"
    TMP=""
    # PATH keeps the (now deleted) mock dir prefix; harmless, and every case calls
    # setup_mock again before using gh.
    unset GH_MOCK_ARGS_LOG GH_MOCK_CALL_DIR GH_MOCK_CREATE_CURSOR GH_MOCK_SUBISSUE_CURSOR \
          GH_MOCK_CREATE_COUNTER GH_MOCK_CREATE_FAIL_FROM GH_MOCK_VIEW_GARBAGE \
          GH_MOCK_ISSUE_NUMS GH_MOCK_NEW_ISSUE_NUM GH_MOCK_VIEW_FAIL GH_MOCK_CREATE_FAIL \
          GH_MOCK_LABEL_LIST_FAIL GH_MOCK_LABEL_CREATE_FAIL GH_MOCK_REPO_LABELS \
          GH_MOCK_SUBISSUE_FAIL_FROM GH_MOCK_GRAPHQL_DBID_FAIL GH_MOCK_SLUG \
          GH_MOCK_REOPEN_FAIL GH_MOCK_VIEW_FAIL_MSG \
          GH_MOCK_LABELS_99 GH_MOCK_TITLE_99 GH_MOCK_LABELS_42 GH_MOCK_TITLE_42 \
          AGENTS_CONFIG_DIR 2>/dev/null || true
}

# --- call-log helpers ---------------------------------------------------------------

create_call_files() {  # → paths of `gh issue create` calls, in call order
    local f
    for f in "$GH_MOCK_CALL_DIR"/call-*.args; do
        [ -f "$f" ] || continue
        [ "$(sed -n '1p' "$f")" = "issue" ] || continue
        [ "$(sed -n '2p' "$f")" = "create" ] || continue
        printf '%s\n' "$f"
    done
}

count_creates() { create_call_files | grep -c . || true; }

nth_create_file() {  # <n>
    create_call_files | sed -n "${1}p"
}

count_attaches() {
    grep -c 'sub_issues' "$GH_MOCK_ARGS_LOG" 2>/dev/null || true
}

arg_after() {  # <call-file> <flag> [occurrence] → the argv element following <flag>
    awk -v flag="$2" -v occ="${3:-1}" 'BEGIN { c = 0 }
      $0 == flag { c++; if (c == occ) { if (getline line > 0) print line; exit } }' "$1"
}

has_label() {  # <call-file> <label>
    awk -v want="$2" '$0 == "--label" { if ((getline v) > 0 && v == want) { found = 1 } }
      END { exit found ? 0 : 1 }' "$1"
}

gh_called_with() { grep -qF -- "$1" "$GH_MOCK_ARGS_LOG" 2>/dev/null; }

# Runs the dispatcher with a timeout, capturing stdout/stderr/rc into globals.
# Globals: OUT, ERR, RC — read immediately by the calling case.
run_dispatch() {
    OUT="$(bash "$RWT" 60 bash "$DISPATCH" "$@" 2>"$TMP/stderr.txt")"
    RC=$?
    ERR="$(cat "$TMP/stderr.txt")"
}

SECTION_DIR="$(dirname "${BASH_SOURCE[0]}")/feat-1699-meta-parent-guard"

# shellcheck source=./feat-1699-meta-parent-guard/guard.sh
. "$SECTION_DIR/guard.sh"
# shellcheck source=./feat-1699-meta-parent-guard/guard-pathological.sh
. "$SECTION_DIR/guard-pathological.sh"
# shellcheck source=./feat-1699-meta-parent-guard/guard-secret-redaction.sh
. "$SECTION_DIR/guard-secret-redaction.sh"
# shellcheck source=./feat-1699-meta-parent-guard/bulk-and-reopen-symmetry.sh
. "$SECTION_DIR/bulk-and-reopen-symmetry.sh"
# shellcheck source=./feat-1699-meta-parent-guard/make-parent.sh
. "$SECTION_DIR/make-parent.sh"
# shellcheck source=./feat-1699-meta-parent-guard/make-parent-first-create-failure.sh
. "$SECTION_DIR/make-parent-first-create-failure.sh"
# shellcheck source=./feat-1699-meta-parent-guard/make-parent-preflight.sh
. "$SECTION_DIR/make-parent-preflight.sh"
# shellcheck source=./feat-1699-meta-parent-guard/label-preflight.sh
. "$SECTION_DIR/label-preflight.sh"
# shellcheck source=./feat-1699-meta-parent-guard/docs-contract.sh
. "$SECTION_DIR/docs-contract.sh"
# shellcheck source=./feat-1699-meta-parent-guard/none-path.sh
. "$SECTION_DIR/none-path.sh"
# shellcheck source=./feat-1699-meta-parent-guard/label-repair-no-delete.sh
. "$SECTION_DIR/label-repair-no-delete.sh"
# shellcheck source=./feat-1699-meta-parent-guard/body-file-mode.sh
. "$SECTION_DIR/body-file-mode.sh"
# shellcheck source=./feat-1699-meta-parent-guard/meta-parent-body-unit.sh
. "$SECTION_DIR/meta-parent-body-unit.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ] && exit 0 || exit 1
