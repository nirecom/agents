# tests/feature-2119-settings-allow-ssot/review-script.sh
# Tests: bin/review-settings-allow, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2
# T9a-T9d plus two predicate canaries: bin/review-settings-allow. Sourced by
# tests/feature-2119-settings-allow-ssot.sh, which owns the counters and helpers.

# The verdict predicate, in one place (CPR-SSOT): a banner without the matching exit code is
# not a verdict. bin/review-env-example set the convention -- a machine reads the exit code
# and a human reads the banner, so a script that prints FAIL and exits 0 is worse than one
# that prints nothing.
classify_review() { # <output> <rc> -> PERFORMED|FAIL|<banner>/rc=<n>
    local out="$1" rc="$2" banner="none"
    printf '%s\n' "$out" | grep -q 'Settings Allow Review: PERFORMED' && banner="PERFORMED"
    printf '%s\n' "$out" | grep -q 'Settings Allow Review: FAIL' && banner="FAIL"
    if [ "$banner" = "PERFORMED" ] && [ "$rc" -eq 0 ]; then printf 'PERFORMED'; return; fi
    if [ "$banner" = "FAIL" ] && [ "$rc" -ne 0 ]; then printf 'FAIL'; return; fi
    printf '%s/rc=%s' "$banner" "$rc"
}

# CANARY. Every T9 row runs through classify_review, so if that predicate silently stopped
# distinguishing verdicts the whole family would agree on nothing meaningful. These two rows
# feed it synthetic output and keep it demonstrably live even while the script under test
# does not exist yet.
t9_predicate_canary() {
    ROWS=$((ROWS + 1))
    assert_eq "T9[canary-performed]: a PERFORMED banner with exit 0 classifies as PERFORMED" \
        "PERFORMED" "$(classify_review '## Settings Allow Review: PERFORMED' 0)"
    ROWS=$((ROWS + 1))
    assert_eq "T9[canary-fail]: a FAIL banner with exit 1 classifies as FAIL" \
        "FAIL" "$(classify_review '## Settings Allow Review: FAIL' 1)"
}

# A review fixture is a fixture tree carrying its own copy of the review script, the
# generator and the SSOT -- each of which the row may delete on purpose. The script is run
# with cwd at the fixture root and never sees the real repository.
mk_review_fixture() { # <name> <gen:yes|no> <ssot:yes|no> <synced:yes|no> -> dir | sentinel
    local dir gen="$2" ssot="$3" synced="$4"
    have_review || { missing_review; return; }
    dir="$(mk_fixture "$1")"
    mkdir -p "$dir/bin"
    cp "$REVIEW" "$dir/bin/review-settings-allow"
    chmod +x "$dir/bin/review-settings-allow" 2>/dev/null || true
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    write_settings "$dir" --
    [ "$synced" = "yes" ] && run_gen "$dir" --write
    [ "$gen" = "no" ] && rm -f "$dir/install/gen-settings-allow.js"
    [ "$ssot" = "no" ] && rm -f "$dir/install/settings-allow-commands.txt"
    printf '%s\n' "$dir"
}

run_review() { # <fixture> -> verdict | sentinel
    local fx="$1" out rc=0
    case "$fx" in "<MISSING:"*) printf '%s' "$fx"; return ;; esac
    out="$( (cd "$fx" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        run_with_timeout 60 bash bin/review-settings-allow) 2>&1 )" || rc=$?
    classify_review "$out" "$rc"
}

# T9b/T9c/T9d are NEGATIVE CONTROLS in two directions. T9b breaks the DATA (settings.json
# drifted from the SSOT) and T9c/T9d break the ENFORCEMENT ITSELF (the generator or the SSOT
# is gone). A gate that reports PERFORMED when its own inputs are missing is the fail-open
# hole this design was reversed to close, so "broken tools" must read as FAIL, never as OK.
t9_verdicts() {
    local id gen ssot synced want label fx
    while IFS='|' read -r id gen ssot synced want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        fx="$(mk_review_fixture "t9-$id" "$gen" "$ssot" "$synced")"
        assert_eq "T9$id: $label" "$want" "$(run_review "$fx")"
    done <<'T9_CASES'
a|yes|yes|yes|PERFORMED|in-sync tree prints the PERFORMED banner and exits 0
b|yes|yes|no|FAIL|settings.json missing the SSOT's spellings prints FAIL and exits non-zero
c|no|yes|yes|FAIL|generator deleted: fail-closed, so the verdict is FAIL and not a silent skip
d|yes|no|yes|FAIL|SSOT deleted: a second, independent way for the gate's own inputs to break
T9_CASES
}

# The review script's existence, asserted once, so the four verdict rows below have one named
# artifact to point at instead of four copies of the same news.
t9_review_present() {
    local got="absent"
    have_review && got="present"
    assert_eq "T9: $REVIEW_REL exists (IMPLEMENTATION MISSING while absent)" "present" "$got"
}

t9_review_present
t9_predicate_canary
t9_verdicts
