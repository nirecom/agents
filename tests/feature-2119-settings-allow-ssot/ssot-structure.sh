# tests/feature-2119-settings-allow-ssot/ssot-structure.sh
# Tests: install/settings-allow-commands.txt, install/path-exposed-commands.txt
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T0-T3b: the SSOT file itself. Sourced by tests/feature-2119-settings-allow-ssot.sh, which
# owns PASS/FAIL/ROWS, assert_eq, ssot_entries and every path variable used here.

SSOT_PRESENT="no"
[ -f "$SSOT" ] && SSOT_PRESENT="yes"
SSOT_LIST="$(ssot_entries "$SSOT")"

# T0 is a FAIL, never a SKIP. A skip here is the exact failure mode this suite exists to
# prevent: the SSOT is the whole feature, so "not built yet" and "deleted by accident" have
# to be the same red line.
t0_ssot_exists() {
    assert_eq "T0: $SSOT_REL exists (IMPLEMENTATION MISSING while absent -- this is a FAIL, not a SKIP)" \
        "yes" "$SSOT_PRESENT"
}

# The interpreter is never written in the SSOT; it is read from the shebang. The resolution
# the generator must implement is spelled out here as the reference: `env <x>` takes the
# following token, and anything that is not bash or node is unresolved (fail-closed).
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

t1a_entries_exist() {
    if [ "$SSOT_PRESENT" != "yes" ]; then
        fail "T1a: cannot check entry existence -- $SSOT_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local missing="" e
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        [ -f "$AGENTS_DIR/$e" ] || missing="$missing $e"
    done <<< "$SSOT_LIST"
    assert_eq "T1a: every SSOT entry resolves to a real file under the agents root" "" "$missing"
}

t1b_shebangs_resolve() {
    if [ "$SSOT_PRESENT" != "yes" ]; then
        fail "T1b: cannot check shebangs -- $SSOT_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local bad="" e r
    while IFS= read -r e; do
        [ -n "$e" ] || continue
        r="$(resolve_shebang "$AGENTS_DIR/$e")"
        [ "$r" = "bash" ] || [ "$r" = "node" ] || bad="$bad $e:$r"
    done <<< "$SSOT_LIST"
    assert_eq "T1b: every SSOT entry's shebang resolves to bash or node (anything else is fail-closed)" "" "$bad"
}

# T2a is the conservative-charset gate. Each entry is interpolated into thirteen permission
# rules, so a `..`, a leading slash, a drive letter or a glob metacharacter would WIDEN a
# rule rather than merely name a file -- the one place here where a typo is a security change
# and not a broken build.
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

t2b_no_duplicates() {
    if [ "$SSOT_PRESENT" != "yes" ]; then
        fail "T2b: cannot check for duplicates -- $SSOT_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local dups
    dups="$(printf '%s\n' "$SSOT_LIST" | sort | uniq -d | tr '\n' ' ' | sed -e 's/[[:space:]]*$//')"
    assert_eq "T2b: the SSOT carries no duplicate entry" "" "$dups"
}

t2c_non_empty() {
    local n got
    n="$(printf '%s\n' "$SSOT_LIST" | grep -c . || true)"
    got="empty"
    [ "${n:-0}" -gt 0 ] && got="non-empty"
    assert_eq "T2c: the SSOT is non-empty (it currently lists ${n:-0} entries)" "non-empty" "$got"
}

in_ssot() { # <entry> -> yes|no
    printf '%s\n' "$SSOT_LIST" | grep -Fxq -- "$1" && { printf 'yes'; return; }
    printf 'no'
}

# T3a -- EXCLUSION REGRESSION PIN. Three commands were deliberately dropped from the initial
# list, each for a different admission-criterion reason. The reason lives in the row label, so
# anyone re-adding one has to delete a sentence explaining why it must not be there.
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
T3A_CASES
}

# T3b -- ADMISSION SNAPSHOT PIN. Presence rows alone cannot see a silent shrink, so the exact
# membership is pinned: eighteen rows plus a count assertion. A member that stops meeting the
# admission criteria then has to leave through this test rather than through a quiet deletion.
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
bin/get-config-var
bin/confirm-off
bin/request-off-clearance
bin/worker-dispatch.js
bin/parse-closes-issues
bin/workflow/set-workflow-type
bin/workflow/record-complexity-and-skip
skills/worktree-start/scripts/derive-worktree-name.sh
bin/workflow/read-complexity-evaluation
bin/workflow/derive-complexity-level
bin/workflow/read-step-status
T3B_CASES
    n="$(printf '%s\n' "$SSOT_LIST" | grep -c . || true)"
    assert_eq "T3b: the SSOT holds exactly the 18 pinned entries and nothing else" "18" "${n:-0}"
}

t0_ssot_exists
t1a_entries_exist
t1b_shebangs_resolve
t2a_charset
t2b_no_duplicates
t2c_non_empty
t3a_exclusions
t3b_snapshot
