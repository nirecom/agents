# tests/feature-2119-settings-allow-ssot/deploy-preconditions.sh
# Tests: install/assemble-settings.js, install/gen-settings-allow.js, install/lib/settings-deploy.js, install/lib/settings-assembly.js
# Tags: install, settings, permissions, deploy, first-install, scope:issue-specific, pwsh-not-required, TL2
# T40-T41: the two preconditions of the deploy path. Sourced AFTER assembler-failclosed.sh.

T40_TOOL="bin/fx-tool"

# T40 -- FIRST INSTALL. Every other fixture in this suite starts with a `home/.claude` directory
# already created, so the whole suite could pass on a machine where the deploy cannot create its
# own destination -- which is precisely the state of a new machine running install.sh for the
# first time, and the state a `git clone` + post-checkout lands in. The contract is
# `fs.mkdirSync(path.dirname(outPath), { recursive: true })`, so BOTH the missing `.claude`
# directory and a missing home above it must resolve to a normal successful deploy. Both CLIs
# are asserted because they reach that mkdir through the one shared writer (CPR-ORTH).
t40_case() { # <asm|gen> <no-claude-dir|no-home> -> "pre/rc/state/rules" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target pre rc rcv state rules first
    dir="$(mk_fixture "t40-$1-$2")"
    mk_tool "$dir" "$T40_TOOL" env-bash
    write_ssot "$dir" "$T40_TOOL"
    write_settings "$dir" --
    write_ext "$dir" --
    case "$2" in
        no-claude-dir) rm -rf "$dir/home/.claude" ;;
        no-home)       rm -rf "$dir/home" ;;
    esac
    # The precondition is recorded, not assumed: mk_fixture creates home/.claude, so a helper
    # that stops removing it would leave every row below passing against the ordinary case.
    if [ -e "$dir/home/.claude" ]; then pre="PRESENT-BEFORE"; else pre="absent-before"; fi
    target="$(deployed_file "$dir")"
    if [ "$1" = "asm" ]; then run_assemble "$dir"; rc="$ASM_RC"
    else run_gen "$dir" --write; rc="$GEN_RC"; fi
    if [ "$rc" -eq 0 ]; then rcv="zero"; else rcv="nonzero"; fi
    if [ -f "$target" ]; then state="created"; else state="ABSENT"; fi
    rules="-"
    if [ -f "$target" ]; then
        deployed_allow_dump "$dir" "$dir/allow.txt"
        first="$(expected_path_rules bash "$T40_TOOL" "$dir" | sed -n 1p)"
        if grep -Fxq -- "$first" "$dir/allow.txt" 2>/dev/null; then rules="rules-present"; else rules="RULES-MISSING"; fi
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
    local cli kind
    for cli in asm gen; do
        for kind in no-claude-dir no-home; do
            T40_VERDICTS="$T40_VERDICTS$cli-$kind=$(t40_case "$cli" "$kind")
"
        done
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
asm-no-claude-dir|1|absent-before|PRECONDITION: the fixture really has no ~/.claude before install/assemble-settings.js runs
asm-no-claude-dir|2|zero|a first install with no ~/.claude directory is the normal path, not an error: the assembler exits 0
asm-no-claude-dir|3|created|and creates the destination directory on the way, so a fresh machine ends up with a deployed settings.json
asm-no-claude-dir|4|rules-present|carrying the generated spellings -- "a file appeared" is not the same as "the rules were injected"
gen-no-claude-dir|1|absent-before|PRECONDITION: the same empty-home fixture for the second CLI
gen-no-claude-dir|2|zero|CPR-ORTH: gen-settings-allow.js --write reaches the same writer and succeeds on the same first-install input
gen-no-claude-dir|3|created|creating the same destination directory
gen-no-claude-dir|4|rules-present|with the same generated rules in it
asm-no-home|1|absent-before|PRECONDITION: the home directory itself is gone, not merely its .claude child
asm-no-home|2|zero|a home with nothing in it at all still deploys: recursive mkdir means the missing PARENT is not a separate failure mode
asm-no-home|3|created|and the whole path down to ~/.claude/settings.json is created
asm-no-home|4|rules-present|complete with the generated rules
gen-no-home|1|absent-before|PRECONDITION: the same absent-home fixture for the second CLI
gen-no-home|2|zero|CPR-ORTH: the second CLI does not fail where the first succeeds
gen-no-home|3|created|creating the same path
gen-no-home|4|rules-present|with the same rules, so neither entry point is the one that only works on an already-installed machine
T40_CASES
}

T41_MECH=""

# T41 -- THE BASE DOCUMENT IS MISSING OR UNREADABLE. `buildAssembledSettings` reads settings.json
# first and throws when it cannot; T17 covers the two MALFORMED spellings (unparseable JSON, wrong
# shape) but never the file simply not being there, which is the state a partial checkout, a
# reverted branch or a botched clone leaves behind. Absent and unreadable are asserted as the SAME
# contract on purpose: an implementation that treats a missing base as `{}` deploys a settings.json
# stripped of every hand-written rule and reports success.
#
# MECHANISM for `unreadable`: a directory occupying the path (EISDIR). chmod cannot make a file
# unreadable by its owner on this host, and a read-only parent directory is not honoured at all --
# both measured while writing assembler-failclosed.sh T36.
t41_mechanism() { # -> blocked|READABLE
    local d="$TMPROOT/t41-mech" out
    mkdir -p "$d/settings.json"
    out="$(node -e '
      try { require("fs").readFileSync(process.argv[1], "utf8"); process.stdout.write("READABLE"); }
      catch (e) { process.stdout.write("blocked"); }
    ' "$(node_path "$d/settings.json")" 2>/dev/null)" || out="NODE-ERROR"
    printf '%s' "$out"
}

t41_case() { # <asm|gen> <absent|is-dir> -> "rc/state/named/code" | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target before after rc out rcv state named code
    dir="$(mk_fixture "t41-$1-$2")"
    mk_tool "$dir" "$T40_TOOL" env-bash
    write_ssot "$dir" "$T40_TOOL"
    write_settings "$dir" --
    # Deployed healthy FIRST: "left byte-identical" is only a claim when a previous deployment
    # exists to preserve, and without it a fail-closed row cannot be told from a no-op run.
    run_assemble "$dir"
    case "$2" in
        absent) rm -f "$dir/settings.json" ;;
        is-dir) rm -f "$dir/settings.json"; mkdir -p "$dir/settings.json" ;;
    esac
    target="$(deployed_file "$dir")"
    before="$(file_digest "$target")"
    if [ "$1" = "asm" ]; then run_assemble "$dir"; rc="$ASM_RC"; out="$ASM_OUT"
    else run_gen "$dir" --write; rc="$GEN_RC"; out="$GEN_OUT"; fi
    after="$(file_digest "$target")"
    if [ "$rc" -ne 0 ]; then rcv="nonzero"; else rcv="zero"; fi
    if [ ! -f "$target" ]; then state="absent"
    elif [ "$before" = "$after" ]; then state="unchanged"
    else state="DEPLOYED-ANYWAY"; fi
    if printf '%s\n' "$out" | grep -Fq 'settings.json'; then named="named"; else named="NOT-NAMED"; fi
    if printf '%s\n' "$out" | grep -Eq 'ENOENT|EISDIR|EACCES|EPERM|EBUSY'; then code="code-stated"; else code="NO-CODE"; fi
    printf '%s/%s/%s/%s' "$rcv" "$state" "$named" "$code"
}

T41_VERDICTS=""

t41_setup() {
    local cli kind
    T41_MECH="$(t41_mechanism)"
    for cli in asm gen; do
        for kind in absent is-dir; do
            T41_VERDICTS="$T41_VERDICTS$cli-$kind=$(t41_case "$cli" "$kind")
"
        done
    done
}

t41_slot() { # <slot> -> verdict
    printf '%s\n' "$T41_VERDICTS" | grep "^$1=" | sed "s/^$1=//"
}

t41_basedoc_table() {
    local slot field want label
    ROWS=$((ROWS + 1))
    assert_eq "T41[mechanism]: MECHANISM CHECK -- a directory occupying settings.json really is unreadable to node on this host (if not, the four is-dir rows below are no-ops)" \
        "blocked" "$T41_MECH"
    while IFS='|' read -r slot field want label; do
        [ -n "$slot" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T41[$slot/f$field]: $label" "$want" "$(t40_field "$(t41_slot "$slot")" "$field")"
    done <<'T41_CASES'
asm-absent|1|nonzero|a base settings.json that is not there stops install/assemble-settings.js -- reading it as an empty document would deploy a file stripped of every hand-written rule
asm-absent|2|unchanged|and the previous deployment survives byte-identical, which is strictly safer than a settings.json missing 121 hand-written rules
asm-absent|3|named|the message names settings.json, so the operator learns WHICH input is missing rather than that "assembly failed"
asm-absent|4|code-stated|and carries the cause code, which is what separates "not there" from "there but unreadable" at a glance
gen-absent|1|nonzero|CPR-ORTH: gen-settings-allow.js --write fails closed on the same missing base
gen-absent|2|unchanged|leaving the same deployed file untouched, because both CLIs go through the one writer
gen-absent|3|named|and naming the same file
gen-absent|4|code-stated|with the same cause code
asm-is-dir|1|nonzero|a base settings.json present but unreadable is the SAME contract as absent, not a softer one
asm-is-dir|2|unchanged|with the previous deployment intact
asm-is-dir|3|named|and the file named in the message
asm-is-dir|4|code-stated|and the cause code stated, so an EISDIR is not reported as if the file were simply missing
gen-is-dir|1|nonzero|CPR-ORTH: the second CLI fails closed on the unreadable base too
gen-is-dir|2|unchanged|leaving the deployed file alone
gen-is-dir|3|named|naming the file
gen-is-dir|4|code-stated|and stating the cause
T41_CASES
}

# T43 moved out: the symlink policy now lives in the sibling deploy-symlink-policy.sh, because
# what it asserts changed sign. This file's copy fixed "the link survives and is written
# THROUGH it" as the success outcome; measured, the installers DELETE that link, so writing
# through one that resolves back into the checkout is the damage, not the contract.

t40_setup
t40_firstinstall_table
t41_setup
t41_basedoc_table
