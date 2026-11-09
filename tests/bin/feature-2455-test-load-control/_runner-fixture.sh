#!/usr/bin/env bash
# tests/bin/feature-2455-test-load-control/_runner-fixture.sh — the run-all runner fixture
# shared by run-all-lease-cases.sh, run-all-grant-cases.sh and auto-config-runner-cases.sh.
# Reuses the feature-1832 run-all fixture (a copied runner outside the live tree).
# fx_init is deliberately NOT called: it installs its own EXIT trap and would
# replace the entry's; the two fixture roots are pinned by hand instead.

# shellcheck source=../../tests/feature-1832-run-all-parallel/_lib.sh
. "$AGENTS_ROOT/tests/tests/feature-1832-run-all-parallel/_lib.sh"
FX_TMP_ROOT="$TMPDIR_BASE/fx"
FX_CACHE_DIR="$FX_TMP_ROOT/run-all-cache"
fx_drop_ambient_controls
# fx_drop_ambient_controls also dropped the entry's resolver pin; restore it so
# neither the runner nor run_ft ever reads the developer's real .env.
export RUN_ALL_CONFIG_VAR_CMD="$NO_CONFIG_VAR_CMD"
# fx_init would export this too: the copied runner reads the live tree's registry through it.
export RUN_ALL_REGISTRY_LIB="$FX_REPO_ROOT/bin/lib/test-language-registry.sh"
mkdir -p "$FX_CACHE_DIR"
# The copied runner sees the fixture's 1024 logical CPUs, so the CPU ceiling never fires by accident.
FX_PATH_PREFIX="$CPU_SHIM_DIR"
R_LANE_VARS="TEST_LANES TEST_MAX_JOBS_PER_HOST TEST_MAX_JOBS_PER_RUN TEST_LANES_HELD TEST_LANES_TTL TEST_LANES_HEARTBEAT TEST_LANES_WAIT_INTERVAL TEST_LANES_WAIT_CAP AUTO_CONFIG_TEST_MAX_JOBS"
# r_lanes_line — the runner's `lanes:` progress line, prefix stripped (empty if none).
r_lanes_line() { sed -n 's/^\[run-all\] lanes: //p' "$R_ERR" | head -n 1; }

# r_reset — drop every lane control and empty the shared slots/, load/ and runs/ between cases.
# Controls are plain (unexported) shell vars: fx_control_args forwards them to
# the runner explicitly and nothing else inherits them.
r_reset() {
    # shellcheck disable=SC2086
    unset $R_LANE_VARS FX_WITH_LANES
    rm -rf "$FX_CACHE_DIR/slots" "$FX_CACHE_DIR/load" "$FX_CACHE_DIR/runs"
}

# r_root <n-peak-dummies> [dummy-opts] — echoes a fixture root with lanes.
r_root() {
    local n="$1" root i; shift
    root="$(FX_WITH_LANES="${FX_WITH_LANES:-1}" fx_new_root)"
    for ((i = 1; i <= n; i++)); do fx_add_dummy "$root" "p$i" "$@"; done
    echo "$root"
}
R_OUT="$FX_TMP_ROOT/r.out"
R_ERR="$FX_TMP_ROOT/r.err"
r_has_lanes_line() { grep -q '^\[run-all\] lanes: ' "$R_ERR"; }
# r_no_leftover <label> — neither a held lane nor a reclaim grave remains.
r_no_leftover() {
    assert_eq "$1: no lane left" "" "$(lane_names "$FX_CACHE_DIR")"
    assert_eq "$1: no .grave.* left" "0" "$(grave_count "$FX_CACHE_DIR")"
}

# r_wait_file <secs> <path> / r_wait_gone <secs> <pid> — fx_wait_file / fx_wait_gone with
# 0.2 s polls instead of 1 s ones: the same <secs> upper bound, an earlier exit.
r_wait_file() {
    local i=0 n=$(( ${1:?} * 5 ))
    while [[ ! -e "${2:?}" ]]; do
        (( i >= n )) && return 1
        sleep 0.2; i=$((i + 1))
    done
    return 0
}
r_wait_gone() {
    local i=0 n=$(( ${1:?} * 5 ))
    while kill -0 "${2:?}" 2>/dev/null; do
        (( i >= n )) && return 1
        sleep 0.2; i=$((i + 1))
    done
    return 0
}

grp_done _runner-fixture.sh
