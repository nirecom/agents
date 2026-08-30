# tests/feature-2119-settings-allow-ssot/cli-contract.sh
# Tests: install/gen-settings-allow.js, settings.json
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T17: the CLI and error contract. Sourced AFTER write-and-drift.sh, whose helpers this reuses.

T17_PRE='Bash(hand-written-only *)'

# T17 -- THREE EXIT CODES, NOT TWO. bin/review-settings-allow maps rc to PERFORMED/FAIL and
# hooks/pre-commit blocks on any non-zero, so the classes must be distinguishable at the
# source: 0 = in sync, 1 = a real finding (missing or orphaned), 2 = the generator could not
# do its job at all (usage, unreadable input, unparseable settings.json). Collapsing 2 into 1
# reports a broken tool as a drift finding; collapsing 2 into 0 is the fail-open hole the whole
# design was reversed to close. Every row also pins the file, because an error path that has
# already half-written settings.json is a worse outcome than the error.
t17_fixture() { # <spec> -> fixture dir
    local spec="$1" dir
    dir="$(mk_fixture "t17-$spec")"
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    printf '%s\n' "$T17_PRE" > "$dir/pre.txt"
    write_settings "$dir" "$dir/pre.txt"
    case "$spec" in
        insync)      run_gen "$dir" --write ;;
        drift)       : ;;
        no-ssot)     rm -f "$dir/install/settings-allow-commands.txt" ;;
        ssot-is-dir) rm -f "$dir/install/settings-allow-commands.txt"
                     mkdir -p "$dir/install/settings-allow-commands.txt" ;;
        bad-json)    printf '%s\n' '{ "permissions": { "allow": [ ' > "$dir/settings.json" ;;
        array-json)  printf '%s\n' '["not", "an", "object"]' > "$dir/settings.json" ;;
        allow-string) printf '%s\n' '{ "permissions": { "allow": "Bash(nope *)" } }' > "$dir/settings.json" ;;
        no-settings) rm -f "$dir/settings.json" ;;
    esac
    printf '%s\n' "$dir"
}

# `--` in the args column stands for "no arguments at all", which the table cannot spell as an
# empty field without the row reading as a blank line.
t17_probe() { # <spec> <args> -> "rc=<n>/<unchanged|MODIFIED|absent>" | sentinel
    have_gen || { missing_gen; return; }
    local dir before after state
    dir="$(t17_fixture "$1")"
    before="$(file_digest "$dir/settings.json")"
    if [ "$2" = "--" ]; then run_gen "$dir"; else run_gen "$dir" "$2"; fi
    after="$(file_digest "$dir/settings.json")"
    if [ ! -f "$dir/settings.json" ]; then state="absent"
    elif [ "$before" = "$after" ]; then state="unchanged"
    else state="MODIFIED"; fi
    printf 'rc=%s/%s' "$GEN_RC" "$state"
}

t17_cli_table() {
    local id spec args want label
    while IFS='|' read -r id spec args want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T17[$id]: $label" "$want" "$(t17_probe "$spec" "$args")"
    done <<'T17_CASES'
no-args|drift|--|rc=2/unchanged|no mode at all is a usage error, and it writes nothing
unknown-mode|drift|--frobnicate|rc=2/unchanged|an unrecognised mode is a usage error rather than a silent default to --check
write-typo|drift|--wrote|rc=2/unchanged|a near-miss of --write must not be accepted as --write
malformed-json|bad-json|--write|rc=2/unchanged|settings.json that does not parse is an IO/format error, never a reason to overwrite it
structural-array|array-json|--write|rc=2/unchanged|valid JSON of the wrong shape (a top-level array) is still unusable
structural-allow|allow-string|--write|rc=2/unchanged|permissions.allow present but not an array: appending to it would silently change its type
missing-ssot|no-ssot|--check|rc=2/unchanged|a deleted SSOT is an error, not "nothing to check" -- fail-closed
unreadable-ssot|ssot-is-dir|--check|rc=2/unchanged|an SSOT path that cannot be read as a file is the second way the input breaks
missing-settings|no-settings|--write|rc=2/absent|a deleted settings.json is not created from scratch by --write
check-in-sync|insync|--check|rc=0/unchanged|the fully synced tree is the only rc=0 for --check
check-drift|drift|--check|rc=1/unchanged|a genuine finding is rc=1 -- distinguishable from the rc=2 outages above
write-success|drift|--write|rc=0/MODIFIED|a successful --write reports rc=0 (POSITIVE CONTROL: the eleven rows above are not all failing for one shared reason)
T17_CASES
}

t17_cli_table
