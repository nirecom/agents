#!/usr/bin/env bash
# Tests: tests/lib/command-guard.sh, tests/lib/command-guard-build.js
# Tags: scope:issue-specific, tl2, command-guard, fixture-isolation
#
# The command guard (#2590): gh / glab / codex exit 97 with a hit, git reads pass through, and
# git writes pass only inside the run root. Fixtures and setup: feature-2590-command-guard/setup.sh.

# TL3 gap: PowerShell (PATHEXT) and the npm-shim codex are not exercised; bash, Node and cmd are.
# TL3 gap: Ctrl-C / timeout-kill propagation through the Windows launcher needs a console.
# TL3 gap: a Windows host without csc.exe (build must fail closed) cannot be simulated safely.

set -uo pipefail
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
source "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"

TMP_ROOT="$(make_tmp)"
readonly TMP_ROOT
trap 'rm -rf "$TMP_ROOT"' EXIT
harness_isolate "$TMP_ROOT/state"
unset CLAUDE_CODE_SESSION_ID

PARTS="$SCRIPT_DIR/feature-2590-command-guard"
. "$PARTS/setup.sh"
. "$PARTS/sentinel-cases.sh"
. "$PARTS/git-cases.sh"
. "$PARTS/misc-cases.sh"

cg_setup || { echo "FAIL: fixture setup"; exit 1; }

case_begin "sentinels-stop-every-route" "tests/lib/command-guard.sh"
cg_case_sentinels_every_route
case_end

case_begin "bin-holds-one-launcher-per-cli" "tests/lib/command-guard-build.js"
cg_case_bin_layout
case_end

case_begin "stripped-env-still-hits" "tests/lib/command-guard.sh"
cg_case_env_stripped
case_end

case_begin "own-stub-wins" "tests/lib/command-guard.sh"
cg_case_own_stub_wins
case_end

case_begin "own-glab-and-codex-stubs-win-on-every-route" "tests/lib/command-guard.sh"
cg_case_own_stub_wins_every_cli
case_end

case_begin "git-reads-pass-through" "tests/lib/command-guard.sh"
cg_case_reads_pass
case_end

case_begin "writes-inside-the-run-root-pass" "tests/lib/command-guard.sh"
cg_case_inside_writes_pass
case_end

case_begin "redirected-writes-are-rejected" "tests/lib/command-guard.sh"
cg_case_redirected_writes_rejected
case_end

case_begin "chained-dash-c-leaving-the-run-root-is-rejected" "tests/lib/command-guard.sh"
cg_case_chained_dash_c_rejected
case_end

case_begin "link-in-the-run-root-to-an-outside-repo-is-rejected" "tests/lib/command-guard.sh"
cg_case_symlink_out_rejected
case_end

case_begin "repo-creation-and-config-outside-are-rejected" "tests/lib/command-guard.sh"
cg_case_repo_creation_and_config_rejected
case_end

case_begin "push-and-network-are-rejected" "tests/lib/command-guard.sh"
cg_case_push_and_network_rejected
case_end

case_begin "rejects-hold-from-node-and-stripped-env" "tests/lib/command-guard.sh"
cg_case_rejects_hold_on_every_route
case_end

case_begin "aliases-count-as-writes" "tests/lib/command-guard.sh"
cg_case_alias_counts_as_write
case_end

case_begin "hit-records-and-helpers" "tests/lib/command-guard.sh"
cg_case_hit_records
case_end

case_begin "instance-config" "tests/lib/command-guard-build.js"
cg_case_instance_config
case_end

case_begin "cache-under-the-host-temp-area" "tests/lib/command-guard-build.js"
cg_case_cache_location
case_end

case_begin "path-prepend-and-preset-dir" "tests/lib/command-guard.sh"
cg_case_path_handling
case_end

case_begin "use-real-takes-the-guard-off-path" "tests/lib/command-guard.sh"
cg_case_use_real
case_end

case_begin "use-real-callers-are-tl3-or-tl4" "tests/lib/command-guard.sh"
cg_case_use_real_callers
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[[ "$FAIL" -eq 0 ]]
