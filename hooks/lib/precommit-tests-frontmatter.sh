#!/bin/bash
# Sourced by hooks/pre-commit. Validates staged test entrypoints (*.sh / *.Tests.ps1 /
# test_*.py) under tests/<category>/ and rejects newly-added flat ones (#1834, #2392),
# printing a CAUSE-SPECIFIC block message. check-test-frontmatter.sh returns exit 1 for
# every failure, so the cause is read from its stderr codes: FLAT_TEST_SH_REJECTED /
# FLAT_TEST_REJECTED = wrong location; the MISSING_*/INVALID_* codes = frontmatter shape.
# Both may fire in one run.

# _precommit_check_tests_frontmatter — reads $_cfg_dir (ambient, as load-env.sh does).
# rc 0 = ok / nothing staged; rc 1 = block the commit.
_precommit_check_tests_frontmatter() {
    local -a _staged_tests=()
    local f _out _rc=0
    while IFS= read -r -d '' f; do
        [ -z "$f" ] && continue
        case "$f" in
            tests/_archive/*) continue ;;
            tests/lib/*) continue ;;
            tests/run-all.sh) continue ;;  # infra runner — no frontmatter, not a test entrypoint
            tests/hooks/*/*.sh|tests/bin/*/*.sh|tests/skills/*/*.sh|tests/agents/*/*.sh|tests/install/*/*.sh|tests/tests/*/*.sh) continue ;;  # suite sub-files — not entrypoints
            tests/hooks/*.sh|tests/bin/*.sh|tests/skills/*.sh|tests/agents/*.sh|tests/install/*.sh|tests/tests/*.sh) _staged_tests+=("$f") ;;
            tests/hooks/*/*.Tests.ps1|tests/bin/*/*.Tests.ps1|tests/skills/*/*.Tests.ps1|tests/agents/*/*.Tests.ps1|tests/install/*/*.Tests.ps1|tests/tests/*/*.Tests.ps1|tests/*/*/test_*.py) continue ;;
            tests/hooks/*.Tests.ps1|tests/bin/*.Tests.ps1|tests/skills/*.Tests.ps1|tests/agents/*.Tests.ps1|tests/install/*.Tests.ps1|tests/tests/*.Tests.ps1|tests/hooks/test_*.py|tests/bin/test_*.py|tests/skills/test_*.py|tests/agents/test_*.py|tests/install/test_*.py|tests/tests/test_*.py) _staged_tests+=("$f") ;;
            tests/*.sh) _staged_tests+=("$f") ;;  # flat tests/<name>.sh — forward so the checker rejects newly-added ones (#1834)
            tests/*.Tests.ps1|tests/test_*.py) _staged_tests+=("$f") ;;  # flat — forwarded for FLAT_TEST_REJECTED (#2392)
            *) continue ;;
        esac
    done < <(git diff --cached --name-only -z -- 'tests/' 2>/dev/null || true)

    [ "${#_staged_tests[@]}" -eq 0 ] && return 0

    # Capture stderr so the cause can be classified; the checker prints only
    # diagnostics (no stdout), so 2>&1 collects the per-file CODE: lines.
    # _cfg_dir is the ambient contract var set by the sourcing hooks/pre-commit.
    # shellcheck disable=SC2154
    _out="$("$_cfg_dir/bin/check-test-frontmatter.sh" --staged "${_staged_tests[@]}" 2>&1)" || _rc=$?
    [ "$_rc" -eq 0 ] && return 0

    # Re-display the checker's per-file diagnostics (file + reason).
    [ -n "$_out" ] && printf '%s\n' "$_out"
    echo ""

    # Cause-specific summaries, keyed on the checker's stderr codes (both may fire).
    if printf '%s\n' "$_out" | grep -qE 'FLAT_TEST_SH_REJECTED|FLAT_TEST_REJECTED'; then
        echo "Commit blocked: new test entrypoint placed directly under tests/."
        echo "A test entrypoint (.sh / .Tests.ps1 / test_*.py) must live under tests/<category>/ (categories: hooks bin skills agents install tests)."
        echo "Move it into the matching category dir, e.g. tests/hooks/<name>.sh."
    fi
    if printf '%s\n' "$_out" | grep -qE 'MISSING_TESTS_HEADER|INVALID_TESTS_TOKEN|MISSING_SCOPE_TAG|MISSING_HARNESS_SOURCE'; then
        echo "Commit blocked: staged test file(s) fail frontmatter validation."
        echo "Each file must have '# Tests: <path>' (comma-separated tokens) and '# Tags: ... scope:...'."
    fi
    return 1
}
