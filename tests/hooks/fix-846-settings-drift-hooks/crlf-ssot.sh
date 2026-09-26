# tests/fix-846-settings-drift-hooks/crlf-ssot.sh
# Tests: hooks/post-merge, hooks/post-checkout, install/settings-allow-commands.txt
# Tags: hook, settings, drift, post-merge, post-checkout, crlf, scope:common, pwsh-not-required, TL2
# T50-T51. Sourced by tests/fix-846-settings-drift-hooks.sh, whose probes and helpers this reuses.
run_crlf_table() {
    require_source "$POST_MERGE" "T50-T51: CRLF SSOT containment" || return
    require_source "$POST_CHECKOUT" "T50-T51: CRLF SSOT containment (post-checkout)" || return
    # WHY CRLF IS A REAL INPUT HERE, not a hypothetical: `core.autocrlf=true` is the Windows
    # default, so the SSOT this hook reads is CRLF in the working tree on the very platform
    # this repo is developed on. The stage-2 filter drops CRLF comment/blank lines (\r is in
    # [[:space:]]) but leaves the \r on an ENTRY, while `grep -qxF` matches whole lines against
    # `git diff --name-only`, which carries none -- so without a strip, "bin/fx-tool\r" is not
    # "bin/fx-tool" and stage 2 silently never fires, indistinguishable from the deliberate
    # fail-open branch. The plan now strips it at read time (`tr -d '\r'`), and these rows are
    # what force that token to exist: they are the CRLF twins of T22/T23, whose LF rows cannot
    # tell a stripping reader from a non-stripping one.
    SSOT_EOL=crlf
    run_trigger_rows <<'CRLF_CASES'
T50|merge|settings.json|called|CONTAINMENT post-merge: stage 1 never reads the SSOT, so its verdict must not move with the SSOT's line endings
T51|checkout|settings.json|called|CONTAINMENT post-checkout: the same, which also proves the hook RUNS to completion on a CRLF SSOT rather than dying, making a T48/T49 failure a miss and not a crash
CRLF_CASES
    SSOT_EOL=lf
}
