# tests/feature-2119-settings-allow-ssot/docs-contract.sh
# Tests: docs/architecture/claude-code/settings.md
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

SETTINGS_DOC_REL="docs/architecture/claude-code/settings.md"
SETTINGS_DOC="$AGENTS_DIR/$SETTINGS_DOC_REL"

# T23 -- THE DOCUMENT IS PART OF THE DELIVERABLE. This change moves several hundred permission
# rules out of the repository entirely: they are injected into ~/.claude/settings.json at
# deploy time, and the only place a maintainer learns that is settings.md. Undocumented, the
# next person adds a rule to the repo's settings.json, watches the next deploy behave as if it
# were not there, and has no way to find out why. So the facts a reader needs before touching
# either file are asserted here rather than left to review.

# Co-occurrence on ONE line, not anywhere in a 400-line document: settings.md already talks
# about `settings.json`, about hooks and about pre-commit in unrelated sections, so a
# file-wide grep for each token separately would pass on today's document, before a word about
# this feature is written.
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
t23_probe() { # <mode:line|file> <ere-list> -> present|ABSENT|sentinel
    local mode="$1" list="$2" old_ifs found=1
    [ -f "$SETTINGS_DOC" ] || { printf '<MISSING:%s>' "$SETTINGS_DOC_REL"; return; }
    old_ifs="$IFS"; IFS='~'
    # shellcheck disable=SC2086
    set -- $list
    IFS="$old_ifs"
    if [ "$mode" = "file" ]; then
        grep -Eqi -- "$1" "$SETTINGS_DOC" && found=0
    else
        doc_line_matches "$SETTINGS_DOC" "$@" && found=0
    fi
    [ "$found" -eq 0 ] && { printf 'present'; return; }
    printf 'ABSENT'
}

# THE EXCLUSION LIST IS THE OTHER HALF OF THE ADMISSION CRITERION. settings.md states what is
# admitted in one clause and what is excluded in the next; pinning only the first leaves every
# absent command looking like an omission somebody should fix. Each excluded FAMILY therefore
# gets its own row, so deleting one from the sentence cannot hide behind the survivors.
t23_docs_table() {
    local id mode eres label
    while IFS='%' read -r id mode eres label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T23[$id]: $SETTINGS_DOC_REL $label" "present" "$(t23_probe "$mode" "$eres")"
    done <<'T23_CASES'
ssot-named%file%install/settings-allow-commands\.txt%names the SSOT file, so a maintainer adding a command knows where to add it
generator-named%file%install/gen-settings-allow\.js%names the generator
data-flow%line%settings-allow-commands~gen-settings-allow%states the flow from SSOT to generator in one sentence, not as two unrelated mentions
flow-to-settings%line%gen-settings-allow~settings\.json%and carries that flow through to settings.json, the file the reader was about to hand-edit
template-table-home%line%gen-settings-allow|settings-allow-rules~template|spelling~one place|single|canonical|owns|only%says the spelling-template table lives in exactly one place (the reason hand-editing drifts)
excluded-wrappers%line%run-with-timeout~exclu|not |never |out of scope%records why wrapper launchers are deliberately NOT allow-listed, so nobody "fixes" the omission
excluded-gh-writes%line%gh write|gh_write|`gh` write~exclu|not |never |out of scope%names `gh` writes as an excluded family: the SSOT is an admission list, and a reader who only sees the admission criterion will read every un-listed command as an oversight
excluded-git-state%line%git state~exclu|not |never |out of scope%names git state-changing commands, the family a contributor is likeliest to add "because the workflow issues them constantly"
excluded-dotenv%line%\.env~exclu|not |never |out of scope%names `.env` readers, so a credential-reading command is not admitted on the grounds that it is internal and auto-issued
excluded-hook-bodies%line%hook bod~exclu|not |never |out of scope%names platform-launched hook bodies, which are never issued through the permission engine at all
excluded-dispatchers%line%dispatch~exclu|not |never |out of scope%names dispatchers whose state-changing work hides behind an argument the engine never sees -- the exclusion whose REASON is least guessable, and therefore the one most likely to be undone
orphan-limit%line%orphan~hand-written|stale|by hand|manual|limit|cannot|not remove|never remove%records the limit of orphan detection, so a stale rule is not assumed to be auto-removed
deploy-injection%line%inject|deploy~\.claude%states that the generated rules are injected into the deployed settings.json, not stored anywhere the reader can edit
no-generated-in-repo%line%generated~not |never |no longer ~commit|repo|tracked%and that they are therefore NOT committed, so a reader does not go looking for them in the repository
argless-pair%line%argument-less|arg-less|without argument|no argument~pair|both|two|as well%explains that every spelling is emitted in an argument-bearing and an argument-less form, which is the bug this change fixes
no-prefix-match%line%prefix|whole command|entire command|full command~match%explains WHY that pair is needed: the permission engine matches the whole command string, so a trailing wildcard is not a prefix match
single-writer%line%assemble-settings~only|single|sole%names install/assemble-settings.js as the one writer of the deployed file, so a second writer is recognisable as a bug
allow-vs-hooks%line%allow~PreToolUse~not |never |cannot %keeps the marker-bypass corollary: an allow rule does not disable a PreToolUse safety hook
count-path-16%line%sixteen|\b16\b~path~spelling|rule|form%states the exact number of PATH spellings, so a reader counting rules in a deployed file can tell a missing family from a miscount
count-bare-6%line%\bsix\b|\b6\b~bare~spelling|rule|form%and the exact number of BARE spellings, which is keyed on a different list and is the half a reader is most likely to miscount
count-total-22%line%twenty-two|\b22\b~rule|permission|spelling%and the per-command total, the one number an operator can check against a real deployed settings.json
T23_CASES
}

# THE STALE HALF. The counts double when the argument-less siblings are added, so the document's
# old eight/three/eleven prose does not go WRONG-looking -- it stays a fluent sentence that
# happens to describe the previous release. A reader who finds it first has no way to tell which
# of two confident numbers is current, and the pre-commit prose is worse: it tells them to expect
# a gate that has been deleted. Absence is therefore asserted, not merely presence of the new text.
t23_stale_table() {
    local id mode eres label
    while IFS='%' read -r id mode eres label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T23[$id]: $SETTINGS_DOC_REL $label" "ABSENT" "$(t23_probe "$mode" "$eres")"
    done <<'T23_STALE_CASES'
stale-eight%file%eight path spellings?%no longer claims eight path spellings anywhere -- that count was true only before the argument-less siblings existed
stale-three%file%three bare spellings?%no longer claims three bare spellings
stale-eleven%file%eleven ([a-z]+ )?(rules?|spellings?)%no longer claims eleven rules per command
stale-reviewer%file%review-settings-allow%no longer points a reader at bin/review-settings-allow, which this change deletes
stale-precommit-gate%line%pre-commit~allow|settings\.json~gate|block|review|drift%no longer describes a pre-commit gate over the allow rules: the drift it guarded cannot exist once the rules are generated, and the prose would send a reader hunting for a hook that is gone
T23_STALE_CASES
}

t23_docs_table
t23_stale_table
