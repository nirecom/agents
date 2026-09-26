# tests/feature-2119-settings-allow-ssot/assembler-failclosed.sh
# Tests: install/assemble-settings.js, install/lib/settings-deploy.js, install/lib/settings-assembly.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T29/T36: the deploy path is fail-closed on ITS OWN inputs. Sourced AFTER fixture.sh.

T29_NOBASE=""
T29_ALLOWTYPE=""
T29_OK=""
T29_IND_NOSSOT=""
T29_IND_BAD=""
T29_IND_NOCMD=""
T29_IND_NOPATH=""
T29_IND_PATHDIR=""

# T29 -- KEEPING THE OLD FILE IS THE SAFE FAILURE. A base document the deploy cannot trust
# (missing, or permissions.allow of the wrong type) must stop it with a non-zero exit AND leave
# the previous deployed file byte-identical. The other half is the #2264 inversion: the deploy
# no longer reads the SSOT lists, so a broken list must NOT stop it -- the lists now feed
# bash-guard, and a deploy that still failed on them would still depend on the generator.
t29_case() { # <case-id> -> "rc/state/reason" | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target before after rcv state reason
    dir="$(mk_fixture "t29-$1")"
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    write_settings "$dir" --
    # Every failure case is DEPLOYED HEALTHY FIRST: "left byte-identical" is only a claim when
    # there is a previous deployed file to preserve.
    [ "$1" = "healthy" ] || run_assemble "$dir"
    case "$1" in
        no-base)       rm -f "$dir/settings.json" ;;
        allow-type)    printf '%s\n' '{ "permissions": { "allow": "Bash(not-an-array *)" } }' > "$dir/settings.json" ;;
        no-ssot)       rm -f "$dir/install/settings-allow-commands.txt" ;;
        bad-shebang)   mk_tool "$dir" bin/fx-bad none
                       write_ssot "$dir" bin/fx-tool bin/fx-bad ;;
        no-cmd-file)   write_ssot "$dir" bin/fx-tool bin/fx-ghost ;;
        no-path-ssot)  rm -f "$dir/install/path-exposed-commands.txt" ;;
        path-ssot-dir) rm -f "$dir/install/path-exposed-commands.txt"
                       mkdir -p "$dir/install/path-exposed-commands.txt" ;;
    esac
    target="$(deployed_file "$dir")"
    before="$(file_digest "$target")"
    run_assemble "$dir"
    after="$(file_digest "$target")"
    if [ "$ASM_RC" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if [ ! -f "$target" ]; then state="absent"
    elif [ "$1" = "healthy" ]; then state="written"
    elif [ "$before" = "$after" ]; then state="unchanged"
    else state="MODIFIED"; fi
    if printf '%s\n' "$ASM_OUT" | grep -Eqi 'settings\.json|permissions'; then
        reason="reason-stated"
    else
        reason="NO-REASON"
    fi
    printf '%s/%s/%s' "$rcv" "$state" "$reason"
}

t29_setup() {
    T29_NOBASE="$(t29_case no-base)"
    T29_ALLOWTYPE="$(t29_case allow-type)"
    T29_OK="$(t29_case healthy)"
    T29_IND_NOSSOT="$(t29_case no-ssot)"
    T29_IND_BAD="$(t29_case bad-shebang)"
    T29_IND_NOCMD="$(t29_case no-cmd-file)"
    T29_IND_NOPATH="$(t29_case no-path-ssot)"
    T29_IND_PATHDIR="$(t29_case path-ssot-dir)"
}

# The stored verdict is `rc/state/reason`; a row names the slot and the field it is about, so
# one fixture run feeds several independent assertions instead of being rebuilt.
t29_field() { # <slot> <n> -> field
    local v
    case "$1" in
        nobase)      v="$T29_NOBASE" ;;
        allowtype)   v="$T29_ALLOWTYPE" ;;
        ok)          v="$T29_OK" ;;
        ind-nossot)  v="$T29_IND_NOSSOT" ;;
        ind-bad)     v="$T29_IND_BAD" ;;
        ind-nocmd)   v="$T29_IND_NOCMD" ;;
        ind-nopath)  v="$T29_IND_NOPATH" ;;
        ind-pathdir) v="$T29_IND_PATHDIR" ;;
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
nobase-rc|nobase|1|nonzero|a deleted base settings.json stops install/assemble-settings.js with a non-zero exit -- it is never created from scratch
nobase-file|nobase|2|unchanged|and the previously deployed settings.json is left byte-identical, not truncated or half-rewritten
nobase-why|nobase|3|reason-stated|the output names the cause, so the operator can fix it instead of guessing why the install failed
allowtype-rc|allowtype|1|nonzero|a base whose permissions.allow is not an array stops the deploy rather than being coerced
allowtype-file|allowtype|2|unchanged|leaving the previous deployment in place
ok-rc|ok|1|zero|POSITIVE CONTROL: a healthy fixture deploys and exits 0, so the rows above are not passing because everything fails
ok-written|ok|2|written|and the deployed file exists afterwards
ind-nossot|ind-nossot|1|zero|#2264: a deleted settings-allow-commands.txt no longer stops the deploy -- the list feeds bash-guard, not settings.json
ind-bad|ind-bad|1|zero|an SSOT entry with no resolvable shebang no longer stops the deploy either
ind-nocmd|ind-nocmd|1|zero|an SSOT entry naming a missing file no longer stops the deploy
ind-nopath|ind-nopath|1|zero|a missing path-exposed-commands.txt no longer stops the deploy
ind-pathdir|ind-pathdir|1|zero|a directory occupying path-exposed-commands.txt no longer stops the deploy (CPR-ORTH: every list input is independent of it)
T29_CASES
}

# T36 -- WRITE FAILURE AT THE DESTINATION. Every T29 failure stops BEFORE the writer is
# reached, so the writer's own error path -- the one where a truncate-then-write implementation
# destroys a working settings.json and exits 0 -- has no coverage there.
#
# MECHANISM: chmod 0444 on the already-deployed destination FILE. Node's writeFileSync into a
# 0444 file throws EPERM and leaves the bytes intact, while a read-only PARENT DIRECTORY is not
# honoured on Windows at all. A directory occupying the path leaves no prior file to compare.
T36_MECH=""
T36_ASM=""
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
# question about which files exist, asked identically of both rows.
t36_names() { # <dir>
    ( cd "$1" 2>/dev/null || exit 0
      find . -type f 2>/dev/null | LC_ALL=C sort | tr '\n' ' ' )
}

t36_case() { # <asm|ok> -> "rc/state/artifacts" | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target home before after names_before names_after rcv state arts
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
    run_assemble "$dir"
    chmod 0644 "$target" 2>/dev/null || true
    after="$(file_digest "$target")"
    names_after="$(t36_names "$home")"
    if [ "$ASM_RC" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if [ "$before" = "$after" ]; then state="unchanged"; else state="MODIFIED"; fi
    if [ "$names_before" = "$names_after" ]; then arts="same-files"; else arts="ARTIFACT:$names_after"; fi
    printf '%s/%s/%s' "$rcv" "$state" "$arts"
}

t36_setup() {
    T36_MECH="$(t36_mechanism)"
    T36_ASM="$(t36_case asm)"
    T36_OK="$(t36_case ok)"
}

t36_field() { # <slot> <n> -> field
    local v
    case "$1" in
        asm) v="$T36_ASM" ;;
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
ok-rc|ok|1|zero|POSITIVE CONTROL: the identical fixture with a WRITABLE destination exits 0, so the rows above fail on the injection and not on the fixture
ok-file|ok|2|MODIFIED|and the deployed file really does change, proving the write path is reached rather than skipped
T36_CASES
}

t29_setup
t29_failclosed_table
t36_setup
t36_writefail_table
