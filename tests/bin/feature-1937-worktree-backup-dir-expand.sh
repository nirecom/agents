#!/usr/bin/env bash
# tests/bin/feature-1937-worktree-backup-dir-expand.sh
# Tests: bin/worker-dispatch/workers/worktree-backup.js, bin/worker-dispatch.js
# Tags: worker-dispatch, worktree-backup, dir_expand, read-budget, enumeration-budget, TL2, scope:issue-specific
#
# Issue #1937: gitignored directories are lost when a worktree is deleted. With
# dir_expand:true the backup worker expands a gitignored directory into its files
# (recursively), under read + enumeration budgets, and warns on anything NOT
# preserved. With dir_expand off/omitted the current skip-and-partial behaviour is
# preserved verbatim. TL3 gap: real NTFS junctions, real docker bind mounts, and
# mkfifo-less OSes — checked at WORKFLOW_USER_VERIFIED preflight.

set -u

if command -v timeout >/dev/null 2>&1 && [ -z "${_WT1937_INNER:-}" ]; then
    _WT1937_INNER=1 timeout 420 bash "$0" "$@"
    exit $?
fi

AGENTS_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
DISPATCH_JS="$AGENTS_DIR/bin/worker-dispatch.js"
nodepath() { if command -v cygpath >/dev/null 2>&1; then cygpath -m "$1"; else echo "$1"; fi; }

PASS=0
FAIL=0
pass() { echo "PASS: $1"; PASS=$((PASS + 1)); }
fail() { echo "FAIL: $1"; [ -n "${2:-}" ] && echo "    detail: $2"; FAIL=$((FAIL + 1)); }
skip() { echo "SKIP: $1 — $2"; }
assert_eq() {
    local name="$1" want="$2" got="$3"
    if [ "$want" = "$got" ]; then pass "$name"
    else fail "$name" "want=$(printf '%q' "$want") got=$(printf '%q' "$got")"; fi
}
run_with_timeout() {
    local secs="$1"; shift
    if command -v timeout >/dev/null 2>&1; then timeout "$secs" "$@"
    else perl -e 'alarm shift; exec @ARGV' "$secs" "$@"; fi
}

if [ ! -f "$DISPATCH_JS" ]; then
    fail "0-dispatcher-present" "$DISPATCH_JS"
    echo ""
    echo "Total: PASS=$PASS FAIL=$FAIL"
    exit 1
fi

TMPD="$(mktemp -d 2>/dev/null || echo "${TMPDIR:-/tmp}/wt-1937-$$")"
mkdir -p "$TMPD"
trap 'rm -rf "$TMPD"' EXIT
PLANS_RAW="$TMPD/plans"; mkdir -p "$PLANS_RAW"
PLANS="$(nodepath "$PLANS_RAW")"

# Capability probes — some cases need real symlinks or a FIFO.
SYMLINK_OK=0
if ln -s "$TMPD" "$TMPD/.slink-probe" 2>/dev/null && [ -L "$TMPD/.slink-probe" ]; then SYMLINK_OK=1; fi
rm -f "$TMPD/.slink-probe" 2>/dev/null
FIFO_OK=0
if command -v mkfifo >/dev/null 2>&1 && mkfifo "$TMPD/.fifo-probe" 2>/dev/null; then
    if node -e 'try{const s=require("fs").lstatSync(process.argv[1]);process.exit(s.isFile()?1:0)}catch(e){process.exit(1)}' "$TMPD/.fifo-probe" 2>/dev/null; then
        FIFO_OK=1
    fi
fi
rm -f "$TMPD/.fifo-probe" 2>/dev/null

# mk <case-tag> <gitignore-with-\n> — fresh main repo + one linked worktree.
# Sets MAIN_RAW / LINKED_RAW / BRANCH / MAIN / LINKED / BACKUP_RAW globals.
mk() {
    CROOT="$TMPD/$1"
    MAIN_RAW="$CROOT/main"; LINKED_RAW="$CROOT/wt"; BRANCH="feature/$1"
    mkdir -p "$MAIN_RAW"
    git -C "$MAIN_RAW" init -q -b main
    git -C "$MAIN_RAW" config user.email "test@example.com"
    git -C "$MAIN_RAW" config user.name "Test"
    git -C "$MAIN_RAW" config core.hooksPath /dev/null
    printf '%b' "$2" > "$MAIN_RAW/.gitignore"
    echo init > "$MAIN_RAW/README.md"
    git -C "$MAIN_RAW" add .gitignore README.md >/dev/null 2>&1
    git -C "$MAIN_RAW" commit -q --no-verify -m init >/dev/null 2>&1
    git -C "$MAIN_RAW" worktree add -q -b "$BRANCH" "$LINKED_RAW" >/dev/null 2>&1
    MAIN="$(nodepath "$MAIN_RAW")"; LINKED="$(nodepath "$LINKED_RAW")"
    BACKUP_RAW="$MAIN_RAW/.worktree-backup/$BRANCH"
}

DOUT=""; DRC=0
# dispatch <payload-json> [ENV=VAL ...] — run the backup worker.
dispatch() {
    local payload="$1"; shift
    printf '%s' "$payload" > "$PLANS_RAW/p.json"
    DRC=0
    DOUT="$(run_with_timeout 90 env "WORKFLOW_PLANS_DIR=$PLANS" "$@" \
        node "$(nodepath "$DISPATCH_JS")" worktree-backup "$MAIN" "$(nodepath "$PLANS_RAW/p.json")" 2>/dev/null)" || DRC=$?
}
field_of() {
    local v
    v="$(printf '%s\n' "$DOUT" | sed -n "s/^$1: //p" | head -1)"
    v="${v%\"}"; v="${v#\"}"
    printf '%s' "$v"
}
summary_has() { case "$(field_of summary)" in *"$1"*) return 0 ;; *) return 1 ;; esac; }
manifest_paths() {
    node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write((m.files||[]).map(f=>f.path).sort().join(","))}catch(e){process.stdout.write("(no-manifest)")}' \
        "$(nodepath "$BACKUP_RAW/manifest.json")" 2>/dev/null
}
manifest_issues() {
    node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(JSON.stringify(m.issues||[]))}catch(e){process.stdout.write("(no-manifest)")}' \
        "$(nodepath "$BACKUP_RAW/manifest.json")" 2>/dev/null
}
paths_has() { case ",$(manifest_paths)," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

# Common payload builder: EXEC_P <extra-json-fields> → full execute payload.
EXEC_P() { printf '{"mode":"execute","worktree_path":"%s","branch":"%s","docker_check":false,"artifact_dir":"%s"%s}' "$LINKED" "$BRANCH" "$PLANS" "$1"; }

# ===========================================================================
# Case 1 — dir_expand OMITTED: an opaque gitignored dir is skipped -> partial,
#   its contents absent, the sibling gitignored file still copied. PASSES today
#   (the backward-compatibility pin).
# ===========================================================================
case_1_backward_compat() {
    mk c1 'state/\nkeep.txt\n'
    printf 'KEEP\n' > "$LINKED_RAW/keep.txt"
    mkdir -p "$LINKED_RAW/state"
    git -C "$LINKED_RAW/state" init -q -b main   # embedded repo => opaque dir entry
    git -C "$LINKED_RAW/state" config core.hooksPath /dev/null
    printf 'LOST\n' > "$LINKED_RAW/state/inner.txt"
    dispatch "$(EXEC_P '')"
    assert_eq "c1/status-partial" "partial" "$(field_of status)"
    if paths_has "keep.txt"; then pass "c1/sibling-file-copied"; else fail "c1/sibling-file-copied" "paths=$(manifest_paths)"; fi
    if paths_has "state/inner.txt"; then fail "c1/dir-contents-not-copied" "state/inner.txt present"; else pass "c1/dir-contents-not-copied"; fi
}

# ===========================================================================
# Case 2 — dir_expand:true expands a plain gitignored dir into its files.
# ===========================================================================
case_2_expand_true() {
    mk c2 'state/\n'
    mkdir -p "$LINKED_RAW/state/sub"
    printf 'AAA\n' > "$LINKED_RAW/state/a.txt"
    printf 'BBB\n' > "$LINKED_RAW/state/sub/b.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')"
    assert_eq "c2/status-copied" "copied" "$(field_of status)"
    if paths_has "state/a.txt"; then pass "c2/top-file-expanded"; else fail "c2/top-file-expanded" "paths=$(manifest_paths)"; fi
    if paths_has "state/sub/b.txt"; then pass "c2/nested-file-expanded"; else fail "c2/nested-file-expanded" "paths=$(manifest_paths)"; fi
    # data integrity: backup bytes must match source bytes
    if [ -f "$BACKUP_RAW/state/a.txt" ]; then
        assert_eq "c2/top-file-content" "AAA" "$(cat "$BACKUP_RAW/state/a.txt")"
    else
        fail "c2/top-file-content" "backup not found: $BACKUP_RAW/state/a.txt"
    fi
    if [ -f "$BACKUP_RAW/state/sub/b.txt" ]; then
        assert_eq "c2/nested-file-content" "BBB" "$(cat "$BACKUP_RAW/state/sub/b.txt")"
    else
        fail "c2/nested-file-content" "backup not found: $BACKUP_RAW/state/sub/b.txt"
    fi
}

# ===========================================================================
# Case 3 — manifest paths are forward-slash normalized regardless of nesting.
# ===========================================================================
case_3_forward_slash() {
    mk c3 'state/\n'
    mkdir -p "$LINKED_RAW/state/deep/deeper"
    printf 'X\n' > "$LINKED_RAW/state/deep/deeper/c.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')"
    case "$(manifest_paths)" in
        *"state/deep/deeper/c.txt"*) pass "c3/forward-slash-nested-path" ;;
        *"\\"*) fail "c3/forward-slash-nested-path" "backslash in paths=$(manifest_paths)" ;;
        *) fail "c3/forward-slash-nested-path" "nested path missing: $(manifest_paths)" ;;
    esac
}

# ===========================================================================
# Case 4 — [BUDGET] a single over-limit file is not read/preserved -> partial.
# ===========================================================================
case_4_single_huge() {
    mk c4 'state/\n'
    mkdir -p "$LINKED_RAW/state"
    printf 'AAAAAAAAAA\n' > "$LINKED_RAW/state/big.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_BYTES=1"
    assert_eq "c4/status-partial" "partial" "$(field_of status)"
    if summary_has "NOT preserved"; then pass "c4/summary-warns-not-preserved"; else fail "c4/summary-warns-not-preserved" "summary='$(field_of summary)'"; fi
}

# ===========================================================================
# Case 5 — [BUDGET] cumulative FILE COUNT across dirs trips the shared budget.
# ===========================================================================
case_5_file_count() {
    mk c5 'd1/\nd2/\n'
    mkdir -p "$LINKED_RAW/d1" "$LINKED_RAW/d2"
    printf 'a\n' > "$LINKED_RAW/d1/a.txt"
    printf 'b\n' > "$LINKED_RAW/d1/b.txt"
    printf 'c\n' > "$LINKED_RAW/d2/c.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_FILES=2"
    assert_eq "c5/status-partial" "partial" "$(field_of status)"
    case "$(manifest_issues)" in
        *"budget cap reached"*) pass "c5/issue-budget-cap-reached" ;;
        *) fail "c5/issue-budget-cap-reached" "issues=$(manifest_issues)" ;;
    esac
    if summary_has "NOT preserved"; then pass "c5/summary-warns-not-preserved"; else fail "c5/summary-warns-not-preserved" "summary='$(field_of summary)'"; fi
}

# ===========================================================================
# Case 6 — [BUDGET] a worktree-internal symlink-to-file must be counted, not
#   read past the budget (regression pin). Needs real symlinks.
# ===========================================================================
case_6_symlink_budget() {
    if [ "$SYMLINK_OK" -ne 1 ]; then skip "c6/symlink-budget" "no real symlink support"; return; fi
    mk c6 'state/\n'
    mkdir -p "$LINKED_RAW/state"
    printf 'BIGCONTENT\n' > "$LINKED_RAW/state/reg.txt"
    ln -s "reg.txt" "$LINKED_RAW/state/link.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_BYTES=1"
    assert_eq "c6/status-partial" "partial" "$(field_of status)"
    if summary_has "NOT preserved"; then pass "c6/summary-warns-not-preserved"; else fail "c6/summary-warns-not-preserved" "summary='$(field_of summary)'"; fi
}

# ===========================================================================
# Case 7 — [C1] over-limit LEGACY input with dir_expand OFF: budgets do NOT
#   apply, every file copies, no NOT-preserved warning. PASSES today.
# ===========================================================================
case_7_legacy_no_budget() {
    mk c7 'sa.txt\nsb.txt\nsc.txt\n'
    printf 'A\n' > "$LINKED_RAW/sa.txt"
    printf 'B\n' > "$LINKED_RAW/sb.txt"
    printf 'C\n' > "$LINKED_RAW/sc.txt"
    dispatch "$(EXEC_P '')" "WORKTREE_BACKUP_MAX_FILES=1" "WORKTREE_BACKUP_MAX_BYTES=1"
    assert_eq "c7/status-copied" "copied" "$(field_of status)"
    if paths_has "sa.txt" && paths_has "sb.txt" && paths_has "sc.txt"; then pass "c7/all-files-copied-despite-caps"
    else fail "c7/all-files-copied-despite-caps" "paths=$(manifest_paths)"; fi
    if summary_has "NOT preserved"; then fail "c7/no-warning-when-off" "summary='$(field_of summary)'"; else pass "c7/no-warning-when-off"; fi
}

# ===========================================================================
# Case 8 — [C2] a non-regular file (FIFO) is skipped with an issue, regular
#   siblings still copy, worktree-end is not blocked. Needs mkfifo.
# ===========================================================================
case_8_non_regular() {
    if [ "$FIFO_OK" -ne 1 ]; then skip "c8/non-regular-file" "no mkfifo support"; return; fi
    mk c8 'state/\n'
    mkdir -p "$LINKED_RAW/state"
    printf 'REG\n' > "$LINKED_RAW/state/reg.txt"
    mkfifo "$LINKED_RAW/state/pipe" 2>/dev/null
    dispatch "$(EXEC_P ',"dir_expand":true')"
    assert_eq "c8/status-partial" "partial" "$(field_of status)"
    if paths_has "state/reg.txt"; then pass "c8/regular-sibling-copied"; else fail "c8/regular-sibling-copied" "paths=$(manifest_paths)"; fi
    case "$(manifest_issues)" in
        *"non-regular file skipped"*) pass "c8/issue-non-regular-skipped" ;;
        *) fail "c8/issue-non-regular-skipped" "issues=$(manifest_issues)" ;;
    esac
}

# ===========================================================================
# Case 9 — [C3] the enumeration budget is ONE counter shared across all dirs;
#   3 dirs x 3 files = 9 > cap 5 truncates and records exactly one issue.
# ===========================================================================
case_9_enumeration_budget() {
    mk c9 'e1/\ne2/\ne3/\n'
    local d f
    for d in e1 e2 e3; do
        mkdir -p "$LINKED_RAW/$d"
        for f in 1 2 3; do printf 'x\n' > "$LINKED_RAW/$d/f$f.txt"; done
    done
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_ENUMERATE=5"
    assert_eq "c9/status-partial" "partial" "$(field_of status)"
    local n
    n="$(node -e 'try{const m=JSON.parse(require("fs").readFileSync(process.argv[1],"utf8"));process.stdout.write(String((m.issues||[]).filter(s=>String(s).indexOf("enumeration budget reached")>=0).length))}catch(e){process.stdout.write("-1")}' "$(nodepath "$BACKUP_RAW/manifest.json")" 2>/dev/null)"
    assert_eq "c9/enumeration-issue-recorded-exactly-once" "1" "$n"
}

# ===========================================================================
# Case 10 — [ZEROFILE] zero regular files preserved but issues exist -> the
#   status is "partial" (a manifest is written), never "skipped".
# ===========================================================================
case_10_zerofile_partial() {
    mk c10 'state/\n'
    mkdir -p "$LINKED_RAW/state"
    printf 'AAAA\n' > "$LINKED_RAW/state/only.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_BYTES=1"
    assert_eq "c10/status-partial-not-skipped" "partial" "$(field_of status)"
    if [ -f "$BACKUP_RAW/manifest.json" ]; then pass "c10/manifest-written-despite-zero-files"
    else fail "c10/manifest-written-despite-zero-files" "no manifest at $BACKUP_RAW"; fi
    if summary_has "NOT preserved"; then pass "c10/summary-warns-not-preserved"; else fail "c10/summary-warns-not-preserved" "summary='$(field_of summary)'"; fi
}

# ===========================================================================
# Case 11 — [2PASS] execute re-inventories at the authoritative moment; a file
#   added AFTER dry_run is still preserved by execute (Pass 2 is not bound to
#   Pass 1's set). dir_expand omitted, so this PASSES today.
# ===========================================================================
case_11_live_reinventory() {
    mk c11 'late.txt\n'
    dispatch "{\"mode\":\"dry_run\",\"worktree_path\":\"$LINKED\",\"branch\":\"$BRANCH\",\"docker_check\":false,\"artifact_dir\":\"$PLANS\"}"
    assert_eq "c11/dry-run-ok" "dry_run_complete" "$(field_of status)"
    printf 'LATECONTENT\n' > "$LINKED_RAW/late.txt"   # appears only after Pass 1
    dispatch "$(EXEC_P '')"
    if paths_has "late.txt"; then pass "c11/execute-preserves-post-dry-run-file"; else fail "c11/execute-preserves-post-dry-run-file" "paths=$(manifest_paths)"; fi
}

# ===========================================================================
# Case 12 — a symlinked directory inside an expanded dir is not recursed into
#   (no escape): the sibling real file copies, the symlink target's out-of-tree
#   content never enters the backup. Needs real symlinks.
# ===========================================================================
case_12_symlink_dir_no_escape() {
    if [ "$SYMLINK_OK" -ne 1 ]; then skip "c12/symlink-dir-no-escape" "no real symlink support"; return; fi
    mk c12 'state/\n'
    mkdir -p "$LINKED_RAW/state" "$CROOT/outside"
    printf 'REAL\n' > "$LINKED_RAW/state/real.txt"
    printf 'ESCAPED-SECRET\n' > "$CROOT/outside/secret.txt"
    ln -s "$CROOT/outside" "$LINKED_RAW/state/link"
    dispatch "$(EXEC_P ',"dir_expand":true')"
    if [ "$(field_of status)" != "failed" ]; then pass "c12/expansion-ran"; else fail "c12/expansion-ran" "status=failed summary='$(field_of summary)'"; fi
    if paths_has "state/real.txt"; then pass "c12/real-sibling-copied"; else fail "c12/real-sibling-copied" "paths=$(manifest_paths)"; fi
    if grep -rqF "ESCAPED-SECRET" "$BACKUP_RAW" 2>/dev/null; then fail "c12/no-symlink-escape" "out-of-tree content entered backup"
    else pass "c12/no-symlink-escape"; fi
}

# ===========================================================================
# Case 13 — [C5] dir and its child both gitignored: expand deduplicates them.
# ===========================================================================
case_13_dup_gitignore() {
    mk c13 'state/\nstate/a.txt\n'
    mkdir -p "$LINKED_RAW/state"
    printf 'AAA\n' > "$LINKED_RAW/state/a.txt"
    printf 'BBB\n' > "$LINKED_RAW/state/b.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')"
    # state/ expands to state/a.txt and state/b.txt; no error from duplicate listing
    case "$(field_of status)" in
        copied|partial) pass "c13/status-not-failed" ;;
        *) fail "c13/status-not-failed" "status=$(field_of status)" ;;
    esac
    if paths_has "state/b.txt"; then pass "c13/non-dup-file-expanded"; else fail "c13/non-dup-file-expanded" "paths=$(manifest_paths)"; fi
    # state/a.txt must appear exactly once — dedup of parent dir + child entry
    local cnt_a
    cnt_a="$(manifest_paths | tr ',' '\n' | grep -c '^state/a\.txt$' 2>/dev/null || echo 0)"
    assert_eq "c13/a.txt-deduped-once" "1" "$cnt_a"
    # verify data integrity: backed-up file content matches source (fail if not copied)
    if [ -f "$BACKUP_RAW/state/a.txt" ]; then
        local got_content
        got_content="$(cat "$BACKUP_RAW/state/a.txt")"
        assert_eq "c13/file-content-intact" "AAA" "$got_content"
    else
        fail "c13/file-content-intact" "backup file not found at $BACKUP_RAW/state/a.txt"
    fi
}

# ===========================================================================
# Case 14 — [C6] budget boundary: exactly-at-limit is preserved, over is not.
# ===========================================================================
case_14_budget_boundary() {
    # Byte boundary: cap=5, file1=5 bytes (kept), file2=3 bytes (cut, 5+3>5)
    mk c14b 'd1/\n'
    mkdir -p "$LINKED_RAW/d1"
    printf 'XXXXX' > "$LINKED_RAW/d1/at-limit.txt"   # 5 bytes
    printf 'YYY' > "$LINKED_RAW/d1/over.txt"          # 3 bytes
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_BYTES=5"
    assert_eq "c14b/status-partial" "partial" "$(field_of status)"
    if paths_has "d1/at-limit.txt"; then pass "c14b/at-limit-preserved"; else fail "c14b/at-limit-preserved" "paths=$(manifest_paths)"; fi
    if paths_has "d1/over.txt"; then fail "c14b/over-limit-cut" "over.txt present"; else pass "c14b/over-limit-cut"; fi

    # File count boundary: cap=2, 2 files (kept), 3rd file (cut)
    mk c14f 'e1/\n'
    mkdir -p "$LINKED_RAW/e1"
    printf 'a\n' > "$LINKED_RAW/e1/f1.txt"
    printf 'b\n' > "$LINKED_RAW/e1/f2.txt"
    printf 'c\n' > "$LINKED_RAW/e1/f3.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_FILES=2"
    assert_eq "c14f/status-partial" "partial" "$(field_of status)"
    local cnt
    cnt="$(manifest_paths | tr ',' '\n' | grep -c 'e1/' 2>/dev/null || echo 0)"
    assert_eq "c14f/exactly-2-files-kept" "2" "$cnt"
}

# ===========================================================================
# Case 15 — [C6] enumeration budget boundary: exactly-at-limit passes, +1 is partial.
# ===========================================================================
case_15_enumerate_boundary() {
    # at-limit: cap=3, 3 expanded files → all enumerated, status copied/partial(ok)
    mk c15a 'ef/\n'
    mkdir -p "$LINKED_RAW/ef"
    printf 'a\n' > "$LINKED_RAW/ef/f1.txt"
    printf 'b\n' > "$LINKED_RAW/ef/f2.txt"
    printf 'c\n' > "$LINKED_RAW/ef/f3.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_ENUMERATE=3"
    case "$(field_of status)" in
        copied|partial) pass "c15a/at-limit-ok" ;;
        *) fail "c15a/at-limit-ok" "status=$(field_of status)" ;;
    esac

    # over-limit: cap=3, 4 expanded files → enumeration cut after 3, status partial
    mk c15b 'eg/\n'
    mkdir -p "$LINKED_RAW/eg"
    printf 'a\n' > "$LINKED_RAW/eg/f1.txt"
    printf 'b\n' > "$LINKED_RAW/eg/f2.txt"
    printf 'c\n' > "$LINKED_RAW/eg/f3.txt"
    printf 'd\n' > "$LINKED_RAW/eg/f4.txt"
    dispatch "$(EXEC_P ',"dir_expand":true')" "WORKTREE_BACKUP_MAX_ENUMERATE=3"
    assert_eq "c15b/over-limit-partial" "partial" "$(field_of status)"
}

# ===========================================================================
# Case 16 — [C2] dir_expand EXPLICIT FALSE: same backward-compat as omitted.
# ===========================================================================
case_16_dir_expand_explicit_false() {
    mk c16 'state/\nkeep.txt\n'
    mkdir -p "$LINKED_RAW/state"
    printf 'SECRET\n' > "$LINKED_RAW/state/secret.txt"
    printf 'KEEP\n' > "$LINKED_RAW/keep.txt"
    dispatch "$(EXEC_P ',"dir_expand":false')"
    # explicit false → backward-compat: git ls-files returns individual files inside
    # plain (non-opaque) ignored directories, so state/secret.txt is still copied.
    # Only opaque dirs (embedded git repo, as in case c1) are skipped as a directory.
    case "$(field_of status)" in
        copied|partial) pass "c16/status-not-failed" ;;
        *) fail "c16/status-not-failed" "status=$(field_of status)" ;;
    esac
    if paths_has "state/secret.txt"; then pass "c16/plain-dir-file-copied"; else fail "c16/plain-dir-file-copied" "state/secret.txt absent — plain dir files should be copied when dir_expand off"; fi
    if paths_has "keep.txt"; then pass "c16/sibling-file-copied"; else fail "c16/sibling-file-copied" "keep.txt absent from manifest"; fi
}

case_begin() { echo "--- case: $1 ($2) ---"; }
case_end() { :; }

case_begin "c1-backward-compat" "bin/worker-dispatch/workers/worktree-backup.js"
case_1_backward_compat
case_end

case_begin "c2-expand-true" "bin/worker-dispatch/workers/worktree-backup.js"
case_2_expand_true
case_end

case_begin "c3-forward-slash" "bin/worker-dispatch/workers/worktree-backup.js"
case_3_forward_slash
case_end

case_begin "c4-single-huge" "bin/worker-dispatch/workers/worktree-backup.js"
case_4_single_huge
case_end

case_begin "c5-file-count" "bin/worker-dispatch/workers/worktree-backup.js"
case_5_file_count
case_end

case_begin "c6-symlink-budget" "bin/worker-dispatch/workers/worktree-backup.js"
case_6_symlink_budget
case_end

case_begin "c7-legacy-no-budget" "bin/worker-dispatch/workers/worktree-backup.js"
case_7_legacy_no_budget
case_end

case_begin "c8-non-regular" "bin/worker-dispatch/workers/worktree-backup.js"
case_8_non_regular
case_end

case_begin "c9-enumeration-budget" "bin/worker-dispatch/workers/worktree-backup.js"
case_9_enumeration_budget
case_end

case_begin "c10-zerofile-partial" "bin/worker-dispatch/workers/worktree-backup.js"
case_10_zerofile_partial
case_end

case_begin "c11-live-reinventory" "bin/worker-dispatch/workers/worktree-backup.js"
case_11_live_reinventory
case_end

case_begin "c12-symlink-dir-no-escape" "bin/worker-dispatch/workers/worktree-backup.js"
case_12_symlink_dir_no_escape
case_end

case_begin "c13-dup-gitignore" "bin/worker-dispatch/workers/worktree-backup.js"
case_13_dup_gitignore
case_end

case_begin "c14-budget-boundary" "bin/worker-dispatch/workers/worktree-backup.js"
case_14_budget_boundary
case_end

case_begin "c15-enumerate-boundary" "bin/worker-dispatch/workers/worktree-backup.js"
case_15_enumerate_boundary
case_end

case_begin "c16-dir-expand-explicit-false" "bin/worker-dispatch/workers/worktree-backup.js"
case_16_dir_expand_explicit_false
case_end

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL"
exit $((FAIL > 0 ? 1 : 0))
