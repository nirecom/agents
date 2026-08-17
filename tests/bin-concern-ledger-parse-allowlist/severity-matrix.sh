# tests/bin-concern-ledger-parse-allowlist/severity-matrix.sh
# Tests: bin/lib/concern-ledger/parse.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/render.sh, bin/lib/concern-ledger.sh, bin/concern-ledger
# Tags: concern-ledger, parser, allowlist, severity, category, table-driven, mutation-probe, scope:common, pwsh-not-required

# ---------------------------------------------------------------------------
# 1. The accepted matrix: every SEVERITY x CATEGORY pair the vocabulary declares.
# ---------------------------------------------------------------------------
echo ""
echo "--- parse 1: the accepted SEVERITY x CATEGORY matrix ---"

assert_eq "1: the category vocabulary was readable (precondition)" \
    "yes" "$([ -n "$VOCAB" ] && printf 'yes' || printf 'no')"

MIN="$TMPDIR_BASE/matrix.in"
: > "$MIN"
MATRIX_N=0
for SEV in HIGH MEDIUM LOW; do
    for CAT in $VOCAB; do
        MATRIX_N=$((MATRIX_N + 1))
        printf 'm-%s-%s\t- [%s] - | bin/lib/concern-ledger/parse.sh#_cl_emit_anchored | %s | matrix concern for %s under %s\n' \
            "$SEV" "$CAT" "$SEV" "$CAT" "$SEV" "$CAT" >> "$MIN"
    done
done
batch "$MIN"

assert_eq "1: the matrix enumerated 3 severities x the whole vocabulary" \
    "$((3 * VOCAB_N))" "$MATRIX_N"
assert_eq_nz "1: the prober returned a result row for every cell" \
    "$MATRIX_N" "$(grep -c '^m-' "$BATCH_OUT" 2>/dev/null || printf 0)"

MATRIX_BAD=""
SEEN_SLOTS=""
SLOT_COLLISION=""
for SEV in HIGH MEDIUM LOW; do
    for CAT in $VOCAB; do
        K="m-$SEV-$CAT"
        OBS="$(res "$K")"
        if [ "$OBS" != "COMPLETE recs=1 unparsed=0" ]; then
            MATRIX_BAD="${MATRIX_BAD:+$MATRIX_BAD }$K=$OBS"
            continue
        fi
        GOT_SEV="$(rec "$K" 2)"; GOT_CAT="$(rec "$K" 5)"; GOT_TXT="$(rec "$K" 8)"
        if [ "$GOT_SEV" != "$SEV" ] || [ "$GOT_CAT" != "$CAT" ] \
           || [ "$GOT_TXT" != "matrix concern for $SEV under $CAT" ]; then
            MATRIX_BAD="${MATRIX_BAD:+$MATRIX_BAD }$K=sev:$GOT_SEV,cat:$GOT_CAT,txt:$GOT_TXT"
            continue
        fi
        # The category is part of the review address: two categories on the same
        # path#anchor must not share a SLOT, or a docs nit inherits a security
        # finding's identity.
        SLOT="$(rec "$K" 3)"
        case " $SEEN_SLOTS " in
            *" $CAT:$SLOT "*) ;;
            *)
                case " $SEEN_SLOTS " in
                    *":$SLOT "*) SLOT_COLLISION="${SLOT_COLLISION:+$SLOT_COLLISION }$CAT" ;;
                esac
                SEEN_SLOTS="${SEEN_SLOTS:+$SEEN_SLOTS }$CAT:$SLOT"
                ;;
        esac
    done
done

assert_eq "1: every declared SEVERITY x CATEGORY pair parses and round-trips" "" "$MATRIX_BAD"
assert_eq "1: no two categories on the same path#anchor share a SLOT" "" "$SLOT_COLLISION"

# ---------------------------------------------------------------------------
# 2. Severity mutation probes: near-misses are rejected, never repaired.
# ---------------------------------------------------------------------------
echo ""
echo "--- parse 2: severity near-misses become #unparsed, never a valid value ---"

SIN="$TMPDIR_BASE/sev.in"
: > "$SIN"
SEV_KEYS=""
SEV_LABEL=""
N=0
while IFS='~' read -r label bullet; do
    label="$(strip "$label")"
    [ -z "$label" ] && continue
    case "$label" in \#*) continue ;; esac
    N=$((N + 1))
    printf 's%s\t- %s - | a/b.sh#fn | correctness | a severity probe\n' "$N" "$(strip "$bullet")" >> "$SIN"
    SEV_KEYS="${SEV_KEYS:+$SEV_KEYS }s$N"
    SEV_LABEL="$SEV_LABEL
s$N	$label"
done <<'TABLE'
a lowercase severity            ~ [high]
a mixed-case severity           ~ [High]
an out-of-vocabulary CRITICAL   ~ [CRITICAL]
an out-of-vocabulary INFO       ~ [INFO]
an empty severity               ~ []
a severity padded with spaces   ~ [ HIGH ]
an unbracketed severity         ~ HIGH
a near-miss HIGHEST             ~ [HIGHEST]
TABLE
batch "$SIN"

for K in $SEV_KEYS; do
    LBL="$(printf '%s' "$SEV_LABEL" | grep -m1 -- "^$K	" | cut -f2)"
    assert_eq "2: $LBL is quarantined as #unparsed with a PARTIAL round label" \
        "PARTIAL recs=0 unparsed=1" "$(res "$K")"
    assert_eq "2: $LBL never becomes a valid severity in a normalized record" \
        "" "$(rec "$K" 2)"
done

# A rejected line survives verbatim under '#unparsed', so an operator can still
# read what the reviewer actually said. Observed through the real CLI's staging
# file rather than the in-process prober.
new_env
VERB="$TMPDIR_BASE/verbatim.txt"
BAD_BULLET="- [CRITICAL] - | a/b.sh#fn | correctness | a severity probe"
mk_report "$VERB" "$BAD_BULLET"
stage "$VERB" 1 verb
VERB_DF="$(delta_file "$PLANS" "$SID" 1 verb)"
assert_contains "2: the rejected bullet is preserved verbatim under #unparsed" \
    "#unparsed|$BAD_BULLET" "$(cat "$VERB_DF" 2>/dev/null || true)"
assert_eq "2: no record with a valid severity is fabricated from it" \
    "0" "$(grep -cE '^-\|(HIGH|MEDIUM|LOW)\|' "$VERB_DF" 2>/dev/null || true)"

