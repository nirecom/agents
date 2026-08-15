#!/usr/bin/env bash
# tests/feature-1894-comment-block-size/scan-scope-and-leak.sh
# Tests: bin/review-comment-block-size
# Tags: comment-block-size, scan-scope, gitignore, symlink, leak, empty-index, scope:issue-specific, scope:feature-1894, layer:TL2
#
# Part 6 — what the scanner is allowed to look at, and what it is allowed to
# say about it.
#
# Two concerns share this file because both are about the boundary of the
# report rather than its arithmetic (CPR-SC): which files enter the scan, and
# which bytes are permitted to leave it.
#
# --all is the mode with a traversal of its own, so it gets the scope cases:
# which files it walks (O11), how it treats modified / excluded / out-of-repo
# entries (O13), and what it prints when nothing is eligible at all (O14).

lpad() { local n="$1" i; for ((i = 1; i <= n; i++)); do echo "l_$i=$i"; done; }
lcm() { local n="$1" tag="$2" i; for ((i = 1; i <= n; i++)); do echo "# $tag $i"; done; }

# ---------------------------------------------------------------------------
# O9 — the comment body itself is never echoed
# ---------------------------------------------------------------------------
# The report is paths, line ranges and counts. A scanner that quoted the
# offending block would push whatever sits in a long comment — credentials,
# customer names, private URLs — into terminal scrollback and CI logs.
echo ""
echo "=== O9: comment bodies never reach stdout/stderr ==="
LEAK="$(new_repo leakcheck)"
{ lpad 2; lcm 12 "$SENTINEL"; lpad 2; } > "$LEAK/leaky.sh"
git -C "$LEAK" add -A >/dev/null 2>&1
run_cb "$LEAK" -- --staged
assert_absent "O9/staged-mode-stdout-clean" "$SENTINEL" "$CB_OUT"
assert_absent "O9/staged-mode-stderr-clean" "$SENTINEL" "$CB_ERR"
# Paired positive, so the two assertions above cannot pass by scanning nothing.
assert_contains "O9/staged-mode-still-reports-the-file" "$CB_FIND: leaky.sh" "$CB_OUT"
run_cb "$LEAK" -- --all
assert_absent "O9/all-mode-stdout-clean" "$SENTINEL" "$CB_OUT"
assert_absent "O9/all-mode-stderr-clean" "$SENTINEL" "$CB_ERR"
assert_contains "O9/all-mode-still-reports-the-file" "leaky.sh" "$CB_OUT"

# ---------------------------------------------------------------------------
# O10 — nothing to scan is a normal outcome, not an error
# ---------------------------------------------------------------------------
echo ""
echo "=== O10: empty index / no in-scope extensions ==="
EMPTY="$(new_repo emptyindex)"
run_cb "$EMPTY" -- --staged
cb_expect_rc "O10/empty-index-rc"
assert_eq "O10/empty-index-no-warn" "0" "$(cb_warn_count)"
case "$(cb_header)" in
    "## Comment-block Size Review:"*) pass "O10/empty-index-header-well-formed" ;;
    *) fail "O10/empty-index-header-well-formed" "got: $(cb_header)" ;;
esac

{ lpad 2; lcm 12 note; } > "$EMPTY/notes.md"
{ lpad 2; lcm 12 note; } > "$EMPTY/data.json"
git -C "$EMPTY" add -A >/dev/null 2>&1
run_cb "$EMPTY" -- --staged
cb_expect_rc "O10/out-of-scope-only-rc"
assert_eq "O10/out-of-scope-only-no-warn" "0" "$(cb_warn_count)"
assert_contains "O10/out-of-scope-only-counted-zero" "Staged code files scanned: 0" "$CB_OUT"

# ---------------------------------------------------------------------------
# O11 — what --all actually walks
# ---------------------------------------------------------------------------
# --all is the manual review mode, so its scope is the tracked working tree:
# committed files count even when nothing is staged, and ignored files do not
# (they are build output, vendored code or local scratch).
echo ""
echo "=== O11: --all scan targets ==="
ALLR="$(new_repo allscope)"
{ lpad 2; lcm 12 committed; } > "$ALLR/committed.sh"
printf 'ignored.sh\nbuild/\n' > "$ALLR/.gitignore"
git -C "$ALLR" add -A >/dev/null 2>&1
git -C "$ALLR" commit -q -m "committed sources"
{ lpad 2; lcm 12 ignored; } > "$ALLR/ignored.sh"
mkdir -p "$ALLR/build"
{ lpad 2; lcm 12 generated; } > "$ALLR/build/generated.sh"
run_cb "$ALLR" -- --all
cb_expect_rc "O11/rc"
assert_contains "O11/committed-file-scanned" "committed.sh" "$CB_OUT"
assert_absent "O11/gitignored-file-skipped" "ignored.sh" "$CB_OUT"
assert_absent "O11/gitignored-dir-skipped" "generated.sh" "$CB_OUT"

if ln -s committed.sh "$ALLR/link.sh" 2>/dev/null && [ -L "$ALLR/link.sh" ]; then
    run_cb "$ALLR" -- --all
    cb_expect_rc "O11/symlink-rc"
    # Following the link would report the same block twice under two names.
    assert_absent "O11/symlink-not-followed" "link.sh" "$CB_OUT"
else
    skip "O11/symlink: this host cannot create symlinks without elevation — symlink handling unverified"
fi

# ---------------------------------------------------------------------------
# O13 — --all traversal: modified tracked file, coexisting exclusions, escape
# ---------------------------------------------------------------------------
# O11 walks a working tree whose only in-scope file is unmodified and whose only
# exclusion is .gitignore. Three traversal properties are still unpinned, and
# each is a different failure (CPR-SC): reading a tracked file's CURRENT bytes
# rather than its committed ones; applying the path-based exclusions and the
# gitignore exclusion in the SAME walk; and refusing to leave the repo.
echo ""
echo "=== O13: --all traversal — modified, coexisting exclusions, escape ==="
TRAV="$(new_repo alltrav)"
mkdir -p "$TRAV/node_modules" "$TRAV/_archive"
{ lpad 2; lcm 3 committed; } > "$TRAV/modified.sh"     # committed: sub-threshold
{ lpad 2; lcm 12 plain; } > "$TRAV/real.sh"
{ lpad 2; lcm 25 vendored; } > "$TRAV/node_modules/vendor.sh"
{ lpad 2; lcm 25 archived; } > "$TRAV/_archive/old.sh"
printf 'scratch.sh\n' > "$TRAV/.gitignore"
git -C "$TRAV" add -A >/dev/null 2>&1
git -C "$TRAV" commit -q -m "tracked sources"
# Now grow the tracked file in the working tree only — nothing staged, nothing
# committed. --all reports what is on disk or it reports nothing useful.
{ lpad 2; lcm 14 grown; } > "$TRAV/modified.sh"
{ lpad 2; lcm 25 scratch; } > "$TRAV/scratch.sh"
run_cb "$TRAV" -- --all
cb_expect_rc "O13/rc"
assert_contains "O13/modified-tracked-file-uses-worktree-bytes" \
    "$CB_FIND: modified.sh — longest comment run 14 lines" "$CB_OUT"
assert_contains "O13/unmodified-tracked-file-still-scanned" "$CB_FIND: real.sh" "$CB_OUT"
# All three exclusion kinds are live in this one walk, so an implementation that
# handles them in mutually exclusive branches cannot pass.
assert_absent "O13/node-modules-excluded" "vendor.sh" "$CB_OUT"
assert_absent "O13/archive-dir-excluded" "old.sh" "$CB_OUT"
assert_absent "O13/gitignored-excluded" "scratch.sh" "$CB_OUT"
assert_eq "O13/exactly-2-warn-lines" "2" "$(cb_warn_count)"

# A symlink pointing OUT of the repo is the escape case: following it would read
# — and report line ranges from — a file the committer never put under version
# control, under a path that does not exist in the repo.
OUTSIDE="$TMPDIR_BASE/outside-target.sh"
{ lpad 2; lcm 30 "$SENTINEL"; } > "$OUTSIDE"
if ln -s "$OUTSIDE" "$TRAV/escape.sh" 2>/dev/null && [ -L "$TRAV/escape.sh" ]; then
    run_cb "$TRAV" -- --all
    cb_expect_rc "O13/escape-symlink-rc"
    assert_absent "O13/escape-symlink-not-reported" "escape.sh" "$CB_OUT"
    assert_absent "O13/escape-target-not-reported" "outside-target.sh" "$CB_OUT"
    assert_absent "O13/escape-target-body-not-leaked" "$SENTINEL" "$CB_OUT"
    assert_eq "O13/escape-warn-count-unchanged" "2" "$(cb_warn_count)"
    rm -f "$TRAV/escape.sh"
else
    skip "O13/escape-symlink: this host cannot create symlinks without elevation — out-of-repo symlink handling unverified"
fi

# ---------------------------------------------------------------------------
# O14 — --all with nothing eligible to scan
# ---------------------------------------------------------------------------
# The staged-mode counterpart is O10. --all needs its own case because it walks
# a different set: a repo whose tracked files are all out-of-scope extensions
# must still PERFORM (and say so) rather than skip, error, or warn.
echo ""
echo "=== O14: --all with zero eligible code files ==="
NOCODE="$(new_repo allnocode)"
{ lpad 2; lcm 20 note; } > "$NOCODE/notes.md"
{ lpad 2; lcm 20 note; } > "$NOCODE/data.json"
git -C "$NOCODE" add -A >/dev/null 2>&1
git -C "$NOCODE" commit -q -m "docs only"
run_cb "$NOCODE" -- --all
cb_expect_rc "O14/rc"
assert_eq "O14/header" "## Comment-block Size Review: PERFORMED (all-scan mode)" "$(cb_header)"
assert_eq "O14/no-warn-line" "0" "$(cb_warn_count)"
assert_absent "O14/no-advisory-footer" "Compress to a one-line summary" "$CB_OUT"
