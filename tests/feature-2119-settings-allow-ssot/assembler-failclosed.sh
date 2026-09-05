# tests/feature-2119-settings-allow-ssot/assembler-failclosed.sh
# Tests: install/assemble-settings.js, install/lib/settings-deploy.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T29: the deploy path is fail-closed, on both CLIs. Sourced AFTER generator.sh.

T29_ASM_NOSSOT=""
T29_ASM_BAD=""
T29_GEN_NOSSOT=""
T29_GEN_BAD=""
T29_OK=""
T29_ASM_NOCMD=""
T29_ASM_NOPATH=""
T29_ASM_PATHDIR=""

# T29 -- KEEPING THE OLD FILE IS THE SAFE FAILURE. If spelling generation breaks, a deploy
# that writes anyway produces a settings.json missing several hundred allow rules while
# reporting success: permissions regress silently and the machine looks healthy. The previous
# deployed file is strictly safer, so the contract is non-zero exit AND the deployed file left
# byte-identical. Both CLIs are asserted, because they share one writer and a polarity that
# holds in only one of them is the bug this pins (CPR-ORTH).
t29_case() { # <asm|gen> <case-id> -> "rc/state/reason/complete" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target before after rc out rcv state reason comp rule
    dir="$(mk_fixture "t29-$1-$2")"
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    write_settings "$dir" --
    # Every failure case is DEPLOYED HEALTHY FIRST: "left byte-identical" is only a claim when
    # there is a previous deployed file to preserve.
    [ "$2" = "healthy" ] || run_assemble "$dir"
    case "$2" in
        no-ssot)     rm -f "$dir/install/settings-allow-commands.txt" ;;
        bad-shebang) mk_tool "$dir" bin/fx-bad none
                     write_ssot "$dir" bin/fx-tool bin/fx-bad ;;
        # The three MISSING-RESOURCE inputs. Unlike the two above, each names a resource the
        # generator reads but never writes, so the tempting implementation is to shrug and
        # carry on -- which silently drops that resource's whole contribution (every bare
        # spelling, or one command's twenty-four) from an otherwise successful-looking deploy.
        no-cmd-file) write_ssot "$dir" bin/fx-tool bin/fx-ghost ;;
        no-path-ssot)  rm -f "$dir/install/path-exposed-commands.txt" ;;
        # `unreadable` spelled as a directory occupying the path: the mechanism cli-contract.sh
        # already uses for the SSOT, and the only one Windows honours (a chmod 0000 file there
        # is still readable by its owner).
        path-ssot-dir) rm -f "$dir/install/path-exposed-commands.txt"
                       mkdir -p "$dir/install/path-exposed-commands.txt" ;;
    esac
    target="$(deployed_file "$dir")"
    before="$(file_digest "$target")"
    if [ "$1" = "asm" ]; then run_assemble "$dir"; rc="$ASM_RC"; out="$ASM_OUT"
    else run_gen "$dir" --write; rc="$GEN_RC"; out="$GEN_OUT"; fi
    after="$(file_digest "$target")"
    if [ "$rc" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if [ ! -f "$target" ]; then state="absent"
    elif [ "$2" = "healthy" ]; then state="written"
    elif [ "$before" = "$after" ]; then state="unchanged"
    else state="DEPLOYED-ANYWAY"; fi
    if printf '%s\n' "$out" | grep -Eqi 'settings-allow-commands|shebang|interpreter|fx-bad|path-exposed-commands|fx-ghost'; then
        reason="reason-stated"
    else
        reason="NO-REASON"
    fi
    comp="-"
    if [ "$2" = "healthy" ]; then
        comp="complete"
        deployed_allow_dump "$dir" "$dir/allow.txt"
        while IFS= read -r rule; do
            [ -n "$rule" ] || continue
            grep -Fxq -- "$rule" "$dir/allow.txt" 2>/dev/null || { comp="MISSING:$rule"; break; }
        done < <(expected_path_rules bash bin/fx-tool "$dir")
    fi
    printf '%s/%s/%s/%s' "$rcv" "$state" "$reason" "$comp"
}

t29_setup() {
    T29_ASM_NOSSOT="$(t29_case asm no-ssot)"
    T29_ASM_BAD="$(t29_case asm bad-shebang)"
    T29_GEN_NOSSOT="$(t29_case gen no-ssot)"
    T29_GEN_BAD="$(t29_case gen bad-shebang)"
    T29_OK="$(t29_case asm healthy)"
    T29_ASM_NOCMD="$(t29_case asm no-cmd-file)"
    T29_ASM_NOPATH="$(t29_case asm no-path-ssot)"
    T29_ASM_PATHDIR="$(t29_case asm path-ssot-dir)"
}

# The stored verdict is `rc/state/reason/complete`; a row names the slot and the field it is
# about, so one fixture run feeds several independent assertions instead of being rebuilt.
t29_field() { # <slot> <n> -> field
    local v
    case "$1" in
        asm-nossot) v="$T29_ASM_NOSSOT" ;;
        asm-bad)    v="$T29_ASM_BAD" ;;
        gen-nossot) v="$T29_GEN_NOSSOT" ;;
        gen-bad)    v="$T29_GEN_BAD" ;;
        ok)          v="$T29_OK" ;;
        asm-nocmd)   v="$T29_ASM_NOCMD" ;;
        asm-nopath)  v="$T29_ASM_NOPATH" ;;
        asm-pathdir) v="$T29_ASM_PATHDIR" ;;
    esac
    case "$v" in
        '<MISSING:'*) printf '%s' "$v"; return ;;
    esac
    printf '%s' "$v" | cut -d'/' -f"$2"
}

t29_failclosed_table() {
    local id slot field want label
    while IFS='|' read -r id slot field want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T29[$id]: $label" "$want" "$(t29_field "$slot" "$field")"
    done <<'T29_CASES'
asm-nossot-rc|asm-nossot|1|nonzero|a deleted SSOT stops install/assemble-settings.js with a non-zero exit
asm-nossot-file|asm-nossot|2|unchanged|and the previously deployed settings.json is left byte-identical, not truncated or half-rewritten
asm-nossot-why|asm-nossot|3|reason-stated|the output names the cause, so the operator can fix it instead of guessing why the install failed
asm-bad-rc|asm-bad|1|nonzero|an SSOT entry whose interpreter cannot be resolved stops the assembler too
asm-bad-file|asm-bad|2|unchanged|leaving the previous deployment in place: a settings.json short of one command is worse than yesterday's
gen-nossot-rc|gen-nossot|1|nonzero|gen-settings-allow.js --write has the SAME polarity for the same broken input
gen-nossot-file|gen-nossot|2|unchanged|and the same duty of care toward the file it did not manage to rebuild
gen-bad-rc|gen-bad|1|nonzero|CPR-ORTH: the unresolvable-interpreter case fails closed in the second CLI as well
gen-bad-file|gen-bad|2|unchanged|with the deployed file untouched, because both CLIs go through the one writer
gen-bad-why|gen-bad|3|reason-stated|and the second CLI states its reason too, rather than exiting non-zero in silence
ok-rc|ok|1|zero|POSITIVE CONTROL: a healthy fixture deploys and exits 0, so the nine rows above are not passing because everything fails
ok-complete|ok|4|complete|and every one of the twenty-four generated path spellings reached the deployed file, so "it wrote something" is not mistaken for "it wrote the rules"
nocmd-rc|asm-nocmd|1|nonzero|an SSOT entry naming a file that does not exist stops the deploy: the entry cannot be expanded, and expanding the other eighteen anyway ships a settings.json quietly short of one command
nocmd-file|asm-nocmd|2|unchanged|and the previous deployment survives byte-identical
nocmd-why|asm-nocmd|3|reason-stated|the output names the unresolvable entry, so the operator knows WHICH SSOT line to fix
nopath-rc|asm-nopath|1|nonzero|a missing install/path-exposed-commands.txt stops the deploy rather than being read as "no command is PATH-exposed" -- that reading silently drops every bare spelling
nopath-file|asm-nopath|2|unchanged|leaving the deployed file untouched
nopath-why|asm-nopath|3|reason-stated|and naming the list it could not read, which an empty-list fallback would never have mentioned
pathdir-rc|asm-pathdir|1|nonzero|the same list present but unreadable (a directory occupying the path) fails closed too: unreadable and absent are not different contracts
pathdir-file|asm-pathdir|2|unchanged|with the previous deployment intact
T29_CASES
}

# T36 -- WRITE FAILURE AT THE DESTINATION. Every T29 case fails BEFORE the writer is reached, so
# the writer's own error path -- the one that runs when the destination refuses the write -- has
# no coverage at all. That is the path where a truncate-then-write implementation destroys a
# working settings.json and exits 0 on the way out.
#
# MECHANISM: chmod 0444 on the already-deployed destination FILE. Measured on this host before
# choosing: Node's writeFileSync into a 0444 file throws EPERM and leaves the bytes intact,
# while a read-only PARENT DIRECTORY (chmod 0555) is not honoured on Windows at all -- the probe
# wrote straight through it. A directory occupying the destination path does throw (EISDIR) but
# leaves no prior file to compare against, so it cannot carry the byte-identical assertion.
T36_MECH=""
T36_ASM=""
T36_GEN=""
T36_OK=""

# The mechanism is itself asserted first. If a future host stops honouring the read-only
# attribute, this row goes red instead of every row below turning into a silent no-op.
t36_mechanism() { # -> blocked|WRITABLE
    local d="$TMPROOT/t36-mech" f out
    mkdir -p "$d"
    f="$d/probe.json"
    printf 'ORIGINAL\n' > "$f"
    chmod 0444 "$f" 2>/dev/null || true
    out="$(node -e '
      try { require("fs").writeFileSync(process.argv[1], "OVERWRITTEN"); process.stdout.write("WRITABLE"); }
      catch (e) { process.stdout.write("blocked"); }
    ' "$(node_path "$f")" 2>/dev/null)" || out="NODE-ERROR"
    chmod 0644 "$f" 2>/dev/null || true
    printf '%s' "$out"
}

# A NAME-only manifest, not a checksum one: the positive control legitimately changes the
# deployed file's contents, so "no partial or temporary artifact was left behind" has to be a
# question about which files exist, asked identically of all three rows.
t36_names() { # <dir>
    ( cd "$1" 2>/dev/null || exit 0
      find . -type f 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' )
}

t36_case() { # <asm|gen|ok> -> "rc/state/artifacts" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target home before after names_before names_after rc rcv state arts
    dir="$(mk_fixture "t36-$1")"
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    write_settings "$dir" --
    run_assemble "$dir"
    target="$(deployed_file "$dir")"
    home="$dir/home/.claude"
    before="$(file_digest "$target")"
    names_before="$(t36_names "$home")"
    if [ "$1" = "ok" ]; then
        # The control has to make the second deploy produce DIFFERENT bytes, or "the write
        # landed" and "the write was refused" would look identical.
        printf '%s\n' 'Bash(second-pass-only *)' > "$dir/pre.txt"
        write_settings "$dir" "$dir/pre.txt"
    else
        chmod 0444 "$target" 2>/dev/null || true
    fi
    if [ "$1" = "gen" ]; then run_gen "$dir" --write; rc="$GEN_RC"
    else run_assemble "$dir"; rc="$ASM_RC"; fi
    chmod 0644 "$target" 2>/dev/null || true
    after="$(file_digest "$target")"
    names_after="$(t36_names "$home")"
    if [ "$rc" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if [ "$before" = "$after" ]; then state="unchanged"; else state="MODIFIED"; fi
    if [ "$names_before" = "$names_after" ]; then arts="same-files"; else arts="ARTIFACT:$names_after"; fi
    printf '%s/%s/%s' "$rcv" "$state" "$arts"
}

t36_setup() {
    T36_MECH="$(t36_mechanism)"
    T36_ASM="$(t36_case asm)"
    T36_GEN="$(t36_case gen)"
    T36_OK="$(t36_case ok)"
}

t36_field() { # <slot> <n> -> field
    local v
    case "$1" in
        asm) v="$T36_ASM" ;;
        gen) v="$T36_GEN" ;;
        ok)  v="$T36_OK" ;;
    esac
    case "$v" in
        '<MISSING:'*) printf '%s' "$v"; return ;;
    esac
    printf '%s' "$v" | cut -d'/' -f"$2"
}

t36_writefail_table() {
    local id slot field want label
    ROWS=$((ROWS + 1))
    assert_eq "T36[mechanism]: MECHANISM CHECK -- a chmod 0444 destination really does refuse a node write on this host (if not, every T36 row below is a no-op)" \
        "blocked" "$T36_MECH"
    while IFS='|' read -r id slot field want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T36[$id]: $label" "$want" "$(t36_field "$slot" "$field")"
    done <<'T36_CASES'
asm-rc|asm|1|nonzero|a destination that refuses the write makes install/assemble-settings.js exit non-zero -- a swallowed EPERM would report a deploy that never happened
asm-file|asm|2|unchanged|and the previously deployed settings.json is byte-identical: the writer never truncates before it knows the write can land
asm-artifacts|asm|3|same-files|with no partial or temporary file left in ~/.claude -- a failed atomic write must clean up its own staging file
gen-rc|gen|1|nonzero|CPR-ORTH: gen-settings-allow.js --write hits the same writer and fails the same way
gen-file|gen|2|unchanged|leaving the same file untouched
ok-rc|ok|1|zero|POSITIVE CONTROL: the identical fixture with a WRITABLE destination exits 0, so the rows above fail on the injection and not on the fixture
ok-file|ok|2|MODIFIED|and the deployed file really does change, proving the write path is reached rather than skipped
T36_CASES
}

t29_setup
t29_failclosed_table
t36_setup
t36_writefail_table
