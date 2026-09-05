# tests/feature-2119-settings-allow-ssot/orphan-preservation.sh
# Tests: install/lib/settings-assembly.js, install/lib/settings-deploy.js, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T25: the two halves of "what a deploy is allowed to remove". Sourced AFTER
# settings-preservation.sh, whose fixture helpers and template contract this part reuses.

T25_FX=""
T25_SHAPE=""
T25_LOCAL=""
T25_PRE='Bash(hand-written-only *)'
T25_LOCAL_RULE='Bash(local-only-edit *)'

# THE TWO DIRECTIONS, which this change makes different and which nothing else separates.
# INPUT SIDE: a generated-shaped rule someone hand-wrote into the repo-tracked settings.json
# is an ORPHAN -- `--check` reports it and a human decides. The deploy never deletes it, so an
# implementation that reads "keep what is current, drop what is not" and rewrites the array
# accordingly must fail here. Every other append-only case in this suite seeds only UNRELATED
# hand-written rules that no template could produce, so none of them can catch that.
# OUTPUT SIDE: the deployed file is a BUILD PRODUCT. A rule that exists only there -- someone
# edited ~/.claude/settings.json by hand -- is overwritten on the next deploy. That is a
# deliberate behaviour change, pinned rather than assumed.
t25_setup() {
    T25_FX="$(mk_fixture t25)"
    mk_tool "$T25_FX" bin/fx-keep env-bash
    write_ssot "$T25_FX" bin/fx-keep
    expected_path_rules bash bin/fx-keep "$T25_FX" > "$T25_FX/keep-all.txt"
    expected_path_rules bash bin/fx-gone "$T25_FX" > "$T25_FX/orphan.txt"
    # The orphan block sits BETWEEN a hand-written rule and two of the current command's own
    # spellings, so "survived" and "stayed at its original index" are separable claims.
    {
        printf '%s\n' "$T25_PRE"
        cat "$T25_FX/orphan.txt"
        sed -n '1p;9p' "$T25_FX/keep-all.txt"
    } > "$T25_FX/pre.txt"
    grep -Fxv -f "$T25_FX/pre.txt" "$T25_FX/keep-all.txt" > "$T25_FX/tail.txt"
    cat "$T25_FX/pre.txt" "$T25_FX/tail.txt" > "$T25_FX/want.txt"
    write_settings "$T25_FX" "$T25_FX/pre.txt"
    run_gen "$T25_FX" --write
    deployed_allow_dump "$T25_FX" "$T25_FX/allow.txt"
}

# The shape canary's fixture is the same command as the orphan, except LISTED in the SSOT, so
# what the deploy emits for it is by definition what a generated rule for that path looks
# like. Comparing the seeded orphan's rendering against that output -- rather than trusting
# this file's expected_path_rules() restatement alone -- is what makes "generated-shaped" a
# claim about the implementation instead of a claim about the test. The rendering compared is
# the one taken at THIS fixture's root: three templates now carry the deploying checkout's
# absolute root as a literal (`<R>` / `<R2W>`), so two different roots can no longer produce
# byte-identical text and a cross-root comparison would test the roots, not the shape.
t25_shape_setup() {
    T25_SHAPE="$(mk_fixture t25-shape)"
    mk_tool "$T25_SHAPE" bin/fx-gone env-bash
    write_ssot "$T25_SHAPE" bin/fx-gone
    write_settings "$T25_SHAPE" --
    run_gen "$T25_SHAPE" --write
    deployed_allow_dump "$T25_SHAPE" "$T25_SHAPE/allow.txt"
    expected_path_rules bash bin/fx-gone "$T25_SHAPE" > "$T25_SHAPE/expected.txt"
}

# The output-side fixture edits the DEPLOYED file directly, the way a user poking at
# ~/.claude/settings.json would, and then deploys again.
t25_local_setup() {
    T25_LOCAL="$(mk_fixture t25-local)"
    mk_tool "$T25_LOCAL" bin/fx-keep env-bash
    write_ssot "$T25_LOCAL" bin/fx-keep
    write_settings "$T25_LOCAL" --
    run_gen "$T25_LOCAL" --write
    node -e '
      const fs = require("fs");
      const p = process.argv[1];
      let o;
      try { o = JSON.parse(fs.readFileSync(p, "utf8")); } catch (e) { process.exit(0); }
      o.permissions = o.permissions || {};
      o.permissions.allow = (o.permissions.allow || []).concat([process.argv[2]]);
      fs.writeFileSync(p, JSON.stringify(o, null, 2) + "\n");
    ' "$(node_path "$(deployed_file "$T25_LOCAL")")" "$T25_LOCAL_RULE" 2>/dev/null || true
    run_gen "$T25_LOCAL" --write
    deployed_allow_dump "$T25_LOCAL" "$T25_LOCAL/allow.txt"
}

t25_probe() { # <id> -> verdict | sentinel
    have_gen || { missing_gen; return; }
    have_lib || { missing_lib; return; }
    local n rule
    case "$1" in
        shape)
            cmp -s "$T25_SHAPE/expected.txt" "$T25_SHAPE/allow.txt" && { printf 'yes'; return; }
            printf 'NOT-GENERATOR-SHAPED'
            ;;
        base-survives)
            while IFS= read -r rule; do
                [ -n "$rule" ] || continue
                grep -Fxq -- "$rule" "$T25_FX/allow.txt" 2>/dev/null || { printf 'DELETED:%s' "$rule"; return; }
            done < "$T25_FX/orphan.txt"
            printf 'yes'
            ;;
        prefix)
            n="$(wc -l < "$T25_FX/pre.txt" | tr -d ' ')"
            head -n "$n" "$T25_FX/allow.txt" > "$T25_FX/head.txt" 2>/dev/null
            cmp -s "$T25_FX/pre.txt" "$T25_FX/head.txt" && { printf 'yes'; return; }
            printf 'MOVED:%s' "$(diff "$T25_FX/pre.txt" "$T25_FX/head.txt" 2>/dev/null | head -4 | tr '\n' ' ')"
            ;;
        appended)
            cmp -s "$T25_FX/want.txt" "$T25_FX/allow.txt" && { printf 'equal'; return; }
            printf 'DIFF:%s' "$(diff "$T25_FX/want.txt" "$T25_FX/allow.txt" 2>/dev/null | head -6 | tr '\n' ' ')"
            ;;
        grew)
            n="$(wc -l < "$T25_FX/tail.txt" | tr -d ' ')"
            [ "${n:-0}" -gt 0 ] && { printf 'yes'; return; }
            printf 'NOTHING-WAS-MISSING'
            ;;
        local-only-gone)
            grep -Fxq -- "$T25_LOCAL_RULE" "$T25_LOCAL/allow.txt" 2>/dev/null \
                && { printf 'SURVIVED'; return; }
            grep -Fxq -- 'Bash(bash bin/fx-keep *)' "$T25_LOCAL/allow.txt" 2>/dev/null \
                && { printf 'gone'; return; }
            printf 'DEPLOY-PRODUCED-NOTHING'
            ;;
    esac
}

t25_orphan_preservation_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T25[$id]: $label" "$want" "$(t25_probe "$id")"
    done <<'T25_CASES'
shape|yes|PRECONDITION: the rules seeded as the orphan are byte-identical to what the deploy itself emits for that path, so the orphan is a generated-shaped rule and not merely unrelated text -- compared SAME-ROOT because the root-literal templates make cross-root byte equality impossible by design
grew|yes|PRECONDITION: the fixture really is missing some of the current command's spellings, so the injection side of the contract is exercised at all
base-survives|yes|INPUT SIDE: all twenty-four spellings of the base document's generated-shaped orphan reach the deployed file -- reporting it is --check's job, deleting it is nobody's
prefix|yes|and each one is still at its ORIGINAL index: the whole base array is an unchanged prefix, so nothing was resorted around the orphan
appended|equal|the missing current rules land after that prefix, in template order, and nothing else changed
local-only-gone|gone|OUTPUT SIDE: a rule hand-added to the DEPLOYED file only is overwritten by the next deploy -- the deployed file is a build product, and this behaviour change is pinned, not assumed
T25_CASES
}

t25_setup
t25_shape_setup
t25_local_setup
t25_orphan_preservation_table
