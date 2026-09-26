# tests/feature-2119-settings-allow-ssot/deploy-preconditions.sh
# Tests: install/assemble-settings.js, install/lib/settings-deploy.js, install/lib/settings-assembly.js
# Tags: install, settings, permissions, deploy, first-install, scope:issue-specific, pwsh-not-required, TL2
# T40-T41: the two preconditions of the deploy path. Sourced AFTER assembler-failclosed.sh.
# The gen-settings-allow.js half of each table retired with the generator in #2264.

T40_TOOL="bin/fx-tool"
T40_MARKER='Bash(t40-base-marker *)'

# T40 -- FIRST INSTALL. Every other fixture in this suite starts with a `home/.claude` directory
# already created, so the whole suite could pass on a machine where the deploy cannot create its
# own destination -- which is precisely the state of a new machine running install.sh for the
# first time, and the state a `git clone` + post-checkout lands in. The contract is
# `fs.mkdirSync(path.dirname(outPath), { recursive: true })`, so BOTH the missing `.claude`
# directory and a missing home above it must resolve to a normal successful deploy.
t40_case() { # <no-claude-dir|no-home> -> "pre/rc/state/rules" | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target pre rcv state rules
    dir="$(mk_fixture "t40-$1")"
    mk_tool "$dir" "$T40_TOOL" env-bash
    write_ssot "$dir" "$T40_TOOL"
    printf '%s\n' "$T40_MARKER" > "$dir/pre.txt"
    write_settings "$dir" "$dir/pre.txt"
    write_ext "$dir" --
    case "$1" in
        no-claude-dir) rm -rf "$dir/home/.claude" ;;
        no-home)       rm -rf "$dir/home" ;;
    esac
    # The precondition is recorded, not assumed: mk_fixture creates home/.claude, so a helper
    # that stops removing it would leave every row below passing against the ordinary case.
    if [ -e "$dir/home/.claude" ]; then pre="PRESENT-BEFORE"; else pre="absent-before"; fi
    target="$(deployed_file "$dir")"
    run_assemble "$dir"
    if [ "$ASM_RC" -eq 0 ]; then rcv="zero"; else rcv="nonzero"; fi
    if [ -f "$target" ]; then state="created"; else state="ABSENT"; fi
    rules="-"
    if [ -f "$target" ]; then
        deployed_allow_dump "$dir" "$dir/allow.txt"
        if grep -Fxq -- "$T40_MARKER" "$dir/allow.txt" 2>/dev/null; then rules="rules-present"; else rules="RULES-MISSING"; fi
    fi
    printf '%s/%s/%s/%s' "$pre" "$rcv" "$state" "$rules"
}

t40_field() { # <verdict> <n> -> field
    case "$1" in
        '<MISSING:'*) printf '%s' "$1"; return ;;
    esac
    printf '%s' "$1" | cut -d'/' -f"$2"
}

T40_VERDICTS=""

t40_setup() {
    local kind
    for kind in no-claude-dir no-home; do
        T40_VERDICTS="$T40_VERDICTS$kind=$(t40_case "$kind")
"
    done
}

t40_slot() { # <slot> -> verdict
    printf '%s\n' "$T40_VERDICTS" | grep "^$1=" | sed "s/^$1=//"
}

t40_firstinstall_table() {
    local slot field want label
    while IFS='|' read -r slot field want label; do
        [ -n "$slot" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T40[$slot/f$field]: $label" "$want" "$(t40_field "$(t40_slot "$slot")" "$field")"
    done <<'T40_CASES'
no-claude-dir|1|absent-before|PRECONDITION: the fixture really has no ~/.claude before install/assemble-settings.js runs
no-claude-dir|2|zero|a first install with no ~/.claude directory is the normal path, not an error: the assembler exits 0
no-claude-dir|3|created|and creates the destination directory on the way, so a fresh machine ends up with a deployed settings.json
no-claude-dir|4|rules-present|carrying the base's rules -- "a file appeared" is not the same as "the base was deployed"
no-home|1|absent-before|PRECONDITION: the home directory itself is gone, not merely its .claude child
no-home|2|zero|a home with nothing in it at all still deploys: recursive mkdir means the missing PARENT is not a separate failure mode
no-home|3|created|and the whole path down to ~/.claude/settings.json is created
no-home|4|rules-present|complete with the base's rules
T40_CASES
}

T41_MECH=""

# T41 -- THE BASE DOCUMENT IS MISSING OR UNREADABLE. `buildAssembledSettings` reads settings.json
# first and throws when it cannot. Absent and unreadable are asserted as the SAME contract on
# purpose: an implementation that treats a missing base as `{}` deploys a settings.json
# stripped of every hand-written rule and reports success.
#
# MECHANISM for `unreadable`: a directory occupying the path (EISDIR). chmod cannot make a file
# unreadable by its owner on this host, and a read-only parent directory is not honoured at all.
t41_mechanism() { # -> blocked|READABLE
    local d="$TMPROOT/t41-mech" out
    mkdir -p "$d/settings.json"
    out="$(node -e '
      try { require("fs").readFileSync(process.argv[1], "utf8"); process.stdout.write("READABLE"); }
      catch (e) { process.stdout.write("blocked"); }
    ' "$(node_path "$d/settings.json")" 2>/dev/null)" || out="NODE-ERROR"
    printf '%s' "$out"
}

t41_case() { # <absent|is-dir> -> "rc/state/named/code" | sentinel
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target before after rcv state named code
    dir="$(mk_fixture "t41-$1")"
    mk_tool "$dir" "$T40_TOOL" env-bash
    write_ssot "$dir" "$T40_TOOL"
    write_settings "$dir" --
    # Deployed healthy FIRST: "left byte-identical" is only a claim when a previous deployment
    # exists to preserve, and without it a fail-closed row cannot be told from a no-op run.
    run_assemble "$dir"
    case "$1" in
        absent) rm -f "$dir/settings.json" ;;
        is-dir) rm -f "$dir/settings.json"; mkdir -p "$dir/settings.json" ;;
    esac
    target="$(deployed_file "$dir")"
    before="$(file_digest "$target")"
    run_assemble "$dir"
    after="$(file_digest "$target")"
    if [ "$ASM_RC" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if [ ! -f "$target" ]; then state="absent"
    elif [ "$before" = "$after" ]; then state="unchanged"
    else state="DEPLOYED-ANYWAY"; fi
    if printf '%s\n' "$ASM_OUT" | grep -Fq 'settings.json'; then named="named"; else named="NOT-NAMED"; fi
    if printf '%s\n' "$ASM_OUT" | grep -Eq 'ENOENT|EISDIR|EACCES|EPERM|EBUSY'; then code="code-stated"; else code="NO-CODE"; fi
    printf '%s/%s/%s/%s' "$rcv" "$state" "$named" "$code"
}

T41_VERDICTS=""

t41_setup() {
    local kind
    T41_MECH="$(t41_mechanism)"
    for kind in absent is-dir; do
        T41_VERDICTS="$T41_VERDICTS$kind=$(t41_case "$kind")
"
    done
}

t41_slot() { # <slot> -> verdict
    printf '%s\n' "$T41_VERDICTS" | grep "^$1=" | sed "s/^$1=//"
}

t41_basedoc_table() {
    local slot field want label
    ROWS=$((ROWS + 1))
    assert_eq "T41[mechanism]: MECHANISM CHECK -- a directory occupying settings.json really is unreadable to node on this host (if not, the is-dir rows below are no-ops)" \
        "blocked" "$T41_MECH"
    while IFS='|' read -r slot field want label; do
        [ -n "$slot" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T41[$slot/f$field]: $label" "$want" "$(t40_field "$(t41_slot "$slot")" "$field")"
    done <<'T41_CASES'
absent|1|nonzero|a base settings.json that is not there stops install/assemble-settings.js -- reading it as an empty document would deploy a file stripped of every hand-written rule
absent|2|unchanged|and the previous deployment survives byte-identical, which is strictly safer than a settings.json missing every hand-written rule
absent|3|named|the message names settings.json, so the operator learns WHICH input is missing rather than that "assembly failed"
absent|4|code-stated|and carries the cause code, which is what separates "not there" from "there but unreadable" at a glance
is-dir|1|nonzero|a base settings.json present but unreadable is the SAME contract as absent, not a softer one
is-dir|2|unchanged|with the previous deployment intact
is-dir|3|named|and the file named in the message
is-dir|4|code-stated|and the cause code stated, so an EISDIR is not reported as if the file were simply missing
T41_CASES
}

# T43 lives in the sibling deploy-symlink-policy.sh.

t40_setup
t40_firstinstall_table
t41_setup
t41_basedoc_table
