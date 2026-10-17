# shellcheck shell=bash
# Tests: bin/lib/run-all-report.sh
# Tags: tests, run-all, fixture, scope:issue-specific
# tests/tests/feature-2501-run-all-report/_fx.sh — fixture roots for the #2501 report members.
# Sourced by the members (the dispatcher skips _*.sh). Builds on the #1832 fx_* helpers
# (sourced, never edited) and adds the launcher, report and registry set beside run-all.

# shellcheck source=../feature-1832-run-all-parallel/_lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/../feature-1832-run-all-parallel/_lib.sh"
# shellcheck source=../../lib/test-language-registry-fixture.sh
. "$FX_REPO_ROOT/tests/lib/test-language-registry-fixture.sh"

RR_LIBS="run-all-launch.sh run-all-report.sh run-all-classify.sh run-all-hits.sh timed-exec.sh test-language-registry-plain.sh"

# rr_require_report — the report lib is the unit under test; its absence is a FAIL, not a skip.
rr_require_report() {
    [ -f "$FX_REPO_ROOT/bin/lib/run-all-report.sh" ] ||
        fx_fail "bin/lib/run-all-report.sh is not present — the #2501 report layer is not implemented"
    return 0
}

# rr_new_root — fx_new_root plus the registry set, the launcher libs and the language wrappers,
# so <root>/bin/run-all.sh resolves every lib from <root> exactly as the repo runner does.
rr_new_root() {
    local root lib
    root="$(fx_new_root)" || return 1
    install_test_language_registry "$root" "$FX_REPO_ROOT" >/dev/null || return 1
    cp "$FX_REPO_ROOT/bin/run-with-timeout.sh" "$root/bin/run-with-timeout.sh" || return 1
    for lib in $RR_LIBS; do
        [ -f "$FX_REPO_ROOT/bin/lib/$lib" ] && cp "$FX_REPO_ROOT/bin/lib/$lib" "$root/bin/lib/$lib"
    done
    [ -d "$FX_REPO_ROOT/bin/lib/test-wrappers" ] && cp -R "$FX_REPO_ROOT/bin/lib/test-wrappers" "$root/bin/lib/"
    [ -d "$FX_REPO_ROOT/hooks/lib/test-language-registry" ] &&
        cp -R "$FX_REPO_ROOT/hooks/lib/test-language-registry" "$root/hooks/lib/"
    echo "$root"
}

# rr_exec <root> <timeout> <out> <err> [args] — fx_exec with the root's own registry loader.
rr_exec() {
    local root="$1"
    RUN_ALL_REGISTRY_LIB="$root/bin/lib/test-language-registry.sh" fx_exec "$@"
}

# rr_add_raw <root> <id> <line>... — a bash test whose body is the given lines, after a header.
rr_add_raw() {
    local root="$1" id="$2" f; shift 2
    f="$root/tests/bin/$id.sh"
    {
        printf '#!/usr/bin/env bash\n# Tests: tests/run-all.sh\n# Tags: fixture, scope:issue-specific\n'
        printf '%s\n' "$@"
    } >"$f"
    chmod +x "$f" 2>/dev/null || true
}

# rr_add_harness <root> <id> — body from stdin (a heredoc in the member), run after sourcing
# the worktree harness so case records land in the runner's result dir.
rr_add_harness() {
    local root="$1" id="$2" body
    body="$(cat)"
    rr_add_raw "$root" "$id" "$(printf '. %q/tests/lib/harness.sh' "$FX_REPO_ROOT")" "$body"
}

# rr_line_no <file> <ERE> — first matching line number, empty when none.
rr_line_no() { grep -nE -- "$2" "$1" 2>/dev/null | head -n 1 | cut -d: -f1; }

# rr_contract_rest <file> — everything after the line-initial "RUN_CONTRACT: " (first such line).
rr_contract_rest() { sed -n 's/^RUN_CONTRACT: //p' "$1" 2>/dev/null | head -n 1; }
