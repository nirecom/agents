#!/bin/bash
# tests/feature-worktree-write-notes.sh
#
# worktree-write-notes feature: WORKTREE_NOTES.md generation + .git/info/exclude
# entry append.
#
# Tests the contract of:
#   - hooks/lib/worktree-notes.js  (writeNotes, appendExclude, run)
#   - bin/worktree-write-notes.js  (stdin JSON → stdout JSON CLI)
#
# Test-first: source files do not yet exist. Tests will FAIL with "Cannot find
# module" until the implementation lands. Once implemented per the contract
# below, all tests should PASS.

set -u

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
if command -v cygpath >/dev/null 2>&1; then
    _AGENTS_DIR_NODE="$(cygpath -m "$AGENTS_DIR")"
else
    _AGENTS_DIR_NODE="$AGENTS_DIR"
fi
BIN_JS="${_AGENTS_DIR_NODE}/bin/worktree-write-notes.js"
LIB_JS="${_AGENTS_DIR_NODE}/hooks/lib/worktree-notes.js"

PASS=0
FAIL=0

pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; FAIL=$((FAIL + 1)); }

TMPDIR_BASE="$(node -e "
const os=require('os'),path=require('path'),fs=require('fs');
const d=path.join(os.tmpdir(),'wwn-'+process.pid).replace(/\\\\/g,'/');
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
        fail "$1 (bin/worktree-write-notes.js not implemented yet)"
        return 1
    fi
    return 0
}

require_lib() {
    if [ ! -f "$LIB_JS" ]; then
        fail "$1 (hooks/lib/worktree-notes.js not implemented yet)"
        return 1
    fi
    return 0
}

# Run a snippet that requires the lib. The snippet receives `lib` in scope and
# may write JSON / text to stdout. Args after the snippet become process.argv[1..N].
# Usage: lib_eval "<js snippet>" [arg1 arg2 ...]
lib_eval() {
    local snippet="$1"; shift
    run_with_timeout 120 node -e "
        const lib = require('${LIB_JS}');
        ${snippet}
    " -- "$@"
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
                process.stdout.write(typeof v === 'string' ? v : JSON.stringify(v));
            } catch (e) {
                process.stdout.write('');
            }
        });
    " -- "$field" <<< "$out" 2>/dev/null
}

# Run the bin script with argv + COPIED_JSON env. Stdout only.
# Usage: run_bin mainRoot worktreePath branch [baseDir] [copiedJSON]
run_bin() {
    local main="$1" wt="$2" branch="$3" baseDir="${4:-}" copied="${5:-}"
    COPIED_JSON="$copied" run_with_timeout 120 node "$BIN_JS" "$main" "$wt" "$branch" "$baseDir" 2>/dev/null
}

run_bin_stderr() {
    local main="$1" wt="$2" branch="$3" baseDir="${4:-}" copied="${5:-}"
    COPIED_JSON="$copied" run_with_timeout 120 node "$BIN_JS" "$main" "$wt" "$branch" "$baseDir" 2>&1 >/dev/null
}

run_bin_exitcode() {
    local main="$1" wt="$2" branch="$3" baseDir="${4:-}" copied="${5:-}"
    COPIED_JSON="$copied" run_with_timeout 120 node "$BIN_JS" "$main" "$wt" "$branch" "$baseDir" >/dev/null 2>&1
    echo "$?"
}

# Make a fresh main-style git repo (with `.git` dir).
setup_main_repo() {
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
    echo "$repo"
}

# Make an empty worktree destination directory.
setup_worktree_dest() {
    local name="$1"
    local wt="$TMPDIR_BASE/$name"
    mkdir -p "$wt"
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$wt"
    else
        echo "$wt"
    fi
}

# Convert path to node-friendly (forward slash) form when on Windows.
node_path() {
    if command -v cygpath >/dev/null 2>&1; then
        cygpath -m "$1"
    else
        echo "$1"
    fi
}

# ============ Tests ============

# ---- N1: writeNotes generates exact markdown ----
test_N1_writeNotes_exact_content() {
    require_lib "test_N1_writeNotes_exact_content" || return
    local wt; wt="$(setup_worktree_dest "n1-wt")"

    lib_eval "
        const r = lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/foo',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: 'C:/git/worktrees',
            copiedFiles: ['a.env','b/.env.local']
        });
        process.stdout.write(JSON.stringify(r));
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/n1-wt/WORKTREE_NOTES.md"
    if [ ! -f "$notes_file" ]; then
        fail "N1: WORKTREE_NOTES.md not created at $notes_file"
        return
    fi

    local expected
    expected="$(printf '%s\n' \
        '# Worktree Notes' \
        'Branch: feature/foo' \
        'Created: 2024-01-15' \
        'Path: /tmp/wt' \
        'WORKTREE_BASE_DIR: C:/git/worktrees' \
        '' \
        '## Gitignored files copied from main' \
        '- a.env' \
        '- b/.env.local' \
        '' \
        '## BugsFound' \
        '- (none)' \
        '' \
        '## RelatedTasks' \
        '- (none)' \
        '' \
        '## NextTasks' \
        '- (none)')"

    local actual
    actual="$(cat "$notes_file")"

    if [ "$actual" = "$expected" ]; then
        pass "N1: writeNotes generates correct markdown content (byte-for-byte)"
    else
        fail "N1: content mismatch
--- expected ---
$expected
--- actual ---
$actual
---"
    fi
}

# ---- N2: copiedFiles=[] → "- (none)" ----
test_N2_writeNotes_empty_copied_renders_none() {
    require_lib "test_N2_writeNotes_empty_copied_renders_none" || return
    local wt; wt="$(setup_worktree_dest "n2-wt")"

    lib_eval "
        lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/empty',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: 'C:/git/worktrees',
            copiedFiles: []
        });
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/n2-wt/WORKTREE_NOTES.md"
    if grep -q "^- (none)$" "$notes_file" 2>/dev/null; then
        pass "N2: copiedFiles=[] renders '- (none)' line"
    else
        fail "N2: missing '- (none)' line in $notes_file"
    fi
}

# ---- N3: baseDir=null → "(default)" ----
test_N3_writeNotes_null_baseDir_renders_default() {
    require_lib "test_N3_writeNotes_null_baseDir_renders_default" || return
    local wt; wt="$(setup_worktree_dest "n3-wt")"

    lib_eval "
        lib.writeNotes({
            worktreePath: process.argv[1],
            branch: 'feature/x',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: null,
            copiedFiles: ['a.env']
        });
    " "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/n3-wt/WORKTREE_NOTES.md"
    if grep -q "^WORKTREE_BASE_DIR: (default)$" "$notes_file" 2>/dev/null; then
        pass "N3: baseDir=null renders 'WORKTREE_BASE_DIR: (default)'"
    else
        fail "N3: missing 'WORKTREE_BASE_DIR: (default)' in $notes_file"
    fi
}

# ---- I1: writeNotes idempotency ----
test_I1_writeNotes_idempotent() {
    require_lib "test_I1_writeNotes_idempotent" || return
    local wt; wt="$(setup_worktree_dest "i1-wt")"

    local snippet="
        const args = {
            worktreePath: process.argv[1],
            branch: 'feature/i',
            createdDate: '2024-01-15',
            resolvedPath: '/tmp/wt',
            baseDir: 'C:/git/worktrees',
            copiedFiles: ['a.env','b/.env.local']
        };
        lib.writeNotes(args);
        lib.writeNotes(args);
    "
    lib_eval "$snippet" "$wt" >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/i1-wt/WORKTREE_NOTES.md"
    if [ ! -f "$notes_file" ]; then
        fail "I1: WORKTREE_NOTES.md not created"
        return
    fi

    # Reference content
    local expected
    expected="$(printf '%s\n' \
        '# Worktree Notes' \
        'Branch: feature/i' \
        'Created: 2024-01-15' \
        'Path: /tmp/wt' \
        'WORKTREE_BASE_DIR: C:/git/worktrees' \
        '' \
        '## Gitignored files copied from main' \
        '- a.env' \
        '- b/.env.local' \
        '' \
        '## BugsFound' \
        '- (none)' \
        '' \
        '## RelatedTasks' \
        '- (none)' \
        '' \
        '## NextTasks' \
        '- (none)')"
    local actual; actual="$(cat "$notes_file")"
    if [ "$actual" = "$expected" ]; then
        pass "I1: writeNotes is idempotent (second call produces identical content)"
    else
        fail "I1: content differs after second call"
    fi
}

# ---- N4: appendExclude appends new pattern to existing file ----
test_N4_appendExclude_appends_to_existing() {
    require_lib "test_N4_appendExclude_appends_to_existing" || return
    local main; main="$(setup_main_repo "n4-main")"
    local main_node; main_node="$(node_path "$main")"

    # Pre-create exclude file with content
    mkdir -p "$main/.git/info"
    printf 'existing-pattern\n' > "$main/.git/info/exclude"

    local out
    out="$(lib_eval "
        const r = lib.appendExclude({
            mainRoot: process.argv[1],
            pattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" 2>/dev/null)"

    local added; added="$(json_field "$out" "excludeAdded")"
    if [ "$added" = "true" ] && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude" \
       && grep -q "^existing-pattern$" "$main/.git/info/exclude"; then
        pass "N4: appendExclude appends new pattern to existing exclude file"
    else
        fail "N4: appendExclude failed (out=$out)"
    fi
}

# ---- N5: appendExclude creates .git/info/ + exclude when missing ----
test_N5_appendExclude_creates_dir_and_file() {
    require_lib "test_N5_appendExclude_creates_dir_and_file" || return
    local main; main="$(setup_main_repo "n5-main")"
    local main_node; main_node="$(node_path "$main")"

    # Remove .git/info entirely (only .git remains)
    rm -rf "$main/.git/info"

    local out
    out="$(lib_eval "
        const r = lib.appendExclude({
            mainRoot: process.argv[1],
            pattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" 2>/dev/null)"

    local added; added="$(json_field "$out" "excludeAdded")"
    if [ "$added" = "true" ] && [ -d "$main/.git/info" ] \
       && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude"; then
        pass "N5: appendExclude creates .git/info/ dir and exclude file"
    else
        fail "N5: missing dir/file or pattern not added (out=$out)"
    fi
}

# ---- I2: appendExclude already-present → skip ----
test_I2_appendExclude_already_present() {
    require_lib "test_I2_appendExclude_already_present" || return
    local main; main="$(setup_main_repo "i2-main")"
    local main_node; main_node="$(node_path "$main")"
    mkdir -p "$main/.git/info"
    printf 'foo\nWORKTREE_NOTES.md\nbar\n' > "$main/.git/info/exclude"

    local before_md5
    before_md5="$(node -e "
        const c = require('crypto');
        const fs = require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$main/.git/info/exclude" 2>/dev/null)"

    local out
    out="$(lib_eval "
        const r = lib.appendExclude({
            mainRoot: process.argv[1],
            pattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" 2>/dev/null)"

    local added; added="$(json_field "$out" "excludeAdded")"
    local reason; reason="$(json_field "$out" "excludeSkipReason")"
    local after_md5
    after_md5="$(node -e "
        const c = require('crypto');
        const fs = require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$main/.git/info/exclude" 2>/dev/null)"

    if [ "$added" = "false" ] && [ "$reason" = "already-present" ] && [ "$before_md5" = "$after_md5" ]; then
        pass "I2: appendExclude when already present → excludeAdded=false, reason=already-present, file unchanged"
    else
        fail "I2: expected added=false reason=already-present, got added=$added reason=$reason (file changed: $before_md5 → $after_md5)"
    fi
}

# ---- Err1: appendExclude when .git is a file ----
test_Err1_appendExclude_git_is_file() {
    require_lib "test_Err1_appendExclude_git_is_file" || return
    local fake="$TMPDIR_BASE/err1-fake"
    mkdir -p "$fake"
    : > "$fake/.git"   # .git is a regular file
    local fake_node; fake_node="$(node_path "$fake")"

    local stderr
    stderr="$(lib_eval "
        try {
            lib.appendExclude({mainRoot: process.argv[1], pattern: 'WORKTREE_NOTES.md'});
            process.stdout.write('NOTHROW');
        } catch (e) {
            process.stderr.write(e.message);
        }
    " "$fake_node" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -qi "unexpected" && echo "$stderr" | grep -qi "is a file"; then
        pass "Err1: appendExclude throws when .git is a file (msg contains 'unexpected' + 'is a file')"
    else
        fail "Err1: expected throw mentioning 'unexpected' + 'is a file' (got: $stderr)"
    fi
}

# ---- Err2: appendExclude when .git missing ----
test_Err2_appendExclude_no_git_dir() {
    require_lib "test_Err2_appendExclude_no_git_dir" || return
    local fake="$TMPDIR_BASE/err2-fake"
    mkdir -p "$fake"   # no .git at all
    local fake_node; fake_node="$(node_path "$fake")"

    local stderr
    stderr="$(lib_eval "
        try {
            lib.appendExclude({mainRoot: process.argv[1], pattern: 'WORKTREE_NOTES.md'});
            process.stdout.write('NOTHROW');
        } catch (e) {
            process.stderr.write(e.message);
        }
    " "$fake_node" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -qi "no .git directory"; then
        pass "Err2: appendExclude throws when .git missing (msg contains 'no .git directory')"
    else
        fail "Err2: expected throw mentioning 'no .git directory' (got: $stderr)"
    fi
}

# ---- N6: run() happy path ----
test_N6_run_happy_path() {
    require_lib "test_N6_run_happy_path" || return
    local main; main="$(setup_main_repo "n6-main")"
    local wt;   wt="$(setup_worktree_dest "n6-wt")"
    local main_node; main_node="$(node_path "$main")"

    local out
    out="$(lib_eval "
        const r = lib.run({
            mainRoot: process.argv[1],
            worktreePath: process.argv[2],
            branch: 'feature/n6',
            createdDate: '2024-01-15',
            resolvedPath: process.argv[2],
            baseDir: null,
            copiedFiles: ['a.env'],
            excludePattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" "$wt" 2>/dev/null)"

    local notesWritten; notesWritten="$(json_field "$out" "notesWritten")"
    local excludeAdded; excludeAdded="$(json_field "$out" "excludeAdded")"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$notesWritten" = "true" ] && [ "$excludeAdded" = "true" ] && [ "$errors" = "[]" ]; then
        pass "N6: run() happy path → notesWritten=true, excludeAdded=true, errors=[]"
    else
        fail "N6: got notesWritten=$notesWritten excludeAdded=$excludeAdded errors=$errors (out=$out)"
    fi
}

# ---- I3: run() second call (idempotency) ----
test_I3_run_idempotent() {
    require_lib "test_I3_run_idempotent" || return
    local main; main="$(setup_main_repo "i3-main")"
    local wt;   wt="$(setup_worktree_dest "i3-wt")"
    local main_node; main_node="$(node_path "$main")"

    local out1 out2
    out1="$(lib_eval "
        const r = lib.run({
            mainRoot: process.argv[1],
            worktreePath: process.argv[2],
            branch: 'feature/i3',
            createdDate: '2024-01-15',
            resolvedPath: process.argv[2],
            baseDir: null,
            copiedFiles: ['a.env'],
            excludePattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" "$wt" 2>/dev/null)"

    local notes_file="$TMPDIR_BASE/i3-wt/WORKTREE_NOTES.md"
    local before_md5
    before_md5="$(node -e "
        const c=require('crypto'),fs=require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$notes_file" 2>/dev/null)"

    out2="$(lib_eval "
        const r = lib.run({
            mainRoot: process.argv[1],
            worktreePath: process.argv[2],
            branch: 'feature/i3',
            createdDate: '2024-01-15',
            resolvedPath: process.argv[2],
            baseDir: null,
            copiedFiles: ['a.env'],
            excludePattern: 'WORKTREE_NOTES.md'
        });
        process.stdout.write(JSON.stringify(r));
    " "$main_node" "$wt" 2>/dev/null)"

    local after_md5
    after_md5="$(node -e "
        const c=require('crypto'),fs=require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$notes_file" 2>/dev/null)"

    local notesWritten2; notesWritten2="$(json_field "$out2" "notesWritten")"
    local excludeAdded2; excludeAdded2="$(json_field "$out2" "excludeAdded")"
    local reason2; reason2="$(json_field "$out2" "excludeSkipReason")"
    local errors2; errors2="$(json_field "$out2" "errors")"

    if [ "$notesWritten2" = "true" ] && [ "$excludeAdded2" = "false" ] \
       && [ "$reason2" = "already-present" ] && [ "$errors2" = "[]" ] \
       && [ "$before_md5" = "$after_md5" ]; then
        pass "I3: run() second call idempotent (notesWritten=true, excludeAdded=false, reason=already-present, file unchanged)"
    else
        fail "I3: notesWritten=$notesWritten2 excludeAdded=$excludeAdded2 reason=$reason2 errors=$errors2 (md5 before=$before_md5 after=$after_md5)"
    fi
}

# ---- Sec1: run() traversal guard — copiedFiles ../etc/passwd ----
test_Sec1_run_traversal_in_copiedFiles() {
    require_lib "test_Sec1_run_traversal_in_copiedFiles" || return
    local main; main="$(setup_main_repo "sec1-main")"
    local wt;   wt="$(setup_worktree_dest "sec1-wt")"
    local main_node; main_node="$(node_path "$main")"

    local stderr
    stderr="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/sec1',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: ['../etc/passwd'],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$main_node" "$wt" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -q "^THROW:"; then
        pass "Sec1: run() traversal guard — copiedFiles '../etc/passwd' throws (not into errors[])"
    else
        fail "Sec1: expected throw, got: $stderr"
    fi
}

# ---- Sec2: run() traversal guard — mainRoot has .. ----
test_Sec2_run_traversal_in_mainRoot() {
    require_lib "test_Sec2_run_traversal_in_mainRoot" || return
    local wt; wt="$(setup_worktree_dest "sec2-wt")"

    local stderr
    stderr="$(lib_eval "
        try {
            const r = lib.run({
                mainRoot: process.argv[1],
                worktreePath: process.argv[2],
                branch: 'feature/sec2',
                createdDate: '2024-01-15',
                resolvedPath: process.argv[2],
                baseDir: null,
                copiedFiles: [],
                excludePattern: 'WORKTREE_NOTES.md'
            });
            process.stdout.write('NOTHROW:' + JSON.stringify(r));
        } catch (e) {
            process.stderr.write('THROW:' + e.message);
        }
    " "$TMPDIR_BASE/../bad/main" "$wt" 2>&1 >/dev/null)"

    if echo "$stderr" | grep -q "^THROW:"; then
        pass "Sec2: run() traversal guard — mainRoot with '..' throws"
    else
        fail "Sec2: expected throw, got: $stderr"
    fi
}

# ---- N7: CLI happy path ----
test_N7_cli_happy_path() {
    require_bin "test_N7_cli_happy_path" || return
    local main; main="$(setup_main_repo "n7-main")"
    local wt;   wt="$(setup_worktree_dest "n7-wt")"
    local main_node; main_node="$(node_path "$main")"

    local out; out="$(run_bin "$main_node" "$wt" "feature/n7" "" '{"copied":["a.env","b/.env.local"]}')"
    local code=$?
    local notesWritten; notesWritten="$(json_field "$out" "notesWritten")"
    local excludeAdded; excludeAdded="$(json_field "$out" "excludeAdded")"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$code" = "0" ] && [ "$notesWritten" = "true" ] && [ "$excludeAdded" = "true" ] \
       && [ "$errors" = "[]" ] && [ -f "$TMPDIR_BASE/n7-wt/WORKTREE_NOTES.md" ] \
       && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude"; then
        pass "N7: CLI happy path → exit 0, JSON ok, files created"
    else
        fail "N7: code=$code notesWritten=$notesWritten excludeAdded=$excludeAdded errors=$errors (out=$out)"
    fi
}

# ---- I4: CLI idempotency ----
test_I4_cli_idempotent() {
    require_bin "test_I4_cli_idempotent" || return
    local main; main="$(setup_main_repo "i4-main")"
    local wt;   wt="$(setup_worktree_dest "i4-wt")"
    local main_node; main_node="$(node_path "$main")"

    run_bin "$main_node" "$wt" "feature/i4" "" '{"copied":["a.env"]}' >/dev/null 2>&1
    local notes_file="$TMPDIR_BASE/i4-wt/WORKTREE_NOTES.md"
    local before_md5
    before_md5="$(node -e "
        const c=require('crypto'),fs=require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$notes_file" 2>/dev/null)"

    local code2; code2="$(run_bin_exitcode "$main_node" "$wt" "feature/i4" "" '{"copied":["a.env"]}')"
    local out2; out2="$(run_bin "$main_node" "$wt" "feature/i4" "" '{"copied":["a.env"]}')"
    local excludeAdded2; excludeAdded2="$(json_field "$out2" "excludeAdded")"
    local reason2; reason2="$(json_field "$out2" "excludeSkipReason")"

    local after_md5
    after_md5="$(node -e "
        const c=require('crypto'),fs=require('fs');
        process.stdout.write(c.createHash('md5').update(fs.readFileSync(process.argv[1])).digest('hex'));
    " -- "$notes_file" 2>/dev/null)"

    if [ "$code2" = "0" ] && [ "$excludeAdded2" = "false" ] && [ "$reason2" = "already-present" ] \
       && [ "$before_md5" = "$after_md5" ]; then
        pass "I4: CLI second run → exit 0, excludeAdded=false, reason=already-present, content unchanged"
    else
        fail "I4: code=$code2 excludeAdded=$excludeAdded2 reason=$reason2 (md5 before=$before_md5 after=$after_md5)"
    fi
}

# ---- Err3: CLI invalid COPIED_JSON ----
test_Err3_cli_invalid_copied_json() {
    require_bin "test_Err3_cli_invalid_copied_json" || return
    local main; main="$(setup_main_repo "err3-main")"
    local wt;   wt="$(setup_worktree_dest "err3-wt")"
    local main_node; main_node="$(node_path "$main")"

    local code; code="$(run_bin_exitcode "$main_node" "$wt" "feature/err3" "" 'this is not json')"
    local errmsg; errmsg="$(run_bin_stderr "$main_node" "$wt" "feature/err3" "" 'this is not json')"

    if [ "$code" != "0" ] && [ -n "$errmsg" ]; then
        pass "Err3: CLI invalid COPIED_JSON → exit 1, stderr non-empty"
    else
        fail "Err3: expected non-zero exit + stderr, got code=$code stderr=$errmsg"
    fi
}

# ---- Err4: CLI missing branch (positional arg) ----
test_Err4_cli_missing_branch() {
    require_bin "test_Err4_cli_missing_branch" || return
    local main; main="$(setup_main_repo "err4-main")"
    local wt;   wt="$(setup_worktree_dest "err4-wt")"
    local main_node; main_node="$(node_path "$main")"

    # branch argv is empty → CLI prints usage to stderr and exits 1
    local code; code="$(run_bin_exitcode "$main_node" "$wt" "")"
    local errmsg; errmsg="$(run_bin_stderr "$main_node" "$wt" "")"

    if [ "$code" != "0" ] && echo "$errmsg" | grep -qi "branch\|usage"; then
        pass "Err4: CLI missing branch arg → exit non-zero, usage mentions branch"
    else
        fail "Err4: code=$code stderr=$errmsg"
    fi
}

# ---- Err5: CLI notesWritten failure ----
test_Err5_cli_notesWritten_failure() {
    require_bin "test_Err5_cli_notesWritten_failure" || return
    local main; main="$(setup_main_repo "err5-main")"
    local main_node; main_node="$(node_path "$main")"
    # worktreePath under an existing FILE — mkdirSync recursive fails
    local block_file="$TMPDIR_BASE/err5-block"
    : > "$block_file"
    local bad_wt="${block_file}/cannot/create/here"
    local bad_wt_node; bad_wt_node="$(node_path "$bad_wt")"

    local code; code="$(run_bin_exitcode "$main_node" "$bad_wt_node" "feature/err5" "" '{"copied":[]}')"
    local out; out="$(run_bin "$main_node" "$bad_wt_node" "feature/err5" "" '{"copied":[]}')"
    local errors; errors="$(json_field "$out" "errors")"

    if [ "$code" != "0" ]; then
        pass "Err5: CLI notesWritten failure → exit non-zero (errors=$errors)"
    else
        fail "Err5: expected non-zero exit, got code=$code errors=$errors"
    fi
}

# ---- N8: WORKTREE_BASE_DIR env unset → "(default)" ----
test_N8_env_unset_defaults() {
    require_bin "test_N8_env_unset_defaults" || return
    local main; main="$(setup_main_repo "n8-main")"
    local wt;   wt="$(setup_worktree_dest "n8-wt")"
    local main_node; main_node="$(node_path "$main")"

    (
        unset WORKTREE_BASE_DIR
        COPIED_JSON='{"copied":[]}' run_with_timeout 120 node "$BIN_JS" "$main_node" "$wt" "feature/n8" "" >/dev/null 2>&1
    )

    local notes_file="$TMPDIR_BASE/n8-wt/WORKTREE_NOTES.md"
    if grep -q "^WORKTREE_BASE_DIR: (default)$" "$notes_file" 2>/dev/null; then
        pass "N8: WORKTREE_BASE_DIR env unset → '(default)'"
    else
        fail "N8: '(default)' line not found in $notes_file"
    fi
}

# ---- N9: WORKTREE_BASE_DIR env set → that value ----
test_N9_env_set_uses_value() {
    require_bin "test_N9_env_set_uses_value" || return
    local main; main="$(setup_main_repo "n9-main")"
    local wt;   wt="$(setup_worktree_dest "n9-wt")"
    local main_node; main_node="$(node_path "$main")"

    (
        export WORKTREE_BASE_DIR="C:/custom/path"
        COPIED_JSON='{"copied":[]}' run_with_timeout 120 node "$BIN_JS" "$main_node" "$wt" "feature/n9" "" >/dev/null 2>&1
    )

    local notes_file="$TMPDIR_BASE/n9-wt/WORKTREE_NOTES.md"
    if grep -q "^WORKTREE_BASE_DIR: C:/custom/path$" "$notes_file" 2>/dev/null; then
        pass "N9: WORKTREE_BASE_DIR='C:/custom/path' → recorded in notes"
    else
        fail "N9: expected 'WORKTREE_BASE_DIR: C:/custom/path' in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- CMD1: SKILL.md POSIX template (plain filenames) ----
test_CMD1_skill_template_basic() {
    require_bin "test_CMD1_skill_template_basic" || return
    local main; main="$(setup_main_repo "cmd1-main")"
    local wt;   wt="$(setup_worktree_dest "cmd1-wt")"
    local main_node; main_node="$(node_path "$main")"

    # SKILL.md POSIX form — verbatim what users invoke.
    bash -c "
        COPIED_JSON='{\"copied\":[\"foo.env\",\"bar.local\"],\"skipped\":[],\"denied\":[],\"errors\":[]}' \
        node '$BIN_JS' '$main_node' '$wt' 'feature/test'
    " >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/cmd1-wt/WORKTREE_NOTES.md"
    if [ -f "$notes_file" ] \
       && grep -q "^- foo.env$" "$notes_file" \
       && grep -q "^- bar.local$" "$notes_file" \
       && grep -q "^WORKTREE_NOTES.md$" "$main/.git/info/exclude"; then
        pass "CMD1: SKILL.md POSIX template → notes contains foo.env+bar.local, exclude has WORKTREE_NOTES.md"
    else
        fail "CMD1: notes/exclude not as expected (notes content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- CMD2: filename with spaces ----
test_CMD2_skill_template_filename_with_spaces() {
    require_bin "test_CMD2_skill_template_filename_with_spaces" || return
    local main; main="$(setup_main_repo "cmd2-main")"
    local wt;   wt="$(setup_worktree_dest "cmd2-wt")"
    local main_node; main_node="$(node_path "$main")"

    bash -c "
        COPIED_JSON='{\"copied\":[\"my file.env\"]}' \
        node '$BIN_JS' '$main_node' '$wt' 'feature/test'
    " >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/cmd2-wt/WORKTREE_NOTES.md"
    if [ -f "$notes_file" ] && grep -q "^- my file\.env$" "$notes_file"; then
        pass "CMD2: filename with spaces → '- my file.env' in notes"
    else
        fail "CMD2: '- my file.env' not in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ---- CMD3: Windows-style backslash path ----
test_CMD3_skill_template_windows_path() {
    require_bin "test_CMD3_skill_template_windows_path" || return
    local main; main="$(setup_main_repo "cmd3-main")"
    local wt;   wt="$(setup_worktree_dest "cmd3-wt")"
    local main_node; main_node="$(node_path "$main")"

    # JSON literal: "sub\\dir\\file" → after JSON.parse → "sub\dir\file".
    bash -c "
        COPIED_JSON='{\"copied\":[\"sub\\\\dir\\\\file\"]}' \
        node '$BIN_JS' '$main_node' '$wt' 'feature/test'
    " >/dev/null 2>&1

    local notes_file="$TMPDIR_BASE/cmd3-wt/WORKTREE_NOTES.md"
    if [ -f "$notes_file" ] && grep -F -q -e '- sub\dir\file' "$notes_file"; then
        pass "CMD3: Windows-style path 'sub\\dir\\file' → recorded as-is"
    else
        fail "CMD3: '- sub\\dir\\file' not in $notes_file (content: $(cat "$notes_file" 2>/dev/null))"
    fi
}

# ============ Run all ============

test_N1_writeNotes_exact_content
test_N2_writeNotes_empty_copied_renders_none
test_N3_writeNotes_null_baseDir_renders_default
test_I1_writeNotes_idempotent
test_N4_appendExclude_appends_to_existing
test_N5_appendExclude_creates_dir_and_file
test_I2_appendExclude_already_present
test_Err1_appendExclude_git_is_file
test_Err2_appendExclude_no_git_dir
test_N6_run_happy_path
test_I3_run_idempotent
test_Sec1_run_traversal_in_copiedFiles
test_Sec2_run_traversal_in_mainRoot
test_N7_cli_happy_path
test_I4_cli_idempotent
test_Err3_cli_invalid_copied_json
test_Err4_cli_missing_branch
test_Err5_cli_notesWritten_failure
test_N8_env_unset_defaults
test_N9_env_set_uses_value
test_CMD1_skill_template_basic
test_CMD2_skill_template_filename_with_spaces
test_CMD3_skill_template_windows_path

echo ""
echo "Results: $PASS passed, $FAIL failed"
echo "Total: PASS=$PASS FAIL=$FAIL"

exit $FAIL
