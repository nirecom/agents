# tests/feature-2119-settings-allow-ssot/review-diagnostics.sh
# Tests: bin/review-settings-allow, install/gen-settings-allow.js
# Tags: install, settings, permissions, ssot, scope:issue-specific, pwsh-not-required, TL2

# T18-T19: what the review script SAYS, and the file mode it ships with. Sourced AFTER
# review-script.sh, whose mk_review_fixture this part reuses.

RD_OUT=""
RD_RC=0

# T18 -- A BANNER IS NOT A DIAGNOSIS. T9 classifies the verdict and stops there, so it stays
# green for a script that prints both banners, swallows the generator's findings, and offers no
# way out. This gate runs from a git hook: the developer sees only this output, and "FAIL" with
# nothing else costs them the whole diagnosis. Missing and Orphaned also need DIFFERENT
# remedies -- --write fixes one and is documented not to touch the other -- so a single generic
# "run --write" line would send someone to a command that cannot help them.
run_review_raw() { # <fixture>
    RD_OUT=""; RD_RC=0
    case "$1" in "<MISSING:"*) RD_OUT="$1"; RD_RC=-1; return ;; esac
    RD_OUT="$( (cd "$1" && unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID && \
        run_with_timeout 60 bash bin/review-settings-allow) 2>&1 )" || RD_RC=$?
}

# An orphan fixture cannot come from mk_review_fixture, whose knobs only delete things: this
# one needs settings.json to carry MORE than the SSOT implies.
mk_orphan_review_fixture() { # -> dir | sentinel
    local dir
    have_review || { missing_review; return; }
    dir="$(mk_fixture rd-orphan)"
    mkdir -p "$dir/bin"
    cp "$REVIEW" "$dir/bin/review-settings-allow"
    chmod +x "$dir/bin/review-settings-allow" 2>/dev/null || true
    mk_tool "$dir" bin/fx-tool env-bash
    write_ssot "$dir" bin/fx-tool
    expected_path_rules bash bin/fx-tool > "$dir/pre.txt"
    expected_path_rules bash bin/fx-dropped >> "$dir/pre.txt"
    write_settings "$dir" "$dir/pre.txt"
    printf '%s\n' "$dir"
}

banner_count() { printf '%s\n' "$RD_OUT" | grep -c 'Settings Allow Review:' || true; }

t18_probe() { # <id> -> verdict | sentinel
    have_review || { missing_review; return; }
    local fx want_rule
    case "$1" in
        drift-banner-count|drift-exit|drift-names-rule|drift-write-remedy)
            fx="$(mk_review_fixture rd-drift yes yes no)" ;;
        orphan-*)
            fx="$(mk_orphan_review_fixture)" ;;
        broken-gen-forwarded)
            fx="$(mk_review_fixture rd-nogen no yes yes)" ;;
        *)
            fx="$(mk_review_fixture rd-sync yes yes yes)" ;;
    esac
    run_review_raw "$fx"
    case "$1" in
        drift-banner-count|synced-banner-count) banner_count ;;
        drift-exit|orphan-exit) printf '%s' "$RD_RC" ;;
        drift-names-rule)
            want_rule="$(expected_path_rules bash bin/fx-tool | sed -n 4p)"
            printf '%s\n' "$RD_OUT" | grep -Fq -- "$want_rule" && { printf 'yes'; return; }
            printf 'no' ;;
        drift-write-remedy)
            printf '%s\n' "$RD_OUT" | grep -Eq 'gen-settings-allow\.js --write' && { printf 'yes'; return; }
            printf 'no' ;;
        orphan-named)
            printf '%s\n' "$RD_OUT" | grep -q 'fx-dropped' && { printf 'yes'; return; }
            printf 'no' ;;
        orphan-manual-remedy)
            printf '%s\n' "$RD_OUT" | grep -Eqi 'manual|by hand|review it yourself' \
                && printf '%s\n' "$RD_OUT" | grep -Eqi '(not|never|cannot) (be )?remove' \
                && { printf 'yes'; return; }
            printf 'no' ;;
        broken-gen-forwarded)
            printf '%s\n' "$RD_OUT" | grep -v 'Settings Allow Review:' | grep -q '[^[:space:]]' \
                && { printf 'yes'; return; }
            printf 'no' ;;
        synced-banner-text)
            printf '%s\n' "$RD_OUT" | grep -q 'Settings Allow Review: PERFORMED' && { printf 'yes'; return; }
            printf 'no' ;;
    esac
}

t18_diagnostics_table() {
    local id want label
    while IFS='|' read -r id want label; do
        [ -n "$id" ] || continue
        ROWS=$((ROWS + 1))
        assert_eq "T18[$id]: $label" "$want" "$(t18_probe "$id")"
    done <<'T18_CASES'
drift-banner-count|1|a drifted tree prints exactly ONE banner line (printing both verdicts satisfies any grep)
drift-exit|1|the exit code is exactly 1 -- not 2, which would read as an outage rather than a finding
drift-names-rule|yes|the generator's findings are forwarded: the missing rule string itself appears in the output
drift-write-remedy|yes|the Missing remedy names `gen-settings-allow.js --write`
orphan-exit|1|an orphan-only tree is also a finding, exit 1
orphan-named|yes|the orphaned command is named in the output
orphan-manual-remedy|yes|the Orphaned remedy is manual review AND says --write will not remove them
broken-gen-forwarded|yes|when the generator itself is gone, its error reaches the developer instead of a bare FAIL
synced-banner-count|1|the in-sync tree also prints exactly one banner
synced-banner-text|yes|and that one banner is PERFORMED (POSITIVE CONTROL for the rows above)
T18_CASES
}

# T19 -- THE FILE MODE. Every T9 row runs the script through `bash <path>` and the pre-commit
# fixtures chmod +x their own copy, so a real git index mode of 100644 passes this whole suite
# and then fail-closes every commit in the repository the moment the hook invokes it directly.
# The index is what a fresh clone gets, so the index is what is asserted.
t19_index_mode() {
    local mode
    mode="$(git -C "$AGENTS_DIR" ls-files -s -- "$REVIEW_REL" 2>/dev/null | awk '{print $1}')"
    assert_eq "T19: $REVIEW_REL is tracked with git index mode 100755 (executable in a fresh clone)" \
        "100755" "${mode:-<UNTRACKED>}"
}

t18_diagnostics_table
t19_index_mode
