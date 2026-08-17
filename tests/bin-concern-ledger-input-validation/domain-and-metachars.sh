# tests/bin-concern-ledger-input-validation/domain-and-metachars.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, input-validation, path-traversal, injection, quoting, table-driven, scope:common, pwsh-not-required

# lang-check: ignore -- table below deliberately includes a non-ASCII session ID fixture
# ---------------------------------------------------------------------------
# 1. The ordinary domain. A session ID is not restricted to [a-z0-9-] anywhere
#    in the codebase, so anything a real workflow state file can hold must work.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 1: session IDs that must keep working ---"

while IFS='~' read -r label sid; do
    label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
    sid="${sid#"${sid%%[![:space:]]*}"}"; sid="${sid%"${sid##*[![:space:]]}"}"
    [ -z "$label" ] && continue
    case "$label" in \#*) continue ;; esac
    new_box
    RC="$(stage_with "$sid" review-security-shared prod)"
    assert_eq "1: $label stages into the plans dir" \
        "rc=0 landed=in-plans concern=yes" \
        "rc=$RC landed=$(landed) concern=$(holds_concern)"
done <<'TABLE'
a plain alphanumeric session ID      ~ sess001
a session ID with dashes             ~ 2026-08-15-sess
a session ID with underscores        ~ sess_001_b
a UUID-shaped session ID             ~ 3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d
a session ID holding a space         ~ sp ace
a session ID holding a dot           ~ sess.001
a non-ASCII session ID               ~ セッション
TABLE

# ---------------------------------------------------------------------------
# 2. Shell metacharacters. The values are interpolated into command arguments,
#    so the property that matters is that they stay data: a metacharacter must
#    never reach a shell, whether the CLI rejects it or files it verbatim.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 2: shell metacharacters stay data ---"

while IFS='~' read -r label sid; do
    label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
    sid="${sid#"${sid%%[![:space:]]*}"}"; sid="${sid%"${sid##*[![:space:]]}"}"
    [ -z "$label" ] && continue
    case "$label" in \#*) continue ;; esac
    new_box
    BEFORE="$(canaries)"
    stage_with "$sid" review-security-shared prod >/dev/null
    assert_eq "2: $label executes nothing" \
        "canaries=$BEFORE" "canaries=$(canaries)"
done <<'TABLE'
a semicolon command separator ~ a;touch PWNED-semi;b
a command substitution        ~ x$(touch PWNED-subst)y
a backtick substitution       ~ x`touch PWNED-tick`y
a pipe into a command         ~ a|touch PWNED-pipe
an ampersand background job   ~ a&touch PWNED-amp
a redirection                 ~ a>PWNED-redir
a glob that matches the box   ~ *
TABLE

# A glob in the session ID must not make the CLI address a file it did not name.
{
    new_box
    printf 'decoy\n' > "$PLANS/decoy-review-security-shared-round-1-delta-prod.txt"
    stage_with '*' review-security-shared prod >/dev/null
    assert_eq "2: a '*' session ID does not overwrite an unrelated staged file" \
        "decoy" "$(cat "$PLANS/decoy-review-security-shared-round-1-delta-prod.txt" 2>/dev/null || true)"
}

# ---------------------------------------------------------------------------
