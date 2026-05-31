#!/bin/bash
# tests/fix-enforce-worktree-bundle-a-targets.sh
# Tests: hooks/lib/bash-write-targets.js
# Tags: enforce-worktree-bundle-a-targets
#
# Unit tests for hooks/lib/bash-write-targets.js (will be implemented after
# tests pass red). Tests call the module via `node -e require(...)`.
#
# Module contract (will exist at hooks/lib/bash-write-targets.js):
#   module.exports = {
#     extractRedirectTargets,   // POSIX > >> 2> &> redirects (skips 2>&1, /dev/null)
#     extractTeeTargets,        // tee args (skips -a/--append/-i/-p flags)
#     extractPwshWriteTargets,  // PowerShell cmdlets
#     extractStagedFiles,       // git diff --cached --name-only
#   };
#
# Each target-extractor returns:
#   string[]  on success
#   null      on parse failure (variable expansion, command substitution,
#             process substitution, missing destination for Move/Copy)

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
MODULE="${_AGENTS_DIR_NODE}/hooks/lib/bash-write-targets.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    else
        "$@"
    fi
}

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'bundle-a-targets-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

# ─────────────────────────────────────────────────────────────────────────────
# Callers (each prints JSON serialization of the function result, or a JS
# error message prefixed by "ERROR:")
# ─────────────────────────────────────────────────────────────────────────────

call_redirect() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractRedirectTargets(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_tee() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractTeeTargets(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_pwsh() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractPwshWriteTargets(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_staged() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractStagedFiles(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

call_cpmv() {
    run_with_timeout 30 node -e "
      try {
        const m = require('$MODULE');
        const r = m.extractCpMvDestination(process.argv[1]);
        console.log(JSON.stringify(r));
      } catch (e) { console.log('ERROR: ' + e.message); }
    " -- "$1" 2>/dev/null
}

assert_fn_result() {
    local desc="$1" got="$2" expected="$3"
    if [ "$got" = "$expected" ]; then
        pass "$desc"
    else
        fail "$desc: expected '$expected', got '$got'"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# extractRedirectTargets
# ─────────────────────────────────────────────────────────────────────────────

test_redirect_basic() {
    assert_fn_result "redirect: > simple"   "$(call_redirect 'echo x > a.md')"  '["a.md"]'
    assert_fn_result "redirect: > quoted path with spaces" \
        "$(call_redirect 'echo x > "C:/path with spaces/f.md"')" \
        '["C:/path with spaces/f.md"]'
    assert_fn_result "redirect: 2>> append stderr" \
        "$(call_redirect 'cmd 2>> err.log')" '["err.log"]'
    assert_fn_result "redirect: 1> stdout" \
        "$(call_redirect 'cmd 1> out')" '["out"]'
    assert_fn_result "redirect: &> all-streams" \
        "$(call_redirect 'cmd &> all.log')" '["all.log"]'
}

test_redirect_skip_cases() {
    # FD-to-FD redirects must not produce file targets.
    assert_fn_result "redirect: 2>&1 fd-to-fd skipped" \
        "$(call_redirect 'cmd 2>&1')" '[]'
    # /dev/null null-sink must not produce file targets.
    assert_fn_result "redirect: > /dev/null null-sink skipped" \
        "$(call_redirect 'cmd > /dev/null')" '[]'
    assert_fn_result "redirect: >> /dev/null null-sink skipped" \
        "$(call_redirect 'cmd >> /dev/null')" '[]'
}

test_redirect_parse_failure() {
    # Variable expansion produces a parse failure (fail-closed).
    # Use single-quoted shell argv so $VAR reaches Node literally.
    assert_fn_result "redirect: \$VAR expansion → null" \
        "$(call_redirect 'echo x > $VAR')" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# extractTeeTargets
# ─────────────────────────────────────────────────────────────────────────────

test_tee_basic() {
    assert_fn_result "tee: piped" \
        "$(call_tee 'cmd | tee file.log')" '["file.log"]'
    assert_fn_result "tee: -a flag skipped, file kept" \
        "$(call_tee 'tee -a out.txt')" '["out.txt"]'
    assert_fn_result "tee: --append flag skipped" \
        "$(call_tee 'tee --append out.txt')" '["out.txt"]'
    assert_fn_result "tee: multi-file" \
        "$(call_tee 'tee f1 f2')" '["f1","f2"]'
}

test_tee_parse_failure() {
    # Process substitution must fail-closed.
    assert_fn_result "tee: process-sub >(cat) → null" \
        "$(call_tee 'tee >(cat)')" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# extractPwshWriteTargets — first-positional cmdlets
# ─────────────────────────────────────────────────────────────────────────────

test_pwsh_first_positional_cmdlets() {
    assert_fn_result "pwsh: Set-Content -Path" \
        "$(call_pwsh 'Set-Content -Path foo.md -Value bar')" '["foo.md"]'
    assert_fn_result "pwsh: Set-Content positional" \
        "$(call_pwsh 'Set-Content foo.md "bar"')" '["foo.md"]'
    assert_fn_result "pwsh: Out-File -FilePath" \
        "$(call_pwsh 'Out-File -FilePath out.log')" '["out.log"]'
    assert_fn_result "pwsh: Add-Content -Path" \
        "$(call_pwsh 'Add-Content -Path a.txt -Value x')" '["a.txt"]'
    assert_fn_result "pwsh: New-Item -Path" \
        "$(call_pwsh 'New-Item -Path myfile.txt')" '["myfile.txt"]'
    assert_fn_result "pwsh: Remove-Item -Path" \
        "$(call_pwsh 'Remove-Item -Path old.txt')" '["old.txt"]'

    # Aliases for first-positional cmdlets
    assert_fn_result "pwsh: alias sc" \
        "$(call_pwsh 'sc foo.md "val"')" '["foo.md"]'
    assert_fn_result "pwsh: alias ac" \
        "$(call_pwsh 'ac a.txt "x"')" '["a.txt"]'
    assert_fn_result "pwsh: alias ni" \
        "$(call_pwsh 'ni myfile.txt')" '["myfile.txt"]'
    assert_fn_result "pwsh: alias ri" \
        "$(call_pwsh 'ri old.txt')" '["old.txt"]'
}

# ─────────────────────────────────────────────────────────────────────────────
# extractPwshWriteTargets — Move/Copy use destination, not source
# ─────────────────────────────────────────────────────────────────────────────

test_pwsh_move_copy_destination() {
    assert_fn_result "pwsh: Move-Item -Destination" \
        "$(call_pwsh 'Move-Item -Path src.md -Destination dst.md')" '["dst.md"]'
    assert_fn_result "pwsh: Copy-Item -Destination" \
        "$(call_pwsh 'Copy-Item -Path src.md -Destination dst.md')" '["dst.md"]'
    assert_fn_result "pwsh: Move-Item positional (2nd = dst)" \
        "$(call_pwsh 'Move-Item src.md dst.md')" '["dst.md"]'
    assert_fn_result "pwsh: Copy-Item positional (2nd = dst)" \
        "$(call_pwsh 'Copy-Item src.md dst.md')" '["dst.md"]'
    assert_fn_result "pwsh: alias mi positional" \
        "$(call_pwsh 'mi src.md dst.md')" '["dst.md"]'
    assert_fn_result "pwsh: alias ci positional" \
        "$(call_pwsh 'ci src.md dst.md')" '["dst.md"]'
}

test_pwsh_move_copy_fail_closed() {
    # Source-only invocation (no destination) → null (fail-closed).
    assert_fn_result "pwsh: Move-Item src only → null" \
        "$(call_pwsh 'Move-Item src.md')" 'null'
    assert_fn_result "pwsh: Copy-Item src only → null" \
        "$(call_pwsh 'Copy-Item src.md')" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# extractStagedFiles
# ─────────────────────────────────────────────────────────────────────────────

setup_temp_repo() {
    # Create a fresh temp git repo with an initial commit on main.
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    echo "init" > "$repo/README.md"
    git -C "$repo" add README.md
    git -C "$repo" commit -q -m "initial"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$repo"
    else
        echo "$repo"
    fi
}

test_staged_files() {
    local repo; repo="$(setup_temp_repo "staged-basic")"
    # Stage a new file.
    echo "newdata" > "$repo/newfile.md"
    git -C "$repo" add newfile.md
    local got; got="$(call_staged "$repo")"
    # Expected: a JSON array containing an absolute path ending with newfile.md.
    local expected_substr="newfile.md"
    if echo "$got" | grep -q "$expected_substr"; then
        # Also assert it's a JSON array starting with [.
        if echo "$got" | grep -qE '^\[.*\]$'; then
            pass "extractStagedFiles: returns array containing newfile.md ($got)"
        else
            fail "extractStagedFiles: not a JSON array ($got)"
        fi
    else
        fail "extractStagedFiles: missing newfile.md ($got)"
    fi

    # No staged files → empty array.
    local repo2; repo2="$(setup_temp_repo "staged-empty")"
    local got2; got2="$(call_staged "$repo2")"
    assert_fn_result "extractStagedFiles: no staged → []" "$got2" '[]'

    # Non-git directory → null.
    local nongit="$TMPDIR_BASE/non-git-dir"
    mkdir -p "$nongit"
    if command -v cygpath >/dev/null 2>&1; then
        nongit="$(cygpath -m "$nongit")"
    fi
    local got3; got3="$(call_staged "$nongit")"
    assert_fn_result "extractStagedFiles: non-git dir → null" "$got3" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# Idempotency
# ─────────────────────────────────────────────────────────────────────────────

test_idempotency() {
    local a b
    a="$(call_redirect 'echo x > foo.md')"
    b="$(call_redirect 'echo x > foo.md')"
    if [ "$a" = "$b" ] && [ "$a" = '["foo.md"]' ]; then
        pass "extractRedirectTargets is idempotent"
    else
        fail "extractRedirectTargets not idempotent: a=$a b=$b"
    fi
}

# ─────────────────────────────────────────────────────────────────────────────
# Security: command substitution / process substitution must fail-closed
# ─────────────────────────────────────────────────────────────────────────────

test_security_redirect_injection() {
    # $(...) is a command substitution — extractor cannot statically resolve
    # the target, so it must fail-closed (null).
    assert_fn_result "redirect: \$(...) command-sub → null" \
        "$(call_redirect 'echo x > /tmp/$(rm -rf /)')" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# extractCpMvDestination
# ─────────────────────────────────────────────────────────────────────────────

test_cpmv_destination() {
    # Normal cases
    assert_fn_result "cp src dst" \
        "$(call_cpmv 'cp src dst')" '"dst"'
    assert_fn_result "cp -r src dst" \
        "$(call_cpmv 'cp -r src dst')" '"dst"'
    assert_fn_result "cp -rp src dst (multiple flags)" \
        "$(call_cpmv 'cp -rp src dst')" '"dst"'
    assert_fn_result "cp a b c dst (multiple sources)" \
        "$(call_cpmv 'cp a b c dst')" '"dst"'
    assert_fn_result "cp absolute outside-repo path" \
        "$(call_cpmv 'cp -r /c/Users/nire/.workflow-plans /c/Users/nire/.workflow-plans-bak')" \
        '"/c/Users/nire/.workflow-plans-bak"'
    assert_fn_result "mv old new" \
        "$(call_cpmv 'mv old.md new.md')" '"new.md"'
    assert_fn_result "mv with flags" \
        "$(call_cpmv 'mv -f src dst')" '"dst"'

    # Fail-closed cases
    assert_fn_result "cp single arg (no dest) → null" \
        "$(call_cpmv 'cp src')" 'null'
    assert_fn_result "cp \$var expansion → null" \
        "$(call_cpmv 'cp src $DST')" 'null'
    assert_fn_result "cp command-sub → null" \
        "$(call_cpmv 'cp src \$(echo dst)')" 'null'
    assert_fn_result "no cp/mv command → null" \
        "$(call_cpmv 'echo hello')" 'null'
}

# ─────────────────────────────────────────────────────────────────────────────
# Run all
# ─────────────────────────────────────────────────────────────────────────────

test_redirect_basic
test_redirect_skip_cases
test_redirect_parse_failure
test_tee_basic
test_tee_parse_failure
test_pwsh_first_positional_cmdlets
test_pwsh_move_copy_destination
test_pwsh_move_copy_fail_closed
test_staged_files
test_idempotency
test_security_redirect_injection
test_cpmv_destination

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"

if [ $FAIL -eq 0 ]; then exit 0; else exit 1; fi
