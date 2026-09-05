# tests/feature-2119-settings-allow-ssot/docs-contract.sh
# Tests: docs/architecture/claude-code/settings.md, install/lib/settings-allow-rules.js
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

# CO-OCCURRENCE CANNOT READ POLARITY, AND THE COUNT ROWS ARE WHERE THAT MATTERS. "The generator
# does not emit twenty-four path spellings" carries every token the count probe looks for and
# states the opposite of the contract; so does "sixteen forms rather than twenty-four". The
# `count` mode below therefore vetoes a line before matching it: a negation standing within a
# clause of an emit/count word, or a supersession phrase anywhere on the line, disqualifies that
# line as evidence. Bounded to `[^.]{0,24}` and to the same sentence, so an unrelated "no" later
# in a long sentence does not silence a correct statement.
DOC_NEG='(\bnot\b|\bno\b|\bnever\b|\bnone\b|don.t|doesn.t|isn.t|aren.t|cannot|can.t|need not|nothing)'
DOC_HEAD='(emit|generat|produc|render|deploy|inject|writ|creat|number|count|total|spelling|rule)'
DOC_SUPERSEDE='(rather than|instead of|supersed|formerly|used to |no longer|obsolete|outdated|deprecated|incorrectly)'

doc_anti_ere() { printf '%s' "($DOC_NEG[^.]{0,24}$DOC_HEAD|$DOC_SUPERSEDE)"; }

doc_line_matches_affirmative() { # <file> <ere>... -> 0 when one AFFIRMATIVE line matches every ere
    local file="$1"; shift
    local anti line ere ok
    [ -f "$file" ] || return 1
    anti="$(doc_anti_ere)"
    while IFS= read -r line; do
        printf '%s\n' "$line" | grep -Eqi -- "$anti" && continue
        ok=yes
        for ere in "$@"; do
            printf '%s\n' "$line" | grep -Eqi -- "$ere" || { ok=no; break; }
        done
        [ "$ok" = yes ] && return 0
    done < "$file"
    return 1
}

# The table is `%`-delimited and its regex column is `~`-delimited, because ERE alternation
# needs `|` for itself. The file argument is a parameter rather than $SETTINGS_DOC so the same
# probe interrogates the mutant fixtures and the changed source file, not the doc alone.
doc_probe_in() { # <file> <rel> <mode:line|file|count> <ere-list> -> present|ABSENT|sentinel
    local file="$1" rel="$2" mode="$3" list="$4" old_ifs found=1
    [ -f "$file" ] || { printf '<MISSING:%s>' "$rel"; return; }
    old_ifs="$IFS"; IFS='~'
    # shellcheck disable=SC2086
    set -- $list
    IFS="$old_ifs"
    case "$mode" in
        file)  grep -Eqi -- "$1" "$file" && found=0 ;;
        count) doc_line_matches_affirmative "$file" "$@" && found=0 ;;
        *)     doc_line_matches "$file" "$@" && found=0 ;;
    esac
    [ "$found" -eq 0 ] && { printf 'present'; return; }
    printf 'ABSENT'
}

t23_probe() { # <mode:line|file|count> <ere-list> -> present|ABSENT|sentinel
    doc_probe_in "$SETTINGS_DOC" "$SETTINGS_DOC_REL" "$1" "$2"
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
T23_CASES
}

# THE STALE HALF. The counts double when the argument-less siblings are added, so the document's
# old eight/three/eleven prose does not go WRONG-looking -- it stays a fluent sentence that
# happens to describe the previous release. A reader who finds it first has no way to tell which
# of two confident numbers is current, and the pre-commit prose is worse: it tells them to expect
# a gate that has been deleted. Absence is therefore asserted, not merely presence of the new text.
# #2201 makes the same move a second time -- sixteen/twenty-two are now the superseded pair --
# which is why the stale rows are a growing list rather than a one-off cleanup.
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
stale-sixteen%file%sixteen ([a-z]+ )?(path )?(rules?|spellings?)%no longer claims sixteen path spellings -- true only until #2201 added the four QUOTED absolute-path families, and left standing it reads as a current count rather than a superseded one
stale-twenty-two%file%twenty-two ([a-z]+ )?(rules?|spellings?)%no longer claims twenty-two rules per command: the per-command total moved with the path count, and a reader who finds the old number first has two confident figures and no way to tell which release each belongs to
stale-reviewer%file%review-settings-allow%no longer points a reader at bin/review-settings-allow, which this change deletes
stale-precommit-gate%line%pre-commit~allow|settings\.json~gate|block|review|drift%no longer describes a pre-commit gate over the allow rules: the drift it guarded cannot exist once the rules are generated, and the prose would send a reader hunting for a hook that is gone
T23_STALE_CASES
}

# THE COUNTS ARE THEIR OWN CONTRACT, AND ONE ERE OWNS EACH. The three numbers are the only part
# of settings.md an operator can check against a real deployed settings.json, and they are what
# #2201 changes; they are also the rows a polarity-reversed sentence would slip past. The EREs
# live in one function so the real-document rows and the mutant rows below cannot drift apart --
# a mutant that a laxer copy of the regex accepts would prove nothing about the doc rows.
t23_count_eres() { # <id> -> ~-delimited ERE list
    case "$1" in
        path-24)  printf '%s' 'twenty-four|\b24\b~path~spelling|permission rule|allow rule' ;;
        bare-6)   printf '%s' '\bsix\b|\b6\b~bare~spelling|permission rule|allow rule' ;;
        total-30) printf '%s' 'thirty|\b30\b~rule|permission|spelling' ;;
        *)        printf '%s' 'UNKNOWN-COUNT-@@@' ;;
    esac
}

t23_count_table() {
    local id label
    while IFS='%' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T23[count-$id]: $SETTINGS_DOC_REL $label" "present" \
            "$(t23_probe count "$(t23_count_eres "$id")")"
    done <<'T23_COUNT_CASES'
path-24%states the exact number of PATH spellings, so a reader counting rules in a deployed file can tell a missing family from a miscount -- the context word is `spelling`, not `form` or a bare `rule`, because settings.md also documents 24 credential-path roots in dot-segment FORMS and a loose context ERE reports that unrelated line as this contract
bare-6%and the exact number of BARE spellings, which is keyed on a different list and is the half a reader is most likely to miscount
total-30%and the per-command total, the one number an operator can check against a real deployed settings.json
T23_COUNT_CASES
}

# Each mutant keeps every token the count ERE looks for and reverses only the polarity, so the
# three canonical controls and the five reversals differ in nothing else. Without them the veto
# above is untested prose: a probe that accepted the reversals would still show three green rows.
t23_fixture() { # <name> <line> -> path to a one-line fixture document
    local dir="$TMPROOT/t23fx"
    mkdir -p "$dir"
    printf '%s\n' "$2" > "$dir/$1.md"
    printf '%s' "$dir/$1.md"
}

t23_count_fixture_table() {
    local id count want line label file
    while IFS='%' read -r id count want line label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        file="$(t23_fixture "$id" "$line")"
        assert_eq "T23[count-fx-$id]: $label" "$want" \
            "$(doc_probe_in "$file" "$id.md" count "$(t23_count_eres "$count")")"
    done <<'T23_COUNT_FIXTURE_CASES'
canon-path%path-24%present%CONTROL: Twenty-four path spellings are emitted for every PATH-exposed command.%a plain affirmative statement of the path count is accepted, so the four reversals below fail for their polarity and not for a probe that rejects everything
canon-bare%bare-6%present%CONTROL: Six bare spellings are emitted alongside them, one allow rule each.%and the affirmative bare-count statement
canon-total%total-30%present%CONTROL: Thirty permission rules are emitted per PATH-exposed command.%and the affirmative per-command total
negate-path%path-24%ABSENT%The generator does not emit twenty-four path spellings.%a flat denial carries every token the path-count probe matches and states the opposite of the contract
nolonger-path%path-24%ABSENT%It no longer produces twenty-four path spellings for a PATH-exposed command.%so does a sentence retiring the number, which is exactly how a superseded count reads after the NEXT change
ratherthan-path%path-24%ABSENT%Sixteen forms are used rather than twenty-four path spellings.%and a supersession phrase, where the number a reader must act on is the one the sentence rejects
negate-bare%bare-6%ABSENT%The tool does not emit six bare spellings.%CPR-ORTH: the bare-count row is vetoed on the same terms, not just the path one
negate-total%total-30%ABSENT%Thirty permission rules are never emitted for a PATH-exposed command.%and the per-command total, whose ERE is the loosest of the three and therefore the likeliest to accept a reversal
T23_COUNT_FIXTURE_CASES
}

# THE SOURCE FILE MAKES THE SAME CLAIM, AND NOTHING WAS WATCHING IT. settings-allow-rules.js
# states the per-command total in a comment beside the templates it counts; #2201 changes the
# templates. Left behind, the stale number is worse than the doc's, because it sits where the
# next maintainer looks to learn how many rules a template list is supposed to produce.
SRC_LIB_REL="install/lib/settings-allow-rules.js"
SRC_LIB="$AGENTS_DIR/$SRC_LIB_REL"

t23_src_table() {
    local id mode eres want label
    while IFS='%' read -r id mode eres want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T23[$id]: $SRC_LIB_REL $label" "$want" "$(doc_probe_in "$SRC_LIB" "$SRC_LIB_REL" "$mode" "$eres")"
    done <<'T23_SRC_CASES'
src-stale-twenty-two%file%twenty-two%ABSENT%no longer claims twenty-two rules per entry: the comment sits beside the template list it counts, so a reader trusts it over any document
src-stale-sixteen%file%sixteen%ABSENT%and does not fall back to the path-only figure either -- the two numbers were superseded together
src-count-current%count%twenty-four|\b24\b~rule|spelling%present%and states the current count affirmatively, in the same comment, so the template list and the number describing it are read together
T23_SRC_CASES
}

t23_docs_table
t23_count_table
t23_count_fixture_table
t23_src_table
t23_stale_table
