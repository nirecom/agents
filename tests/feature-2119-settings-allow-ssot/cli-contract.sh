# tests/feature-2119-settings-allow-ssot/cli-contract.sh
# Tests: install/gen-settings-allow.js, install/assemble-settings.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T17: the CLI and error contract. Sourced AFTER write-and-drift.sh, whose helpers this reuses.

T17_PRE='Bash(hand-written-only *)'

# T17 -- THREE EXIT CODES, NOT TWO, and the protected file is now the DEPLOYED one. 0 = in
# sync, 1 = a real finding, 2 = the tool could not do its job at all (usage, unreadable input,
# unparseable base document, nothing deployed yet). Collapsing 2 into 1 reports a broken tool
# as drift; collapsing 2 into 0 is the fail-open hole this design closes. Every row also pins
# ~/.claude/settings.json, because an error path that has already half-written the file the
# permission engine reads is a worse outcome than the error itself. The four-branch validation
# the base document has always had -- parse / shape / permissions / allow -- is RETARGETED at the
# deployed document rather than dropped, so each branch gets its own row and its own token.
t17_fixture() { # <spec> -> fixture dir
    local spec="$1" dir
    dir="$(mk_fixture "t17-$spec")"
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    printf '%s\n' "$T17_PRE" > "$dir/pre.txt"
    write_settings "$dir" "$dir/pre.txt"
    # Every spec but `fresh` is DEPLOYED HEALTHY FIRST, and the damage is done afterwards.
    # Without that step an rc=2 row could not tell "rejected the bad input" from "there was
    # nothing deployed to check", and `fresh` is the row that pins the second reading.
    case "$spec" in
        fresh)   : ;;
        drifted) : > "$dir/install/settings-allow-commands.txt"
                 run_gen "$dir" --write
                 write_ssot "$dir" bin/fx-tool ;;
        *)       run_gen "$dir" --write ;;
    esac
    case "$spec" in
        no-ssot)      rm -f "$dir/install/settings-allow-commands.txt" ;;
        ssot-is-dir)  rm -f "$dir/install/settings-allow-commands.txt"
                      mkdir -p "$dir/install/settings-allow-commands.txt" ;;
        bad-json)     printf '%s\n' '{ "permissions": { "allow": [ ' > "$dir/settings.json" ;;
        array-json)   printf '%s\n' '["not", "an", "object"]' > "$dir/settings.json" ;;
        allow-string) printf '%s\n' '{ "permissions": { "allow": "Bash(nope *)" } }' > "$dir/settings.json" ;;
        # The four `dep-*` specs damage the DEPLOYED document and leave the fixture's base
        # settings.json healthy, which is the whole point: a --check still reading the repo
        # original would find that healthy base and answer rc=0 or rc=1, so rc=2 here can only
        # come from a --check that reads the deployed path.
        dep-json)     printf '%s\n' '{ "permissions": { "allow": [ ' > "$(deployed_file "$dir")" ;;
        dep-array)    printf '%s\n' '["not", "an", "object"]' > "$(deployed_file "$dir")" ;;
        dep-noperms)  printf '%s\n' '{ "env": { "FOO": "bar" } }' > "$(deployed_file "$dir")" ;;
        dep-allowstr) printf '%s\n' '{ "permissions": { "allow": "Bash(nope *)" } }' > "$(deployed_file "$dir")" ;;
    esac
    printf '%s\n' "$dir"
}

# WHICH validation branch fired, read off the fragment each one has carried all along. The plan
# keeps these four branches verbatim and swaps only the file they name, so matching the invariant
# half of the message pins the branch without pinning either the prose or the spelling of the
# deployed path. UNCLASSIFIED is a real verdict: an rc=2 that arrives with none of the four
# fragments is a crash being read as input validation, which is the failure this suite exists to
# prevent elsewhere (missing_lib) and must not be allowed back in through the message column.
t17_branch() { # -> branch token, from $GEN_OUT
    case "$GEN_OUT" in
        *"is not valid JSON"*)                                printf 'json-parse' ;;
        *"is not a JSON object"*)                             printf 'not-object' ;;
        *'no usable "permissions" object'*)                   printf 'no-permissions' ;;
        *"permissions.allow is present but is not an array"*) printf 'allow-not-array' ;;
        *)                                                    printf 'UNCLASSIFIED' ;;
    esac
}

# `--` in the args column stands for "no arguments at all", which the table cannot spell as an
# empty field without the row reading as a blank line. The `fresh` row carries a third field:
# rc=2 alone would also be produced by a crash, and what makes the "nothing is deployed yet"
# exit actionable is that the message says which command to run.
t17_probe() { # <spec> <args> -> "rc=<n>/<unchanged|MODIFIED|absent>[/<guidance>]" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local dir target before after state guide
    dir="$(t17_fixture "$1")"
    target="$(deployed_file "$dir")"
    before="$(file_digest "$target")"
    if [ "$2" = "--" ]; then
        run_gen "$dir"
    else
        # shellcheck disable=SC2086
        run_gen "$dir" $2
    fi
    after="$(file_digest "$target")"
    if [ ! -f "$target" ]; then state="absent"
    elif [ "$before" = "$after" ]; then state="unchanged"
    else state="MODIFIED"; fi
    case "$1" in
        fresh) : ;;
        dep-*) printf 'rc=%s/%s/%s' "$GEN_RC" "$state" "$(t17_branch)"; return ;;
        *)     printf 'rc=%s/%s' "$GEN_RC" "$state"; return ;;
    esac
    if printf '%s\n' "$GEN_OUT" | grep -q 'assemble-settings'; then guide="assemble-named"; else guide="NO-RERUN-GUIDANCE"; fi
    printf 'rc=%s/%s/%s' "$GEN_RC" "$state" "$guide"
}

t17_cli_table() {
    local id spec args want label
    while IFS='|' read -r id spec args want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T17[$id]: $label" "$want" "$(t17_probe "$spec" "$args")"
    done <<'T17_CASES'
no-args|insync|--|rc=2/unchanged|no mode at all is a usage error, and it leaves the deployed file alone
unknown-mode|insync|--frobnicate|rc=2/unchanged|an unrecognised mode is a usage error rather than a silent default to --check
write-typo|insync|--wrote|rc=2/unchanged|a near-miss of --write must not be accepted as --write
staged-alone|insync|--staged|rc=2/unchanged|--staged belonged to the deleted pre-commit gate: it is now an unknown argument, not a mode that quietly checks the index
check-staged|insync|--check --staged|rc=2/unchanged|and it stays unknown when appended to a valid mode, so a stale hook invocation fails loudly instead of half-working
malformed-json|bad-json|--write|rc=2/unchanged|a base settings.json that does not parse is an IO error, never a reason to deploy something built from a guess
structural-array|array-json|--write|rc=2/unchanged|valid JSON of the wrong shape (a top-level array) is still unusable as a base document
structural-allow|allow-string|--write|rc=2/unchanged|base permissions.allow present but not an array: appending to it would silently change its type
missing-ssot|no-ssot|--check|rc=2/unchanged|a deleted SSOT is an error, not "nothing to check" -- fail-closed
unreadable-ssot|ssot-is-dir|--check|rc=2/unchanged|an SSOT path that cannot be read as a file is the second way the input breaks
not-deployed|fresh|--check|rc=2/absent/assemble-named|nothing deployed yet is an outage, not drift: rc=2, no file conjured, and the message names install/assemble-settings.js so the reader knows the fix
dep-json|dep-json|--check|rc=2/unchanged/json-parse|a DEPLOYED document that does not parse is the second reading of "the tool could not do its job", and it is REACHED only because --check reads the deployed path -- the fixture base beside it is healthy
dep-array|dep-array|--check|rc=2/unchanged/not-object|valid JSON of the wrong shape at the deployed path (top-level array) is rejected on its own branch, not folded into the parse failure above
dep-noperms|dep-noperms|--check|rc=2/unchanged/no-permissions|a deployed document with no usable permissions object is rc=2, never rc=1: "there are no rules here" must not be reported as "every generated rule is missing"
dep-allowstr|dep-allowstr|--check|rc=2/unchanged/allow-not-array|a deployed permissions.allow that is a string is rc=2 for the same reason -- comparing the generated set against a scalar would name all 30 spellings as drift
check-in-sync|insync|--check|rc=0/unchanged|a deployed file carrying every current spelling is the only rc=0 for --check
check-drift|drifted|--check|rc=1/unchanged|a genuine finding is rc=1 -- distinguishable from the rc=2 outages above
write-success|drifted|--write|rc=0/MODIFIED|a successful deploy reports rc=0 (POSITIVE CONTROL: the seventeen rows above are not all failing for one shared reason)
T17_CASES
}

t17_cli_table
