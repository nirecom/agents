#!/usr/bin/env bash
# Tests: bin/gh, bin/github-issues/migration/create-project.sh, bin/github-issues/migration/state.sh
# Tags: github, issues, bin, shell, env
# Tests for fix #529: create-project.sh uses "REPO_NAME — Issue Timeline" (U+2014 em dash)
# instead of "REPO_NAME migration" as the project title.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
STATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/state.sh"
CREATE_SCRIPT="$REPO_ROOT/bin/github-issues/migration/create-project.sh"
GH_MOCK="$REPO_ROOT/tests/fixtures/migration/gh-mock.sh"

run_with_timeout() {
  if command -v timeout >/dev/null 2>&1; then timeout 30 "$@"
  else perl -e 'alarm 30; exec @ARGV' -- "$@"; fi
}

TMPROOT=""; REPO=""
setup_fixture() {
    local has_existing="${1:-0}"
    TMPROOT="$(mktemp -d)"
    REPO="$TMPROOT/repo"
    mkdir -p "$REPO"
    # shellcheck disable=SC1090
    source "$STATE_SCRIPT"
    state_init "$REPO" >/dev/null 2>&1
    mkdir -p "$TMPROOT/bin"
    printf '#!/bin/bash\nexec "%s" "$@"\n' "$GH_MOCK" > "$TMPROOT/bin/gh"
    chmod +x "$TMPROOT/bin/gh"
    export PATH="$TMPROOT/bin:$PATH"
    export MOCK_LOG="$TMPROOT/gh-mock.log"
    export MOCK_COUNTER="$TMPROOT/gh-mock-counter"
    : > "$MOCK_LOG"
    if [ "$has_existing" = "1" ]; then export MOCK_HAS_EXISTING_PROJECT="1"
    else unset MOCK_HAS_EXISTING_PROJECT 2>/dev/null || true; fi
}
teardown_fixture() {
    rm -rf "$TMPROOT"
    unset MOCK_LOG MOCK_COUNTER MOCK_HAS_EXISTING_PROJECT MOCK_LINK_FAILS 2>/dev/null || true
    TMPROOT=""; REPO=""
}

PASS=0; FAIL=0
ok() { PASS=$((PASS+1)); echo "PASS: $1"; }
ng() { FAIL=$((FAIL+1)); echo "FAIL: $1"; }
assert() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else ng "$n"; fi; }

# T1: new-create path passes new title format (em dash) to createProjectV2
setup_fixture 0
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "T1 create-project exits 0" [ "$_rc" = "0" ]
assert "T1 MOCK_LOG contains em dash title" grep -qF '— Issue Timeline' "$MOCK_LOG"
assert "T1 MOCK_LOG does not contain old 'migration' title" bash -c '! grep -qF "migration" "$1"' _ "$MOCK_LOG"
teardown_fixture

# T2: existing-reuse path finds project with new title format
# After fix: mock returns "mockrepo — Issue Timeline", script searches for same.
setup_fixture 1
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "T2 create-project exits 0" [ "$_rc" = "0" ]
# Project #99 reused — must appear in state
assert "T2 project number 99 in state (reused)" bash -c '[ "$(jq -r .project.number "$1/.migration-state.json")" = "99" ]' _ "$REPO"
# No createProjectV2 mutation should have been called (project was reused, not created)
assert "T2 MOCK_LOG does NOT contain createProjectV2 mutation" bash -c '! grep -qF "createProjectV2" "$1"' _ "$MOCK_LOG"
teardown_fixture

# T3: old title "mockrepo migration" does NOT match — new project created instead
# Use a custom gh wrapper that returns the old title for `project list`.
setup_fixture 0
OLD_MOCK_GH="$TMPROOT/bin/gh"
cat > "$OLD_MOCK_GH" <<'OLDMOCK'
#!/bin/bash
LOG="${MOCK_LOG:-/dev/null}"
COUNTER_FILE="${MOCK_COUNTER:-/tmp/gh-mock-counter}"
if [ ! -f "$COUNTER_FILE" ]; then echo 101 > "$COUNTER_FILE"; fi
cmd="${1:-}"; shift || true
case "$cmd" in
    repo)
        sub="${1:-}"; shift || true
        echo "gh repo $sub $*" >> "$LOG"
        case "$sub" in
            view)
                has_jq=0; json_field=""; prev=""
                for arg in "$@"; do
                    [ "$prev" = "--json" ] && json_field="$arg"
                    [ "$arg" = "--jq" ] && has_jq=1
                    prev="$arg"
                done
                if [ "$has_jq" = "1" ]; then
                    case "$json_field" in
                        owner) echo "mockowner" ;;
                        name)  echo "mockrepo" ;;
                        *)     echo "" ;;
                    esac
                else
                    echo '{"owner":{"login":"mockowner"},"name":"mockrepo"}'
                fi
                ;;
            *) echo '{}' ;;
        esac
        exit 0
        ;;
    auth)
        sub="${1:-}"; shift || true
        echo "gh auth $sub $*" >> "$LOG"
        [ "$sub" = "status" ] && echo "Logged in. Scopes: project, repo"
        exit 0
        ;;
    project)
        sub="${1:-}"; shift || true
        echo "gh project $sub $*" >> "$LOG"
        case "$sub" in
            list)
                # Return OLD title "mockrepo migration" — should NOT match after fix
                echo '{"projects":[{"number":88,"title":"mockrepo migration","id":"PVT_kwDOold"}]}'
                ;;
            view)
                echo '{"id":"PVT_kwDOmock","number":99}'
                ;;
            field-list)
                echo '{"fields":[{"name":"Status","id":"PVTF_status"}]}'
                ;;
            field-create)
                echo '{"id":"PVTF_contentdate_mock"}'
                ;;
            *)
                echo '{"number":99,"id":"PVT_mock","fields":{"nodes":[]}}'
                ;;
        esac
        exit 0
        ;;
    api)
        first="${1:-}"
        echo "gh api $*" >> "$LOG"
        if [ "$first" = "graphql" ]; then
            query_body=""
            jq_filter=""
            prev_arg=""
            for arg in "$@"; do
                case "$arg" in
                    query=*) query_body="${arg#query=}" ;;
                    --jq)    : ;;
                    *)
                        [ "$prev_arg" = "--jq" ] && jq_filter="$arg"
                        ;;
                esac
                prev_arg="$arg"
            done
            json_out=""
            case "$query_body" in
                *createProjectV2Field*)
                    json_out='{"data":{"createProjectV2Field":{"projectV2Field":{"id":"PVTF_contentdate_mock"}}}}' ;;
                *createProjectV2*)
                    json_out='{"data":{"createProjectV2":{"projectV2":{"id":"PVT_kwDOnew","number":100}}}}' ;;
                *viewer*id*)
                    json_out='{"data":{"viewer":{"id":"MDQ6User_mock123"}}}' ;;
                *user*login*)
                    json_out='{"data":{"user":{"id":"MDQ6User_mock123"}}}' ;;
                *organization*login*)
                    json_out='{"data":{"organization":{"id":"MDEyOk9yZ_mock123"}}}' ;;
                *linkProjectV2ToRepository*)
                    json_out='{"data":{"linkProjectV2ToRepository":{"repository":{"id":"R_kgDOmock"}}}}' ;;
                *)
                    json_out='{"data":{}}' ;;
            esac
            if [ -n "$jq_filter" ] && command -v jq >/dev/null 2>&1; then
                echo "$json_out" | jq -r "$jq_filter"
            else
                echo "$json_out"
            fi
        else
            base_json='{"node_id":"R_kgDOmock","name":"mockrepo","full_name":"mockowner/mockrepo"}'
            jq_filter=""
            prev=""
            for arg in "$@"; do
                [ "$prev" = "--jq" ] && jq_filter="$arg"
                prev="$arg"
            done
            if [ -n "$jq_filter" ] && command -v jq >/dev/null 2>&1; then
                echo "$base_json" | jq -r "$jq_filter"
            else
                echo "$base_json"
            fi
        fi
        exit 0
        ;;
    *)
        echo "gh $cmd $*" >> "$LOG"
        exit 0
        ;;
esac
OLDMOCK
chmod +x "$OLD_MOCK_GH"
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
assert "T3 create-project exits 0" [ "$_rc" = "0" ]
assert "T3 MOCK_LOG contains createProjectV2 (new project created)" grep -qF 'createProjectV2' "$MOCK_LOG"
# Project number must NOT be 88 (the old project)
assert "T3 project number is not 88 (old title not reused)" bash -c '[ "$(jq -r .project.number "$1/.migration-state.json")" != "88" ]' _ "$REPO"
teardown_fixture

# T4: em dash integrity — title contains U+2014 (0xe2 0x80 0x94), not ASCII hyphen
setup_fixture 0
_rc=0
run_with_timeout bash "$CREATE_SCRIPT" "$REPO" >/dev/null 2>&1 || _rc=$?
# Check for the em dash byte sequence in the log
assert "T4 MOCK_LOG contains U+2014 em dash (not ASCII hyphen)" grep -qF $'\xe2\x80\x94' "$MOCK_LOG"
assert "T4 MOCK_LOG does not contain ' - ' (space-hyphen-space)" bash -c '! grep -qF " - " "$1"' _ "$MOCK_LOG"
assert "T4 MOCK_LOG does not contain double-hyphen '--'" bash -c '! grep -qF -- "-- " "$1"' _ "$MOCK_LOG"
teardown_fixture

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
