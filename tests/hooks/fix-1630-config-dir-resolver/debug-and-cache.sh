# tests/fix-1630-config-dir-resolver/debug-and-cache.sh
# Tests: hooks/lib/agents-config-dir.js
# Tags: hook, config-dir, resolver, debug, cache, security, scope:issue-specific
#
# STATUS: RED until C4 lands — every row reports
# `ERROR: require agents-config-dir.js: Cannot find module ...`.
# Sourced by tests/fix-1630-config-dir-resolver.sh.
#
# C10 — two contracts the T4c unit rows do not reach:
#
#   DEBUG-* : the fall-through diagnostic. When a candidate is rejected the
#             resolver emits ONE stderr line under AGENTS_HOOK_DEBUG=1 naming
#             only the adopted `source`. The stale env value is a secret-shaped
#             canary here, so the row fails if the resolver ever prints the
#             value it rejected: a hook that echoes AGENTS_CONFIG_DIR into a
#             transcript leaks a filesystem layout (and, in the field, whatever
#             a mis-set env var happened to contain).
#   CACHE-* : _resetCacheForTest() must invalidate BOTH a successful and a null
#             memoized answer. A reset that only clears the success path leaves
#             every later test in a process sharing a stale null.

run_debug_and_cache_cases() {
    # A stale path whose final segment is a secret-shaped canary. It carries no
    # marker, so the env candidate must be rejected and never echoed.
    local secret="s3cr3t-canary-do-not-print"
    local stale_raw="$TMPDIR_BASE/stale-with-$secret"
    mkdir -p "$stale_raw"
    local stale; stale="$(norm "$stale_raw")"

    # Two marker-valid config dirs (2-point markers: hooks/enforce-worktree.js + bin).
    local v1_raw="$TMPDIR_BASE/valid-acd-1" v2_raw="$TMPDIR_BASE/valid-acd-2"
    mkdir -p "$v1_raw/hooks" "$v1_raw/bin" "$v2_raw/hooks" "$v2_raw/bin"
    : > "$v1_raw/hooks/enforce-worktree.js"
    : > "$v2_raw/hooks/enforce-worktree.js"
    local v1 v2; v1="$(norm "$v1_raw")"; v2="$(norm "$v2_raw")"

    # ── DEBUG-* ─────────────────────────────────────────────────────────────
    assert_eq "DEBUG-1 stale env falls through and names only the adopted source" \
        "$(AGENTS_HOOK_DEBUG=1 AGENTS_CONFIG_DIR="$stale" probe debugline "$secret")" \
        "lines=1,leak=false,source=module"

    assert_eq "DEBUG-2 no debug flag emits nothing at all" \
        "$(AGENTS_CONFIG_DIR="$stale" probe debugline "$secret")" \
        "lines=0,leak=false,source=none"

    assert_eq "DEBUG-3 a valid env candidate is adopted without a fall-through line" \
        "$(AGENTS_HOOK_DEBUG=1 AGENTS_CONFIG_DIR="$AGENTS_DIR_NODE" probe debugline "$secret")" \
        "lines=0,leak=false,source=none"

    assert_eq "DEBUG-4 a missing env var falls through and names only the adopted source" \
        "$(AGENTS_HOOK_DEBUG=1 env -u AGENTS_CONFIG_DIR node "$PROBE_JS" debugline "$secret" 2>/dev/null)" \
        "lines=1,leak=false,source=module"

    # ── CACHE-* ─────────────────────────────────────────────────────────────
    assert_eq "CACHE-1 successful resolution is memoized and recomputed after reset" \
        "$(probe recompute "$v1" "$v2")" \
        "first_is_a1=true,cached_same=true,after_is_a2=true"

    assert_eq "CACHE-2 a null resolution is memoized and recomputed after reset" \
        "$(AGENTS_CONFIG_DIR="$stale" probe recompute-null)" \
        "first=null,cached=null,after_null=false"
}
