#!/bin/bash
# tests/skills/feature-capture-env.sh
# Tests: skills/worktree-end/scripts/capture-env.sh, skills/worktree-end/scripts/write-env-json.js
# Tags: worktree, end, cleanup, skill, bin, scope:common, worktree-notes, notes-backup, fail-closed
# Multi-repo worktree: ## SiblingWorktrees awk parsing in capture-env.sh and the
# SIBLING_REPOS_JSON passthrough in write-env-json.js (CE4, CE1, CE-parse*).
# #2019 NB*: the WORKTREE_NOTES.md backup must be byte-identical, or capture-env.sh aborts
# before final-report-env.json (the backup is the only copy that survives worktree removal).

set -u

SCRIPT_CHECKOUT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
. "$SCRIPT_CHECKOUT_ROOT/tests/lib/harness.sh"
WRITE_ENV_JS="$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/write-env-json.js"
CAPTURE_ENV_SH="$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/capture-env.sh"

TMPDIR_BASE="$(make_tmp)"
readonly TMPDIR_BASE
trap 'rm -rf "$TMPDIR_BASE"' EXIT
harness_isolate "$TMPDIR_BASE/iso"
unset CLAUDE_CODE_SESSION_ID PLANS_DIR
export CLAUDE_TRANSCRIPT_BASE_DIR="$TMPDIR_BASE/transcripts"
mkdir -p "$CLAUDE_TRANSCRIPT_BASE_DIR"

# ---- CE4: write-env-json.js passes SIBLING_REPOS_JSON env var through to output ----
test_CE4_write_env_json_sibling_repos_field() {
    if [ ! -f "$WRITE_ENV_JS" ]; then
        fail "CE4: write-env-json.js not found at $WRITE_ENV_JS"
        return
    fi

    local out_json="$TMPDIR_BASE/ce4-out.json"
    local sibling_val='[{"repo":"owner/r","pr_number":42}]'

    SIBLING_REPOS_JSON="$sibling_val" \
        run_with_timeout 30 node "$WRITE_ENV_JS" "$out_json" >/dev/null 2>&1

    if [ ! -f "$out_json" ]; then
        fail "CE4: write-env-json.js did not create output file at $out_json"
        return
    fi

    local actual_val
    actual_val="$(node -e "
        const fs = require('fs');
        const j = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
        process.stdout.write(j.SIBLING_REPOS_JSON || '');
    " -- "$out_json" 2>/dev/null)"

    if [ "$actual_val" = "$sibling_val" ]; then
        pass "CE4: write-env-json.js SIBLING_REPOS_JSON field equals env var value"
    else
        fail "CE4: SIBLING_REPOS_JSON field mismatch: expected='$sibling_val' actual='$actual_val'"
    fi
}

# ---- CE-parse1: awk parsing of ## SiblingWorktrees with (none) → 0 entries ----
test_CEparse1_awk_parses_none_entry() {
    local notes_file="$TMPDIR_BASE/ceparse1-notes.md"
    printf '## SiblingWorktrees\n- (none)\n' > "$notes_file"

    # Extract sibling entries using the same awk pattern as capture-env.sh will use.
    # Lines matching "- repo: X, path: Y" are extracted; "- (none)" is skipped.
    local count
    count="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f && /^- repo:/{print}' "$notes_file" | wc -l | tr -d ' ')"

    if [ "$count" = "0" ]; then
        pass "CE-parse1: awk parsing of '## SiblingWorktrees\\n- (none)' yields 0 sibling entries"
    else
        fail "CE-parse1: expected 0 entries, got $count"
    fi
}

# ---- CE-parse2: awk parsing of ## SiblingWorktrees with one entry → repo and path extracted ----
test_CEparse2_awk_parses_one_entry() {
    local notes_file="$TMPDIR_BASE/ceparse2-notes.md"
    printf '## History Notes\n- (none)\n\n## SiblingWorktrees\n- repo: owner/repo2, path: /other/wt\n\n## AnotherSection\n- foo\n' > "$notes_file"

    # Extract sibling entries — should get the "- repo: ..." line
    local lines
    lines="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f && /^- repo:/{print}' "$notes_file")"
    local count
    count="$(printf '%s\n' "$lines" | grep -c '^- repo:' 2>/dev/null || echo 0)"

    if [ "$count" != "1" ]; then
        fail "CE-parse2: expected 1 entry line, got $count (lines: $lines)"
        return
    fi

    # Extract repo and path from "- repo: owner/repo2, path: /other/wt"
    local repo_val
    repo_val="$(printf '%s\n' "$lines" | sed 's/^- repo: \([^,]*\),.*/\1/')"
    local path_val
    path_val="$(printf '%s\n' "$lines" | sed 's/.*path: //')"

    if [ "$repo_val" = "owner/repo2" ] && [ "$path_val" = "/other/wt" ]; then
        pass "CE-parse2: awk extracts repo=owner/repo2 path=/other/wt from SiblingWorktrees section"
    else
        fail "CE-parse2: repo='$repo_val' path='$path_val' (expected owner/repo2 / /other/wt)"
    fi
}

# ---- CE1: capture-env.sh BOOTSTRAP_MODE=1 with (none) siblings → SIBLING_REPOS_JSON=[] ----
test_CE1_capture_env_bootstrap_sibling_repos_empty() {
    if [ ! -f "$CAPTURE_ENV_SH" ]; then
        fail "CE1: capture-env.sh not found at $CAPTURE_ENV_SH"
        return
    fi

    local wt="$TMPDIR_BASE/ce1-wt"
    mkdir -p "$wt"
    # Write a WORKTREE_NOTES.md with SiblingWorktrees (none) and a Session-ID
    printf '# Worktree Notes\nBranch: feature/test\nSession-ID: test-session-123\n\n## SiblingWorktrees\n- (none)\n' \
        > "$wt/WORKTREE_NOTES.md"

    local mock_bin="$TMPDIR_BASE/ce1-mockbin"
    mkdir -p "$mock_bin"

    # Mock gh — handle any invocation gracefully
    cat > "$mock_bin/gh" << 'GHEOF'
#!/bin/bash
if [[ "$*" == *"pr list"* ]]; then
    echo "99"
elif [[ "$*" == *"pr view"* ]]; then
    printf '{"title":"test","url":"https://github.com/test/repo/pull/99","state":"MERGED","mergeCommit":{"oid":"abc1234567890def"}}'
fi
GHEOF
    chmod +x "$mock_bin/gh"

    # Mock git — return branch name and SHA
    cat > "$mock_bin/git" << 'GITEOF'
#!/bin/bash
if [[ "$*" == *"rev-parse --abbrev-ref"* ]]; then
    echo "feature/test"
elif [[ "$*" == *"rev-parse HEAD"* ]]; then
    echo "abc1234567890def"
fi
GITEOF
    chmod +x "$mock_bin/git"

    local plans_dir="$TMPDIR_BASE/ce1-plans"
    mkdir -p "$plans_dir"

    # Patch capture-env.sh: replace LIB_DIR with a temp dir containing mocked scripts
    local lib_dir="$TMPDIR_BASE/ce1-scripts"
    mkdir -p "$lib_dir"

    # Mock detect-restart.sh
    cat > "$lib_dir/detect-restart.sh" << 'DREOF'
#!/bin/bash
echo "cc_restart=not_required|"
echo "vscode_reload=not_required|"
echo "installer_rerun=not_required|"
echo "os_reboot=not_required|"
DREOF
    chmod +x "$lib_dir/detect-restart.sh"

    # Use the REAL write-env-json.js (we are testing that it passes SIBLING_REPOS_JSON through)
    cp "$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/write-env-json.js" "$lib_dir/write-env-json.js"

    # Copy extract-pr-fields.js (needed by non-bootstrap path but not used in BOOTSTRAP_MODE=1)
    if [ -f "$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/extract-pr-fields.js" ]; then
        cp "$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/extract-pr-fields.js" "$lib_dir/extract-pr-fields.js"
    fi

    # Patch LIB_DIR in a copy of capture-env.sh
    local script_copy="$TMPDIR_BASE/ce1-capture-env.sh"
    sed -e "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$lib_dir\"|" \
        -e "s|^SCRIPT_CHECKOUT_ROOT=.*|SCRIPT_CHECKOUT_ROOT=\"$SCRIPT_CHECKOUT_ROOT\"|" \
        "$CAPTURE_ENV_SH" > "$script_copy"
    chmod +x "$script_copy"

    # #2434: the env JSON is a control file — <WORKFLOW_STATE_DIR>/<sid>.control/final-report-env.json.
    local wf_dir="$TMPDIR_BASE/ce1-workflow"
    mkdir -p "$wf_dir"
    local env_json="$wf_dir/test-session-123.control/final-report-env.json"

    BOOTSTRAP_MODE=1 \
    BOOTSTRAP_COMMIT_SHA=abc1234567890def \
    PLANS_DIR="$plans_dir" \
    WORKFLOW_PLANS_DIR="$plans_dir" \
    WORKFLOW_STATE_DIR="$wf_dir" \
    PATH="$mock_bin:$PATH" \
        run_with_timeout 30 bash "$script_copy" "$wt" "owner/repo" "(none)" "" >/dev/null 2>&1
    local code=$?

    if [ ! -f "$env_json" ]; then
        fail "CE1: capture-env.sh exit $code but $env_json not created (SIBLING_REPOS_JSON field test blocked)"
        return
    fi
    if [ -e "$plans_dir/test-session-123-final-report-env.json" ]; then
        fail "CE1: legacy plans-dir env JSON was written (control file must live only in the control dir)"
        return
    fi

    local sibling_field
    sibling_field="$(node -e "
        const fs = require('fs');
        const j = JSON.parse(fs.readFileSync(process.argv[1], 'utf8'));
        process.stdout.write(j.SIBLING_REPOS_JSON !== undefined ? j.SIBLING_REPOS_JSON : '__MISSING__');
    " -- "$env_json" 2>/dev/null)"

    if [ "$sibling_field" = "[]" ]; then
        pass "CE1: capture-env.sh BOOTSTRAP_MODE=1 with (none) siblings → SIBLING_REPOS_JSON=[]"
    elif [ "$sibling_field" = "__MISSING__" ]; then
        fail "CE1: SIBLING_REPOS_JSON field missing from $env_json (field not yet added to write-env-json.js)"
    else
        fail "CE1: SIBLING_REPOS_JSON='$sibling_field' (expected '[]')"
    fi
}

# ---- CE-parse3: awk parsing of ## SiblingWorktrees with 2 entries → both extracted ----
test_CEparse3_awk_parses_two_entries() {
    local notes_file="$TMPDIR_BASE/ceparse3-notes.md"
    printf '## SiblingWorktrees\n- repo: owner/repo2, path: /wt/repo2\n- repo: owner/repo3, path: /wt/repo3\n' > "$notes_file"

    local lines
    lines="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f && /^- repo:/{print}' "$notes_file")"
    local count
    count="$(printf '%s\n' "$lines" | grep -c '^- repo:' 2>/dev/null || echo 0)"

    if [ "$count" != "2" ]; then
        fail "CE-parse3: expected 2 entry lines, got $count (lines: $lines)"
        return
    fi

    # Assert both repo values are present
    if ! printf '%s\n' "$lines" | grep -q 'owner/repo2'; then
        fail "CE-parse3: missing owner/repo2 in extracted lines (lines: $lines)"
        return
    fi
    if ! printf '%s\n' "$lines" | grep -q 'owner/repo3'; then
        fail "CE-parse3: missing owner/repo3 in extracted lines (lines: $lines)"
        return
    fi

    # Assert both path values are present
    if ! printf '%s\n' "$lines" | grep -q '/wt/repo2'; then
        fail "CE-parse3: missing /wt/repo2 in extracted lines (lines: $lines)"
        return
    fi
    if ! printf '%s\n' "$lines" | grep -q '/wt/repo3'; then
        fail "CE-parse3: missing /wt/repo3 in extracted lines (lines: $lines)"
        return
    fi

    pass "CE-parse3: awk extracts 2 entries (owner/repo2+owner/repo3, /wt/repo2+/wt/repo3) from SiblingWorktrees section"
}

# ---- CE-parse5: awk parsing when ## SiblingWorktrees is the LAST section (no trailing ##) ----
test_CEparse5_awk_last_section_no_trailing_header() {
    local notes_file="$TMPDIR_BASE/ceparse5-notes.md"
    # SiblingWorktrees is the LAST section — no following ## header to reset the f flag
    printf '## SiblingWorktrees\n- repo: owner/r2, path: /wt/r2\n' > "$notes_file"

    local lines
    lines="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f && /^- repo:/{print}' "$notes_file")"
    local count
    count="$(printf '%s\n' "$lines" | grep -c '^- repo:' 2>/dev/null || echo 0)"

    if [ "$count" = "1" ]; then
        pass "CE-parse5: awk extracts 1 entry when ## SiblingWorktrees is the last section (no trailing ## to reset f)"
    else
        fail "CE-parse5: expected 1 entry when section is last, got $count (lines: $lines)"
    fi
}

# L3 gap (what this test does NOT catch):
# - CE2/CE3: non-bootstrap capture-env.sh normal mode with sibling repo PR resolution via gh
#   (requires a full mock-gh setup for primary + sibling gh pr list/view/mergeCommit calls)
# - Real GitHub API access for live sibling PR resolution validation
# - Multi-repo session Final Report showing correct per-repo PR links
# - CE6/CE7: capture-env.sh SESSION_ID format rejection and BOOTSTRAP_COMMIT_SHA empty-when-required validation (pre-existing script validation, out of scope for this feature)
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED preflight
# via bin/check-verification-gate.sh category: skill-orchestration

# ---- CE-parse4: ## SiblingWorktrees header present but completely empty body → 0 entries ----
# Should PASS: awk stops at the next ## section and finds no "- repo:" lines.
test_CEparse4_awk_empty_body_after_header() {
    local notes_file="$TMPDIR_BASE/ceparse4-notes.md"
    printf '## SiblingWorktrees\n\n## NextSection\n- foo\n' > "$notes_file"

    local count
    count="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f && /^- repo:/{print}' "$notes_file" | wc -l | tr -d ' ')"

    if [ "$count" = "0" ]; then
        pass "CE-parse4: awk extracts 0 entries from '## SiblingWorktrees' with empty body (stopped at ## NextSection)"
    else
        fail "CE-parse4: expected 0 entries from empty body, got $count"
    fi
}

# ---- CE-parse7: notes file has no ## SiblingWorktrees section at all → 0 entries ----
# Should PASS: awk 'f' flag is never set so no lines are printed.
test_CEparse7_awk_no_sibling_section() {
    local notes_file="$TMPDIR_BASE/ceparse7-notes.md"
    printf '## History Notes\n- (none)\n' > "$notes_file"

    local count
    count="$(awk '/^## SiblingWorktrees/{f=1;next} f && /^## /{f=0} f && /^- repo:/{print}' "$notes_file" | wc -l | tr -d ' ')"

    if [ "$count" = "0" ]; then
        pass "CE-parse7: awk extracts 0 entries when notes file has no '## SiblingWorktrees' section"
    else
        fail "CE-parse7: expected 0 entries when section absent, got $count"
    fi
}

# ---- NB*: notes backup verification (#2019) ----
# Sandbox: LIB_DIR holds the real JSON writers and a fake detect-restart; gh/git are fakes.
# The cp shim truncates a copy to WORKTREE_NOTES.md (exit 0) and hands every other copy to the real cp.
NB="$TMPDIR_BASE/nb"
nb_setup() {
    mkdir -p "$NB/fakebin" "$NB/shimbin" "$NB/lib"
    cat > "$NB/fakebin/gh" << 'GHEOF'
#!/bin/bash
if [[ "$*" == *"pr list"* ]]; then echo "42"
elif [[ "$*" == *"mergeCommit"* ]]; then echo "abc1234567890"
elif [[ "$*" == *"pr view"* ]]; then printf '{"title":"t","url":"https://github.com/example-owner/example-repo/pull/42","state":"MERGED"}'
fi
GHEOF
    printf '#!/bin/bash\necho "fix/2019-test"\n' > "$NB/fakebin/git"
    printf '#!/bin/bash\nprintf "cc_restart=not_required|\\nvscode_reload=not_required|\\ninstaller_rerun=not_required|\\nos_reboot=not_required|\\n"\n' > "$NB/lib/detect-restart.sh"
    cat > "$NB/shimbin/cp" << CPEOF
#!/bin/bash
dst="\${@: -1}"; src="\${@: -2:1}"
if [[ "\$dst" == *WORKTREE_NOTES.md ]]; then head -c 10 "\$src" > "\$dst"; exit 0; fi
exec "$(command -v cp)" "\$@"
CPEOF
    chmod +x "$NB/fakebin/gh" "$NB/fakebin/git" "$NB/lib/detect-restart.sh" "$NB/shimbin/cp"
    local f
    for f in write-env-json.js extract-pr-fields.js sibling-repos-json.js; do
        cp "$SCRIPT_CHECKOUT_ROOT/skills/worktree-end/scripts/$f" "$NB/lib/$f"
    done
    sed -e "s|LIB_DIR=\"\$(cd \"\$(dirname \"\$0\")\" && pwd)\"|LIB_DIR=\"$NB/lib\"|" \
        -e "s|^SCRIPT_CHECKOUT_ROOT=.*|SCRIPT_CHECKOUT_ROOT=\"$SCRIPT_CHECKOUT_ROOT\"|" \
        "$CAPTURE_ENV_SH" > "$NB/capture-env.sh"
    grep -q "^LIB_DIR=\"$NB/lib\"" "$NB/capture-env.sh" || fail "NB setup: LIB_DIR rewrite did not apply"
}

# nb_run <tag> <bootstrap|normal> <backupdir|plans> <ok|notfile|truncated|nonotes> — sets NB_RC,
# NB_ERR, NB_ENV (env JSON path), NB_BACKUP (expected backup file), NB_NOTES (source notes).
nb_run() {
    local tag="$1" branch="$2" dest="$3" mode="$4" sid="nb-$1"
    local wt="$NB/$tag-wt" bdir="$NB/$tag-backup" bootstrap=0 extra_path="$NB/fakebin"
    mkdir -p "$wt" "$bdir"
    NB_NOTES="$wt/WORKTREE_NOTES.md"
    [[ "$mode" != "nonotes" ]] && printf 'Session-ID: %s\nBranch: fix/test\n\n## BugsFound\n- unpromoted entry\n' "$sid" > "$NB_NOTES"
    local backup_arg="$bdir"
    NB_BACKUP="$bdir/WORKTREE_NOTES.md"
    if [[ "$dest" == "plans" ]]; then backup_arg="(none)"; NB_BACKUP="$WORKFLOW_PLANS_DIR/$sid-notes-backup/WORKTREE_NOTES.md"; fi
    [[ "$mode" == "notfile" ]] && mkdir -p "$NB_BACKUP"
    [[ "$mode" == "truncated" ]] && extra_path="$NB/shimbin:$NB/fakebin"
    [[ "$branch" == "bootstrap" ]] && bootstrap=1
    NB_RC=0
    (cd "$NB" && PATH="$extra_path:$PATH" BOOTSTRAP_MODE="$bootstrap" BOOTSTRAP_COMMIT_SHA=abc \
        run_with_timeout 60 bash "$NB/capture-env.sh" "$wt" "example-owner/example-repo" "$backup_arg" "$sid") \
        > "$NB/out.txt" 2> "$NB/err.txt" || NB_RC=$?
    NB_ERR="$(cat "$NB/err.txt")"
    NB_ENV="$WORKFLOW_STATE_DIR/$sid.control/final-report-env.json"
}
nb_env_state() { [[ -f "$NB_ENV" ]] && echo yes || echo no; }
nb_expect_ok() {
    if [[ "$NB_RC" == "0" && -f "$NB_ENV" ]] && cmp -s "$NB_NOTES" "$NB_BACKUP"; then
        pass "$1: exit 0, env JSON written, backup byte-identical"
    else
        fail "$1: exit 0 + env JSON + identical backup" "rc=$NB_RC env=$(nb_env_state) err=$NB_ERR"
    fi
}
nb_expect_abort() {
    if [[ "$NB_RC" != "0" && ! -f "$NB_ENV" ]] && grep -q "WORKTREE_NOTES.md" <<< "$NB_ERR"; then
        pass "$1: exit non-zero, no env JSON, stderr names WORKTREE_NOTES.md"
    else
        fail "$1: exit non-zero + no env JSON + stderr naming WORKTREE_NOTES.md" "rc=$NB_RC env=$(nb_env_state) err=$NB_ERR"
    fi
}

test_NB1_happy_path() {
    local b d
    for b in normal bootstrap; do for d in backupdir plans; do
        nb_run "ok-$b-$d" "$b" "$d" ok; nb_expect_ok "NB1 ok $b/$d"
    done; done
}
test_NB2_backup_path_not_a_file() {
    local b d
    for b in normal bootstrap; do for d in backupdir plans; do
        nb_run "nf-$b-$d" "$b" "$d" notfile; nb_expect_abort "NB2 directory at backup path $b/$d"
    done; done
}
test_NB3_truncated_copy() {
    local b d
    for b in normal bootstrap; do for d in backupdir plans; do
        nb_run "tr-$b-$d" "$b" "$d" truncated
        if [[ -f "$NB_BACKUP" ]] && ! cmp -s "$NB_NOTES" "$NB_BACKUP"; then pass "NB3 shim left a differing backup $b/$d"; else fail "NB3 shim left a differing backup $b/$d"; fi
        nb_expect_abort "NB3 truncated backup $b/$d"
    done; done
}
test_NB4_no_notes_skips_verify() {
    local b
    for b in normal bootstrap; do
        nb_run "nn-$b" "$b" plans nonotes
        if [[ "$NB_RC" == "0" && -f "$NB_ENV" && ! -e "$(dirname "$NB_BACKUP")" ]] && grep -q '"NOTES_BACKUP_PATH": ""' "$NB_ENV"; then
            pass "NB4 no notes $b: exit 0, env JSON with empty NOTES_BACKUP_PATH, no backup dir"
        else
            fail "NB4 no notes $b: exit 0 + empty NOTES_BACKUP_PATH" "rc=$NB_RC env=$(nb_env_state) err=$NB_ERR"
        fi
    done
}

# ============ Run all ============

case_begin "write-env-json-sibling-repos-field" "skills/worktree-end/scripts/write-env-json.js"
test_CE4_write_env_json_sibling_repos_field
case_end

case_begin "sibling-worktrees-awk-parse" "skills/worktree-end/scripts/capture-env.sh"
test_CEparse1_awk_parses_none_entry
test_CEparse2_awk_parses_one_entry
test_CEparse3_awk_parses_two_entries
test_CEparse4_awk_empty_body_after_header
test_CEparse5_awk_last_section_no_trailing_header
test_CEparse7_awk_no_sibling_section
case_end

case_begin "bootstrap-sibling-repos-empty" "skills/worktree-end/scripts/capture-env.sh"
test_CE1_capture_env_bootstrap_sibling_repos_empty
case_end

nb_setup

case_begin "notes-backup-happy-path-byte-identical" "skills/worktree-end/scripts/capture-env.sh"
test_NB1_happy_path
case_end

case_begin "notes-backup-path-not-a-file-aborts" "skills/worktree-end/scripts/capture-env.sh"
test_NB2_backup_path_not_a_file
case_end

case_begin "notes-backup-truncated-copy-aborts" "skills/worktree-end/scripts/capture-env.sh"
test_NB3_truncated_copy
case_end

case_begin "no-notes-skips-backup-verify" "skills/worktree-end/scripts/capture-env.sh"
test_NB4_no_notes_skips_verify
case_end

echo ""
echo "Results: $PASS passed, $FAIL failed, $SKIP skipped"
echo "Total: PASS=$PASS FAIL=$FAIL"

[ "$FAIL" -eq 0 ]
