# tests/feature-1180-commit-lang-check/group-exclude.sh
# Tests: hooks/lib/lint-commit-lang.js, hooks/lib/lang-config.js, hooks/lib/path-coverage-match.js, hooks/lib/glob-match.js, hooks/pre-commit
# Tags: lang-enforce, commit-hook, code-lang-exclude, scope:issue-specific
#
# Group X — CODE_LANG_EXCLUDE repo-root bypass: X1..X30.
# Dispatch only (no case logic): the group outgrew the 500-line HARD limit of
# rules/coding/file-split.md, so the cases live in sibling group-exclude-*.sh
# files and this file sources them in case order.
#
#   group-exclude-lib.sh        shared fixtures, classifiers, assert_eq
#   group-exclude-match.sh      X1..X9, X21, X22, X25  — matching semantics
#   group-exclude-precommit.sh  X12..X14, X19, X20, X24, X26, X30 — hook integration
#   group-exclude-failopen.sh   X10, X11, X17, X18, X27..X29 — repo-root detection failure
#   group-exclude-platform.sh   X15, X16, X23           — Windows path forms
#
# SUT (NOT yet implemented at authoring time — RED is the expected state):
#   hooks/lib/lang-config.js         loadCodeLangExclude()
#   hooks/lib/lint-commit-lang.js    repoRoot() + exclude gate at the top of check()
#   hooks/lib/path-coverage-match.js isCoveredByEntryList() (already implemented)
#
# TL3 gap (what this test does NOT catch):
# - The PATH-manipulation fail-open cases are POSIX-only: X17 (shim forcing
#   `git rev-parse --show-toplevel` to exit 128), X29 (shim forcing it to exit 0
#   with empty stdout) and X28 (git absent from PATH entirely). On Windows,
#   Node's spawnSync("git", ...) cannot execute an extensionless shell script
#   resolved through PATH, so a `git` shim is unreachable from
#   lint-commit-lang.js; and on git-bash the interpreters the hook needs live
#   alongside git.exe, so a git-free PATH cannot be built either. Windows
#   fail-open coverage therefore rests on the unit-level real-fault cases X10/X11
#   (non-repo cwd), the spawnSync error-shape probe X27, and the non-repo-cwd
#   integration case X18 — there is NO real Windows PATH-manipulation
#   integration test, and the "git exits 0 with empty stdout" branch has no
#   Windows coverage at all.
# - Real `git commit` wiring: like the rest of this family, integration cases
#   invoke hooks/pre-commit directly rather than through a real commit.
# - Real Windows git-bash PATH + AGENTS_CONFIG_DIR symlink resolution.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: hook-registration.
#
# Test isolation: CODE_LANG_EXCLUDE is NEVER passed as "" — hooks/lib/load-env.js
# treats an empty process.env value as unset and lets .env overwrite it. lib.sh's
# helpers therefore inject $EXCLUDE_ISOLATION_SENTINEL into every call that does
# not decide the variable itself; the single case that needs a genuinely empty
# value (X11) stubs AGENTS_CONFIG_DIR at an isolated directory with no .env.

_XG_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# shellcheck source=./group-exclude-lib.sh
. "$_XG_DIR/group-exclude-lib.sh"
# shellcheck source=./group-exclude-match.sh
. "$_XG_DIR/group-exclude-match.sh"
# shellcheck source=./group-exclude-precommit.sh
. "$_XG_DIR/group-exclude-precommit.sh"
# shellcheck source=./group-exclude-failopen.sh
. "$_XG_DIR/group-exclude-failopen.sh"
# shellcheck source=./group-exclude-platform.sh
. "$_XG_DIR/group-exclude-platform.sh"
