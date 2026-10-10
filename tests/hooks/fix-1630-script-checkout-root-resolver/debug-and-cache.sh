# tests/hooks/fix-1630-script-checkout-root-resolver/debug-and-cache.sh
# Tests: hooks/lib/script-checkout-root.js
# Tags: hook, agents-main-root, resolver, debug, cache, security, scope:issue-specific
# Sourced by tests/hooks/fix-1630-script-checkout-root-resolver.sh.
# C10 — two contracts the T4c unit rows do not reach:
#   DEBUG-* : under AGENTS_HOOK_DEBUG=1 a resolution emits ONE stderr line naming
#             only the adopted `source` — never a directory value, neither the
#             ignored AGENTS_MAIN_ROOT one (leak) nor the resolved root (root_leak).
#   CACHE-* : _resetCacheForTest() must invalidate BOTH a successful and a null
#             memoized answer, or later cases in a process share a stale null.

run_debug_and_cache_cases() {
    # A stale path whose final segment is a secret-shaped canary. It carries no
    # marker and must never be echoed.
    local secret="s3cr3t-canary-do-not-print"
    local stale_raw="$TMPDIR_BASE/stale-with-$secret"
    mkdir -p "$stale_raw"
    local stale; stale="$(norm "$stale_raw")"

    # A marker-valid dir (2-point markers: hooks/enforce-worktree.js + bin) with
    # its own canary segment: it would validate if it were ever enumerated.
    local valid_secret="v4lid-canary-do-not-print"
    local valid_raw="$TMPDIR_BASE/valid-with-$valid_secret"
    mkdir -p "$valid_raw/hooks" "$valid_raw/bin"
    : > "$valid_raw/hooks/enforce-worktree.js"
    local valid; valid="$(norm "$valid_raw")"

    local quiet="lines=1,leak=false,root_leak=false,source=module"

    # ── DEBUG-* ─────────────────────────────────────────────────────────────
    expect_eq "DEBUG-1 a stale AGENTS_MAIN_ROOT is ignored and only the adopted source is named" \
        "$(probe_env AGENTS_HOOK_DEBUG=1 "AGENTS_MAIN_ROOT=$stale" -- debugline "$secret")" "$quiet"

    expect_eq "DEBUG-2 no debug flag emits nothing at all" \
        "$(probe_env "AGENTS_MAIN_ROOT=$stale" -- debugline "$secret")" \
        "lines=0,leak=false,root_leak=false,source=none"

    expect_eq "DEBUG-3 a marker-valid AGENTS_MAIN_ROOT is not adopted and not echoed" \
        "$(probe_env AGENTS_HOOK_DEBUG=1 "AGENTS_MAIN_ROOT=$valid" -- debugline "$valid_secret")" "$quiet"

    expect_eq "DEBUG-4 a missing AGENTS_MAIN_ROOT names only the adopted source" \
        "$(probe_env AGENTS_HOOK_DEBUG=1 -u AGENTS_MAIN_ROOT -- debugline "$secret")" "$quiet"

    expect_eq "DEBUG-5 only the exact flag value 1 turns the line on" \
        "$(probe_env AGENTS_HOOK_DEBUG=true -u AGENTS_MAIN_ROOT -- debugline "$secret")" \
        "lines=0,leak=false,root_leak=false,source=none"

    # Without this row root_leak=false above could be a check that never fires.
    expect_eq "DEBUG-ctrl the root_leak check answers true for a line that carries the root" \
        "$(probe_env -u AGENTS_MAIN_ROOT -- debugline-selfcheck "$secret")" \
        "lines=1,leak=false,root_leak=true,source=module"

    # ── CACHE-* ─────────────────────────────────────────────────────────────
    expect_eq "CACHE-1 successful resolution is memoized and recomputed after reset" \
        "$(probe_env "AGENTS_MAIN_ROOT=$valid" -- recompute "$SCRIPT_CHECKOUT_ROOT_NODE")" \
        "first_is_a1=true,cached_same=true,after_null=true"

    expect_eq "CACHE-2 a null resolution is memoized and recomputed after reset" \
        "$(probe_env "AGENTS_MAIN_ROOT=$stale" -- recompute-null)" \
        "first=null,cached=null,after_null=false"
}
