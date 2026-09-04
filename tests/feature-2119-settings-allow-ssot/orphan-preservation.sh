# tests/feature-2119-settings-allow-ssot/orphan-preservation.sh
# Tests: install/gen-settings-allow.js, settings.json
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T25: --write must not delete what --check merely REPORTS. Sourced AFTER
# settings-preservation.sh, whose fixture helpers and template contract this part reuses.

T25_FX=""
T25_SHAPE=""
T25_PRE='Bash(hand-written-only *)'

# THE HOLE THIS CLOSES. T6 and T11/T12 all pin append-only against arrays whose pre-existing
# entries are UNRELATED hand-written rules -- `Bash(hand-written-one *)` and friends, which no
# template could ever produce. An implementation that reads "keep what is still current, drop
# what is not" and rewrites permissions.allow accordingly passes every one of them, because it
# has nothing generated-shaped to drop. The plan is explicit that --write appends only and that
# orphan REMOVAL is a separate human judgment (A-2), so the load-bearing fixture is the one
# nothing else builds: a generated-shaped orphan -- the full ten path spellings of a command
# that is NOT in the SSOT -- sitting in the array next to rules that really are missing.
t25_setup() {
    T25_FX="$(mk_fixture t25)"
    mk_tool "$T25_FX" bin/fx-keep env-bash
    write_ssot "$T25_FX" bin/fx-keep
    expected_path_rules bash bin/fx-keep > "$T25_FX/keep-all.txt"
    expected_path_rules bash bin/fx-gone > "$T25_FX/orphan.txt"
    # The orphan block sits BETWEEN a hand-written rule and two of the current command's own
    # spellings, so "survived" and "stayed at its original index" are separable claims.
    {
        printf '%s\n' "$T25_PRE"
        cat "$T25_FX/orphan.txt"
        sed -n '1p;5p' "$T25_FX/keep-all.txt"
    } > "$T25_FX/pre.txt"
    grep -Fxv -f "$T25_FX/pre.txt" "$T25_FX/keep-all.txt" > "$T25_FX/tail.txt"
    cat "$T25_FX/pre.txt" "$T25_FX/tail.txt" > "$T25_FX/want.txt"
    write_settings "$T25_FX" "$T25_FX/pre.txt"
    run_gen "$T25_FX" --write
    cp "$T25_FX/settings.json" "$T25_FX/after-first.json" 2>/dev/null || true
    run_gen "$T25_FX" --write
    allow_dump "$T25_FX" "$T25_FX/allow.txt"
}

# The shape canary's fixture is the same command as the orphan, except LISTED in the SSOT, so
# what the generator emits for it is by definition what a generated rule for that path looks
# like. Comparing the seeded orphan against that output -- rather than against this file's own
# expected_path_rules() restatement -- is what makes "generated-shaped" a claim about the
# implementation instead of a claim about the test.
t25_shape_setup() {
    T25_SHAPE="$(mk_fixture t25-shape)"
    mk_tool "$T25_SHAPE" bin/fx-gone env-bash
    write_ssot "$T25_SHAPE" bin/fx-gone
    write_settings "$T25_SHAPE" --
    run_gen "$T25_SHAPE" --write
    allow_dump "$T25_SHAPE" "$T25_SHAPE/allow.txt"
}

t25_probe() { # <id> -> verdict | sentinel
    have_gen || { missing_gen; return; }
    local n rule
    case "$1" in
        shape)
            cmp -s "$T25_FX/orphan.txt" "$T25_SHAPE/allow.txt" && { printf 'yes'; return; }
            printf 'NOT-GENERATOR-SHAPED'
            ;;
        survives)
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
        idempotent)
            cmp -s "$T25_FX/after-first.json" "$T25_FX/settings.json" && { printf 'yes'; return; }
            printf 'SECOND-WRITE-DIFFERS'
            ;;
        grew)
            n="$(wc -l < "$T25_FX/tail.txt" | tr -d ' ')"
            [ "${n:-0}" -gt 0 ] && { printf 'yes'; return; }
            printf 'NOTHING-WAS-MISSING'
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
shape|yes|PRECONDITION: the seeded orphan is byte-identical to what the generator itself emits for that path, so it is a generated-shaped rule and not merely unrelated text
grew|yes|PRECONDITION: the fixture really is missing some of the current command's spellings, so the append side of the contract is exercised at all
survives|yes|every one of the orphan's ten spellings is still present after --write: detection is --check's job, removal is nobody's
prefix|yes|and each one is still at its ORIGINAL index -- the whole pre-existing array is an unchanged prefix, so nothing was resorted around the orphan
appended|equal|the missing current rules land after that prefix, in template order, and nothing else changed
idempotent|yes|a second --write over the orphan-bearing file is byte-identical: the orphan is not re-appended and not re-removed
T25_CASES
}

t25_setup
t25_shape_setup
t25_orphan_preservation_table
