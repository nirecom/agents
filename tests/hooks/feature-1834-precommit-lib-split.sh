#!/usr/bin/env bash
# tests/hooks/feature-1834-precommit-lib-split.sh
# Tests: hooks/pre-commit, hooks/lib/precommit-tests-frontmatter.sh, hooks/lib/precommit-agents-repo-gates.sh, bin/check-test-frontmatter.sh
# Tags: pre-commit, tests-frontmatter, cause-messages, refactor, file-split, TL2, scope:issue-specific, agents-repo-gates, session-id-ssot, migration-blocks, security, word-splitting, error-path, fail-open
set -u

# Protects the #1834 file split of hooks/pre-commit (two gate blocks moved to hooks/lib/).
# Part A: cause-specific block messages of _precommit_check_tests_frontmatter (A1-A5).
# Part B: hook wiring (B1) + the split's size reason (B2).
# Part C: _precommit_agents_repo_gates (session-id/migration gates C1) + frontmatter
# security/codes (C2/C3). This dispatcher owns shared harness+module sourcing and ALL
# fixture helpers/globals; per-part cases live in feature-1834-precommit-lib-split/*.sh.
AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
# shellcheck source=tests/lib/harness.sh
. "$AGENTS_DIR/tests/lib/harness.sh"

# Layer: TL2 (real checker + real git fixtures + the real module, not the claude -p host).
# TL3 gap (what this test does NOT catch):
# - Whether git invokes hooks/pre-commit via core.hooksPath on this host (the function is
#   called directly here); exercised by tests/hooks/cc-pre-commit-on-demand-rules.sh.
# Closest-to-action mitigation: checked at WORKFLOW_USER_VERIFIED preflight via
# bin/check-verification-gate.sh category: hook-registration.
PRECOMMIT="$AGENTS_DIR/hooks/pre-commit"
LIB_FM="$AGENTS_DIR/hooks/lib/precommit-tests-frontmatter.sh"

# Tier 1: implementation-missing guard, ahead of any fixture work.
MISSING=0
[ -f "$PRECOMMIT" ] || { echo "FAIL: IMPLEMENTATION MISSING: $PRECOMMIT"; MISSING=1; }
[ -f "$LIB_FM" ]    || { echo "FAIL: IMPLEMENTATION MISSING: $LIB_FM"; MISSING=1; }
if [ "$MISSING" -eq 1 ]; then
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — #1834 file split)"
    exit 1
fi

# _cfg_dir is the ambient contract var the extracted function reads. Point it at the REAL
# worktree so the function invokes the real bin/check-test-frontmatter.sh.
_cfg_dir="$AGENTS_DIR"
# shellcheck source=hooks/lib/precommit-tests-frontmatter.sh
. "$LIB_FM"

if ! declare -f _precommit_check_tests_frontmatter >/dev/null 2>&1; then
    echo "FAIL: IMPLEMENTATION MISSING: $LIB_FM lacks _precommit_check_tests_frontmatter"
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — #1834 file split)"
    exit 1
fi

# Part C also drives the second extracted module. _cfg_dir (above) is the ambient
# fallback; each Part C case overrides it via AGENTS_CONFIG_DIR to point the gates
# at a fixture repo. The module only defines a function, so sourcing is side-effect-free.
LIB_AR="$AGENTS_DIR/hooks/lib/precommit-agents-repo-gates.sh"
[ -f "$LIB_AR" ] || { echo "FAIL: IMPLEMENTATION MISSING: $LIB_AR"; echo ""; echo "Results: 0 passed, 1 failed (target not yet implemented — #1834 file split)"; exit 1; }
# shellcheck source=hooks/lib/precommit-agents-repo-gates.sh
. "$LIB_AR"
if ! declare -f _precommit_agents_repo_gates >/dev/null 2>&1; then
    echo "FAIL: IMPLEMENTATION MISSING: $LIB_AR lacks _precommit_agents_repo_gates"
    echo ""
    echo "Results: 0 passed, 1 failed (target not yet implemented — #1834 file split)"
    exit 1
fi

# split-modules-wired — structural proof of the #1834 split. The tier-1 guards above
# abort on absence; this case additionally asserts the WIRING: that hooks/pre-commit
# actually sources both extracted lib basenames — something nothing else here checks.
# It also re-affirms both lib files exist and both functions are defined, so the case
# is a single honest assertion of the split outcome behind the 4-path # Tests: header.
case_begin "split-modules-wired" "hooks/pre-commit"
_wire_fail=""
[ -f "$LIB_FM" ] || _wire_fail="$_wire_fail missing-file:$LIB_FM"
[ -f "$LIB_AR" ] || _wire_fail="$_wire_fail missing-file:$LIB_AR"
declare -f _precommit_check_tests_frontmatter >/dev/null 2>&1 || _wire_fail="$_wire_fail undefined:_precommit_check_tests_frontmatter"
declare -f _precommit_agents_repo_gates >/dev/null 2>&1 || _wire_fail="$_wire_fail undefined:_precommit_agents_repo_gates"
grep -qF 'precommit-tests-frontmatter.sh' "$PRECOMMIT" || _wire_fail="$_wire_fail unwired:precommit-tests-frontmatter.sh"
grep -qF 'precommit-agents-repo-gates.sh' "$PRECOMMIT" || _wire_fail="$_wire_fail unwired:precommit-agents-repo-gates.sh"
if [ -n "$_wire_fail" ]; then
    fail "split-modules-wired" "#1834 split incomplete —$_wire_fail"
else
    pass "split-modules-wired: both lib modules exist, both functions are defined, and hooks/pre-commit sources both lib files"
fi
case_end

TMPBASE="$(make_tmp)"
trap 'rm -rf "$TMPBASE"' EXIT

# init_fixture <dir> — throwaway git repo with HEAD (so git cat-file -e HEAD:<rel>
# distinguishes new files) and hooks disabled.
init_fixture() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add README.md >/dev/null 2>&1
    git -C "$dir" commit -q -m initial >/dev/null 2>&1
}

OUT=""; RC=0
# run_fm_check <repo> — invoke the function with the fixture as CWD, so its git diff and
# the checker's git show :<rel> resolve the fixture repo.
run_fm_check() {
    local repo="$1"
    OUT="$( ( cd "$repo" && _precommit_check_tests_frontmatter ) 2>&1 )"
    RC=$?
}

# flat_new.sh carries VALID frontmatter so its ONLY defect is the flat location;
# broken.sh omits every header so its ONLY defect is frontmatter shape.
write_valid_flat() {
    local repo="$1"
    mkdir -p "$repo/tests"
    # shellcheck disable=SC2016  # $AGENTS_DIR must be written literally into the fixture.
    printf '%s\n' '#!/usr/bin/env bash' \
        '# tests/flat_new.sh' \
        '# Tests: hooks/pre-commit' \
        '# Tags: scope:common' \
        '. "$AGENTS_DIR/tests/lib/harness.sh"' > "$repo/tests/flat_new.sh"
    git -C "$repo" add --chmod=+x -- tests/flat_new.sh >/dev/null 2>&1
}
write_broken_categorized() {
    local repo="$1"
    mkdir -p "$repo/tests/hooks"
    printf '%s\n' '#!/usr/bin/env bash' \
        '# broken.sh — no # Tests: header, no # Tags: line' > "$repo/tests/hooks/broken.sh"
    git -C "$repo" add --chmod=+x -- tests/hooks/broken.sh >/dev/null 2>&1
}
write_good_categorized() {
    local repo="$1"
    mkdir -p "$repo/tests/hooks"
    printf '%s\n' '#!/usr/bin/env bash' \
        '# good.sh' \
        '# Tests: hooks/pre-commit' \
        '# Tags: scope:common' > "$repo/tests/hooks/good.sh"
    git -C "$repo" add --chmod=+x -- tests/hooks/good.sh >/dev/null 2>&1
}

# write_staged_nofm <repo> <relpath> — stage a HEADERLESS file at an arbitrary tests/ path.
# Headerless means it WOULD fail frontmatter validation if the checker inspected it; staging
# it at an excluded path and getting rc 0 with no output proves the path is filtered BEFORE
# the checker runs (the exclusion is a true gate no-op, not a lenient checker pass).
write_staged_nofm() {
    local repo="$1" rel="$2"
    mkdir -p "$repo/$(dirname "$rel")"
    printf '%s\n' '#!/usr/bin/env bash' '# no frontmatter — would fail if this path were inspected' > "$repo/$rel"
    git -C "$repo" add --chmod=+x -- "$rel" >/dev/null 2>&1
}

LOC_MSG='must live under tests/<category>/'
FM_MSG='fail frontmatter validation'

# Part C shared fixtures. mk_agents_fixture wires a repo so _od_cfg_dir == repo-top (the
# agents-repo match the gates guard on). The on-demand checker is a pass-through stub
# (covered by cc-pre-commit-on-demand-rules.sh); the session-id/migration checkers are
# shims onto the REAL bin/*.sh, so C1a-C1e exercise real gates. Per fixture-isolation.md
# the fixtures disable git hooks and set an identity.
init_repo_bare() {
    local dir="$1"
    mkdir -p "$dir"
    git -C "$dir" init -q -b main
    git -C "$dir" config user.email "test@example.com"
    git -C "$dir" config user.name "Test"
    git -C "$dir" config core.hooksPath /dev/null
    git -C "$dir" config core.autocrlf false
}
# shellcheck disable=SC2016  # "$@" is written literally into each shim, not expanded here.
mk_agents_fixture() {
    local dir="$1"
    init_repo_bare "$dir"
    mkdir -p "$dir/bin" "$dir/hooks"
    printf '#!/usr/bin/env bash\nexit 0\n' > "$dir/bin/check-on-demand-rules.sh"
    chmod +x "$dir/bin/check-on-demand-rules.sh"
    printf '#!/usr/bin/env bash\nexec bash "%s/bin/check-session-id-ssot.sh" "$@"\n' "$AGENTS_DIR" > "$dir/bin/check-session-id-ssot.sh"
    chmod +x "$dir/bin/check-session-id-ssot.sh"
    printf '#!/usr/bin/env bash\nexec bash "%s/bin/check-migration-blocks.sh" "$@"\n' "$AGENTS_DIR" > "$dir/bin/check-migration-blocks.sh"
    chmod +x "$dir/bin/check-migration-blocks.sh"
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -q -m initial >/dev/null 2>&1
}

# _install_gate_shim <path> <mode> — write (or omit) a controlled checker shim.
#   clean -> exec exit 0   rc2 -> exec exit 2   rc3 -> exec exit 3
#   absent -> no file (the [ ! -x ] guard fires the fail-open skip)
_install_gate_shim() {
    local path="$1" mode="$2"
    case "$mode" in
        clean)  printf '#!/usr/bin/env bash\nexit 0\n' > "$path"; chmod +x "$path" ;;
        rc2)    printf '#!/usr/bin/env bash\nexit 2\n' > "$path"; chmod +x "$path" ;;
        rc3)    printf '#!/usr/bin/env bash\nexit 3\n' > "$path"; chmod +x "$path" ;;
        absent) rm -f "$path" ;;
        *) echo "_install_gate_shim: unknown mode '$mode'" >&2; return 1 ;;
    esac
}

# mk_agents_fixture_rc <dir> <si_mode> <mb_mode> [od_mode] — like mk_agents_fixture but with
# CONTROLLED session-id/migration checker exits, to exercise the shared rc-handling
# template (skip-on-nonexec / block-on-1|2 / fail-open-on-unexpected-rc) without a real
# violation. On-demand shim defaults to clean exit-0 (override via od_mode). Non-target gates stay clean so a
# fail-open case returns GRC 0 and a block is attributable to the target gate; the gates
# run on-demand -> session-id -> migration, so a clean session-id lets control reach it.
mk_agents_fixture_rc() {
    local dir="$1" si_mode="$2" mb_mode="$3" od_mode="${4:-clean}"
    init_repo_bare "$dir"
    mkdir -p "$dir/bin" "$dir/hooks"
    _install_gate_shim "$dir/bin/check-on-demand-rules.sh" "$od_mode"
    _install_gate_shim "$dir/bin/check-session-id-ssot.sh" "$si_mode"
    _install_gate_shim "$dir/bin/check-migration-blocks.sh" "$mb_mode"
    printf 'init\n' > "$dir/README.md"
    git -C "$dir" add -A >/dev/null 2>&1
    git -C "$dir" commit -q -m initial >/dev/null 2>&1
}

# run_agents_gates <repo> <cfg-dir> — the function calls `exit 1` on a violation, so it
# must run in a subshell (else it would kill the test). AGENTS_CONFIG_DIR sets the
# _od_cfg_dir the gates resolve; CWD is the repo under commit.
GOUT=""; GRC=0
run_agents_gates() {
    local repo="$1" cfg="$2"
    GOUT="$( ( cd "$repo" && export AGENTS_CONFIG_DIR="$cfg" && _precommit_agents_repo_gates ) 2>&1 )"
    GRC=$?
}

SID_MSG='session-id env reads bypassing the SSOT resolver'
MIG_MSG='migration block format violations'
SID_SKIP_MSG='session-id SSOT gate skipped'
MIG_SKIP_MSG='migration blocks gate skipped'
OD_MSG='on-demand rules-injection notation violations'
OD_SKIP_MSG='on-demand rules notation gate skipped'

# Per-part cases (sourced; share the helpers/globals above).
SCRIPT_DIR="$(dirname "${BASH_SOURCE[0]}")/feature-1834-precommit-lib-split"
# shellcheck source=./feature-1834-precommit-lib-split/part-a-cause-messages.sh
. "$SCRIPT_DIR/part-a-cause-messages.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-b-wiring-size.sh
. "$SCRIPT_DIR/part-b-wiring-size.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-c-gates.sh
. "$SCRIPT_DIR/part-c-gates.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-c-gates-errorpath.sh
. "$SCRIPT_DIR/part-c-gates-errorpath.sh"
# shellcheck source=./feature-1834-precommit-lib-split/part-c-frontmatter.sh
. "$SCRIPT_DIR/part-c-frontmatter.sh"

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
[ "$FAIL" -gt 0 ] && exit 1
exit 0
