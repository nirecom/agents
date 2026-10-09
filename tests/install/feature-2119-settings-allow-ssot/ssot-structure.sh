# tests/install/feature-2119-settings-allow-ssot/ssot-structure.sh
# Tests: install/settings-allow-commands.txt, install/path-exposed-commands.txt, hooks/lib/allow-command-list.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T0-T3b: the SSOT file itself. Sourced by tests/install/feature-2119-settings-allow-ssot.sh, which
# owns PASS/FAIL/ROWS, assert_eq, ssot_entries and every path variable used here.

SSOT_PRESENT="no"
[ -f "$SSOT" ] && SSOT_PRESENT="yes"
SSOT_LIST="$(ssot_entries "$SSOT")"

# T0 is a FAIL, never a SKIP. A skip here is the exact failure mode this suite exists to
# prevent: the SSOT is the whole feature, so "not built yet" and "deleted by accident" have
# to be the same red line.
case_begin "t0-ssot-exists" "install/settings-allow-commands.txt"
t0_ssot_exists() {
    assert_eq "T0: $SSOT_REL exists (IMPLEMENTATION MISSING while absent -- this is a FAIL, not a SKIP)" \
        "yes" "$SSOT_PRESENT"
}
t0_ssot_exists
case_end

case_begin "t1a-entries-exist" "install/settings-allow-commands.txt"
t1a_entries_exist() {
    if [ "$SSOT_PRESENT" != "yes" ]; then
        fail "T1a: cannot check entry existence -- $SSOT_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local missing="" e
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        [ -f "$SCRIPT_CHECKOUT_ROOT/$e" ] || missing="$missing $e"
    done <<< "$SSOT_LIST"
    assert_eq "T1a: every SSOT entry resolves to a real file under the agents root" "" "$missing"
}
t1a_entries_exist
case_end

# The interpreter is never written in the SSOT; it is read from the shebang. The resolution
# hooks/lib/allow-command-list.js must implement is spelled out here as the reference: `env <x>`
# takes the following token, and anything that is not bash or node is unresolved (no allow).
case_begin "t1b-shebangs-resolve" "hooks/lib/allow-command-list.js"
resolve_shebang() { # <file> -> bash|node|unresolved
    local line first
    [ -f "$1" ] || { printf 'unresolved'; return; }
    IFS= read -r line < "$1"
    case "$line" in "#!"*) : ;; *) printf 'unresolved'; return ;; esac
    set -- ${line#\#!}
    [ "$#" -gt 0 ] || { printf 'unresolved'; return; }
    first="$(basename "$1")"
    if [ "$first" = "env" ]; then
        shift
        [ "$#" -gt 0 ] || { printf 'unresolved'; return; }
        first="$(basename "$1")"
    fi
    case "$first" in bash|node) printf '%s' "$first" ;; *) printf 'unresolved' ;; esac
}

t1b_shebangs_resolve() {
    if [ "$SSOT_PRESENT" != "yes" ]; then
        fail "T1b: cannot check shebangs -- $SSOT_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local bad="" e r
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        r="$(resolve_shebang "$SCRIPT_CHECKOUT_ROOT/$e")"
        [ "$r" = "bash" ] || [ "$r" = "node" ] || bad="$bad $e:$r"
    done <<< "$SSOT_LIST"
    assert_eq "T1b: every SSOT entry's shebang resolves to bash or node (anything else is fail-closed)" "" "$bad"
}
t1b_shebangs_resolve
case_end

# T2a is the conservative-charset gate. Each entry is a path bash-guard auto-approves (#2264),
# so a `..`, a leading slash, a drive letter or a glob metacharacter would WIDEN the approved
# set rather than merely name a file -- the one place here where a typo is a security change
# and not a broken build.
case_begin "t2a-charset" "install/settings-allow-commands.txt"
t2a_charset() {
    if [ "$SSOT_PRESENT" != "yes" ]; then
        fail "T2a: cannot check the entry charset -- $SSOT_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local bad="" e
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        case "$e" in
            *..*|[A-Za-z]:*|/*|*\**|*\?*|*\[*|*\ *|*\\*) bad="$bad $e"; continue ;;
        esac
        printf '%s' "$e" | grep -Eq '^[A-Za-z0-9._/-]+$' || bad="$bad $e"
    done <<< "$SSOT_LIST"
    assert_eq "T2a: every entry is a plain relative path (no .., no leading slash, no drive letter, no glob metacharacter)" \
        "" "$bad"
}
t2a_charset
case_end

case_begin "t2b-no-duplicates" "install/settings-allow-commands.txt"
t2b_no_duplicates() {
    if [ "$SSOT_PRESENT" != "yes" ]; then
        fail "T2b: cannot check for duplicates -- $SSOT_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local dups
    dups="$(printf '%s\n' "$SSOT_LIST" | sort | uniq -d | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
    assert_eq "T2b: the SSOT carries no duplicate entry" "" "$dups"
}
t2b_no_duplicates
case_end

case_begin "t2c-non-empty" "install/settings-allow-commands.txt"
t2c_non_empty() {
    local n got
    n="$(printf '%s\n' "$SSOT_LIST" | grep -c . || true)"
    got="empty"
    [ "${n:-0}" -gt 0 ] && got="non-empty"
    assert_eq "T2c: the SSOT is non-empty (it currently lists ${n:-0} entries)" "non-empty" "$got"
}
t2c_non_empty
case_end

in_ssot() { # <entry> -> yes|no
    printf '%s\n' "$SSOT_LIST" | grep -Fxq -- "$1" && { printf 'yes'; return; }
    printf 'no'
}

# T3a -- EXCLUSION REGRESSION PIN. Four commands were deliberately dropped, each for a
# different admission-criterion reason. The reason lives in the row label, so anyone
# re-adding one has to delete a sentence explaining why it must not be there.
case_begin "t3a-exclusions" "install/settings-allow-commands.txt"
t3a_exclusions() {
    local entry label
    while IFS='|' read -r entry label; do
        [ -n "$entry" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T3a[$entry]: $label" "no" "$(in_ssot "$entry")"
    done <<'T3A_CASES'
bin/run-with-timeout.sh|wrapper launcher -- its trailing template would allow-list every command run through it (criterion d)
bin/github-issues/issue-create-dispatch.sh|gh write: creates issues and attaches sub-issues, changing state outside the repo (criterion a)
hooks/record-off-skill-invocation.js|hook body launched by the platform, not by the model; no skill or rule tells anyone to run it (criterion e)
bin/github-issues/issue-body-append.sh|gh write: edits an existing issue body, changing state outside the repo (criterion a)
T3A_CASES
}
t3a_exclusions
case_end

# T3b -- ADMISSION SNAPSHOT PIN. Presence rows alone cannot see a silent shrink, so the exact
# membership is pinned: one row per entry plus a count assertion. A member that stops meeting
# the admission criteria then has to leave through this test rather than through a quiet
# deletion, and one ARRIVING has to arrive through it too -- the count row is what makes an
# unannounced addition visible, since every presence row still passes when the file grows.
# The three that PR #2158's security review removed (get-config-var, request-off-clearance,
# worker-dispatch.js) stay out. #2201 admitted two; #2102 admitted read-session-facts (it was
# never pinned here, so the count row is what caught it); #2075 admitted find-tests-for-source.sh;
# #2265 admitted handoff-append; #2455 admitted the read-only test-lanes-status.sh;
# #2079 admitted the run-tests calibration probe and the one-effect session mark.
case_begin "t3b-snapshot" "install/settings-allow-commands.txt"
t3b_snapshot() {
    local entry n
    while IFS= read -r entry; do
        [ -n "$entry" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T3b[$entry]: listed in the SSOT" "yes" "$(in_ssot "$entry")"
    done <<'T3B_CASES'
bin/workflow/next-step
bin/supervisor-report
bin/workflow-plans-dir
bin/worker-dispatch-paths
bin/resolve-worktree-path
bin/concern-ledger
bin/review-code-codex
bin/confirm-off
bin/parse-closes-issues
bin/workflow/set-workflow-type
bin/workflow/record-complexity-and-skip
skills/worktree-start/scripts/derive-worktree-name.sh
bin/workflow/read-complexity-evaluation
bin/workflow/derive-complexity-level
bin/workflow/read-step-status
bin/check-issues-class-coverage
bin/workflow/record-skip-judgment
skills/_shared/assemble-mandatory.sh
bin/detect-scope-change.sh
skills/review-tests/scripts/select-staged-files.sh
bin/detect-non-github.sh
bin/worktree-notes-append.js
bin/workflow/read-session-facts
skills/issue-create/scripts/make-empty-verdict.sh
bin/find-tests-for-source.sh
bin/workflow/handoff-append
bin/test-lanes-status.sh
skills/run-tests/scripts/probe-calibration.sh
skills/run-tests/scripts/mark-calibration-asked.sh
T3B_CASES
    n="$(printf '%s\n' "$SSOT_LIST" | grep -c . || true)"
    assert_eq "T3b: the SSOT holds exactly the 29 pinned entries and nothing else" "29" "${n:-0}"
}
t3b_snapshot
case_end

# T46 -- THE READER, NOT THE FILE. Every row above reads the SSOT through ssot_entries, and the
# allow-command-list.js reads both list files again in production: split on \n, strip TRAILING
# whitespace only, drop empty lines and lines whose first non-blank character is `#`. Neither
# reader is exercised by the real files, which are tidy. A disagreement between them is silent
# and one-directional: an entry the harness drops but the reader keeps becomes an auto-approved
# path that no test in this suite ever looks at, and the reverse hides a real entry from T1a's
# existence check and T2a's charset gate. Each row therefore pins the parse AND the agreement.
# Target: the path-exposed list is the second file this shared line format governs.
case_begin "t46-reader-format" "install/path-exposed-commands.txt"
T46_DIR="$TMPROOT/t46"

t46_write() { # <case> <file>
    case "$1" in
        crlf)             printf 'bin/a\r\nbin/b\r\n' ;;
        crlf-no-final)    printf '# c\r\nbin/a\r\n\r\nbin/b\r' ;;
        trailing-space)   printf 'bin/a   \nbin/b\t \n' ;;
        no-final-newline) printf 'bin/a\nbin/b' ;;
        indented-comment) printf '   # three spaces then hash\nbin/a\n\t# tab then hash\n' ;;
        leading-space)    printf '  bin/a\nbin/b\n' ;;
        inline-hash)      printf 'bin/a # not-a-comment\nbin/b\n' ;;
        blank-only)       printf '\n   \n\t\n' ;;
        *)                printf '' ;;
    esac > "$2"
}

# The production contract restated here, the way resolve_shebang restates the interpreter rule:
# importing allow-command-list.js's own reader could only prove it equals itself.
# BATCHED: one node reads every case file named on argv (each its own file, so no case sees
# another's bytes) and emits one NUL-terminated comma-joined result per file, in argv order.
T46_REFERENCE_JS='
  const fs = require("fs");
  const out = process.argv.slice(1).map((f) => {
    let raw = "";
    try { raw = fs.readFileSync(f, "utf8"); } catch (e) { raw = ""; }
    return raw.split("\n").map((l) => l.replace(/\s+$/, ""))
      .filter((l) => l.length > 0 && !/^\s*#/.test(l)).join(",");
  });
  process.stdout.write(out.map((s) => s + "\0").join(""));
'

# Bracketed so a leading space inside an entry, and an empty result, are both visible in the
# table's want column instead of being eaten by it.
t46_probe() { # <case-file> <reference-result> -> [entries] | DISAGREE...
    local h r="$2"
    h="$(ssot_entries "$1" | tr '\n' ',' | sed -e 's/,$//')"
    [ "$h" = "$r" ] || { printf 'DISAGREE harness[%s] reader[%s]' "$h" "$r"; return; }
    printf '[%s]' "$h"
}

t46_reader_table() {
    local id want label f i dir_np ids=() wants=() labels=() files=()
    mkdir -p "$T46_DIR"
    dir_np="$(node_path "$T46_DIR")"
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        f="$T46_DIR/$id.txt"
        if [ "$id" = "absent-file" ]; then rm -f "$f"; else t46_write "$id" "$f"; fi
        ids+=("$id"); wants+=("$want"); labels+=("$label"); files+=("$dir_np/$id.txt")
    done <<'T46_CASES'
crlf|[bin/a,bin/b]|a CRLF file parses to the same entries as an LF one -- a surviving \r would become part of the entry and match nothing
crlf-no-final|[bin/a,bin/b]|CRLF plus a comment, a blank line and no final newline at once: the last entry is still read
trailing-space|[bin/a,bin/b]|trailing spaces and tabs are stripped, so an invisible edit does not become a distinct entry
no-final-newline|[bin/a,bin/b]|a file whose last line has no newline still yields that last entry rather than dropping it
indented-comment|[bin/a]|a `#` after leading spaces or a tab is still a comment: the first NON-BLANK character decides
leading-space|[  bin/a,bin/b]|leading whitespace is NOT stripped -- it stays part of the entry so T2a's charset gate rejects it instead of a trimmed path being silently approved
inline-hash|[bin/a # not-a-comment,bin/b]|`#` after text starts no comment: only a whole-line comment is dropped, so a `#` in a path cannot truncate an entry
blank-only|[]|a file of nothing but blank and whitespace-only lines reads as zero entries, not as one empty entry
empty-file|[]|a zero-byte file reads as zero entries
absent-file|[]|a file that does not exist reads as zero entries rather than erroring out of the sourcing part file
T46_CASES
    nul_records "T46 reference reader" "${#ids[@]}" node -e "$T46_REFERENCE_JS" "${files[@]}"
    for i in "${!ids[@]}"; do
        ROWS=$((ROWS + 1))
        assert_eq "T46[${ids[$i]}]: ${labels[$i]}" "${wants[$i]}" \
            "$(t46_probe "$T46_DIR/${ids[$i]}.txt" "${NUL_RECS[$i]}")"
    done
}
t46_reader_table
case_end
