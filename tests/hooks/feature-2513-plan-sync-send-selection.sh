#!/usr/bin/env bash
# tests/hooks/feature-2513-plan-sync-send-selection.sh
# Tests: hooks/lib/plan-sync.js, hooks/show-plan-link.js
# Tags: plan-sync, plans, git, lib, hook, TL2, scope:issue-specific, project-host, send-selection, provision, progress-file
# #2513: which plans leave the machine. A plan is sent only when the host of the project it
# was written for (recorded by the hook) is the host of the plan destination.
set -uo pipefail

# TL3 gap (what this test does NOT catch):
# - a real push/auth round trip to GitHub or GitLab (the ssh stub answers for every host)
# - a project origin resolved through the developer's own global git config
# - the hook as Claude Code delivers it (the hook input is built by hand here)
# Closest-to-action mitigation: WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=../lib/harness.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
# shellcheck source=../lib/plan-sync-fixture.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-fixture.sh"

psf_setup || { fail "setup" "psf_setup failed"; exit 1; }
# psf_setup pins both dirs inside a function; the top-level re-export is the pin the
# isolation gate (bin/check-plans-dir-isolation.sh) sees, inherited by the sourced groups.
export WORKFLOW_STATE_DIR="$WORKFLOW_STATE_DIR" WORKFLOW_PLANS_DIR="$WORKFLOW_PLANS_DIR"
psf_tag_unimplemented_fails
trap psf_cleanup EXIT

# expect_eq <name> <got> <want> — reports "not implemented" for a missing module.
expect_eq() {
  case "$2" in
    NOT_IMPLEMENTED:*) fail "$1" "not implemented (${2})"; return ;;
  esac
  if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "want=$(printf '%q' "$3") got=$(printf '%q' "$2")"; fi
}

if psf_git_version_ok; then pass "git-version>=2.32"; else fail "git-version>=2.32" "$(git version)"; fi

# The real gh / glab (network) never answer a visibility question here.
psf_drop_cli_from_path gh
psf_drop_cli_from_path glab

SEL_DIR="$SCRIPT_CHECKOUT_ROOT/tests/hooks/feature-2513-plan-sync-send-selection"
case_begin "project-host-record" "hooks/show-plan-link.js"
. "$SEL_DIR/project-host-record.sh"
case_end
# #2594: session-progress.md is synced like a plan but never marked or announced as one.
case_begin "progress-file-sync" "hooks/show-plan-link.js"
. "$SEL_DIR/progress-sync.sh"
case_end

# shellcheck source=../lib/plan-sync-flow.sh
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/plan-sync-flow.sh"
case_begin "send-selection-sync" "hooks/lib/plan-sync.js"
. "$SEL_DIR/sync.sh"
case_end
case_begin "send-selection-provision" "hooks/lib/plan-sync.js"
. "$SEL_DIR/provision.sh"
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed"
[ "$FAIL" -eq 0 ]
