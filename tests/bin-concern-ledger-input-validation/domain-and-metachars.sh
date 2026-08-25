# tests/bin-concern-ledger-input-validation/domain-and-metachars.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, input-validation, path-traversal, injection, quoting, table-driven, scope:common, pwsh-not-required

# lang-check: ignore -- table below deliberately includes a non-ASCII session ID fixture
# ---------------------------------------------------------------------------
# 1. A session ID reaches a derived file name, so #2025 C9 made the allowlist
#    fail-closed ([A-Za-z0-9._-]): anything outside it is refused before a byte
#    is written.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 1: session IDs inside and outside the allowlist ---"

while IFS='~' read -r label sid want; do
    label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
    sid="${sid#"${sid%%[![:space:]]*}"}"; sid="${sid%"${sid##*[![:space:]]}"}"
    want="${want#"${want%%[![:space:]]*}"}"; want="${want%"${want##*[![:space:]]}"}"
    [ -z "$label" ] && continue
    case "$label" in \#*) continue ;; esac
    new_box
    RC="$(stage_with "$sid" review-security-shared prod)"
    if [ "$want" = "accepted" ]; then
        assert_eq "1: $label stages into the plans dir" \
            "rc=0 landed=in-plans concern=yes" \
            "rc=$RC landed=$(landed) concern=$(holds_concern)"
    else
        # Fail-closed is refused *and* inert: a non-zero rc that still left a
        # file somewhere would be the worse half of the old behaviour.
        assert_eq "1: $label is refused before anything is written" \
            "refused=yes landed=nowhere concern=no" \
            "refused=$([ "$RC" -ne 0 ] && printf yes || printf no) landed=$(landed) concern=$(holds_concern)"
    fi
done <<'TABLE'
a plain alphanumeric session ID      ~ sess001                              ~ accepted
a session ID with dashes             ~ 2026-08-15-sess                      ~ accepted
a session ID with underscores        ~ sess_001_b                           ~ accepted
a UUID-shaped session ID             ~ 3f2b1c4d-5e6f-4a7b-8c9d-0e1f2a3b4c5d ~ accepted
a session ID holding a dot           ~ sess.001                             ~ accepted
a session ID holding a space         ~ sp ace                               ~ rejected
a non-ASCII session ID               ~ セッション                            ~ rejected
TABLE

# The allowlist is a character class with no length term, so a token can be
# entirely legal and still name a file the OS will not create — NAME_MAX on
# POSIX, MAX_PATH on Windows. Which side of the limit a host falls on is not
# this CLI's contract; that the attempt is all-or-nothing is.
{
    new_box
    LONG_SID="$(printf '%0300d' 0 | tr '0' 'a')"
    assert_eq_nz "1: the overlong token is allowlist-legal (precondition)" \
        "chars=300 illegal=no" \
        "chars=${#LONG_SID} illegal=$(case "$LONG_SID" in *[!A-Za-z0-9._-]*) printf yes ;; *) printf no ;; esac)"

    LONG_RC="$(stage_with "$LONG_SID" review-security-shared prod)"
    LONG_OUT="rc=$([ "$LONG_RC" -ne 0 ] && printf nonzero || printf zero) landed=$(landed) concern=$(holds_concern)"
    assert_eq "1: an overlong session ID either stages completely or writes nothing at all" \
        "consistent" \
        "$(case "$LONG_OUT" in
            "rc=zero landed=in-plans concern=yes") printf consistent ;;
            "rc=nonzero landed=nowhere concern=no") printf consistent ;;
            *) printf '%s' "$LONG_OUT" ;;
           esac)"
    assert_eq "1: and leaves no publication temporary behind either way" \
        "0" "$(find "$PLANS" -maxdepth 1 -name '.sp-tmp.*' 2>/dev/null | wc -l | tr -d ' ')"
}

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
