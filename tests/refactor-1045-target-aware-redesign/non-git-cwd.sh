#!/bin/bash
# R-19: non-git CWD → universal rule abstains cleanly, well-formed JSON, no crash
# Per detail.md Step 3 guard-1: if repoRoot === null (CWD is not in any git
# repo), the universal rule MUST abstain cleanly. A naive impl that calls
# isPathOutsideRepo(target, null) without the guard would throw, the hook
# would crash, and stdout would lack the "decision" key.
# This is a smoke test on hook integrity for the null-repoRoot path —
# whatever decision the hook ultimately returns (allow or block), it must
# return a well-formed JSON decision, not crash.

# ============================================================================
# R-19: non-git CWD → universal rule abstains (no crash on null repoRoot)
# ============================================================================
test_r19_no_repo_root_no_crash() {
    require_impl "R-19" || return
    local nongit; nongit="$(mktemp -d)"
    if command -v cygpath >/dev/null 2>&1; then nongit="$(cygpath -m "$nongit")"; fi
    local out
    out="$(run_bash_guard "echo x > /tmp/foo-r19-$$" "$nongit" ENFORCE_WORKTREE=on)"
    if printf '%s' "$out" | grep -q '"decision"'; then
        pass "R-19: non-git CWD: universal rule abstains cleanly (well-formed decision, no crash)"
    else
        fail "R-19: non-git CWD: hook crashed or returned malformed output ($out)"
    fi
    rm -rf "$nongit" 2>/dev/null || true
}

test_r19_no_repo_root_no_crash
