#!/bin/bash
# tests/fix-1899-origin-repo-resolver/callers.sh
# Tests: bin/github-issues/lib/board-card.sh, bin/github-issues/lib/resolve-project.sh, skills/issue-close-finalize/scripts/pre-flight.sh
# Tags: origin-resolution, github-issues, board-card, resolve-project, pre-flight, TL2, scope:issue-specific
#
# Groups D, E and F of the fix-1899-origin-repo-resolver split suite — the bash
# CALLERS that used to derive repository identity from `gh repo view`.
#
# Why: a resolver that is correct in isolation buys nothing while its callers keep
# asking the API. Each group installs a `gh` stub that answers with the UPSTREAM
# identity while the git fixture's origin says something else, so any caller still
# routing through `gh repo view` returns the upstream answer and fails here —
# exactly the #1899 defect, pinned at the seam where it does damage.
#
# TL2 (real git fixtures, real bash, stubbed `gh`). TL3 gap: no real GitHub API
# and no real multi-remote clone. Mitigated at WORKFLOW_USER_VERIFIED preflight
# (bin/check-verification-gate.sh) since the change is skill-orchestration class.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# Group F's target. Declared here rather than in _lib.sh: the other split groups
# never touch resolve-project.sh, and AGENTS_DIR is already exported by _lib.sh.
RESOLVE_PROJECT_LIB="$AGENTS_DIR/bin/github-issues/lib/resolve-project.sh"

# ===========================================================================
# Group D — board-card.sh::resolve_owner_repo delegates to origin
# ===========================================================================
mk_gh_stub() {
    local bindir="$TMP/stubbin"
    mkdir -p "$bindir"
    cat >"$bindir/gh" <<'STUB'
#!/bin/bash
# Deliberately WRONG answer: pretends the API resolved the upstream repo.
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
    echo "upstream-owner/upstream-repo"
    exit 0
fi
exit 0
STUB
    chmod +x "$bindir/gh"
    printf '%s' "$bindir"
}

group_board_card() {
    local dir stub got rc
    stub="$(mk_gh_stub)"
    dir="$(mk_repo "bc" "https://github.com/origin-owner/origin-repo.git")"
    git -C "$dir" remote add upstream "https://github.com/upstream-owner/upstream-repo.git"

    got=$(PATH="$stub:$PATH" run_with_timeout 20 bash -c '
        set -u
        cd "$2" || exit 92
        unset BOARD_CARD_REPO_OVERRIDE
        . "$1"
        resolve_owner_repo
    ' _ "$BOARD_CARD_LIB" "$dir" 2>/dev/null)
    rc=$?
    assert_eq "board-card/uses-origin-not-upstream" "0|origin-owner/origin-repo" "$rc|$got"

    # No origin at all -> non-zero, and it must NOT emit the gh answer.
    dir="$(mk_repo "bc-noorigin" "__NONE__")"
    got=$(PATH="$stub:$PATH" run_with_timeout 20 bash -c '
        set -u
        cd "$2" || exit 92
        unset BOARD_CARD_REPO_OVERRIDE
        . "$1"
        resolve_owner_repo
    ' _ "$BOARD_CARD_LIB" "$dir" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$got" ]; then
        pass "board-card/no-origin-fails-closed"
    else
        fail "board-card/no-origin-fails-closed — rc=$rc out=$(printf '%q' "$got")"
    fi

    # Config-dependent branch: BOARD_CARD_REPO_OVERRIDE short-circuits entirely.
    # The fixture has NO origin remote, so a git-touching path could not succeed —
    # a rc 0 with the override value proves the short-circuit ran first.
    got=$(PATH="$stub:$PATH" BOARD_CARD_REPO_OVERRIDE="override-owner/override-repo" \
        run_with_timeout 20 bash -c '
        set -u
        cd "$2" || exit 92
        . "$1"
        resolve_owner_repo
    ' _ "$BOARD_CARD_LIB" "$dir" 2>/dev/null)
    rc=$?
    assert_eq "board-card/override-short-circuits" "0|override-owner/override-repo" "$rc|$got"
}

# ===========================================================================
# Group E — pre-flight.sh: exit-code + `OWNER_REPO=` stdout contract
#
#   The stdout shape and the 0/1 exit codes are load-bearing: the caller runs
#   `eval "$(bash ".../pre-flight.sh")" || exit 0`, a shape that
#   hooks/enforce-worktree/main-worktree-allows/worker-script.js matches by
#   regex. These cases pin the contract while the resolution source changes.
# ===========================================================================
group_pre_flight() {
    local dir stub out rc
    stub="$(mk_gh_stub)"

    dir="$(mk_repo "pf" "https://github.com/origin-owner/origin-repo.git")"
    git -C "$dir" remote add upstream "https://github.com/upstream-owner/upstream-repo.git"
    out=$(PATH="$stub:$PATH" run_with_timeout 30 bash -c '
        cd "$2" || exit 92
        bash "$1"
    ' _ "$PRE_FLIGHT" "$dir" 2>/dev/null)
    rc=$?
    assert_eq "pre-flight/github-origin-exit0" "0" "$rc"
    assert_eq "pre-flight/stdout-owner-repo" "OWNER_REPO=origin-owner/origin-repo" "$out"

    # Sourceable-shape pin: the single stdout line must survive `eval`.
    local evaled
    evaled=$(PATH="$stub:$PATH" run_with_timeout 30 bash -c '
        cd "$2" || exit 92
        eval "$(bash "$1")" || exit 0
        printf "%s" "${OWNER_REPO:-}"
    ' _ "$PRE_FLIGHT" "$dir" 2>/dev/null)
    assert_eq "pre-flight/eval-shape-preserved" "origin-owner/origin-repo" "$evaled"

    # Non-GitHub origin -> exit 1, no OWNER_REPO on stdout.
    dir="$(mk_repo "pf-gitlab" "https://gitlab.com/owner/repo.git")"
    out=$(PATH="$stub:$PATH" run_with_timeout 30 bash -c '
        cd "$2" || exit 92
        bash "$1"
    ' _ "$PRE_FLIGHT" "$dir" 2>/dev/null)
    rc=$?
    assert_eq "pre-flight/non-github-exit1" "1|" "$rc|$out"

    # No origin remote -> exit 1 and NO OWNER_REPO. Today pre-flight treats the
    # rc=2 "unknown" branch as proceed and prints the gh (upstream) answer.
    dir="$(mk_repo "pf-noorigin" "__NONE__")"
    out=$(PATH="$stub:$PATH" run_with_timeout 30 bash -c '
        cd "$2" || exit 92
        bash "$1"
    ' _ "$PRE_FLIGHT" "$dir" 2>/dev/null)
    rc=$?
    assert_eq "pre-flight/no-origin-exit1" "1|" "$rc|$out"
}

# ===========================================================================
# Group F — resolve-project.sh::resolve_project_for_repo queries the ORIGIN repo
#
#   board-card.sh is only the first hop: resolve_project_for_repo takes the
#   owner/repo it hands back and interpolates it into `gh api graphql -F owner=
#   -F repo=`, which is what actually decides WHICH repository's Projects v2
#   board the session reads and writes. Group D pins the hop; this group pins
#   the destination, so an upstream-flavoured identity re-entering anywhere
#   between the two is caught at the API boundary where the damage happens.
#
#   Same fixture shape as Group D (origin and upstream point at different
#   owner/repo pairs, and the `gh` stub answers `gh repo view` with the UPSTREAM
#   identity). The stub additionally records every `-F owner=` / `-F repo=` pair
#   it is handed, plus any `gh repo view` invocation, so both the value used and
#   the route taken to it are assertable.
# ===========================================================================
mk_gh_recording_stub() {
    local bindir="$TMP/stubbin-gql"
    mkdir -p "$bindir"
    cat >"$bindir/gh" <<'STUB'
#!/bin/bash
# Records what it was asked, then answers just enough for resolve-project.sh to
# reach (and only reach) the owner/repo-bearing GraphQL calls.
ARGS="$*"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
    printf 'repo-view\n' >> "${GH_REPO_VIEW_LOG:-/dev/null}"
    # Deliberately WRONG answer: pretends the API resolved the upstream repo.
    echo "upstream-owner/upstream-repo"
    exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
    gql_owner=""
    gql_repo=""
    while [ $# -gt 0 ]; do
        case "$1" in
            owner=*) gql_owner="${1#owner=}" ;;
            repo=*)  gql_repo="${1#repo=}" ;;
        esac
        shift
    done
    if [ -n "$gql_owner" ] || [ -n "$gql_repo" ]; then
        printf '%s/%s\n' "$gql_owner" "$gql_repo" >> "${GH_GRAPHQL_ARGS_LOG:-/dev/null}"
    fi
    case "$ARGS" in
        *"| length"*)
            # One linked project -> resolve-project.sh proceeds to the
            # first-node query, which carries owner/repo a second time.
            echo "1"
            exit 0
            ;;
    esac
    # Empty first-node payload ends the resolve early (rc 1). The later
    # project-id-only queries never carry owner/repo, so stopping here keeps the
    # stub small without losing anything this group asserts.
    exit 0
fi
exit 0
STUB
    chmod +x "$bindir/gh"
    printf '%s' "$bindir"
}

group_resolve_project() {
    local dir stub gql_log view_log recorded rc
    stub="$(mk_gh_recording_stub)"
    gql_log="$TMP/gql-args.log"
    view_log="$TMP/repo-view.log"
    : >"$gql_log"
    : >"$view_log"

    dir="$(mk_repo "rp" "https://github.com/origin-owner/origin-repo.git")"
    git -C "$dir" remote add upstream "https://github.com/upstream-owner/upstream-repo.git"

    PATH="$stub:$PATH" GH_GRAPHQL_ARGS_LOG="$gql_log" GH_REPO_VIEW_LOG="$view_log" \
        run_with_timeout 30 bash -c '
        set -u
        cd "$2" || exit 92
        unset BOARD_CARD_REPO_OVERRIDE
        unset _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM
        unset _ISSUE_CREATE_INTERNAL_PROJECT_ID
        . "$1"
        resolve_project_for_repo
    ' _ "$RESOLVE_PROJECT_LIB" "$dir" >/dev/null 2>&1
    rc=$?

    # Every recorded pair collapses to one line when they all name origin; an
    # upstream-flavoured call would show up as a second line and fail the compare.
    recorded="$(sort -u "$gql_log" 2>/dev/null)"
    assert_eq "resolve-project/graphql-targets-origin" "origin-owner/origin-repo" "$recorded"

    # Guard against a vacuous pass: the assertion above is only meaningful if the
    # owner/repo-bearing calls actually happened.
    if [ "$(wc -l <"$gql_log")" -ge 1 ]; then
        pass "resolve-project/graphql-owner-repo-was-passed"
    else
        fail "resolve-project/graphql-owner-repo-was-passed — no -F owner=/-F repo= call recorded (rc=$rc)"
    fi

    # Route, not just value: identity must never be sourced from the API.
    if [ ! -s "$view_log" ]; then
        pass "resolve-project/never-calls-gh-repo-view"
    else
        fail "resolve-project/never-calls-gh-repo-view — $(wc -l <"$view_log") invocation(s)"
    fi

    # No origin at all -> fails closed, and NO graphql call is made with the
    # upstream identity the stub would happily have supplied.
    : >"$gql_log"
    dir="$(mk_repo "rp-noorigin" "__NONE__")"
    PATH="$stub:$PATH" GH_GRAPHQL_ARGS_LOG="$gql_log" GH_REPO_VIEW_LOG="$view_log" \
        run_with_timeout 30 bash -c '
        set -u
        cd "$2" || exit 92
        unset BOARD_CARD_REPO_OVERRIDE
        unset _ISSUE_CREATE_INTERNAL_OWNER _ISSUE_CREATE_INTERNAL_PROJECT_NUM
        unset _ISSUE_CREATE_INTERNAL_PROJECT_ID
        . "$1"
        resolve_project_for_repo
    ' _ "$RESOLVE_PROJECT_LIB" "$dir" >/dev/null 2>&1
    rc=$?
    if [ "$rc" -ne 0 ] && [ ! -s "$gql_log" ]; then
        pass "resolve-project/no-origin-fails-closed"
    else
        fail "resolve-project/no-origin-fails-closed — rc=$rc recorded=$(printf '%q' "$(cat "$gql_log")")"
    fi
}

# ===========================================================================
# Group D2 — board-card.sh::resolve_item_id addresses the ORIGIN repository
#
#   Group D pins the first hop (resolve_owner_repo). This group pins the
#   DESTINATION inside the same file: resolve_item_id takes that owner/repo,
#   splits it, and hands the halves to `gh api graphql -F owner= -F repo=`. That
#   call decides WHICH repository's Projects v2 card the caller reads and later
#   edits, so an upstream-flavoured identity re-entering between the split and
#   the call is the #1899 defect at the point where it does damage.
#
#   It is also the CWD-isolation half of the coverage: tests/feature-ensure-board-card.sh
#   drives the board-card path with an inline `gh` mock but from the AMBIENT
#   checkout, so its owner/repo comes from whatever repository the suite happens
#   to run in. Every case here runs with cwd pinned to a purpose-built fixture
#   carrying origin and upstream that point at DIFFERENT repositories, so the
#   assertion cannot be satisfied by the developer's own remote.
# ===========================================================================
mk_gh_gql_recorder() {
    local bindir="$TMP/stubbin-bc-gql"
    mkdir -p "$bindir"
    cat >"$bindir/gh" <<'STUB'
#!/bin/bash
ARGS="$*"
if [ "${1:-}" = "repo" ] && [ "${2:-}" = "view" ]; then
    printf 'repo-view\n' >> "${GH_REPO_VIEW_LOG:-/dev/null}"
    # Deliberately WRONG answer: pretends the API resolved the upstream repo.
    echo "upstream-owner/upstream-repo"
    exit 0
fi
if [ "${1:-}" = "api" ] && [ "${2:-}" = "graphql" ]; then
    gql_owner=""
    gql_repo=""
    while [ $# -gt 0 ]; do
        case "$1" in
            owner=*) gql_owner="${1#owner=}" ;;
            repo=*)  gql_repo="${1#repo=}" ;;
        esac
        shift
    done
    printf '%s/%s\n' "$gql_owner" "$gql_repo" >> "${GH_GRAPHQL_ARGS_LOG:-/dev/null}"
    echo "PVTI_stub_item"
    exit 0
fi
exit 0
STUB
    chmod +x "$bindir/gh"
    printf '%s' "$bindir"
}

group_board_card_item_id() {
    local dir stub gql_log view_log out rc
    stub="$(mk_gh_gql_recorder)"
    gql_log="$TMP/bc-gql-args.log"
    view_log="$TMP/bc-repo-view.log"
    : >"$gql_log"; : >"$view_log"

    dir="$(mk_repo "bc-item" "https://github.com/origin-owner/origin-repo.git")"
    git -C "$dir" remote add upstream "https://github.com/upstream-owner/upstream-repo.git"

    out=$(PATH="$stub:$PATH" GH_GRAPHQL_ARGS_LOG="$gql_log" GH_REPO_VIEW_LOG="$view_log" \
        run_with_timeout 20 bash -c '
        set -u
        cd "$2" || exit 92
        unset BOARD_CARD_REPO_OVERRIDE
        PROJECT_ID="PVT_stub_project"
        . "$1"
        resolve_item_id 42
    ' _ "$BOARD_CARD_LIB" "$dir" 2>/dev/null)
    rc=$?

    assert_eq "board-card/item-id-graphql-targets-origin" "origin-owner/origin-repo" \
        "$(sort -u "$gql_log" 2>/dev/null)"
    assert_eq "board-card/item-id-returns-stub-item" "0|PVTI_stub_item" "$rc|$out"
    # Route, not just value: identity must never be sourced from the API.
    if [ ! -s "$view_log" ]; then
        pass "board-card/item-id-never-calls-gh-repo-view"
    else
        fail "board-card/item-id-never-calls-gh-repo-view — $(wc -l <"$view_log") invocation(s)"
    fi

    # No origin -> resolve_item_id must fail closed BEFORE any graphql call. The
    # stub would gladly have answered with an item id for the upstream repo.
    : >"$gql_log"
    dir="$(mk_repo "bc-item-noorigin" "__NONE__")"
    git -C "$dir" remote add upstream "https://github.com/upstream-owner/upstream-repo.git"
    out=$(PATH="$stub:$PATH" GH_GRAPHQL_ARGS_LOG="$gql_log" GH_REPO_VIEW_LOG="$view_log" \
        run_with_timeout 20 bash -c '
        set -u
        cd "$2" || exit 92
        unset BOARD_CARD_REPO_OVERRIDE
        PROJECT_ID="PVT_stub_project"
        . "$1"
        resolve_item_id 42
    ' _ "$BOARD_CARD_LIB" "$dir" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ] && [ ! -s "$gql_log" ]; then
        pass "board-card/item-id-no-origin-makes-no-graphql-call"
    else
        fail "board-card/item-id-no-origin-makes-no-graphql-call — rc=$rc out=$(printf '%q' "$out") recorded=$(printf '%q' "$(cat "$gql_log")")"
    fi
}

# ===========================================================================
# Group E2 — pre-flight.sh: the remaining rejection paths, and the guarantee
#   that a rejection never reaches an API call.
#
#   Group E covers origin-vs-upstream, non-GitHub origin and missing origin. The
#   two arms left uncovered are the ones a caller is most likely to hit by
#   accident and least likely to notice: a github.com origin whose PATH is
#   malformed (rc 3 from the resolver), and a run from a directory that is not a
#   git checkout at all. Both must produce exit 1, EMPTY stdout — the caller runs
#   `eval "$(bash pre-flight.sh)"`, so any stray stdout line becomes shell input —
#   and a diagnostic on stderr.
#
#   The recording `gh` stub is the downstream-action assertion the direct-subprocess
#   test owes: /issue-close-finalize's later steps are all `gh` calls, and this
#   script is the gate in front of them. Zero invocations on every rejection path
#   is the observable form of "the close/comment action was never reached".
# ===========================================================================
group_pre_flight_rejections() {
    local dir stub log out rc err
    stub="$(mk_gh_gql_recorder)"
    log="$TMP/pf-repo-view.log"
    : >"$log"

    # run_pf <dir> — sets PF_OUT / PF_ERR / PF_RC.
    run_pf() {
        local d="$1" errf="$TMP/pf-stderr.log"
        : >"$errf"
        PF_OUT=$(PATH="$stub:$PATH" GH_REPO_VIEW_LOG="$log" GH_GRAPHQL_ARGS_LOG="$log" \
            run_with_timeout 30 bash -c '
            cd "$2" || exit 92
            bash "$1"
        ' _ "$PRE_FLIGHT" "$d" 2>"$errf")
        PF_RC=$?
        PF_ERR="$(cat "$errf")"
    }

    # github.com origin, malformed path -> resolver rc 3 -> pre-flight exit 1.
    dir="$(mk_repo "pf-malformed" "https://github.com/onlyowner")"
    run_pf "$dir"
    assert_eq "pre-flight/malformed-origin-exit1" "1|" "$PF_RC|$PF_OUT"
    if [ -n "$PF_ERR" ]; then
        pass "pre-flight/malformed-origin-diagnostic-on-stderr"
    else
        fail "pre-flight/malformed-origin-diagnostic-on-stderr — stderr was empty"
    fi

    # Dot-segment origin: the traversal shape. Same verdict, and specifically NOT
    # a rc 0 that would hand `../x` to every downstream `gh api repos/<o>/<r>`.
    dir="$(mk_repo "pf-traversal" "https://github.com/../x.git")"
    run_pf "$dir"
    assert_eq "pre-flight/dot-segment-origin-exit1" "1|" "$PF_RC|$PF_OUT"

    # Not a git checkout at all.
    dir="$TMP/pf-not-a-repo"
    rm -rf "$dir"; mkdir -p "$dir"
    run_pf "$dir"
    assert_eq "pre-flight/non-git-directory-exit1" "1|" "$PF_RC|$PF_OUT"

    # No rejection path may have started a `gh` process.
    if [ ! -s "$log" ]; then
        pass "pre-flight/rejections-invoke-no-gh"
    else
        fail "pre-flight/rejections-invoke-no-gh — $(wc -l <"$log") invocation(s)"
    fi

    # Required-env contract: AGENTS_CONFIG_DIR is how the script finds the
    # resolver library. Unset, it must abort loudly rather than source nothing and
    # fall through to an empty OWNER_REPO.
    dir="$(mk_repo "pf-noacd" "https://github.com/origin-owner/origin-repo.git")"
    out=$(PATH="$stub:$PATH" run_with_timeout 30 env -u AGENTS_CONFIG_DIR bash -c '
        cd "$2" || exit 92
        bash "$1"
    ' _ "$PRE_FLIGHT" "$dir" 2>/dev/null)
    rc=$?
    if [ "$rc" -ne 0 ] && [ -z "$out" ]; then
        pass "pre-flight/unset-agents-config-dir-aborts"
    else
        fail "pre-flight/unset-agents-config-dir-aborts — rc=$rc out=$(printf '%q' "$out")"
    fi

    # Positive control for the two "no gh call" assertions above: the stub does
    # record when something calls it.
    PATH="$stub:$PATH" GH_REPO_VIEW_LOG="$log" gh repo view >/dev/null 2>&1 || true
    if [ -s "$log" ]; then
        pass "pre-flight/gh-recorder-is-wired-up"
    else
        fail "pre-flight/gh-recorder-is-wired-up — stub recorded nothing even when called directly"
    fi
}

group_board_card
group_board_card_item_id
group_pre_flight
group_pre_flight_rejections
group_resolve_project

finish
