# tests/feature-2119-settings-allow-ssot/write-and-drift.sh
# Tests: install/gen-settings-allow.js, settings.json
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T6-T7b: what --write does to a settings.json, and what --check sees. Sourced AFTER
# generator.sh, whose fixture helpers (mk_fixture, mk_tool, write_ssot, write_settings,
# allow_dump, run_gen, expected_path_rules) this part reuses.

T6_FIXTURE=""
T6_PRE_A='Bash(hand-written-one *)'
T6_PRE_B='Bash(hand-written-two *)'

# T6 -- append-only, idempotent, byte-stable. The generator edits the repository's own
# settings.json, so the risk is not a wrong rule but a reordered or reformatted file whose
# diff nobody can read; the three probes below are the three ways that goes wrong.
t6_setup() {
    T6_FIXTURE="$(mk_fixture t6)"
    mk_tool "$T6_FIXTURE" bin/fx-tool env-bash
    write_ssot "$T6_FIXTURE" bin/fx-tool
    printf '%s\n%s\n' "$T6_PRE_A" "$T6_PRE_B" > "$T6_FIXTURE/pre.txt"
    write_settings "$T6_FIXTURE" "$T6_FIXTURE/pre.txt"
    run_gen "$T6_FIXTURE" --write
    cp "$T6_FIXTURE/settings.json" "$T6_FIXTURE/after-first.json" 2>/dev/null || true
    run_gen "$T6_FIXTURE" --write
}

t6_probe() { # <a|b|c> -> yes|no|sentinel
    have_gen || { missing_gen; return; }
    local dump head2
    case "$1" in
        a)
            dump="$T6_FIXTURE/allow.txt"
            allow_dump "$T6_FIXTURE" "$dump"
            head2="$(head -2 "$dump" 2>/dev/null)"
            [ "$head2" = "$(printf '%s\n%s' "$T6_PRE_A" "$T6_PRE_B")" ] && { printf 'yes'; return; }
            printf 'no'
            ;;
        b)
            cmp -s "$T6_FIXTURE/after-first.json" "$T6_FIXTURE/settings.json" && { printf 'yes'; return; }
            printf 'no'
            ;;
        c)
            node -e '
              const fs = require("fs");
              const raw = fs.readFileSync(process.argv[1], "utf8");
              const round = JSON.stringify(JSON.parse(raw), null, 2) + "\n";
              console.log(raw === round ? "yes" : "no");
            ' "$(node_path "$T6_FIXTURE/settings.json")" 2>/dev/null || printf 'no'
            ;;
    esac
}

t6_write_contract() {
    local id label
    while IFS='|' read -r id label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T6$id: $label" "yes" "$(t6_probe "$id")"
    done <<'T6_CASES'
a|the pre-existing allow entries survive --write unchanged and in order (append-only)
b|a second --write leaves the file byte-identical (idempotent)
c|the written file equals JSON.parse -> stringify(_, null, 2) + newline (formatting contract)
T6_CASES
}

# T7 is the drift gate against the REAL repository: settings.json must already carry every
# spelling the SSOT implies, and no orphan. `--check` only reads, so the real tree is safe.
t7_real_repo_in_sync() {
    if ! have_gen; then
        fail "T7: cannot check the real settings.json -- $GEN_REL is missing (IMPLEMENTATION MISSING)"
        return
    fi
    local rc=0 out
    out="$( (cd "$AGENTS_DIR" && run_with_timeout 60 node "$GEN_REL" --check) 2>&1 )" || rc=$?
    if [ "$rc" -eq 0 ]; then
        pass "T7: the real $SETTINGS_REL is in sync with $SSOT_REL (no missing, no orphaned entries)"
    else
        fail "T7: $GEN_REL --check reported drift (rc=$rc)" "$out"
    fi
}

# T7b -- NEGATIVE CONTROL for orphan detection. The fixture settings.json carries the full
# template set for a path that is NOT in the SSOT, which an implementation that only looks for
# MISSING entries reports as perfectly in sync. Both the exit code and the report text are
# asserted, because a non-zero exit that names nothing is not actionable.
t7b_orphan_detection() {
    local fx rc_verdict names_verdict
    fx="$(mk_fixture t7b)"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    expected_path_rules bash bin/fx-keep > "$fx/pre.txt"
    expected_path_rules bash bin/fx-dropped >> "$fx/pre.txt"
    write_settings "$fx" "$fx/pre.txt"
    run_gen "$fx" --check
    if have_gen; then
        if [ "$GEN_RC" -ne 0 ]; then rc_verdict="nonzero"; else rc_verdict="zero"; fi
        if printf '%s\n' "$GEN_OUT" | grep -q 'fx-dropped'; then names_verdict="named"; else names_verdict="not-named"; fi
    else
        rc_verdict="$(missing_gen)"; names_verdict="$(missing_gen)"
    fi
    ROWS=$((ROWS + 1))
    assert_eq "T7b[exit]: an allow entry whose path left the SSOT makes --check exit non-zero" \
        "nonzero" "$rc_verdict"
    ROWS=$((ROWS + 1))
    assert_eq "T7b[report]: the orphan report names bin/fx-dropped" "named" "$names_verdict"
}

# T7c -- `--check` MUST NOT WRITE. Both the drift gate (C2) and the orphan report (C3) run
# --check from hooks/pre-commit against the REAL settings.json, and T7 above points it at the
# real repository too; a --check that "helpfully" repaired what it found would rewrite the
# repository from inside a hook, with no diff anyone asked for. The drifted fixture is the
# load-bearing half: the tempting moment to write is exactly where drift was just detected.
file_digest() { # <file> -> bytes+checksum, or a marker when unreadable
    cksum < "$1" 2>/dev/null || printf 'UNREADABLE'
}

t7c_probe() { # <in-sync|drifted> -> unchanged|MODIFIED|sentinel
    have_gen || { missing_gen; return; }
    local fx before after
    fx="$(mk_fixture "t7c-$1")"
    mk_tool "$fx" bin/fx-keep env-bash
    write_ssot "$fx" bin/fx-keep
    if [ "$1" = "in-sync" ]; then
        expected_path_rules bash bin/fx-keep > "$fx/pre.txt"
    else
        expected_path_rules bash bin/fx-dropped > "$fx/pre.txt"
    fi
    write_settings "$fx" "$fx/pre.txt"
    before="$(file_digest "$fx/settings.json")"
    run_gen "$fx" --check
    after="$(file_digest "$fx/settings.json")"
    [ "$before" = "$after" ] && { printf 'unchanged'; return; }
    printf 'MODIFIED'
}

t7c_check_is_read_only() {
    local kind label
    while IFS='|' read -r kind label; do
        [ -n "$kind" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T7c[$kind]: $label" "unchanged" "$(t7c_probe "$kind")"
    done <<'T7C_CASES'
in-sync|--check leaves an already-in-sync settings.json byte-identical (no reformatting)
drifted|--check reports drift without repairing it: detection reads, only --write writes
T7C_CASES
}

t6_setup
t6_write_contract
t7_real_repo_in_sync
t7b_orphan_detection
t7c_check_is_read_only
