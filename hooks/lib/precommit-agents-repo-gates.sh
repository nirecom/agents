#!/bin/bash
# Sourced by hooks/pre-commit. Runs the agents-repo-only commit gates: the
# on-demand rules-injection notation gate (#2270 companion), the session-id SSOT
# gate (#2270), the migration-blocks gate (#1987), the plans-dir artifact-name
# gate (#2434) and the plans-dir isolation gate (#2512). All are skipped unless
# the repo under commit IS the agents repo.

# _precommit_agents_repo_gates — reads $_cfg_dir (ambient). Exits the hook with 1
# on a violation; returns 0 otherwise. No-op in a non-agents repo.
_precommit_agents_repo_gates() {
    local _od_repo_top _od_cfg_dir _od_is_agents_repo _od_agents_common _od_repo_common
    local _od_agents_abs _od_repo_abs _od_f _od_checker _od_rc _od_out
    local _si_checker _si_rc _si_out _mb_f _mb_checker _mb_rc _mb_out
    local _od_staged _mb_staged _pa_checker _pa_rc _pa_out _pi_checker _pi_rc _pi_out

    _od_repo_top="$(git rev-parse --show-toplevel 2>/dev/null || true)"
    [ -n "$_od_repo_top" ] || return 0
    _od_cfg_dir="${AGENTS_CONFIG_DIR:-$_cfg_dir}"
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
        # msys answers pwd -P in the spelling it was entered by (a Temp dir as /tmp or /c/...).
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
    _od_checker="$_od_cfg_dir/bin/check-on-demand-rules.sh"
    if [ ! -x "$_od_checker" ]; then
        echo "pre-commit: check-on-demand-rules.sh missing or not executable at $_od_checker — on-demand rules notation gate skipped" >&2
    else
        _od_rc=0
        _od_out="$("$_od_checker" --staged ${_od_staged[@]+"${_od_staged[@]}"} 2>&1)" || _od_rc=$?
        case "$_od_rc" in
            0) : ;;
            1|2)
                printf '%s\n' "$_od_out"
                echo ""
                echo "Commit blocked: on-demand rules-injection notation violations (checker rc=$_od_rc)."
                echo "See docs/architecture/claude-code/rules-injection.md."
                exit 1
                ;;
            *)
                echo "pre-commit: check-on-demand-rules.sh rc=$_od_rc — on-demand rules notation gate skipped" >&2
                ;;
        esac
    fi

    # ---------- session-id SSOT gate (issue #2270) ----------
    # rc 2 is a caller contract breach (bad flag, rotted allowlist), not an outage,
    # so a rename cannot silently disarm the gate. Real outages (missing/unrunnable
    # checker, unexpected rc) leave the commit alone with a diagnostic.
    _si_checker="$_od_cfg_dir/bin/check-session-id-ssot.sh"
    if [ ! -x "$_si_checker" ]; then
        echo "pre-commit: check-session-id-ssot.sh missing or not executable at $_si_checker — session-id SSOT gate skipped" >&2
    else
        _si_rc=0
        _si_out="$(bash "$_si_checker" --staged 2>&1)" || _si_rc=$?
        case "$_si_rc" in
            0) : ;;
            1|2)
                printf '%s\n' "$_si_out"
                echo ""
                echo "Commit blocked: session-id env reads bypassing the SSOT resolver (checker rc=$_si_rc)."
                echo "See docs/architecture/claude-code/session-id-resolution.md."
                exit 1
                ;;
            *)
                echo "pre-commit: check-session-id-ssot.sh rc=$_si_rc — session-id SSOT gate skipped" >&2
                ;;
        esac
    fi

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
    # Real outages (missing/unrunnable checker, unexpected rc) leave the commit alone.
    _mb_checker="$_od_cfg_dir/bin/check-migration-blocks.sh"
    if [ ! -x "$_mb_checker" ]; then
        echo "pre-commit: check-migration-blocks.sh missing or not executable at $_mb_checker — migration blocks gate skipped" >&2
    else
        _mb_rc=0
        _mb_out="$("$_mb_checker" --staged ${_mb_staged[@]+"${_mb_staged[@]}"} 2>&1)" || _mb_rc=$?
        case "$_mb_rc" in
            0) : ;;
            1|2)
                printf '%s\n' "$_mb_out"
                echo ""
                echo "Commit blocked: migration block format violations (checker rc=$_mb_rc)."
                exit 1
                ;;
            *)
                echo "pre-commit: check-migration-blocks.sh rc=$_mb_rc — migration blocks gate skipped" >&2
                ;;
        esac
    fi

    # ---------- plans-dir artifact-name gate (issue #2434) ----------
    # Whole-tree scan: a name assembled under the plans dir must be a registered artifact.
    _pa_checker="$_od_cfg_dir/bin/check-plans-artifacts"
    if [ ! -f "$_pa_checker" ] || ! command -v node >/dev/null 2>&1; then
        echo "pre-commit: check-plans-artifacts or node missing at $_pa_checker — plans-dir artifact gate skipped" >&2
    else
        _pa_rc=0
        _pa_out="$(cd "$_od_repo_top" && node "$_od_cfg_dir"/bin/check-plans-artifacts --source 2>&1)" || _pa_rc=$?
        case "$_pa_rc" in
            0) : ;;
            1|2)
                printf '%s\n' "$_pa_out"
                echo ""
                echo "Commit blocked: plans-dir names that are not registered artifacts (checker rc=$_pa_rc)."
                echo "See docs/architecture/claude-code/state-dirs.md."
                exit 1
                ;;
            *)
                echo "pre-commit: check-plans-artifacts rc=$_pa_rc — plans-dir artifact gate skipped" >&2
                ;;
        esac
    fi

    # ---------- plans-dir isolation gate (issue #2512) ----------
    # Staged residual old-name token; the tests/ pin scan runs only when a tests/*.sh is staged.
    _pi_checker="$_od_cfg_dir/bin/check-plans-dir-isolation.sh"
    if [ ! -f "$_pi_checker" ]; then
        echo "pre-commit: check-plans-dir-isolation.sh missing at $_pi_checker — plans-dir isolation gate skipped" >&2
    else
        _pi_rc=0
        _pi_out="$(cd "$_od_repo_top" && bash "$_pi_checker" --staged 2>&1)" || _pi_rc=$?
        case "$_pi_rc" in
            0) : ;;
            1|2)
                printf '%s\n' "$_pi_out"
                echo ""
                echo "Commit blocked: test fixture isolation violations (checker rc=$_pi_rc)."
                echo "See rules/test/fixture-isolation.md."
                exit 1
                ;;
            *)
                echo "pre-commit: check-plans-dir-isolation.sh rc=$_pi_rc — plans-dir isolation gate skipped" >&2
                ;;
        esac
    fi
}
