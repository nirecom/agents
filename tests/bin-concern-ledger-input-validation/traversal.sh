# tests/bin-concern-ledger-input-validation/traversal.sh
# Tests: bin/concern-ledger, bin/lib/concern-ledger.sh, bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/finalize.sh
# Tags: concern-ledger, input-validation, path-traversal, injection, quoting, table-driven, scope:common, pwsh-not-required

# 3. Traversal. This is the failure the plans dir exists to prevent: a session
#    ID carrying a separator makes the derived name a path, and the round's
#    bytes leave the directory the caller nominated.
# ---------------------------------------------------------------------------
echo ""
echo "--- input 3: separators in a derived name ---"

# rejected_or <rc> — 'rejected' when the CLI refused, 'accepted' when it claimed
# success. The rc alone, named rather than numbered, so a row reads as a verdict.
rejected_or() { [ "$1" -ne 0 ] && printf 'rejected' || printf 'accepted'; }

{
    new_box
    RC="$(stage_with "../escaped" review-security-shared prod)"
    # Required behaviour: a separator in a derived name must be refused before
    # any filesystem mutation. Nothing may be written outside the plans dir the
    # caller nominated, and the refusal must carry a non-zero exit.
    assert_eq "3: a '..' session ID is rejected before it can write anywhere" \
        "verdict=rejected landed=nowhere" \
        "verdict=$(rejected_or "$RC") landed=$(landed)"
}

{
    new_box
    RC="$(stage_with "sub/nested" review-security-shared prod)"
    assert_eq "3: a '/' session ID is rejected as an invalid token before it can write anywhere" \
        "rc=2 landed=nowhere concern=no" \
        "rc=$RC landed=$(landed) concern=$(holds_concern)"
}

# The absolute-path form is the silent-loss case, and it is worse than the
# traversal: the CLI reports success while the round's findings reach no file at
# all. Composite so that "nothing was written" cannot pass on its own — the rc
# is what makes it a loss rather than a rejection.
{
    new_box
    ABS="$TMPDIR_BASE/absolute-target"
    RC="$(stage_with "$ABS" review-security-shared prod)"
    # Required behaviour: success is a claim that the round reached disk. When
    # the delta destination cannot be written the CLI must not make that claim.
    assert_eq "3: an absolute session ID is rejected rather than silently losing the round" \
        "verdict=rejected concern-on-disk=no" \
        "verdict=$(rejected_or "$RC") concern-on-disk=$(holds_concern)"
    assert_eq "3: and in no case does it write outside the plans dir" \
        "nowhere" "$(landed)"
}

# The same three inputs feed every path the ledger owns, so a separator that
# escapes in one escapes in all of them (CPR-ORTH). Asserted over the builders
# themselves rather than one subcommand's behaviour.
{
    # The probe reports each builder's rc alongside its output, so a refusal
    # (rc non-zero, nothing printed) is distinguishable from a builder that was
    # never reached and from one that printed an escaping path. Counting lines
    # of output alone cannot tell those three apart: a builder that starts
    # refusing prints nothing, and the old loop dropped empty lines before
    # counting, so a correct fix would have read as "the probe stopped working".
    PROBE="$TMPDIR_BASE/paths.sh"
    cat > "$PROBE" <<'PROBE_EOF'
#!/usr/bin/env bash
set +u
source "$1" >/dev/null 2>&1 || exit 127
probe() {
    local name="$1"; shift
    local out rc
    out="$("$@" 2>/dev/null)"; rc=$?
    printf '%s|rc=%s|out=%s\n' "$name" "$rc" "$out"
}
probe ledger   cl_ledger_path   "$2" "$3" f
probe snapshot cl_snapshot_path "$2" "$3" f
probe json     cl_json_path     "$2" "$3" f
probe diag     cl_diag_path     "$2" "$3" f
probe round    cl_round_path    "$2" "$3" f
probe delta    cl_delta_path    "$2" "$3" f 1 p
PROBE_EOF

    # count_probe <session-id> → "calls=N emitted=N escaping=N refused=N"
    count_probe() {
        local calls=0 emitted=0 escaping=0 refused=0 line rc out
        while IFS= read -r line; do
            calls=$((calls + 1))
            rc="${line#*|rc=}"; rc="${rc%%|*}"
            out="${line#*|out=}"
            [ "$rc" = 0 ] || refused=$((refused + 1))
            [ -n "$out" ] && emitted=$((emitted + 1))
            case "$out" in */plansdir/../*) escaping=$((escaping + 1)) ;; esac
        done < <(bash "$PROBE" "$LIB" /plansdir "$1" 2>/dev/null)
        printf 'calls=%s emitted=%s escaping=%s refused=%s' \
            "$calls" "$emitted" "$escaping" "$refused"
    }

    # A good token first: this is what makes the refusal case below meaningful.
    # Without it, "every builder refused" would also be satisfied by a library
    # that had stopped building paths at all.
    assert_eq_nz "3: every path builder was probed and builds a path from a good token" \
        "calls=6 emitted=6 escaping=0 refused=0" "$(count_probe "sess-01")"
    # Required behaviour: no builder may emit a path that leaves the plans dir.
    # The counts are over all six, so a fix to one of them is not enough
    # (CPR-ORTH).
    assert_eq "3: no path builder lets a '..' escape the plans dir" \
        "calls=6 emitted=0 escaping=0 refused=6" "$(count_probe "../escaped")"
}

echo ""
echo "--- input 3b: the --ledger bypass of the three-part address ---"

# 3b. --ledger names the ledger outright, so need_addr stops requiring the
#     address and the validated builders above are never reached. reduce and
#     check-staged still paste the session ID and the format into the delta
#     glob they discover with, so the tokens stay an injection surface after the
#     bypass and the check has to sit on them rather than on the address
#     (#2025 C11). Refusal alone is not the property: the subcommand also owns
#     a ledger it was handed directly, so "changed nothing" is asserted over the
#     whole sandbox rather than over the plans dir.

# glob_sub <sub> <sid> <format> — reduce/check-staged addressed by --ledger.
glob_sub() {
    local rc=0
    bash "$CLI" "$1" --ledger "$LED3B" --plans-dir "$PLANS" \
        --session-id "$2" --format "$3" --round 1 >/dev/null 2>&1 || rc=$?
    printf '%s' "$rc"
}

# fingerprint <dir> — every file under dir with its byte count, so a write
# anywhere in the sandbox shows up as a changed string rather than as a path
# the assertion would have had to name in advance.
fingerprint() {
    find "$1" -type f -exec wc -c {} \; 2>/dev/null | tr -s ' ' ' ' | sort
}

{
    new_box
    LED3B="$BOX/held-concern-ledger.txt"
    {
        printf '#concern-ledger-v2|review-security-shared|sess3b|cycle=1\n'
        printf 'C1|HIGH|open|1|1|bin/x#fn:security|d3b01|review-code-codex|review-code-codex|-|held\n'
    } > "$LED3B"
    printf 'decoy\n' > "$PLANS/decoy.txt"
    BEFORE3B="$(fingerprint "$BOX")"

    ROWS3B=0
    while IFS='~' read -r label sub sid fmt; do
        label="${label#"${label%%[![:space:]]*}"}"; label="${label%"${label##*[![:space:]]}"}"
        sub="${sub#"${sub%%[![:space:]]*}"}"; sub="${sub%"${sub##*[![:space:]]}"}"
        sid="${sid#"${sid%%[![:space:]]*}"}"; sid="${sid%"${sid##*[![:space:]]}"}"
        fmt="${fmt#"${fmt%%[![:space:]]*}"}"; fmt="${fmt%"${fmt##*[![:space:]]}"}"
        [ -z "$label" ] && continue
        case "$label" in \#*) continue ;; esac
        ROWS3B=$((ROWS3B + 1))
        assert_eq "3b: $label" "rc=2" "rc=$(glob_sub "$sub" "$sid" "$fmt")"
    done <<'TABLE'
reduce with a '..' session ID          ~ reduce       ~ ../escaped ~ review-security-shared
check-staged with a '..' session ID    ~ check-staged ~ ../escaped ~ review-security-shared
reduce with a '..' format              ~ reduce       ~ sess3b     ~ ../escaped
reduce with an absolute session ID     ~ reduce       ~ /abs/path  ~ review-security-shared
reduce with a backslash session ID     ~ check-staged ~ sub\esc    ~ review-security-shared
reduce with a metacharacter format     ~ reduce       ~ sess3b     ~ a;b
check-staged with a glob format        ~ check-staged ~ sess3b     ~ *
reduce with an option-shaped ID        ~ reduce       ~ -rf        ~ review-security-shared
reduce with no session ID at all       ~ reduce       ~            ~ review-security-shared
check-staged with no format at all     ~ check-staged ~ sess3b     ~
TABLE

    assert_eq_nz "3b: every row of the bypass table ran" "10" "$ROWS3B"
    # The last two rows are only reachable because --ledger made the address
    # optional: without it the CLI would have stopped at "--session-id is
    # required" and the glob would never have been built.
    assert_eq_nz "3b: and not one of them changed a byte in the sandbox" \
        "$BEFORE3B" "$(fingerprint "$BOX")"

    # Both directions of the same classifier. Without these, every row above
    # would also pass against a build in which reduce and check-staged had
    # stopped discovering anything at all.
    printf '#producer|review-code-codex|complete|complete|anchored|1\n' \
        > "$PLANS/sess3b-review-security-shared-round-1-delta-review-code-codex.txt"
    assert_eq "3b: an accepted address still reduces into the ledger --ledger named" \
        "rc=0" "rc=$(glob_sub reduce sess3b review-security-shared)"
    assert_eq_nz "3b: and the reduction really reached that ledger" \
        "1" "$(grep -c 'stale' "$LED3B" | tr -d ' ')"
    CS3B="$(bash "$CLI" check-staged --ledger "$LED3B" --plans-dir "$PLANS" \
        --session-id sess3b --format review-security-shared --round 1 2>&1)"
    assert_eq_nz "3b: and check-staged reaches discovery and names who has not staged" \
        "1" "$(printf '%s' "$CS3B" | grep -c -F 'security-scanner:missing' | tr -d ' ')"
}

# ---------------------------------------------------------------------------
