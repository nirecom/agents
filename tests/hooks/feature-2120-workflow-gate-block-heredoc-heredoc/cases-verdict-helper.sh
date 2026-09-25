# Tests: hooks/enforce-worktree.js
# Tags: enforce-worktree, harness-self-test, table-driven, scope:issue-specific
# M13 — negative controls for the harness's own verdict_of() decoder (helpers.sh).
# Sourced by feature-2120-workflow-gate-block-heredoc-heredoc.sh.

run_M13() {
    # M13 (C5, test-review round 3) — NEGATIVE CONTROLS for verdict_of() itself. The
    # helper is the false-green surface every assert_allowed rides on, so its own
    # mapping is pinned table-driven. Unrelated JSON shapes and unknown decision
    # values must NOT be credited as "allow".
    local label payload want got
    while IFS='~' read -r label payload want; do
        [[ -z "$label" || "$label" =~ ^[[:space:]]*# ]] && continue
        label="${label//[[:space:]]/}"; want="${want//[[:space:]]/}"
        got="$(verdict_of "$payload")"
        if [ "$got" = "$want" ]; then pass "M13 $label → $want"
        else fail "M13 $label: want '$want', got '$got'"; fi
    done <<'TABLE'
# label                  ~ hook stdout                              ~ verdict
canonical-allow          ~ {}                                       ~ allow
canonical-block          ~ {"decision":"block","reason":"nope"}     ~ block
# --- unknown/unexpected decision values are NOT allows ---------------------
decision-allow-string    ~ {"decision":"allow"}                     ~ unknown-decision:allow
decision-approve         ~ {"decision":"approve"}                   ~ unknown-decision:approve
decision-empty-string    ~ {"decision":""}                          ~ unknown-decision:
decision-null            ~ {"decision":null}                        ~ unknown-decision:null
decision-block-uppercase ~ {"decision":"BLOCK"}                     ~ unknown-decision:BLOCK
# --- unrelated JSON shapes are NOT allows ----------------------------------
error-object             ~ {"error":"boom"}                         ~ non-canonical:error
reason-without-decision  ~ {"reason":"blocked but no decision key"} ~ non-canonical:reason
hook-specific-output     ~ {"hookSpecificOutput":{"x":1}}           ~ non-canonical:hookSpecificOutput
json-array               ~ []                                       ~ non-object
json-array-nonempty      ~ [{"decision":"block"}]                   ~ non-object
# --- not a JSON object at all ----------------------------------------------
json-null                ~ null                                     ~ unparseable
json-number              ~ 42                                       ~ unparseable
json-string              ~ "allow"                                  ~ unparseable
plain-text               ~ Error: cannot find module                ~ unparseable
empty-stdout             ~                                          ~ unparseable
TABLE

    # Last-line-wins is load-bearing: a hook that logs noise before its verdict
    # must still be read from the FINAL parseable object, not the first.
    got="$(verdict_of "$(printf 'warn: something\n{}')")"
    if [ "$got" = "allow" ]; then pass "M13 trailing-verdict-after-noise → allow"
    else fail "M13 trailing-verdict-after-noise: want 'allow', got '$got'"; fi
}
