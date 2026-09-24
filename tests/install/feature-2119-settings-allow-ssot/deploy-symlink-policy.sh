# tests/feature-2119-settings-allow-ssot/deploy-symlink-policy.sh
# Tests: install/lib/settings-deploy.js, install/assemble-settings.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T43: what the single writer does when the deploy target is a SYMLINK. Sourced AFTER generator.sh.

T43_TOOL="bin/fx-tool"
T43_SENTINEL='Bash(second-pass-only *)'

# WHY THE AXIS IS "WHERE THE LINK LANDS", NOT "IS IT A LINK". The installers REMOVE this link
# (install/win/dotfileslink.ps1, install/linux/dotfileslink.sh), both calling it stale, so a write
# THROUGH one resolving back into the checkout puts hundreds of generated allow rules into the
# repository's own tracked settings.json -- the state #2119 removes. Hence: in-repo link is
# detached; a link landing OUTSIDE is a deliberate arrangement and is written through as before.
# Cutting on "is it a link" would break the deliberate ones too (CPR-UNV).
# Authoritative rationale: the A1 section of the #2119 detail plan.

T43_RC=0
T43_ERR=""

# TL3 gap: a REAL legacy machine is out of reach here. This reproduces the SHAPE of a stale link in
# a fixture whose "repository" is a temp directory. Whether a pre-installer host still carries that
# link, and whether install.ps1 / install.sh clear it before the assembler ever runs, needs the real
# installer on a real host. Windows reparse-point flavours are likewise recorded for THIS host only,
# by the mechanism row below, and generalised nowhere.

t43_mklink() { # <target-abs> <link-abs> -> ok | NOT-A-LINK | FAILED:<code>
    node -e '
      const fs = require("fs");
      try { fs.symlinkSync(process.argv[1], process.argv[2], "file"); }
      catch (e) { process.stdout.write("FAILED:" + (e.code || e.message)); process.exit(0); }
      try { process.stdout.write(fs.lstatSync(process.argv[2]).isSymbolicLink() ? "ok" : "NOT-A-LINK"); }
      catch (e) { process.stdout.write("FAILED:" + (e.code || e.message)); }
    ' "$(node_path "$1")" "$(node_path "$2")" 2>/dev/null || printf 'FAILED:node'
}

# lstat, never stat: `[ -f ]` on a symlink answers about the TARGET, so the one question this file
# exists to ask -- "is the deployed path still a link?" -- is the one the shell test cannot answer.
# The link target is deliberately NOT carried in the verdict: it holds `/`, the verdict delimiter.
t43_linkstate() { # <path> -> link | regular | other | absent | PROBE-ERROR
    node -e '
      const fs = require("fs");
      let st;
      try { st = fs.lstatSync(process.argv[1]); } catch (e) { process.stdout.write("absent"); process.exit(0); }
      if (st.isSymbolicLink()) process.stdout.write("link");
      else if (st.isFile()) process.stdout.write("regular");
      else process.stdout.write("other");
    ' "$(node_path "$1")" 2>/dev/null || printf 'PROBE-ERROR'
}

# The PARENT of the deploy target can be the link instead of the leaf -- `~/.claude` itself pointing
# into the checkout. A leaf-only lstat never sees it, and unlinking is not the answer either: removing
# a directory link would orphan everything else under it. So this shape falls to the module's
# fail-closed side -- refuse, write nothing, leave the previous deployment standing.
t43_mkdirlink() { # <target-abs> <link-abs> -> ok | NOT-A-LINK | FAILED:<code>
    node -e '
      const fs = require("fs");
      const kinds = process.platform === "win32" ? ["junction", "dir"] : ["dir"];
      let last = "unknown";
      for (const kind of kinds) {
          try { fs.symlinkSync(process.argv[1], process.argv[2], kind); last = ""; break; }
          catch (e) { last = e.code || e.message; }
      }
      if (last) { process.stdout.write("FAILED:" + last); process.exit(0); }
      try { process.stdout.write(fs.lstatSync(process.argv[2]).isSymbolicLink() ? "ok" : "NOT-A-LINK"); }
      catch (e) { process.stdout.write("FAILED:" + (e.code || e.message)); }
    ' "$(node_path "$1")" "$(node_path "$2")" 2>/dev/null || printf 'FAILED:node'
}

# Creating a symlink on Windows needs developer mode or elevation, so the fixture's own premise is
# asserted rather than assumed: without this row a host that silently produced a COPY would leave
# every row below green against an ordinary regular file -- green, and evidence of nothing.
t43_mechanism() { # -> ok | NOT-A-LINK | FAILED:<code>
    local d="$TMPROOT/t43-mech"
    mkdir -p "$d"
    printf 'ORIGINAL\n' > "$d/real.json"
    t43_mklink "$d/real.json" "$d/link.json"
}

# stderr is captured SEPARATELY from stdout here (run_gen / run_assemble fold them together): the
# detach is a warning on a run that SUCCEEDS, so "reported on stderr" and "exited zero" have to be
# two independent observations rather than one merged blob.
t43_run() { # <asm|gen> <fixture>
    local fx="$2"
    T43_ERR="$fx/stderr.txt"
    T43_RC=0
    if [ "$1" = "asm" ]; then
        ( cd "$fx" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
          HOME="$fx/home" USERPROFILE="$(node_path "$fx/home")" \
          CLAUDE_CONFIG_DIR="$fx/home/.claude" \
          run_with_timeout 60 node install/assemble-settings.js ) \
          > "$fx/stdout.txt" 2> "$T43_ERR" || T43_RC=$?
    else
        ( cd "$fx" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
          HOME="$fx/home" USERPROFILE="$(node_path "$fx/home")" \
          CLAUDE_CONFIG_DIR="$fx/home/.claude" \
          run_with_timeout 60 node install/gen-settings-allow.js --write ) \
          > "$fx/stdout.txt" 2> "$T43_ERR" || T43_RC=$?
    fi
}

# Verdict: rc/state/orig/content/note/fresh. A field a case cannot speak to stays `-`, so every row
# below names a real observation of that case rather than a default that happened to line up.
t43_case() { # <asm|gen> <shape> -> verdict | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    [ -f "$ASSEMBLE" ] || { missing_assemble; return; }
    local dir target ext repo_before repo_after rc state orig content note fresh first
    local inside_dir="" inside_before="-" inside_after="-" inside="-"
    dir="$(mk_fixture "t43-$1-$2")"
    mk_tool "$dir" "$T43_TOOL" env-bash
    write_ssot "$dir" "$T43_TOOL"
    write_settings "$dir" --
    # Deployed healthy FIRST: only then is "the previous deployment survived" a claim about
    # something that exists, and only then does the target start out as a plain regular file.
    run_assemble "$dir"
    target="$(deployed_file "$dir")"
    ext="$TMPROOT/t43-$1-$2-outside"
    mkdir -p "$ext"
    printf '%s\n' '{ "permissions": { "allow": ["Bash(outside-home *)"] } }' > "$ext/settings.json"
    # into-repo points at the fixture's OWN settings.json -- the repository base, and the one shape
    # where "wrote through the link" and "wrote into the repository" are the same event. broken
    # points OUTSIDE and nowhere, so it cannot be decided by where it lands: that row pins which
    # side an unresolvable link falls to.
    case "$2" in
        plain-file) : ;;
        absent)     rm -f "$target" ;;
        into-repo|failclosed)
            rm -f "$target"; t43_mklink "$dir/settings.json" "$target" > /dev/null ;;
        outside-repo)
            rm -f "$target"; t43_mklink "$ext/settings.json" "$target" > /dev/null ;;
        broken)
            rm -f "$target"; t43_mklink "$ext/never-existed.json" "$target" > /dev/null ;;
        parent-into-repo)
            # The whole ~/.claude directory becomes a link INTO the checkout, carrying the healthy
            # first deployment across so "the previous deployment stands" is a claim about a file
            # that really exists.
            inside_dir="$dir/claude-inside"
            mkdir -p "$inside_dir"
            cp "$target" "$inside_dir/settings.json"
            rm -rf "$dir/home/.claude"
            t43_mkdirlink "$inside_dir" "$dir/home/.claude" > /dev/null ;;
    esac
    # The second deploy must produce DIFFERENT bytes, or "rewritten" and "never touched" are the
    # same observation. The fail-closed row breaks the generator instead of moving the sentinel.
    if [ "$2" = "failclosed" ]; then
        rm -f "$dir/install/settings-allow-commands.txt"
    else
        printf '%s\n' "$T43_SENTINEL" > "$dir/pre.txt"
        write_settings "$dir" "$dir/pre.txt"
    fi
    repo_before="$(file_digest "$dir/settings.json")"
    if [ -n "$inside_dir" ]; then inside_before="$(file_digest "$inside_dir/settings.json")"; fi
    t43_run "$1" "$dir"
    repo_after="$(file_digest "$dir/settings.json")"
    if [ -n "$inside_dir" ]; then
        inside_after="$(file_digest "$inside_dir/settings.json")"
        if [ "$inside_before" = "$inside_after" ]; then inside="inside-untouched"; else inside="INSIDE-WRITTEN"; fi
    fi
    if [ "$T43_RC" -eq 0 ]; then rc="zero"; else rc="nonzero"; fi
    state="$(t43_linkstate "$target")"
    if [ "$repo_before" = "$repo_after" ]; then orig="orig-identical"; else orig="ORIG-CHANGED"; fi
    content="RULES-MISSING"
    fresh="STALE"
    deployed_allow_dump "$dir" "$dir/allow.txt"
    first="$(expected_path_rules bash "$T43_TOOL" "$dir" | sed -n 1p)"
    grep -Fxq -- "$first" "$dir/allow.txt" 2>/dev/null && content="rules-present"
    grep -Fxq -- "$T43_SENTINEL" "$dir/allow.txt" 2>/dev/null && fresh="overwritten"
    if grep -Eqi 'symlink|symbolic link' "$T43_ERR" 2>/dev/null; then note="noted"; else note="silent"; fi
    printf '%s/%s/%s/%s/%s/%s/%s' "$rc" "$state" "$orig" "$content" "$note" "$fresh" "$inside"
}

# A directory link is its own mechanism: Windows grants a junction where it refuses a file symlink,
# and refuses both without developer mode. Gating the parent-link rows on their OWN probe keeps a
# host that can do one but not the other from reporting a green row it never exercised.
t43_dirmechanism() { # -> ok | NOT-A-LINK | FAILED:<code>
    local d="$TMPROOT/t43-dirmech"
    mkdir -p "$d/real"
    t43_mkdirlink "$d/real" "$d/link"
}

T43_MECH=""
T43_DIRMECH=""
T43_VERDICTS=""

t43_setup() {
    local shape
    T43_MECH="$(t43_mechanism)"
    [ "$T43_MECH" = "ok" ] || return 0
    T43_DIRMECH="$(t43_dirmechanism)"
    for shape in plain-file absent into-repo outside-repo broken failclosed; do
        T43_VERDICTS="$T43_VERDICTS asm-$shape=$(t43_case asm "$shape")
"
    done
    if [ "$T43_DIRMECH" = "ok" ]; then
        T43_VERDICTS="$T43_VERDICTS asm-parent-into-repo=$(t43_case asm parent-into-repo)
"
    fi
    T43_VERDICTS="$T43_VERDICTS gen-into-repo=$(t43_case gen into-repo)
"
}

t43_slot() { # <slot> -> verdict
    printf '%s\n' "$T43_VERDICTS" | grep -- "$1=" | sed "s/^.*$1=//"
}

t43_field() { # <verdict> <n> -> field
    case "$1" in
        '<MISSING:'*) printf '%s' "$1"; return ;;
    esac
    printf '%s' "$1" | cut -d'/' -f"$2"
}

t43_symlink_table() {
    local slot field want label
    ROWS=$((ROWS + 1))
    assert_eq "T43[mechanism]: MECHANISM CHECK -- this host really creates a symlink rather than a copy (if not, every T43 row below is a no-op against an ordinary file)" \
        "ok" "$T43_MECH"
    while IFS='|' read -r slot field want label; do
        [ -n "$slot" ] || continue
        ROWS=$((ROWS + 1))
        if [ "$T43_MECH" != "ok" ]; then
            skip "T43[$slot/f$field]: $label -- SKIPPED: this host refused symlink creation ($T43_MECH), so a linked deploy target cannot be represented here"
            continue
        fi
        case "$slot" in
            *parent-into-repo)
                if [ "$T43_DIRMECH" != "ok" ]; then
                    skip "T43[$slot/f$field]: $label -- SKIPPED: this host refused DIRECTORY link creation ($T43_DIRMECH), so a linked parent cannot be represented here"
                    continue
                fi ;;
        esac
        assert_eq "T43[$slot/f$field]: $label" "$want" "$(t43_field "$(t43_slot "$slot")" "$field")"
    done <<'T43_CASES'
asm-plain-file|1|zero|CONTROL: an ordinary regular deploy target is untouched by any of this -- the assembler still exits 0
asm-plain-file|2|regular|and the target is still a regular file, so symlink handling did not convert a plain file into something else
asm-plain-file|4|rules-present|carrying the generated spellings
asm-plain-file|6|overwritten|and the NEW base content, which is what makes "the file was rewritten" an observation rather than an assumption
asm-absent|1|zero|CONTROL: no deploy target at all is the first-install path, and still exits 0 with a symlink branch standing in front of the write
asm-absent|2|regular|creating a plain regular file, never a link
asm-absent|4|rules-present|with the generated spellings in it
asm-into-repo|1|zero|a link resolving INSIDE the agents repository is not an error: the deploy succeeds
asm-into-repo|2|regular|but it is DETACHED -- the deployed path is a regular file afterwards, because writing through it would push the generated rules back into the repository's own settings.json, the exact state #2119 removes
asm-into-repo|3|orig-identical|and the repository original is byte-identical: the link was removed, not followed
asm-into-repo|4|rules-present|while the deployed path itself carries the generated rules, so detaching cost the user nothing
asm-into-repo|5|noted|and one stderr line names the link, because a file silently replacing a link is a change the operator must be able to find afterwards
asm-outside-repo|1|zero|a link resolving OUTSIDE the repository is somebody's deliberate arrangement and deploys normally
asm-outside-repo|2|link|and is STILL a link afterwards: the axis is where the link lands, not whether it is a link, so a deliberate one is left alone
asm-outside-repo|4|rules-present|with the file behind it now holding the generated rules -- written THROUGH the link, as before
asm-broken|1|zero|a link whose target does not resolve at all still deploys successfully
asm-broken|2|regular|falling to the DETACH side: a broken link cannot be honoured, so the write must not chase it
asm-broken|4|rules-present|and the deployed path carries the generated rules
asm-broken|5|noted|with the link named on stderr, the same way the in-repo detach is
asm-failclosed|1|nonzero|D3 BEFORE A1: with generation broken, the deploy fails closed even though the target is a detachable in-repo link
asm-failclosed|2|link|and the link is STILL a link -- the fail-closed check runs BEFORE the detach, so a failing deploy never unlinks something it then cannot replace
asm-failclosed|3|orig-identical|leaving the repository original byte-identical, which is what "nothing was written" means here
asm-parent-into-repo|1|nonzero|THE PARENT IS THE LINK: `~/.claude` itself resolves into the checkout, which a leaf-only lstat never sees. Unlinking is not available -- removing a directory link orphans everything else under it -- so this shape falls to the module's fail-closed side and the deploy REFUSES
asm-parent-into-repo|3|orig-identical|leaving the repository original byte-identical: the whole point is that the generated rules never reach the checkout's own tracked settings.json
asm-parent-into-repo|7|inside-untouched|and the file BEHIND the link is untouched too, which is the observation the repository digest alone cannot make -- a write that landed there would still leave `$dir/settings.json` identical
asm-parent-into-repo|4|rules-present|the previous deployment still stands: refusing wrote nothing, so the operator is left with the last good file rather than a truncated one
asm-parent-into-repo|6|STALE|and it is the OLD deployment, not a fresh one -- the second pass's base sentinel never reached it, which is what "nothing was written" means for this row
asm-parent-into-repo|5|noted|with the link named on stderr, because a refusal the operator cannot locate is indistinguishable from a hang
gen-into-repo|1|zero|CPR-ORTH: gen-settings-allow.js --write reaches the same single writer and succeeds on the same in-repo link
gen-into-repo|2|regular|detaching it the same way
gen-into-repo|3|orig-identical|leaving the same repository original untouched
gen-into-repo|4|rules-present|with the same rules deployed, so neither entry point is the one that writes back into the checkout
T43_CASES
}

t43_setup
t43_symlink_table
