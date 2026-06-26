#!/bin/bash
# tests/feature-920-companion-issues/_lib.sh
# Shared helpers for the feature-920-companion-issues split test suite.
#
# Sourced by each split file (a-series.sh / b-series.sh / c-d-series.sh) so
# they can also run standalone.
#
# Provides:
#   - AGENTS_DIR / FIND_SCRIPT / WORKFLOW_INIT_SKILL / CLARIFY_INTENT_SKILL /
#     ENV_EXAMPLE path constants
#   - PASS / FAIL counters and pass / fail helpers
#   - run_with_timeout wrapper (10s)
#   - setup_mock / teardown_mock — gh dispatcher mock + identifier-namespace
#     fixture for find-companion-issues.sh
#   - reason_col3 — extract reason from first TSV stdout line
#
# Idempotent — guarded so multiple sources do not redefine state.

if [ -n "${_COMPANION_LIB_SOURCED:-}" ]; then
    return 0
fi
_COMPANION_LIB_SOURCED=1

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
FIND_SCRIPT="$AGENTS_DIR/bin/github-issues/find-companion-issues.sh"
WORKFLOW_INIT_SKILL="$AGENTS_DIR/skills/workflow-init/SKILL.md"
CLARIFY_INTENT_SKILL="$AGENTS_DIR/skills/clarify-intent/SKILL.md"
ENV_EXAMPLE="$AGENTS_DIR/.env.example"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm '"$secs"'; exec @ARGV' -- "$@"; fi
}

# Mock setup — gh dispatcher + identifier-namespace fixture.
setup_mock() {
    TMP="$(mktemp -d 2>/dev/null || mktemp -d -t findcomp)"
    mkdir -p "$TMP/mock-bin"

    cat > "$TMP/mock-bin/gh" <<'MOCKGH'
#!/bin/bash
# Dispatch on subcommand + --json shape + api path.
sub1="${1:-}"
sub2="${2:-}"

# --- gh issue view <N> --json <fields> ---
if [ "$sub1" = "issue" ] && [ "$sub2" = "view" ]; then
    N="${3:-}"
    JSON_FIELDS=""
    args=("$@")
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        if [ "${args[$i]}" = "--json" ]; then
            j=$((i + 1))
            JSON_FIELDS="${args[$j]:-}"
            break
        fi
        i=$((i + 1))
    done
    case "$JSON_FIELDS" in
        *body*comments*|*comments*body*)
            VARNAME="GH_MOCK_BODY_COMMENTS_${N}"
            VAL="${!VARNAME:-}"
            if [ -z "$VAL" ]; then echo '{"body":"","comments":[]}'; else echo "$VAL"; fi
            exit 0
            ;;
        *labels*state*|*state*labels*|*number*title*labels*state*)
            VARNAME="GH_MOCK_CAND_${N}"
            VAL="${!VARNAME:-}"
            if [ -z "$VAL" ]; then echo "{\"number\":${N},\"title\":\"\",\"labels\":[],\"state\":\"OPEN\"}"; else echo "$VAL"; fi
            exit 0
            ;;
        *number*title*body*|*title*body*)
            VARNAME="GH_MOCK_VIEW_${N}"
            VAL="${!VARNAME:-}"
            if [ "$VAL" = "fail" ]; then echo "mock gh view fail" >&2; exit 1; fi
            if [ -z "$VAL" ]; then echo "{\"number\":${N},\"title\":\"\",\"body\":\"\"}"; else echo "$VAL"; fi
            exit 0
            ;;
        *title*)
            VARNAME="GH_MOCK_VIEW_${N}"
            VAL="${!VARNAME:-}"
            if [ -z "$VAL" ]; then echo "{\"title\":\"\"}"; else echo "$VAL"; fi
            exit 0
            ;;
    esac
    echo '{}'
    exit 0
fi

# --- gh issue list --state open ... --search <tok> ... ---
if [ "$sub1" = "issue" ] && [ "$sub2" = "list" ]; then
    SEARCH_VAL=""
    args=("$@")
    i=0
    while [ "$i" -lt "${#args[@]}" ]; do
        if [ "${args[$i]}" = "--search" ]; then
            j=$((i + 1))
            SEARCH_VAL="${args[$j]:-}"
            break
        fi
        i=$((i + 1))
    done
    # Extract first whitespace-delimited token of search string.
    TOK="${SEARCH_VAL%% *}"
    if [ -n "$TOK" ]; then
        # Bash env names can't contain hyphens — normalize - -> _ in the
        # var name. Tests must export GH_MOCK_SEARCH_<token-with-underscores>.
        TOK_VAR="${TOK//-/_}"
        VARNAME="GH_MOCK_SEARCH_${TOK_VAR}"
        VAL="${!VARNAME:-}"
        if [ -z "$VAL" ]; then echo "[]"; else echo "$VAL"; fi
    else
        # No --search → legacy single-list mock fallback.
        echo "${GH_MOCK_LIST:-[]}"
    fi
    exit 0
fi

# --- gh api repos/.../issues/<N> | issues/<N>/sub_issues ---
if [ "$sub1" = "api" ]; then
    API_PATH="${2:-}"
    case "$API_PATH" in
        /*) API_PATH="${API_PATH#/}" ;;
    esac
    # repos/<owner>/<repo>/issues/<N>[/sub_issues]
    N=$(printf '%s' "$API_PATH" | awk -F'/' '/issues/{for(i=1;i<=NF;i++) if ($i=="issues") {print $(i+1); exit}}')
    case "$API_PATH" in
        */sub_issues|*/sub_issues/)
            VARNAME="GH_MOCK_SUBISSUES_${N}"
            VAL="${!VARNAME:-}"
            if [ -z "$VAL" ]; then echo "[]"; else echo "$VAL"; fi
            exit 0
            ;;
        *issues/*)
            VARNAME="GH_MOCK_ISSUE_${N}"
            VAL="${!VARNAME:-}"
            if [ -z "$VAL" ]; then echo '{"parent":null}'; else echo "$VAL"; fi
            exit 0
            ;;
    esac
    case "$API_PATH" in
        graphql*) echo '{"data":{}}'; exit 0 ;;
    esac
    echo '{}'
    exit 0
fi

# --- gh repo view --json nameWithOwner ---
if [ "$sub1" = "repo" ] && [ "$sub2" = "view" ]; then
    REPO="${GH_MOCK_REPO:-nirecom/agents}"
    echo "{\"nameWithOwner\":\"${REPO}\"}"
    exit 0
fi

# Unknown invocation — silent empty
echo "[]"
exit 0
MOCKGH
    chmod +x "$TMP/mock-bin/gh"

    cat > "$TMP/mock-bin/is-github-dotcom-remote" <<'MOCKREMOTE'
#!/bin/bash
exit "${MOCK_REMOTE_RC:-0}"
MOCKREMOTE
    chmod +x "$TMP/mock-bin/is-github-dotcom-remote"

    export PATH="$TMP/mock-bin:$PATH"

    # Identifier-namespace fixture (Pass B): a small AGENTS_CONFIG_DIR layout
    # whose file/dir basenames serve as the identifier namespace.
    mkdir -p "$TMP/agents-root/skills/worktree-end"
    mkdir -p "$TMP/agents-root/skills/supervisor"
    mkdir -p "$TMP/agents-root/hooks"
    mkdir -p "$TMP/agents-root/bin"
    mkdir -p "$TMP/agents-root/agents"
    mkdir -p "$TMP/agents-root/rules"
    touch "$TMP/agents-root/hooks/enforce-worktree.js"
    touch "$TMP/agents-root/bin/supervisor-report"
    touch "$TMP/agents-root/agents/detail-planner.md"
    touch "$TMP/agents-root/rules/test.md"
    export AGENTS_CONFIG_DIR="$TMP/agents-root"

    # wip-state.sh mock (Pass-C 3-axis WIP filter, #1117 Step 3). `check <N>`
    # prints MOCK_WIP_STATE_GET_RESULT (default "none") and exits
    # MOCK_WIP_STATE_GET_RC (default 0). RC!=0 lets tests exercise the
    # fail-open branch (candidate included when WIP probe errors).
    mkdir -p "$TMP/agents-root/bin/github-issues"
    cat > "$TMP/agents-root/bin/github-issues/wip-state.sh" <<'MOCKWIPSTATE'
#!/bin/bash
# args: check <N>  → print same|other|none, exit MOCK_WIP_STATE_GET_RC.
rc="${MOCK_WIP_STATE_GET_RC:-0}"
if [ "$rc" -ne 0 ]; then exit "$rc"; fi
echo "${MOCK_WIP_STATE_GET_RESULT:-none}"
exit 0
MOCKWIPSTATE
    chmod +x "$TMP/agents-root/bin/github-issues/wip-state.sh"
}

teardown_mock() {
    if [ -n "${TMP:-}" ] && [ -d "$TMP" ]; then
        PATH="${PATH#$TMP/mock-bin:}"
        export PATH
        rm -rf "$TMP" 2>/dev/null || true
    fi
    # Unset all dynamic GH_MOCK_* env-var families.
    for v in $(env | grep -oE '^GH_MOCK_(VIEW|BODY_COMMENTS|CAND|ISSUE|SUBISSUES|SEARCH)_[A-Za-z0-9_-]+' || true); do
        unset "$v"
    done
    unset GH_MOCK_LIST GH_MOCK_REPO MOCK_REMOTE_RC 2>/dev/null || true
    unset MOCK_WIP_STATE_GET_RESULT MOCK_WIP_STATE_GET_RC 2>/dev/null || true
    # Restore AGENTS_CONFIG_DIR to repo root for non-mock tests.
    export AGENTS_CONFIG_DIR="$AGENTS_DIR"
}

# Helper: extract column 3 (reason) from first stdout line.
reason_col3() {
    printf '%s\n' "$1" | head -1 | awk -F'\t' '{print $3}'
}
