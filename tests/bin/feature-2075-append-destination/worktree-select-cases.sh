#!/usr/bin/env bash
# Tests: skills/review-tests/scripts/select-staged-files.sh, bin/resolve-worktree-path
# Tags: scope:issue-specific
# Part of tests/feature-2075-append-destination.sh (rules/coding/file-split.md).
# Cases W1-W2 (TL2): the --added-only filter on the RESOLVED-WORKTREE output path.
# S10 exercises only the NOSTATE CWD fallback, so the `git -C "$WORKTREE"` call
# site — the one RT-1a actually reaches in a real session — is untested there.
# Fixture shape follows tests/fix-882-resolve-worktree-path.sh: real linked
# worktree + a workflow state file whose cwd points at it.

# shellcheck source=../../lib/harness.sh
if ! declare -f case_begin >/dev/null 2>&1; then
  AGENTS_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../../.." && pwd)"
  source "$AGENTS_ROOT/tests/lib/harness.sh"
fi

case_begin "worktree-select-series" "skills/review-tests/scripts/select-staged-files.sh"

if ! command -v node >/dev/null 2>&1; then
    for _wid in W1 W2; do
        case_ran "$_wid"
        skip "$_wid node is unavailable — the worktree resolver cannot run"
    done
else
    W_BASE="$TMPDIR_BASE/wtsel"
    W_MAIN="$W_BASE/main"
    W_LINKED="$W_BASE/linked"
    W_WF="$W_BASE/workflow"
    W_PLANS="$W_BASE/plans"
    W_TRANSCRIPTS="$W_BASE/transcripts"
    W_SID="feature-2075-wtsel-sid"
    mkdir -p "$W_MAIN" "$W_WF" "$W_PLANS" "$W_TRANSCRIPTS"

    if command -v cygpath >/dev/null 2>&1; then
        w_node() { cygpath -m "$1"; }
    else
        w_node() { printf '%s' "$1"; }
    fi

    git -C "$W_MAIN" init -q
    git -C "$W_MAIN" config core.hooksPath /dev/null
    git -C "$W_MAIN" config core.autocrlf false
    git -C "$W_MAIN" config user.email "t@example.com"
    git -C "$W_MAIN" config user.name "t"
    printf 'init\n' > "$W_MAIN/README.md"
    git -C "$W_MAIN" add -A >/dev/null 2>&1
    git -C "$W_MAIN" commit -q --no-verify -m init >/dev/null 2>&1
    git -C "$W_MAIN" worktree add -q -b "f2075-wtsel" "$W_LINKED" >/dev/null 2>&1

    # The linked worktree carries one ADDED and one MODIFIED staged path.
    mkdir -p "$W_LINKED/tests"
    printf 'one\n' > "$W_LINKED/tests/tracked.sh"
    git -C "$W_LINKED" add -A >/dev/null 2>&1
    git -C "$W_LINKED" commit -q --no-verify -m base >/dev/null 2>&1
    printf 'two\n' >> "$W_LINKED/tests/tracked.sh"
    printf 'new\n' > "$W_LINKED/tests/added.sh"
    git -C "$W_LINKED" add -A >/dev/null 2>&1

    # A differently-named staged path in the MAIN worktree: if it ever shows up,
    # the filter was applied to the wrong repository.
    printf 'main\n' > "$W_MAIN/tests-main-decoy.sh"
    git -C "$W_MAIN" add -A >/dev/null 2>&1

    printf '{\n  "version": 1,\n  "session_id": "%s",\n  "created_at": "2026-09-12T00:00:00.000Z",\n  "cwd": "%s",\n  "git_branch": "f2075-wtsel",\n  "steps": {}\n}\n' \
        "$W_SID" "$(w_node "$W_LINKED")" > "$W_WF/$W_SID.json"

    WSEL_OUT=""
    WSEL_RC=0
    run_wselect() {
        local outf errf
        outf="$(mktemp)"; errf="$(mktemp)"
        (
            cd "$W_BASE" || exit 1
            SESSION_ID="" \
            CLAUDE_SESSION_ID="" \
            CLAUDE_CODE_SESSION_ID="$W_SID" \
            CLAUDE_ENV_FILE="" \
            CLAUDE_TRANSCRIPT_BASE_DIR="$(w_node "$W_TRANSCRIPTS")" \
            CLAUDE_WORKFLOW_DIR="$(w_node "$W_WF")" \
            WORKFLOW_PLANS_DIR="$(w_node "$W_PLANS")" \
            AGENTS_CONFIG_DIR="$(w_node "$AGENTS_ROOT")" \
                bash "$RUN_TIMEOUT" 60 bash "$SELECT_SH" "$@"
        ) >"$outf" 2>"$errf"
        WSEL_RC=$?
        WSEL_OUT="$(LC_ALL=C sort < "$outf" | tr '\n' ' ' | sed 's/ *$//')"
        rm -f "$outf" "$errf"
    }

    # ── W1 default output path: the resolved worktree, unfiltered ───────────
    case_ran W1
    run_wselect
    assert_eq "W1 default exit code on the resolved-worktree path" "0" "$WSEL_RC"
    assert_eq "W1 default lists the added and the modified path of the LINKED worktree" \
        "tests/added.sh tests/tracked.sh" "$WSEL_OUT"

    # ── W2 the same path with --added-only ─────────────────────────────────
    case_ran W2
    run_wselect --added-only
    assert_eq "W2 --added-only exit code on the resolved-worktree path" "0" "$WSEL_RC"
    assert_eq "W2 --added-only drops the modified path" "tests/added.sh" "$WSEL_OUT"
    case " $WSEL_OUT " in
        *" tests-main-decoy.sh "*)
            fail "W2 the main worktree's staged file leaked in — the filter ran against the wrong repo" ;;
        *)
            pass "W2 the main worktree's staged file never appears" ;;
    esac

    git -C "$W_MAIN" worktree remove --force "$W_LINKED" >/dev/null 2>&1 || true
fi

case_end

case_begin "worktree-resolve-path-coverage" "bin/resolve-worktree-path"
if [[ -f "$AGENTS_ROOT/bin/resolve-worktree-path" ]]; then
    pass "P0-ext bin/resolve-worktree-path exists (used by this test suite)"
else
    fail "P0-ext bin/resolve-worktree-path missing"
fi
case_end

grp_done "worktree-select-cases.sh"
