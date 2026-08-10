#!/bin/bash
# tests/fix-1899-parse-remote-url/module-contract.sh
# Tests: hooks/lib/parse-remote-url.js, hooks/lib/is-private-repo.js
# Tags: parse-remote-url, origin-resolution, purity, backward-compat, TL1, scope:issue-specific
#
# Groups D and E of the fix-1899-parse-remote-url split suite — the module-level
# contract rather than a parse verdict: parse-remote-url.js must stay PURE (no
# process, no disk), and is-private-repo.js must keep exporting the two names it
# always exported, answering identically to the new module.
#
# TL3 gap: purity is checked lexically, not by sandboxing the module at runtime.
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.

set -u

# shellcheck source=_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/_lib.sh"

# ===========================================================================
# Group D — purity: parse-remote-url.js must not touch the process or the disk
# ===========================================================================
group_purity() {
    if [ ! -f "$AGENTS_DIR/hooks/lib/parse-remote-url.js" ]; then
        fail "purity/module-present — hooks/lib/parse-remote-url.js missing"
        return
    fi
    local pat label
    for pat in 'child_process' 'require\("fs"\)' "require\\('fs'\\)" 'execSync' 'spawnSync'; do
        label="${pat//[^A-Za-z_]/}"
        if grep -qE "$pat" "$AGENTS_DIR/hooks/lib/parse-remote-url.js"; then
            fail "purity/absent-$label — parse-remote-url.js references $pat"
        else
            pass "purity/absent-$label"
        fi
    done
}

# ===========================================================================
# Group E — backward compat: is-private-repo.js keeps both export names
#           (GREEN today, must STAY green after the move to a re-export)
# ===========================================================================
group_backward_compat() {
    assert_eq "compat/is-private-repo.extractHost" "github.com" \
        "$(call_fn "$IPR_JS" extractHost 'git@github.com:owner/repo.git')"
    assert_eq "compat/is-private-repo.extractRepoId" "owner/repo" \
        "$(call_fn "$IPR_JS" extractRepoId 'https://github.com/owner/repo.git')"
    # Post-fix the two names must ALSO be reachable from the new module, and both
    # copies must agree — a divergent duplicate is the failure this pins.
    assert_eq "compat/same-answer-extractHost" \
        "$(call_fn "$IPR_JS" extractHost 'https://github.com/owner/repo.git')" \
        "$(call_fn "$PRU_JS" extractHost 'https://github.com/owner/repo.git')"
}

group_purity
group_backward_compat

finish
