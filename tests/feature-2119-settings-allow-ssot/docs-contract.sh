# tests/feature-2119-settings-allow-ssot/docs-contract.sh
# Tests: docs/architecture/claude-code/settings.md
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

SETTINGS_DOC_REL="docs/architecture/claude-code/settings.md"
SETTINGS_DOC="$AGENTS_DIR/$SETTINGS_DOC_REL"

# T23 -- THE DOCUMENT IS PART OF THE DELIVERABLE. This change moves ~150 permission rules from
# "hand-typed strings someone edits" to "generated output nobody may edit by hand", and the
# only place a future maintainer learns that is settings.md. An undocumented generator is
# re-hand-edited within one release: the next person adds a rule directly to settings.json,
# the gate blocks their commit, and they have no way to find out why. So the facts a reader
# needs before touching settings.json are asserted here, not left to review.

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
template-table-home%line%gen-settings-allow~template|spelling~one place|single|canonical|owns|only%says the spelling-template table lives in exactly one place (the reason hand-editing drifts)
excluded-wrappers%line%run-with-timeout~exclu|not |never |out of scope%records why wrapper launchers are deliberately NOT allow-listed, so nobody "fixes" the omission
orphan-limit%line%orphan~limit|cannot|not remove|never remove|manual|by hand%records the limit of orphan detection, so a stale rule is not assumed to be auto-removed
gate-location%line%review-settings-allow~pre-commit%locates the drift gate at hooks/pre-commit
gate-fail-closed%line%review-settings-allow|gate~fail-closed|fail closed%states the gate is fail-closed, so deleting it is not a way to turn it off
allow-vs-hooks%line%allow~PreToolUse~not |never |cannot %keeps the marker-bypass corollary: an allow rule does not disable a PreToolUse safety hook
T23_CASES
}

t23_docs_table
