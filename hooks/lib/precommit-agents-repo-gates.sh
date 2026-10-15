#!/bin/bash
# Sourced by hooks/pre-commit. Runs the agents-repo-only commit gates: the
# on-demand rules-injection notation gate (#2270 companion), the session-id SSOT
# gate (#2270), the migration-blocks gate (#1987), the plans-dir artifact-name
# gate (#2434), the plans-dir isolation gate (#2512) and the root-names gate
# (#2561). All are skipped unless the repo under commit IS the agents repo.

# _precommit_agents_repo_gates — reads $_cfg_dir (ambient). Exits the hook with 1
# on a violation or a gate outage; returns 0 otherwise. No-op in a non-agents repo.
_precommit_agents_repo_gates() {
    local _od_repo_top _od_cfg_dir _od_is_agents_repo _od_agents_common _od_repo_common
    local _od_agents_abs _od_repo_abs _od_f _mb_f _od_staged _mb_staged

    _od_repo_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_od_repo_top" ] || return 0
    _od_cfg_dir="$_cfg_dir"
    _od_is_agents_repo=0
    # -u GIT_DIR/GIT_WORK_TREE/GIT_PREFIX: git invokes this hook with those set for the
    # repo being committed to, and an inherited GIT_DIR silently overrides -C's target
    # directory for repo discovery -- without the unset, both calls below resolve to the
    # committing repo regardless of $_od_cfg_dir, producing a false agents-repo match for
    # every repo.
    _od_agents_common="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX git -C "$_od_cfg_dir" rev-parse --git-common-dir 2>/dev/null || true)"
    _od_repo_common="$(env -u GIT_DIR -u GIT_WORK_TREE -u GIT_PREFIX git -C "$_od_repo_top" rev-parse --git-common-dir 2>/dev/null || true)"
    if [ -n "$_od_agents_common" ] && [ -n "$_od_repo_common" ]; then
        _od_agents_abs="$(cd "$_od_cfg_dir" 2>/dev/null && cd "$_od_agents_common" 2>/dev/null && pwd -P || printf '%s' "$_od_agents_common")"
        _od_repo_abs="$(cd "$_od_repo_top" 2>/dev/null && cd "$_od_repo_common" 2>/dev/null && pwd -P || printf '%s' "$_od_repo_common")"
        # msys answers pwd -P in the spelling it was entered by (a Temp dir as /tmp or a drive-letter path).
        if command -v cygpath >/dev/null 2>&1; then
            _od_agents_abs="$(cygpath -m "$_od_agents_abs" 2>/dev/null || printf '%s' "$_od_agents_abs")"
            _od_repo_abs="$(cygpath -m "$_od_repo_abs" 2>/dev/null || printf '%s' "$_od_repo_abs")"
        fi
        [ "$_od_agents_abs" = "$_od_repo_abs" ] && _od_is_agents_repo=1
    fi

    [ "$_od_is_agents_repo" = "1" ] || return 0

    # on-demand rules-injection notation gate (#2270 companion). Own agents-repo
    # guard; exit map + rationale: docs/architecture/claude-code/rules-injection.md.

    # NUL-delimited: without -z git applies quotePath to a name containing a
    # newline or a non-ASCII byte, and the filename identity is destroyed before
    # the checker ever sees it. mapfile -d '' keeps one name = one array element.
    _od_staged=()
    while IFS= read -r -d '' _od_f; do
        case "$_od_f" in
            rules/*.md|hooks/lib/rules-injection-policy.js) _od_staged+=("$_od_f") ;;
        esac
    done < <(git diff --cached --name-only -z 2>/dev/null || true)

    # The checker runs on every agents-repo commit, not only when a rules file is
    # staged: the notation contract is a property of the whole tree (a policy-only
    # edit can break a rule it never touched, and some filenames git cannot even
    # stage on this platform). The staged list is still passed so out-of-root paths
    # are surfaced; an empty list is a valid invocation.
    _precommit_run_agents_gate "$_od_repo_top" "$_od_cfg_dir/bin/check-on-demand-rules.sh" exec \
        "on-demand rules-injection notation violations" docs/architecture/claude-code/rules-injection.md \
        --staged ${_od_staged[@]+"${_od_staged[@]}"}

    # ---------- session-id SSOT gate (issue #2270) ----------
    # rc 2 is a caller contract breach (bad flag, rotted allowlist), not an outage,
    # so a rename cannot silently disarm the gate.
    # The path tables are read from the cwd tree (bin/check-session-id-ssot/path-tables.txt).
    _precommit_run_agents_gate "$_od_repo_top" "$_od_cfg_dir/bin/check-session-id-ssot.sh" bash \
        "session-id env reads bypassing the SSOT resolver" docs/architecture/claude-code/session-id-resolution.md \
        --staged

    # ---------- migration-blocks gate (issue #1987) ----------
    # _mb_staged: all staged files (excluding rules/*.md and tests/)
    # no extension filter — extensionless files and .ps1 etc. are also included
    _mb_staged=()
    while IFS= read -r -d '' _mb_f; do
        case "$_mb_f" in
            rules/*.md) ;;   # excluded: docs only
            tests/*)    ;;   # excluded: test files
            *)          _mb_staged+=("$_mb_f") ;;
        esac
    done < <(git diff --cached --name-only -z 2>/dev/null || true)

    # Blocking on axis-1/2 violations (rc 1 AND rc 2); warnings pass through (rc 0).
    _precommit_run_agents_gate "$_od_repo_top" "$_od_cfg_dir/bin/check-migration-blocks.sh" exec \
        "migration block format violations" "" \
        --staged ${_mb_staged[@]+"${_mb_staged[@]}"}

    # ---------- plans-dir artifact-name gate (issue #2434) ----------
    # Whole-tree scan: a name assembled under the plans dir must be a registered artifact.
    # The kind and exception tables are read from the cwd tree (hooks/lib/plans-artifact-registry.json).
    _precommit_run_agents_gate "$_od_repo_top" "$_od_cfg_dir/bin/check-plans-artifacts" node \
        "plans-dir names that are not registered artifacts" docs/architecture/claude-code/state-dirs.md \
        --source

    # ---------- plans-dir isolation gate (issue #2512) ----------
    # Staged residual old-name token; the tests/ pin scan runs only when a tests/*.sh is staged.
    _precommit_run_agents_gate "$_od_repo_top" "$_od_cfg_dir/bin/check-plans-dir-isolation.sh" bash \
        "test fixture isolation violations" rules/test/fixture-isolation.md \
        --staged

    # ---------- root-names gate (issue #2561) ----------
    # Staged files of the cwd repo; the retired-name list and the table are read from its index.
    _precommit_run_agents_gate "$_od_repo_top" "$_od_cfg_dir/bin/check-root-names.sh" bash \
        "root-name violations" docs/architecture/claude-code/root-names.md \
        --staged
}

# _precommit_run_agents_gate <repo-top> <checker> <exec|bash|node> <what> <doc|""> [args...]
# Runs one checker from <repo-top>. rc 0 passes; every other outcome exits the hook with 1:
# rc 1|2 is a violation, while a missing checker, a missing interpreter or any other rc is
# an outage the gate cannot vouch for, so it fails closed (#2589). Emergency bypass:
# `git commit --no-verify`.
_precommit_run_agents_gate() {
    local _g_top="$1" _g_checker="$2" _g_runner="$3" _g_what="$4" _g_doc="$5" _g_name _g_rc=0 _g_out
    shift 5
    _g_name="${_g_checker##*/}"
    if [ ! -f "$_g_checker" ] || { [ "$_g_runner" = exec ] && [ ! -x "$_g_checker" ]; } \
        || { [ "$_g_runner" != exec ] && ! command -v "$_g_runner" >/dev/null 2>&1; }; then
        echo "pre-commit: $_g_name missing or not runnable (${_g_runner}) at $_g_checker." >&2
        echo "Commit blocked: the agents-repo gate fails closed. Emergency bypass: git commit --no-verify" >&2
        exit 1
    fi
    if [ "$_g_runner" = exec ]; then
        _g_out="$(cd "$_g_top" && "$_g_checker" "$@" 2>&1)" || _g_rc=$?
    else
        _g_out="$(cd "$_g_top" && "$_g_runner" "$_g_checker" "$@" 2>&1)" || _g_rc=$?
    fi
    case "$_g_rc" in
        0) return 0 ;;
        1|2)
            printf '%s\n' "$_g_out"
            echo ""
            echo "Commit blocked: $_g_what (checker rc=$_g_rc)."
            [ -z "$_g_doc" ] || echo "See $_g_doc."
            ;;
        *)
            printf '%s\n' "$_g_out" >&2
            echo "pre-commit: $_g_name rc=$_g_rc is not a verdict (0 clean, 1 or 2 violation)." >&2
            echo "Commit blocked: the agents-repo gate fails closed. Emergency bypass: git commit --no-verify" >&2
            ;;
    esac
    exit 1
}
