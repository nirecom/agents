#!/bin/bash
# Tests: bin/scan-outbound.sh, bin/scan-outbound.sh., hooks/lib, hooks/lib/bash-write-patterns.js, hooks/lib/forge-write-extract.js, hooks/lib/is-private-repo.js, hooks/lib/parse-git-args.js, hooks/scan-outbound.js, hooks/scan-outbound.js.
# Tags: scan, filter, outbound, hook, intent
# Integration tests for the forge-write-scan extension to hooks/scan-outbound.js.
#
# Post-implementation contract under test:
#   - For Bash gh forge-write commands (issue/pr create|edit|close|comment + pr review),
#     scan --body / --title / --body-file / heredoc text through bin/scan-outbound.sh.
#   - rc=1 -> block + "Private information"
#   - rc=2 -> block + "Ask the user"
#   - rc=0 -> approve
#   - Private repo -> approve (skip)
#   - Non-existent --body-file -> approve (fail-open, scanner returns 0 on empty)
#   - Out-of-scope (gh repo *, gh issue list, gh api ...) -> approve
#   - Existing paths (git commit message, Edit/Write) keep working unchanged.
#
# Until hooks/lib/forge-write-extract.js is implemented in source, a no-op
# stub is dropped into FAKE_AGENTS so the hook can load. With the stub the
# block-expected forge tests will all FAIL — that is intentional, the script
# still runs to completion and reports counts.
set -euo pipefail

DOTFILES_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCANNER_SRC="$DOTFILES_DIR/bin/scan-outbound.sh"
HOOK_SRC="$DOTFILES_DIR/hooks/scan-outbound.js"
ISPRIV_SRC="$DOTFILES_DIR/hooks/lib/is-private-repo.js"
PARSEGIT_SRC="$DOTFILES_DIR/hooks/lib/parse-git-args.js"
BWPATTERNS_SRC="$DOTFILES_DIR/hooks/lib/bash-write-patterns.js"
FORGE_SRC="$DOTFILES_DIR/hooks/lib/forge-write-extract.js"
ERRORS=0

fail() { echo "FAIL: $1"; ERRORS=$((ERRORS + 1)); }
pass() { echo "PASS: $1"; }

run_with_timeout() {
    if command -v timeout >/dev/null 2>&1; then
        timeout 120 "$@"
    else
        perl -e 'alarm 120; exec @ARGV' -- "$@"
    fi
}

TMPBASE="$(mktemp -d)"
trap 'rm -rf "$TMPBASE"' EXIT

# ---- Build the fake agents tree ----
FAKE_AGENTS="$TMPBASE/agents"
mkdir -p "$FAKE_AGENTS/bin" "$FAKE_AGENTS/hooks/lib"
cp "$SCANNER_SRC"   "$FAKE_AGENTS/bin/scan-outbound.sh"
cp "$HOOK_SRC"      "$FAKE_AGENTS/hooks/scan-outbound.js"
cp "$ISPRIV_SRC"    "$FAKE_AGENTS/hooks/lib/is-private-repo.js"
[ -f "$PARSEGIT_SRC" ]   && cp "$PARSEGIT_SRC"   "$FAKE_AGENTS/hooks/lib/parse-git-args.js"
[ -f "$BWPATTERNS_SRC" ] && cp "$BWPATTERNS_SRC" "$FAKE_AGENTS/hooks/lib/bash-write-patterns.js"

if [ -f "$FORGE_SRC" ]; then
    cp "$FORGE_SRC" "$FAKE_AGENTS/hooks/lib/forge-write-extract.js"
    echo "INFO: using real hooks/lib/forge-write-extract.js"
else
    # No-op stub so the hook can still `require()` it. With this stub installed,
    # all forge-write block-expected cases will FAIL — by design until the real
    # module is implemented.
    cat > "$FAKE_AGENTS/hooks/lib/forge-write-extract.js" <<'EOF'
"use strict";
function isForgeScanTarget(/*command*/) { return false; }
function extractTexts(/*command*/) { return { inline: [], filePaths: [] }; }
module.exports = { isForgeScanTarget, extractTexts };
EOF
    echo "INFO: hooks/lib/forge-write-extract.js missing — using no-op stub (forge tests expected to FAIL)"
fi

chmod +x "$FAKE_AGENTS/bin/scan-outbound.sh"
: > "$FAKE_AGENTS/.private-info-allowlist"
cat > "$FAKE_AGENTS/.private-info-blocklist" <<'EOF'
forbiddenword[0-9]+
warn:suspicious[a-z]+pattern
EOF

HOOK="$FAKE_AGENTS/hooks/scan-outbound.js"

# ---- gh stubs ----
# Default stub: exit 1 (any gh repo view fails -> non-private repo path).
STUB_BIN="$TMPBASE/stubbin"
mkdir -p "$STUB_BIN"
cat > "$STUB_BIN/gh" <<'EOF'
#!/bin/bash
exit 1
EOF
chmod +x "$STUB_BIN/gh"
# Windows-compatible .cmd wrapper for default stub (Node.js on Windows needs .cmd)
cat > "$STUB_BIN/gh.cmd" <<'CMD'
@echo off
exit /b 1
CMD
EXEC_PATH="$STUB_BIN:$PATH"

# Private-repo gh stub: makes gh api repos/<id> --jq .private print "true"
STUB_BIN_PRIV="$TMPBASE/stubbin-priv"
mkdir -p "$STUB_BIN_PRIV"
cat > "$STUB_BIN_PRIV/gh" <<'EOF'
#!/bin/bash
# Stub gh that always reports the target repo as private
case "$1" in
    api)
        # gh api repos/owner/repo --jq .private
        echo "true"
        exit 0
        ;;
    *)
        exit 0
        ;;
esac
EOF
chmod +x "$STUB_BIN_PRIV/gh"
# Windows-compatible .cmd wrapper for private stub
cat > "$STUB_BIN_PRIV/gh.cmd" <<'CMD'
@echo off
if "%~1"=="api" (
    echo true
    exit /b 0
)
exit /b 0
CMD
EXEC_PATH_PRIV="$STUB_BIN_PRIV:$PATH"

# is-private-repo.js needs an `origin` remote to even reach `gh api`. Create
# a real git repo with a github.com origin so the private-repo branch is taken
# when EXEC_PATH_PRIV is used.
PRIV_REPO="$TMPBASE/privrepo"
mkdir -p "$PRIV_REPO"
git -C "$PRIV_REPO" init -q
git -C "$PRIV_REPO" remote add origin "git@github.com:fake/private-repo.git"
PRIV_FILE="$PRIV_REPO/note.txt"
: > "$PRIV_FILE"

# Path outside any git repo for the default (public/non-repo) cases
NOREPO_PATH="$TMPBASE/notrepo/foo.txt"
mkdir -p "$(dirname "$NOREPO_PATH")"

# ---- run helper ----
HK_OUT=""
HK_RC=0
run_hook() {
    local payload="$1"
    local exec_path="${2:-$EXEC_PATH}"
    set +e
    HK_OUT="$(printf '%s' "$payload" | PATH="$exec_path" run_with_timeout node "$HOOK" 2>/dev/null)"
    HK_RC=$?
    set -e
}

expect_approve() {
    local desc="$1"
    if echo "$HK_OUT" | grep -q '"decision":"approve"'; then
        pass "$desc"
    else
        fail "$desc — expected approve, got: [$HK_OUT]"
    fi
}

expect_block_with() {
    local desc="$1" needle="$2"
    if echo "$HK_OUT" | grep -q '"decision":"block"' && echo "$HK_OUT" | grep -qF "$needle"; then
        pass "$desc"
    else
        fail "$desc — expected block + '$needle', got: [$HK_OUT]"
    fi
}

# ============================================================================
# Test cases
# ============================================================================

echo "=== 1) gh issue create with hard match -> block + 'Private information' ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body \"oops forbiddenword42 leaked\""}}
JSON
)"
expect_block_with "gh issue create hard hit -> block" "Private information"

echo ""
echo "=== 2) gh issue create with warn match -> block + 'Ask the user' ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body \"contains suspiciousxxxpattern here\""}}
JSON
)"
expect_block_with "gh issue create warn hit -> block + Ask" "Ask the user"

echo ""
echo "=== 3) gh issue comment with clean body -> approve ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue comment 5 --body \"totally safe content\""}}
JSON
)"
expect_approve "gh issue comment clean -> approve"

echo ""
echo "=== 4) gh pr create with hard match -> block + 'Private information' ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh pr create --body \"forbiddenword42 in pr\""}}
JSON
)"
expect_block_with "gh pr create hard hit -> block" "Private information"

echo ""
echo "=== 5) --body-file with hard hit file -> block + 'Private information' ==="
BODY_HARD="$TMPBASE/hard-body.md"
cat > "$BODY_HARD" <<'EOF'
This file contains forbiddenword42 inside it.
EOF
run_hook "$(cat <<JSON
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body-file $BODY_HARD"}}
JSON
)"
expect_block_with "--body-file hard hit -> block" "Private information"

echo ""
echo "=== 6) --body-file with clean file -> approve ==="
BODY_CLEAN="$TMPBASE/clean-body.md"
cat > "$BODY_CLEAN" <<'EOF'
This file is perfectly clean.
EOF
run_hook "$(cat <<JSON
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body-file $BODY_CLEAN"}}
JSON
)"
expect_approve "--body-file clean -> approve"

echo ""
echo "=== 7) --body-file with non-existent path -> approve (fail-open) ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body-file /tmp/definitely-does-not-exist-xyz.md"}}
JSON
)"
expect_approve "--body-file missing path -> approve"

echo ""
echo "=== 8) gh repo edit -> approve (v1 scope exclusion) ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh repo edit --description \"desc\""}}
JSON
)"
expect_approve "gh repo edit -> approve"

echo ""
echo "=== 9) gh issue list -> approve (read-only) ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue list --state open"}}
JSON
)"
expect_approve "gh issue list -> approve"

echo ""
echo "=== 10) Regression: git commit -m with hard hit -> block ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"git commit -m \"msg with forbiddenword42\""}}
JSON
)"
expect_block_with "git commit hard hit -> block (regression)" "Private information"

echo ""
echo "=== 11) Private repo + forge write with hard hit -> approve (private skip) ==="
# Run inside the private repo so resolveRepoDir() picks it up
pushd "$PRIV_REPO" >/dev/null
run_hook "$(cat <<JSON
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body \"forbiddenword42 in private repo\""}}
JSON
)" "$EXEC_PATH_PRIV"
popd >/dev/null
expect_approve "private repo forge write hard hit -> approve (skip)"

echo ""
echo "=== 12) Regression: Edit tool hard hit -> block ==="
run_hook "$(cat <<JSON
{"tool_name":"Edit","tool_input":{"file_path":"$NOREPO_PATH","new_string":"oops forbiddenword42 leaked"}}
JSON
)"
expect_block_with "Edit hard hit -> block (regression)" "Private information"

echo ""
echo "=== 13) gh issue create with --body=value (equals form) hard match -> block ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue create --title \"T\" --body=\"oops forbiddenword42 leaked\""}}
JSON
)"
expect_block_with "gh issue create --body= hard hit -> block" "Private information"

echo ""
echo "=== 14) gh issue create with unquoted --body hard match -> block ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body forbiddenword42"}}
JSON
)"
expect_block_with "gh issue create unquoted --body hard hit -> block" "Private information"

echo ""
echo "=== 15) gh issue create with heredoc non-EOF delimiter hard match -> block ==="
run_hook "$(cat <<'JSON'
{"tool_name":"Bash","tool_input":{"command":"gh issue create --body \"$(cat <<'END'\nforbiddenword42 inside heredoc\nEND\n)\""}}
JSON
)"
expect_block_with "gh issue create non-EOF heredoc hard hit -> block" "Private information"

echo ""
echo "================================"
if [ "$ERRORS" -eq 0 ]; then
    echo "All tests passed!"
else
    echo "$ERRORS test(s) FAILED"
    exit 1
fi
