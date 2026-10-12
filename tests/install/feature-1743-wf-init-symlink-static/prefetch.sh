# shellcheck shell=bash
# Sourced by tests/install/feature-1743-wf-init-symlink-static.sh inside a case span.
# --- P1/P2: the real installer runs the pytest pre-fetch after the repo-visibility launcher ---
# Reads PREFETCH_FILE (set by the caller to SH_FILE or PS_FILE) and PREFETCH_WARN (the detector).

_pf_name="${PREFETCH_FILE##*/}"
if [ -n "$(_prefetch_line "$PREFETCH_FILE")" ]; then
    pass "P1: $_pf_name runs uv run --no-project --with pytest python -c 'import pytest'"
else
    fail "P1: $_pf_name has no executable pytest pre-fetch (uv run --no-project --with pytest python -c ... import pytest)"
fi

if _prefetch_after_launcher "$PREFETCH_FILE"; then
    pass "P2: $_pf_name pre-fetches pytest after the repo-visibility launcher generation"
else
    fail "P2: $_pf_name pre-fetch is missing or precedes the repo-visibility launcher (prefetch=$(_prefetch_line "$PREFETCH_FILE") launcher=$(_visibility_launcher_line "$PREFETCH_FILE"))"
fi

if "$PREFETCH_WARN" "$PREFETCH_FILE"; then
    pass "P3: $_pf_name treats a failed pre-fetch as a warning and carries on"
else
    fail "P3: $_pf_name pre-fetch failure is not warning-only (missing, unguarded under set -e / unchecked \$LASTEXITCODE, no warning, or exits/throws)"
fi
