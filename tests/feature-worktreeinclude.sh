#!/bin/bash
# tests/feature-worktreeinclude.sh
# Tests: bin/worktree-copy-include.js, hooks/lib/worktree-copy.js, hooks/lib/worktree-include-match.js
# Tags: worktreeinclude
#
# B-Hybrid Phase 1: .worktreeinclude file-copy feature
#
# Tests the contract of:
#   - hooks/lib/worktree-include-match.js  (buildMatcher wrapping ignore@^5.3.2)
#   - hooks/lib/worktree-copy.js            (copyInclude({mainRoot, worktreePath, includeFile}))
#   - bin/worktree-copy-include.js          (stdin JSON → stdout JSON CLI)
#
# Test-first: source files may not yet exist. Tests will FAIL with "Cannot find
# module" until the implementation lands. Once implemented per the contract
# below, all tests should PASS.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
BIN_JS="${_AGENTS_DIR_NODE}/bin/worktree-copy-include.js"
LIB_COPY_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-copy.js"
LIB_MATCH_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-include-match.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'wti-'+process.pid).replace(/\\\\/g,'/');
fs.mkdirSync(d,{recursive:true});
console.log(d);
" 2>/dev/null)"
[ -z "$TMPDIR_BASE" ] && TMPDIR_BASE="$(mktemp -d)"
trap 'rm -rf "$TMPDIR_BASE"' EXIT

run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then
        timeout "$secs" "$@"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'alarm shift; exec @ARGV' "$secs" "$@"
    else
        "$@"
    fi
}

require_bin() {
    if [ ! -f "$BIN_JS" ]; then
        fail "$1 (bin/worktree-copy-include.js not implemented yet)"
        return 1
    fi
    return 0
}

# Build a JSON payload safely via node (avoids backslash quoting hell).
# Args: mainRoot worktreePath includeFile-or-empty
make_payload() {
    local main="$1"
    local wt="$2"
    local inc="${3:-}"
    node -e "
        const j = {
            mainRoot: process.argv[1],
            worktreePath: process.argv[2]
        };
        if (process.argv[3]) j.includeFile = process.argv[3];
        else j.includeFile = null;
        process.stdout.write(JSON.stringify(j));
    " -- "$main" "$wt" "$inc" 2>/dev/null
}

# Run the bin script with given JSON payload. Echoes stdout. Stderr captured
# separately via run_bin_stderr.
# Args: payload
run_bin() {
    local payload="$1"
    printf '%s' "$payload" | run_with_timeout 60 node "$BIN_JS" 2>/dev/null
}

# Run and capture stderr.
run_bin_stderr() {
    local payload="$1"
    printf '%s' "$payload" | run_with_timeout 60 node "$BIN_JS" 2>&1 >/dev/null
}

# Run and capture exit code (with stdout discarded).
run_bin_exitcode() {
    local payload="$1"
    printf '%s' "$payload" | run_with_timeout 60 node "$BIN_JS" >/dev/null 2>&1
    echo "$?"
}

# JSON field extraction via node (no jq dependency).
json_field() {
    local out="$1"
    local field="$2"
    node -e "
        let buf = '';
        process.stdin.on('data', c => buf += c);
        process.stdin.on('end', () => {
            try {
                const j = JSON.parse(buf);
                const v = j[process.argv[1]];
                process.stdout.write(JSON.stringify(v));
            } catch (e) {
                process.stdout.write('');
            }
        });
    " -- "$field" <<< "$out" 2>/dev/null
}

# Check whether a JSON array contains a value (substring match for paths,
# normalized to forward slashes).
json_array_contains() {
    local arr="$1"
    local needle="$2"
    node -e "
        const arr = JSON.parse(process.argv[1] || '[]');
        const needle = process.argv[2];
        const norm = s => String(s).replace(/\\\\/g, '/');
        const found = arr.some(item => {
            // entries may be strings or objects with a 'path' field
            const p = typeof item === 'string' ? item : (item && item.path) || '';
            return norm(p).indexOf(needle) !== -1;
        });
        process.exit(found ? 0 : 1);
    " -- "$arr" "$needle" 2>/dev/null
}

# Set up a fake main worktree git repo with .gitignore + gitignored files.
# Args: name -> echoes the absolute path to the repo
setup_main_repo() {
    local name="$1"
    local repo="$TMPDIR_BASE/$name"
    mkdir -p "$repo"
    git -C "$repo" init -q -b main
    git -C "$repo" config user.email "test@example.com"
    git -C "$repo" config user.name "Test"
    git -C "$repo" config core.hooksPath /dev/null
    cat > "$repo/.gitignore" <<'EOF'
.env*
!.env.example
*.local
node_modules/
.private-info-allowlist
config/.env.local
EOF
    echo "init" > "$repo/README.md"
    git -C "$repo" add .gitignore README.md
    git -C "$repo" commit -q -m "initial"
    echo "$repo"
}

# Set up an empty worktree destination directory.
# Args: name -> echoes the absolute path
setup_worktree_dest() {
    local name="$1"
    local wt="$TMPDIR_BASE/$name"
    mkdir -p "$wt"
    echo "$wt"
}

# ============ Tests ============

test_N1_env_local_copied() {
    require_bin "test_N1_env_local_copied" || return
    local main; main="$(setup_main_repo "n1-main")"
    local wt;   wt="$(setup_worktree_dest "n1-wt")"
    echo ".env.local" > "$main/.worktreeinclude"
    echo "SECRET=value" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    if json_array_contains "$copied" ".env.local"; then
        if [ -f "$wt/.env.local" ]; then
            pass "N1: .env.local in include + gitignored → copied"
        else
            fail "N1: copied[] reports .env.local but file not present at dest"
        fi
    else
        fail "N1: .env.local should be in copied[] (got: $out)"
    fi
}

test_N2_env_example_skipped() {
    require_bin "test_N2_env_example_skipped" || return
    local main; main="$(setup_main_repo "n2-main")"
    local wt;   wt="$(setup_worktree_dest "n2-wt")"
    echo ".env.example" > "$main/.worktreeinclude"
    echo "TEMPLATE=1" > "$main/.env.example"
    git -C "$main" add .env.example
    git -C "$main" commit -q -m "track env example"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local skipped; skipped="$(json_field "$out" "skipped")"

    if [ -f "$wt/.env.example" ]; then
        fail "N2: .env.example should NOT be copied (not gitignored)"
    elif json_array_contains "$skipped" ".env.example"; then
        pass "N2: .env.example not gitignored → skipped[]"
    else
        # Acceptable: skipped[] silent, but file still not copied.
        pass "N2: .env.example not gitignored → not copied (skipped[] silent acceptable)"
    fi
}

test_N3_private_info_allowlist_copied() {
    require_bin "test_N3_private_info_allowlist_copied" || return
    local main; main="$(setup_main_repo "n3-main")"
    local wt;   wt="$(setup_worktree_dest "n3-wt")"
    echo ".private-info-allowlist" > "$main/.worktreeinclude"
    echo "pat1" > "$main/.private-info-allowlist"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    if json_array_contains "$copied" ".private-info-allowlist" && \
       [ -f "$wt/.private-info-allowlist" ]; then
        pass "N3: .private-info-allowlist in include + gitignored → copied"
    else
        fail "N3: .private-info-allowlist should be copied (got: $out)"
    fi
}

test_N4_stdout_json_shape() {
    require_bin "test_N4_stdout_json_shape" || return
    local main; main="$(setup_main_repo "n4-main")"
    local wt;   wt="$(setup_worktree_dest "n4-wt")"
    echo ".env.local" > "$main/.worktreeinclude"
    echo "x=1" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"

    # Validate it is JSON and has the four required fields.
    local valid
    valid="$(node -e "
        let buf=''; process.stdin.on('data',c=>buf+=c);
        process.stdin.on('end',()=>{
            try {
                const j = JSON.parse(buf);
                const ok = j && Array.isArray(j.copied) && Array.isArray(j.skipped)
                        && Array.isArray(j.denied) && Array.isArray(j.errors);
                process.stdout.write(ok ? 'ok' : 'bad');
            } catch (e) { process.stdout.write('parse-fail'); }
        });
    " <<< "$out" 2>/dev/null)"

    if [ "$valid" = "ok" ]; then
        pass "N4: stdout is valid JSON with copied/skipped/denied/errors arrays"
    else
        fail "N4: stdout JSON shape invalid ($valid) — got: $out"
    fi
}

test_N5_denylist_blocks_copy() {
    require_bin "test_N5_denylist_blocks_copy" || return
    local main; main="$(setup_main_repo "n5-main")"
    local wt;   wt="$(setup_worktree_dest "n5-wt")"
    cat > "$main/.worktreeinclude" <<'EOF'
.env.local
.env.production
EOF
    echo ".env.production" > "$main/.worktree-copyignore"
    echo "ok=1" > "$main/.env.local"
    echo "PROD_SECRET=danger" > "$main/.env.production"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local denied; denied="$(json_field "$out" "denied")"

    if [ -f "$wt/.env.production" ]; then
        fail "N5: SECURITY — .env.production must NOT be copied (denylist) — got: $out"
    elif json_array_contains "$denied" ".env.production"; then
        pass "N5: .env.production in copyexclude → denied[], not copied"
    else
        fail "N5: .env.production should appear in denied[] — got: $out"
    fi
}

test_N6_worktree_backup_guard_excluded() {
    require_bin "test_N6_worktree_backup_guard_excluded" || return
    local main; main="$(setup_main_repo "n6-main")"
    local wt;   wt="$(setup_worktree_dest "n6-wt")"
    echo ".private-info-allowlist" > "$main/.worktreeinclude"
    # No .worktree-copyignore — tests the hardcoded guard alone.

    # Add .worktree-backup to fixture's .gitignore (post initial-commit) so
    # nested paths under it are gitignored too.
    echo ".worktree-backup" >> "$main/.gitignore"

    # File under .worktree-backup/ — should be blocked by hardcoded guard.
    mkdir -p "$main/.worktree-backup/some-task"
    echo "leak=1" > "$main/.worktree-backup/some-task/.private-info-allowlist"

    # Top-level .private-info-allowlist — should still be copied.
    echo "pat1" > "$main/.private-info-allowlist"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    local nested_blocked=1
    if json_array_contains "$copied" ".worktree-backup/some-task/.private-info-allowlist"; then
        nested_blocked=0
    fi
    if [ -f "$wt/.worktree-backup/some-task/.private-info-allowlist" ]; then
        nested_blocked=0
    fi

    local toplevel_copied=0
    if json_array_contains "$copied" ".private-info-allowlist" && \
       [ -f "$wt/.private-info-allowlist" ]; then
        toplevel_copied=1
    fi

    if [ "$nested_blocked" = "1" ] && [ "$toplevel_copied" = "1" ]; then
        pass "N6: .worktree-backup/ path excluded by hardcoded guard, top-level .private-info-allowlist still copied"
    else
        fail "N6: nested_blocked=$nested_blocked toplevel_copied=$toplevel_copied — out: $out"
    fi
}

test_N6b_worktree_backup_denylist_excluded() {
    require_bin "test_N6b_worktree_backup_denylist_excluded" || return
    local main; main="$(setup_main_repo "n6b-main")"
    local wt;   wt="$(setup_worktree_dest "n6b-wt")"
    echo ".private-info-allowlist" > "$main/.worktreeinclude"

    # Copy production .worktree-copyignore — test passes only after step 2 adds
    # .worktree-backup/ to that file.
    cp "${AGENTS_DIR}/.worktree-copyignore" "$main/.worktree-copyignore"

    # outer/ prefix ensures hardcoded guard does NOT fire (startsWith check).
    mkdir -p "$main/outer/.worktree-backup/inner"
    echo "leak=1" > "$main/outer/.worktree-backup/inner/.private-info-allowlist"

    # Top-level .private-info-allowlist — denylist does NOT block it directly.
    echo "pat1" > "$main/.private-info-allowlist"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"
    local denied; denied="$(json_field "$out" "denied")"

    local nested_blocked=1
    if json_array_contains "$copied" "outer/.worktree-backup/inner/.private-info-allowlist"; then
        nested_blocked=0
    fi
    if [ -f "$wt/outer/.worktree-backup/inner/.private-info-allowlist" ]; then
        nested_blocked=0
    fi

    local nested_denied=0
    if json_array_contains "$denied" "outer/.worktree-backup/inner/.private-info-allowlist"; then
        nested_denied=1
    fi

    local toplevel_copied=0
    if json_array_contains "$copied" ".private-info-allowlist" && \
       [ -f "$wt/.private-info-allowlist" ]; then
        toplevel_copied=1
    fi

    if [ "$nested_blocked" = "1" ] && [ "$nested_denied" = "1" ] && [ "$toplevel_copied" = "1" ]; then
        pass "N6b: outer/.worktree-backup/inner path blocked by .worktree-copyignore denylist (guard not reached)"
    else
        fail "N6b: nested_blocked=$nested_blocked nested_denied=$nested_denied toplevel_copied=$toplevel_copied — out: $out"
    fi
}

test_E1_no_include_file() {
    require_bin "test_E1_no_include_file" || return
    local main; main="$(setup_main_repo "e1-main")"
    local wt;   wt="$(setup_worktree_dest "e1-wt")"
    # No .worktreeinclude file at all.
    echo "x=1" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local code; code="$(run_bin_exitcode "$payload")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    if [ "$code" = "0" ] && [ "$copied" = "[]" ]; then
        pass "E1: no .worktreeinclude → 0 copied, exit 0"
    else
        fail "E1: expected exit 0 + empty copied[], got code=$code copied=$copied"
    fi
}

test_E2_empty_include_file() {
    require_bin "test_E2_empty_include_file" || return
    local main; main="$(setup_main_repo "e2-main")"
    local wt;   wt="$(setup_worktree_dest "e2-wt")"
    : > "$main/.worktreeinclude"
    echo "x=1" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local code; code="$(run_bin_exitcode "$payload")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    if [ "$code" = "0" ] && [ "$copied" = "[]" ]; then
        pass "E2: empty .worktreeinclude → 0 copied, exit 0"
    else
        fail "E2: expected exit 0 + empty copied[], got code=$code copied=$copied"
    fi
}

test_E3_comment_and_blank_lines_ignored() {
    require_bin "test_E3_comment_and_blank_lines_ignored" || return
    local main; main="$(setup_main_repo "e3-main")"
    local wt;   wt="$(setup_worktree_dest "e3-wt")"
    cat > "$main/.worktreeinclude" <<'EOF'
# this is a comment

  # indented comment

.env.local

EOF
    echo "x=1" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    if json_array_contains "$copied" ".env.local"; then
        pass "E3: comments and blank lines ignored, .env.local still copied"
    else
        fail "E3: expected .env.local in copied[], got: $out"
    fi
}

test_E4_negation_excludes() {
    require_bin "test_E4_negation_excludes" || return
    local main; main="$(setup_main_repo "e4-main")"
    local wt;   wt="$(setup_worktree_dest "e4-wt")"
    cat > "$main/.worktreeinclude" <<'EOF'
*.local
!.env.local
EOF
    echo "a=1" > "$main/.env.local"
    echo "b=1" > "$main/other.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    local has_other has_env
    if json_array_contains "$copied" "other.local"; then has_other=1; else has_other=0; fi
    if json_array_contains "$copied" ".env.local"; then has_env=1; else has_env=0; fi

    if [ "$has_other" = "1" ] && [ "$has_env" = "0" ]; then
        pass "E4: ! negation excludes .env.local; other.local still copied"
    else
        fail "E4: negation logic incorrect (other=$has_other env=$has_env) — out: $out"
    fi
}

test_E5_nested_path_creates_parent_dir() {
    require_bin "test_E5_nested_path_creates_parent_dir" || return
    local main; main="$(setup_main_repo "e5-main")"
    local wt;   wt="$(setup_worktree_dest "e5-wt")"
    echo "config/.env.local" > "$main/.worktreeinclude"
    mkdir -p "$main/config"
    echo "x=1" > "$main/config/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"

    if [ -f "$wt/config/.env.local" ]; then
        pass "E5: nested path → parent dir auto-created"
    else
        fail "E5: expected $wt/config/.env.local to exist — out: $out"
    fi
}

test_Err1_invalid_json_stdin() {
    require_bin "test_Err1_invalid_json_stdin" || return
    local code; code="$(run_bin_exitcode "this is not json")"
    local errmsg; errmsg="$(run_bin_stderr "this is not json")"

    if [ "$code" != "0" ] && [ -n "$errmsg" ]; then
        pass "Err1: invalid JSON → non-zero exit + stderr message"
    elif [ "$code" != "0" ]; then
        pass "Err1: invalid JSON → non-zero exit (stderr empty acceptable)"
    else
        fail "Err1: invalid JSON should non-zero exit (got code=$code)"
    fi
}

test_Err2_missing_mainRoot() {
    require_bin "test_Err2_missing_mainRoot" || return
    local code; code="$(run_bin_exitcode '{"worktreePath":"/tmp/wt"}')"
    if [ "$code" != "0" ]; then
        pass "Err2: missing mainRoot → non-zero exit"
    else
        fail "Err2: missing mainRoot should non-zero exit (got code=$code)"
    fi
}

test_Err3_nonexistent_mainRoot() {
    require_bin "test_Err3_nonexistent_mainRoot" || return
    local wt; wt="$(setup_worktree_dest "err3-wt")"
    local payload; payload="$(make_payload "$TMPDIR_BASE/does-not-exist-$$" "$wt")"
    local code; code="$(run_bin_exitcode "$payload")"
    local out; out="$(run_bin "$payload")"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$code" != "0" ]; then
        pass "Err3: non-existent mainRoot → non-zero exit"
    elif [ -n "$errors" ] && [ "$errors" != "[]" ] && [ "$errors" != "null" ]; then
        pass "Err3: non-existent mainRoot → reported in errors[]"
    else
        fail "Err3: expected non-zero exit or errors[] entry, got code=$code errors=$errors"
    fi
}

test_I1_idempotency() {
    require_bin "test_I1_idempotency" || return
    local main; main="$(setup_main_repo "i1-main")"
    local wt;   wt="$(setup_worktree_dest "i1-wt")"
    echo ".env.local" > "$main/.worktreeinclude"
    echo "x=1" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out1; out1="$(run_bin "$payload")"
    local copied1; copied1="$(json_field "$out1" "copied")"
    local out2; out2="$(run_bin "$payload")"
    local copied2; copied2="$(json_field "$out2" "copied")"
    local code2; code2="$(run_bin_exitcode "$payload")"

    if [ "$copied1" = "$copied2" ] && [ "$code2" = "0" ] && [ -f "$wt/.env.local" ]; then
        pass "I1: idempotent (second run same copied[], exit 0, file still there)"
    else
        fail "I1: not idempotent — copied1=$copied1 copied2=$copied2 code2=$code2"
    fi
}

test_Sec1_no_file_contents_in_stdout() {
    require_bin "test_Sec1_no_file_contents_in_stdout" || return
    local main; main="$(setup_main_repo "sec1-main")"
    local wt;   wt="$(setup_worktree_dest "sec1-wt")"
    echo ".env.local" > "$main/.worktreeinclude"
    local secret_marker="SUPER_SECRET_VALUE_DO_NOT_LEAK_$$"
    echo "TOKEN=$secret_marker" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"

    if echo "$out" | grep -q "$secret_marker"; then
        fail "Sec1: SECURITY — file contents leaked to stdout!"
    else
        pass "Sec1: stdout JSON contains paths only, never file contents"
    fi
}

test_Sec2_denylist_wins_over_includelist() {
    require_bin "test_Sec2_denylist_wins_over_includelist" || return
    local main; main="$(setup_main_repo "sec2-main")"
    local wt;   wt="$(setup_worktree_dest "sec2-wt")"
    echo ".env.production" > "$main/.worktreeinclude"
    echo ".env.production" > "$main/.worktree-copyignore"
    echo "BIG_SECRET=danger" > "$main/.env.production"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"

    if [ -f "$wt/.env.production" ]; then
        fail "Sec2: SECURITY — denylist did not override includelist (file copied)"
    else
        pass "Sec2: denylist wins over include (file not copied)"
    fi
}

test_Sec3_path_traversal_in_mainRoot_rejected() {
    require_bin "test_Sec3_path_traversal_in_mainRoot_rejected" || return
    local wt; wt="$(setup_worktree_dest "sec3-wt")"
    # mainRoot containing ../ — should be rejected (non-zero exit) or yield error.
    local payload
    payload="$(make_payload "$TMPDIR_BASE/../../../etc" "$wt")"
    local code; code="$(run_bin_exitcode "$payload")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$code" != "0" ]; then
        pass "Sec3: ../ path traversal in mainRoot → non-zero exit"
    elif [ "$copied" = "[]" ] && [ "$errors" != "[]" ] && [ -n "$errors" ]; then
        pass "Sec3: ../ path traversal in mainRoot → empty copied[] + errors[]"
    elif [ "$copied" = "[]" ]; then
        pass "Sec3: ../ path traversal in mainRoot → no files copied"
    else
        fail "Sec3: SECURITY — ../ in mainRoot allowed copy (copied=$copied)"
    fi
}

test_Sec4_traversal_pattern_in_include() {
    require_bin "test_Sec4_traversal_pattern_in_include" || return
    local main; main="$(setup_main_repo "sec4-main")"
    local wt;   wt="$(setup_worktree_dest "sec4-wt")"
    cat > "$main/.worktreeinclude" <<'EOF'
../../etc/passwd
/etc/passwd
EOF
    echo "x=1" > "$main/.env.local"

    local payload; payload="$(make_payload "$main" "$wt")"
    local out; out="$(run_bin "$payload")"
    local copied; copied="$(json_field "$out" "copied")"

    # Ensure no /etc/passwd-like absolute leakage and no etc/ directory created in wt.
    if [ -e "$wt/etc/passwd" ] || [ -e "$wt/passwd" ]; then
        fail "Sec4: SECURITY — traversal pattern caused write outside expected tree"
    elif json_array_contains "$copied" "etc/passwd"; then
        fail "Sec4: SECURITY — traversal pattern reported as copied: $copied"
    else
        pass "Sec4: traversal pattern in include → not copied"
    fi
}

test_C1_warn_on_unmatched_pattern() {
    require_bin "test_C1_warn_on_unmatched_pattern" || return
    local main; main="$(setup_main_repo "c1-main")"
    local wt;   wt="$(setup_worktree_dest "c1-wt")"
    # pattern matches no gitignored files
    echo "totally-nonexistent-pattern-xyz.local" > "$main/.worktreeinclude"

    local payload; payload="$(make_payload "$main" "$wt")"
    local code; code="$(run_bin_exitcode "$payload")"
    local errmsg; errmsg="$(run_bin_stderr "$payload")"

    if [ "$code" = "0" ] && echo "$errmsg" | grep -qi "WARN"; then
        pass "C1: unmatched include pattern → stderr WARN, exit 0"
    elif [ "$code" = "0" ]; then
        fail "C1: expected stderr 'WARN' for unmatched pattern (got code=$code stderr=$errmsg)"
    else
        fail "C1: unmatched pattern should exit 0 (warn-only), got code=$code"
    fi
}

# ============ Run all ============

test_N1_env_local_copied
test_N2_env_example_skipped
test_N3_private_info_allowlist_copied
test_N4_stdout_json_shape
test_N5_denylist_blocks_copy
test_N6_worktree_backup_guard_excluded
test_N6b_worktree_backup_denylist_excluded
test_E1_no_include_file
test_E2_empty_include_file
test_E3_comment_and_blank_lines_ignored
test_E4_negation_excludes
test_E5_nested_path_creates_parent_dir
test_Err1_invalid_json_stdin
test_Err2_missing_mainRoot
test_Err3_nonexistent_mainRoot
test_I1_idempotency
test_Sec1_no_file_contents_in_stdout
test_Sec2_denylist_wins_over_includelist
test_Sec3_path_traversal_in_mainRoot_rejected
test_Sec4_traversal_pattern_in_include
test_C1_warn_on_unmatched_pattern

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
