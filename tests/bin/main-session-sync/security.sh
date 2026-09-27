# Tests: install/linux/session-sync-init.sh
# Tags: bin, install, git, session-sync, security, installer, scope:common
# Part of tests/bin/main-session-sync.sh; owns the helpers the other security-* parts
# reuse, so the dispatcher must source it before them.

# TL3 gap (skills/_shared/test-design.md): TL2 — the installer runs for real, but
# only against throwaway fixtures with $HOME relocated under $TMPDIR_BASE.
# Not covered: a genuine NTFS junction or platform $HOME layout defeating
# _resolve_realpath, and a real ~/.claude carrying real objects and hooks.
# Mitigation: checked at WORKFLOW_USER_VERIFIED preflight, category installer.

echo ""
echo "=== session-sync-init.sh security tests (#1773) ==="

SEC_INIT="$DOTFILES_DIR/install/linux/session-sync-init.sh"
SEC_INIT_PS1="$DOTFILES_DIR/install/win/session-sync-init.ps1"
SEC_TABLE="$DOTFILES_DIR/tests/fixtures/session-sync-remote-url-table.txt"
SEC_PATTERNS="$DOTFILES_DIR/tests/fixtures/session-sync-remote-url-patterns.txt"
SEC_OUTSIDE_ROOT="$(dirname "$TMPDIR_BASE")/sec-outside-$$"
SEC_TAB="$(printf '\t')"

# _sec_run <args...> — run the installer, leaving rc in $_SEC_RC and combined
# output in $_SEC_OUT. Never aborts: every case asserts on the exit status.
_sec_run() {
    _SEC_OUT=$("$SEC_INIT" "$@" 2>&1 </dev/null) && _SEC_RC=0 || _SEC_RC=$?
}

# _sec_old_root <claude-dir> <origin-url|""> — build a pre-migration layout: a git
# root directly in the claude dir with one real commit and the two seed files.
# $_SEC_OLD_HEAD lets a later assertion tell "the old repo moved" from "a fresh
# repo was initialized at the destination".
_sec_old_root() {
    mkdir -p "$1"
    git init "$1" >/dev/null 2>&1
    _git_prepare_repo "$1"
    [ -z "$2" ] || git -C "$1" remote add origin "$2" >/dev/null 2>&1
    printf 'old-gitignore\n' > "$1/.gitignore"
    printf 'old-gitattributes\n' > "$1/.gitattributes"
    printf 'old-session\n' > "$1/old-session.jsonl"
    git -C "$1" add -A >/dev/null 2>&1
    git -C "$1" commit -q -m "pre-migration history" >/dev/null 2>&1
    _SEC_OLD_HEAD=$(git -C "$1" rev-parse --verify HEAD 2>/dev/null || echo "no-head")
}

# _sec_temp_leftovers <dir> — echo the first stray transaction artifact found
# ANYWHERE under <dir>, not just at its top level: the staging names the
# migration uses (`.old.*`, `.migrate-tmp.*`, `.bak*`) can be created one level
# down — inside projects/, or beside a nested repo — and a top-level-only check
# would call that clean. Kept symmetric with the PowerShell Get-StagingResidue.
_sec_temp_leftovers() {
    [ -d "$1" ] || return 0
    find "$1" \( -name '*.migrate-tmp' -o -name '*.migrate-tmp.*' \
        -o -name '*.old' -o -name '*.old.*' \
        -o -name '*.bak' -o -name '*.bak.*' \) -print 2>/dev/null | head -1 || true
}

# _sec_tracked_snapshot <dir> — HEAD plus the literal content of every tracked
# file, as one comparable blob. A rejected run that overwrites the working tree
# without committing leaves HEAD where it was, so "unchanged" is only proved by
# comparing the content itself.
_sec_tracked_snapshot() {
    if [ ! -d "$1/.git" ]; then
        printf 'NO-REPO\n'
        return 0
    fi
    printf 'head=%s\n' "$(git -C "$1" rev-parse --verify HEAD 2>/dev/null || echo none)"
    git -C "$1" ls-files 2>/dev/null | sort | while IFS= read -r sec_snap_file; do
        printf 'file=%s content=[%s]\n' "$sec_snap_file" "$(cat "$1/$sec_snap_file" 2>/dev/null || echo MISSING)"
    done
}

# _sec_worktree_status <dir> — `git status --porcelain` on one line. Empty means
# no modified, staged or untracked residue; "NO-REPO" when the repo is gone.
_sec_worktree_status() {
    if [ ! -d "$1/.git" ]; then
        printf 'NO-REPO'
        return 0
    fi
    git -C "$1" status --porcelain 2>/dev/null | sort | tr '\n' ';'
}

# _sec_table_rows — verdict rows the fixture declares, counted independently of
# the loop that consumes them, so a lost TAB cannot agree with a hardcoded number.
SEC_TABLE_ROWS=$(grep -cE "^(ALLOW|DENY)$SEC_TAB" "$SEC_TABLE" 2>/dev/null || echo 0)

# --- Table-driven: the canonical patterns under bash's own engine ---
# The installer rows below prove the shipped script agrees with the table; this
# case proves the pinned pattern text is ERE-legal and classifies every row
# correctly. A `(?:...)` form would not be — bash would reject the pattern and
# every URL would fall out the same side. Both suites run the same table.
echo "[security] Canonical allowlist patterns under bash ERE"
SEC_PAT_SCHEME=""
SEC_PAT_SCP=""
if [ ! -f "$SEC_PATTERNS" ]; then
    fail "canonical pattern fixture missing: $SEC_PATTERNS"
else
    while IFS="$SEC_TAB" read -r sec_key sec_val || [ -n "${sec_key:-}" ]; do
        case "${sec_key:-}" in ''|'#'*) continue ;; esac
        case "$sec_key" in
            SCHEME) SEC_PAT_SCHEME="${sec_val:-}" ;;
            SCP)    SEC_PAT_SCP="${sec_val:-}" ;;
        esac
    done < "$SEC_PATTERNS"
    if [ -n "$SEC_PAT_SCHEME" ] && [ -n "$SEC_PAT_SCP" ]; then
        pass "both canonical patterns parsed from the fixture"
    else
        fail "canonical pattern fixture did not yield both SCHEME and SCP rows"
    fi
fi

if [ -n "$SEC_PAT_SCHEME" ] && [ -n "$SEC_PAT_SCP" ]; then
    sec_pat_bad=0
    sec_pat_rows=0
    while IFS="$SEC_TAB" read -r sec_kind sec_url || [ -n "${sec_kind:-}" ]; do
        case "${sec_kind:-}" in ''|'#'*) continue ;; esac
        [ -n "${sec_url:-}" ] || continue
        sec_pat_rows=$((sec_pat_rows + 1))
        if [[ "$sec_url" =~ $SEC_PAT_SCHEME ]] || [[ "$sec_url" =~ $SEC_PAT_SCP ]]; then
            sec_verdict=ALLOW
        else
            sec_verdict=DENY
        fi
        if [ "$sec_verdict" != "$sec_kind" ]; then
            fail "bash ERE verdict $sec_verdict, table says $sec_kind: $sec_url"
            sec_pat_bad=$((sec_pat_bad + 1))
        fi
    done < "$SEC_TABLE"
    if [ "$sec_pat_bad" -eq 0 ] && [ "$sec_pat_rows" -eq "$SEC_TABLE_ROWS" ]; then
        pass "bash ERE agrees with all $sec_pat_rows table rows"
    else
        fail "bash ERE disagreed on $sec_pat_bad of $sec_pat_rows rows (declared $SEC_TABLE_ROWS)"
    fi
fi

# --- Static: no non-capturing group reaches either installer ---
# `(?:...)` is legal in .NET and rejected by POSIX ERE, so it is the one
# construct that can make the two installers silently disagree. Asserted on both
# files, symmetric per CPR-ORTH.
echo "[security] neither installer uses a non-capturing group"
for sec_src in "$SEC_INIT" "$SEC_INIT_PS1"; do
    if grep -qF '(?:' "$sec_src" 2>/dev/null; then
        fail "non-capturing group found in $(basename "$sec_src") — not POSIX ERE"
    else
        pass "$(basename "$sec_src") is free of non-capturing groups"
    fi
done

# --- Table-driven: remote-URL allowlist, through the real installer ---
# Classifier both-direction coverage (protection-fix-tests.md Pattern 4): the
# table carries allow verdicts as well as reject verdicts, so an over-broad
# refusal fails as loudly as an accepted attack URL.
echo "[security] Remote-URL allowlist contrast table"
SEC_ROW=0
if [ ! -f "$SEC_TABLE" ]; then
    fail "URL contrast table missing: $SEC_TABLE"
else
    while IFS="$SEC_TAB" read -r sec_kind sec_url || [ -n "${sec_kind:-}" ]; do
        case "${sec_kind:-}" in ''|'#'*) continue ;; esac
        [ -n "${sec_url:-}" ] || continue
        SEC_ROW=$((SEC_ROW + 1))
        sec_claude="$TMPDIR_BASE/sec-url-$SEC_ROW/.claude"
        mkdir -p "$sec_claude"
        _sec_run --claude-dir "$sec_claude" --remote-url "$sec_url"
        sec_got=$(git -C "$sec_claude/projects" remote get-url origin 2>/dev/null || true)
        if [ "$sec_kind" = "ALLOW" ]; then
            if [ "$_SEC_RC" -eq 0 ] && [ "$sec_got" = "$sec_url" ]; then
                pass "allowlist accepts: $sec_url"
            else
                fail "allowlist rejected a legitimate URL: $sec_url (rc=$_SEC_RC origin=$sec_got)"
            fi
        else
            # Negative assertion (protection-fix-tests.md Pattern 1): validation
            # lands before any filesystem write, so projects/ must not exist at
            # all — not merely be repo-less.
            if [ "$_SEC_RC" -ne 0 ] && [ ! -e "$sec_claude/projects" ]; then
                pass "allowlist refuses: $sec_url"
            else
                fail "allowlist accepted a forbidden URL: $sec_url (rc=$_SEC_RC origin=$sec_got)"
            fi
        fi
    done < "$SEC_TABLE"
    if [ "$SEC_ROW" -eq "$SEC_TABLE_ROWS" ] && [ "$SEC_ROW" -ge 16 ]; then
        pass "contrast table supplied all $SEC_ROW cases"
    else
        fail "contrast table parsed $SEC_ROW of $SEC_TABLE_ROWS cases (TAB separator lost?)"
    fi
fi

# --- Error: claude-dir outside $HOME is refused ---
echo "[security] --claude-dir outside \$HOME"
_sec_run --claude-dir "$SEC_OUTSIDE_ROOT/claude" --no-remote
if [ "$_SEC_RC" -ne 0 ] && [ ! -d "$SEC_OUTSIDE_ROOT/claude/projects" ]; then
    pass "claude-dir outside \$HOME refused without touching the path"
else
    fail "claude-dir outside \$HOME was accepted (rc=$_SEC_RC)"
fi

# --- Error: an out-of-$HOME claude dir that already holds a git root ---
# The bare-directory case above proves the path is refused; this one proves the
# refusal is worth something. A real ~/.claude outside $HOME carries exactly what
# the migration destroys, so the attack payoff is measured here: the committed
# repo, both seed files and the tracked working tree must all survive byte-intact.
echo "[security] out-of-\$HOME claude dir carrying a committed git root"
SEC_OUT_GIT="$SEC_OUTSIDE_ROOT/with-git"
_sec_old_root "$SEC_OUT_GIT" "https://example.invalid/outside.git"
SEC_OUT_HEAD="$_SEC_OLD_HEAD"
_sec_run --claude-dir "$SEC_OUT_GIT" --expected-origin "https://example.invalid/outside.git" --no-remote
SEC_OUT_HEAD_AFTER=$(git -C "$SEC_OUT_GIT" rev-parse --verify HEAD 2>/dev/null || echo "none")
SEC_OUT_LEFT=$(_sec_temp_leftovers "$SEC_OUT_GIT")
if [ "$_SEC_RC" -eq 0 ]; then
    fail "out-of-\$HOME claude dir with a git root was accepted"
elif [ "$SEC_OUT_HEAD_AFTER" != "$SEC_OUT_HEAD" ]; then
    fail "out-of-\$HOME: the committed repo was moved or destroyed ($SEC_OUT_HEAD_AFTER)"
elif [ "$(cat "$SEC_OUT_GIT/.gitignore" 2>/dev/null)" != "old-gitignore" ]; then
    fail "out-of-\$HOME: .gitignore was rewritten or removed by a rejected run"
elif [ "$(cat "$SEC_OUT_GIT/.gitattributes" 2>/dev/null)" != "old-gitattributes" ]; then
    fail "out-of-\$HOME: .gitattributes was rewritten or removed by a rejected run"
elif [ ! -f "$SEC_OUT_GIT/old-session.jsonl" ]; then
    fail "out-of-\$HOME: the tracked working-tree file was removed by a rejected run"
elif [ -e "$SEC_OUT_GIT/projects" ] || [ -n "$SEC_OUT_LEFT" ]; then
    fail "out-of-\$HOME: the rejected run still wrote into the path ($SEC_OUT_LEFT)"
else
    pass "out-of-\$HOME: refused with repo, seed files and working tree intact"
fi

# --- Boundary: claude-dir equal to $HOME is accepted ---
echo "[security] --claude-dir equal to \$HOME"
_sec_run --claude-dir "$HOME" --no-remote
if [ "$_SEC_RC" -eq 0 ]; then
    pass "\$HOME itself is inside the boundary"
else
    fail "\$HOME itself was refused (rc=$_SEC_RC, output: $_SEC_OUT)"
fi

# --- Error: same-prefix sibling of $HOME is refused ---
# "${HOME}-sibling" shares $HOME as a string prefix but is not a descendant; a
# separator-less prefix comparison would wrongly admit it.
echo "[security] \${HOME}-sibling is not inside \$HOME"
SEC_SIBLING="${HOME}-sibling"
_sec_run --claude-dir "$SEC_SIBLING/.claude" --no-remote
if [ "$_SEC_RC" -ne 0 ] && [ ! -d "$SEC_SIBLING/.claude/projects" ]; then
    pass "same-prefix sibling of \$HOME refused"
else
    fail "same-prefix sibling of \$HOME accepted (rc=$_SEC_RC)"
fi
rm -rf "$SEC_SIBLING" 2>/dev/null || true

# --- Error: symlink escape from inside $HOME ---
echo "[security] symlink under \$HOME pointing outside"
mkdir -p "$SEC_OUTSIDE_ROOT/target"
SEC_LINK="$HOME/sec-evil-link"
ln -s "$SEC_OUTSIDE_ROOT/target" "$SEC_LINK" 2>/dev/null || true
if [ -L "$SEC_LINK" ]; then
    _sec_run --claude-dir "$SEC_LINK" --no-remote
    if [ "$_SEC_RC" -ne 0 ] && [ ! -d "$SEC_OUTSIDE_ROOT/target/projects" ]; then
        pass "symlink whose target leaves \$HOME refused"
    else
        fail "symlink escape accepted (rc=$_SEC_RC)"
    fi
else
    pending "symlink escape: this platform did not create a symlink (ln -s unsupported)"
fi

# --- Error: symlink in an intermediate path component ---
# The escape hides mid-path, so a helper resolving only the last component would
# wave it through. Regression guard for whole-path resolution.
echo "[security] symlink in an intermediate claude-dir component"
SEC_MIDLINK="$HOME/sec-mid-link"
ln -s "$SEC_OUTSIDE_ROOT/target" "$SEC_MIDLINK" 2>/dev/null || true
if [ -L "$SEC_MIDLINK" ]; then
    _sec_run --claude-dir "$SEC_MIDLINK/nested/.claude" --no-remote
    if [ "$_SEC_RC" -ne 0 ] && [ ! -d "$SEC_OUTSIDE_ROOT/target/nested" ]; then
        pass "intermediate-component symlink escape refused"
    else
        fail "intermediate-component symlink escape accepted (rc=$_SEC_RC)"
    fi
else
    pending "intermediate symlink escape: this platform did not create a symlink"
fi

rm -rf "$SEC_OUTSIDE_ROOT" 2>/dev/null || true
