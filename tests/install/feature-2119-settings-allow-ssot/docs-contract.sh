# tests/feature-2119-settings-allow-ssot/docs-contract.sh
# Tests: docs/architecture/claude-code/settings.md, hooks/lib/allow-command-list.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

SETTINGS_DOC_REL="docs/architecture/claude-code/settings.md"
SETTINGS_DOC="$AGENTS_DIR/$SETTINGS_DOC_REL"

# T23 -- THE DOCUMENT IS PART OF THE DELIVERABLE. Since #2264 the agents' own commands are no
# longer allow-listed through generated settings.json rules: bash-guard answers them with
# permissionDecision "allow" from the two SSOT lists, read by hooks/lib/allow-command-list.js.
# settings.md is the only place a maintainer learns that, so the facts a reader needs before
# touching either list are asserted here, and the generator prose is asserted GONE.

# Co-occurrence on ONE line, not anywhere in a long document: settings.md already talks about
# `settings.json`, hooks and allow rules in unrelated sections, so a file-wide grep for each
# token separately would pass on a document that never states the contract.
doc_line_matches() { # <file> <ere>... -> 0 when one line matches every ere
    local file="$1"; shift
    local line ere ok
    [ -f "$file" ] || return 1
    while IFS= read -r line; do
        ok=yes
        for ere in "$@"; do
            printf '%s\n' "$line" | grep -Eqi -- "$ere" || { ok=no; break; }
        done
        [ "$ok" = yes ] && return 0
    done < "$file"
    return 1
}

# The table is `%`-delimited and its regex column is `~`-delimited, because ERE alternation
# needs `|` for itself.
doc_probe_in() { # <file> <rel> <mode:line|file> <ere-list> -> present|ABSENT|sentinel
    local file="$1" rel="$2" mode="$3" list="$4" old_ifs found=1
    [ -f "$file" ] || { printf '<MISSING:%s>' "$rel"; return; }
    old_ifs="$IFS"; IFS='~'
    # shellcheck disable=SC2086
    set -- $list
    IFS="$old_ifs"
    case "$mode" in
        file) grep -Eqi -- "$1" "$file" && found=0 ;;
        *)    doc_line_matches "$file" "$@" && found=0 ;;
    esac
    [ "$found" -eq 0 ] && { printf 'present'; return; }
    printf 'ABSENT'
}

t23_probe() { # <mode:line|file> <ere-list> -> present|ABSENT|sentinel
    doc_probe_in "$SETTINGS_DOC" "$SETTINGS_DOC_REL" "$1" "$2"
}

# THE EXCLUSION LIST IS THE OTHER HALF OF THE ADMISSION CRITERION. Each excluded FAMILY gets its
# own row, so deleting one from the sentence cannot hide behind the survivors -- and since an
# entry is now auto-approved by a hook rather than by a rule, the criterion matters MORE.
t23_docs_table() {
    local id mode eres label
    while IFS='%' read -r id mode eres label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T23[$id]: $SETTINGS_DOC_REL $label" "present" "$(t23_probe "$mode" "$eres")"
    done <<'T23_CASES'
ssot-named%file%install/settings-allow-commands\.txt%names the SSOT file, so a maintainer adding a command knows where to add it
path-list-named%file%install/path-exposed-commands\.txt%names the PATH-exposed list, the second input that decides the bare spellings
reader-named%file%hooks/lib/allow-command-list\.js%names the reader that turns both lists into the allow set
data-flow%line%allow-command-list~bash-guard|allow\.js%states the flow from the reader to bash-guard in one sentence, not as two unrelated mentions
decision-allow%line%permissionDecision~allow%says the result is a hook permissionDecision "allow", so nobody goes looking for generated rules in settings.json
deny-survives%line%allow~deny~still|remain|stay|survive|not overrid|cannot overrid|never overrid|continue%keeps the corollary that a hook allow does not override deny / ask rules
cwd-normalize%line%cwd~relative%states that a relative spelling is only allowed when the cwd is known, so a missing or invalid cwd cannot widen the approved set
compound-deny%line%bash-guard~compound|&&~deny%says a compound command line is denied by bash-guard unconditionally, replacing the old glob-matching caveat
excluded-wrappers%line%run-with-timeout~exclu|not |never |out of scope%records why wrapper launchers are deliberately NOT allow-listed, so nobody "fixes" the omission
excluded-gh-writes%line%gh write|gh_write|`gh` write~exclu|not |never |out of scope%names `gh` writes as an excluded family: a reader who only sees the admission criterion will read every un-listed command as an oversight
excluded-git-state%line%git state~exclu|not |never |out of scope%names git state-changing commands, the family a contributor is likeliest to add "because the workflow issues them constantly"
excluded-dotenv%line%\.env~exclu|not |never |out of scope%names `.env` readers, so a credential-reading command is not admitted on the grounds that it is internal and auto-issued
excluded-hook-bodies%line%hook bod~exclu|not |never |out of scope%names platform-launched hook bodies, which are never issued through the permission engine at all
excluded-dispatchers%line%dispatch~exclu|not |never |out of scope%names dispatchers whose state-changing work hides behind an argument the engine never sees
single-writer%line%assemble-settings~only|single|sole%names install/assemble-settings.js as the one writer of the deployed file, so a second writer is recognisable as a bug
allow-vs-hooks%line%allow~PreToolUse~not |never |cannot %keeps the marker-bypass corollary: an allow rule does not disable a PreToolUse safety hook
T23_CASES
}

# THE STALE HALF. A superseded paragraph does not look wrong -- it stays a fluent description of
# the previous release, and a reader who finds it first has no way to tell which of two confident
# accounts is current. Absence is therefore asserted, not merely presence of the new text. #2264
# retires the generator and every per-command count with it, so all the counts join this list.
t23_stale_table() {
    local id mode eres label
    while IFS='%' read -r id mode eres label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T23[$id]: $SETTINGS_DOC_REL $label" "ABSENT" "$(t23_probe "$mode" "$eres")"
    done <<'T23_STALE_CASES'
stale-generator%file%gen-settings-allow%no longer names install/gen-settings-allow.js, which #2264 deletes
stale-rules-lib%file%settings-allow-rules%no longer names install/lib/settings-allow-rules.js, deleted with it
stale-generated-section%file%generated allow rules%no longer carries the "Generated allow rules" section the bash-guard section replaces
stale-eight%file%eight path spellings?%no longer claims eight path spellings anywhere
stale-three%file%three bare spellings?%no longer claims three bare spellings
stale-eleven%file%eleven ([a-z]+ )?(rules?|spellings?)%no longer claims eleven rules per command
stale-sixteen%file%sixteen ([a-z]+ )?(path )?(rules?|spellings?)%no longer claims sixteen path spellings
stale-twenty-two%file%twenty-two ([a-z]+ )?(rules?|spellings?)%no longer claims twenty-two rules per command
stale-twenty-four%file%twenty-four ([a-z]+ )?(path )?(rules?|spellings?)%no longer claims twenty-four path spellings -- the last count the generator emitted, now superseded by the hook
stale-reviewer%file%review-settings-allow%no longer points a reader at bin/review-settings-allow, which #2119 deleted
stale-precommit-gate%line%pre-commit~allow|settings\.json~gate|block|review|drift%no longer describes a pre-commit gate over the allow rules
T23_STALE_CASES
}

t23_docs_table
t23_stale_table
