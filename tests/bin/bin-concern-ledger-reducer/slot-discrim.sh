# tests/bin-concern-ledger-reducer/slot-discrim.sh
# Tests: bin/lib/concern-ledger.sh, bin/lib/concern-ledger/reduce.sh, bin/lib/concern-ledger/core.sh, bin/lib/concern-ledger/parse.sh, bin/concern-ledger
# Tags: concern-ledger, reducer, bind, merge, completeness, table-driven, scope:common, pwsh-not-required
# Sourced by tests/bin-concern-ledger-reducer.sh.
# Detail-plan Test plan cases 1-3: cl_slot determinism + non-collision, cl_slot_body
# discrimination, cl_discrim freezing material. Key-generation is a parser-class
# subject, so every case is table-driven (skills/_shared/test-design/parser-regex-tests.md).

echo ""
echo "--- reducer 1-3: slot / body-slot / discrim key generation ---"

HEX8='^[0-9a-f]{8}$'
BHEX9='^b[0-9a-f]{8}$'

SD_BASE=$(cl cl_slot "bin/foo.sh" "cl_bind" "correctness")
assert_match "1: cl_slot baseline is 8 lowercase hex chars" "$HEX8" "$SD_BASE"

# ---------------------------------------------------------------------------
# 1 + 2. Normalization equivalences (same) and non-collisions (diff).
#   <sp> expands to a literal space so trim behaviour is testable inside the table.
# ---------------------------------------------------------------------------
while IFS='|' read -r name p a c want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="$(trim "$want")"
    p="$(trim "$p")"; a="$(trim "$a")"; c="$(trim "$c")"
    p="${p//<sp>/ }"; a="${a//<sp>/ }"; c="${c//<sp>/ }"
    got=$(cl cl_slot "$p" "$a" "$c")
    if ! printf '%s' "$got" | grep -Eq "$HEX8"; then
        res="invalid"
    elif [[ "$got" == "$SD_BASE" ]]; then
        res="same"
    else
        res="diff"
    fi
    assert_eq "1/2: $name" "$want" "$res"
done <<'TABLE'
identity            | bin/foo.sh    | cl_bind     | correctness | same
backslash-separator | bin\foo.sh    | cl_bind     | correctness | same
dot-slash-prefix    | ./bin/foo.sh  | cl_bind     | correctness | same
uppercase-path      | BIN/FOO.SH    | cl_bind     | correctness | same
uppercase-anchor    | bin/foo.sh    | CL_BIND     | correctness | same
uppercase-category  | bin/foo.sh    | cl_bind     | CORRECTNESS | same
padded-anchor       | bin/foo.sh    | <sp>cl_bind<sp> | correctness | same
padded-category     | bin/foo.sh    | cl_bind     | <sp>correctness<sp> | same
other-category      | bin/foo.sh    | cl_bind     | security    | diff
other-anchor        | bin/foo.sh    | cl_merge    | correctness | diff
other-path          | bin/bar.sh    | cl_bind     | correctness | diff
whole-file-anchor   | bin/foo.sh    | -           | correctness | diff
TABLE

# ---------------------------------------------------------------------------
# 3. cl_slot_body — 'b'-prefixed 9 chars, whitespace/case normalized, never
#    collides with an anchor-derived slot.
# ---------------------------------------------------------------------------
SD_BODY=$(cl cl_slot_body "finalize must not delete the live ledger")
assert_match "3: cl_slot_body is 'b' + 8 hex chars" "$BHEX9" "$SD_BODY"

SD_BODY_REPEAT=$(cl cl_slot_body "finalize must not delete the live ledger")
assert_eq_nz "3: cl_slot_body is deterministic" "$SD_BODY" "$SD_BODY_REPEAT"

while IFS='|' read -r name text want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="$(trim "$want")"; text="$(trim "$text")"
    text="${text//<sp>/ }"
    got=$(cl cl_slot_body "$text")
    if ! printf '%s' "$got" | grep -Eq "$BHEX9"; then
        res="invalid"
    elif [[ "$got" == "$SD_BODY" ]]; then
        res="same"
    else
        res="diff"
    fi
    assert_eq "3: body-slot $name" "$want" "$res"
done <<'TABLE'
identical-text    | finalize must not delete the live ledger    | same
collapsed-spaces  | finalize<sp><sp><sp>must not delete the live ledger | same
mixed-case        | Finalize MUST not delete the Live Ledger    | same
different-text    | finalize may delete the live ledger         | diff
TABLE

# A body slot must never equal an anchor slot: the 'b' prefix guarantees it, and
# this pins the guarantee rather than the prefix implementation.
if [[ -n "$SD_BODY" && "$SD_BODY" == "$SD_BASE" ]]; then
    fail "3: body slot collided with anchor slot ($SD_BODY)"
else
    if printf '%s' "$SD_BODY" | grep -Eq "$BHEX9"; then
        pass "3: body slot never equals an anchor-derived slot"
    else
        fail "3: body slot malformed, collision guarantee unverifiable. Got: $SD_BODY"
    fi
fi

# ---------------------------------------------------------------------------
# 3b. cl_discrim — token-sorted content digest (frozen at first observation).
# ---------------------------------------------------------------------------
SD_DISC=$(cl cl_discrim "ledger write is not atomic")
assert_match "3b: cl_discrim is 8 lowercase hex chars" "$HEX8" "$SD_DISC"

while IFS='|' read -r name text want; do
    [[ -z "${name// }" || "$name" =~ ^[[:space:]]*# ]] && continue
    name="$(trim "$name")"; want="$(trim "$want")"; text="$(trim "$text")"
    text="${text//<sp>/ }"
    got=$(cl cl_discrim "$text")
    if ! printf '%s' "$got" | grep -Eq "$HEX8"; then
        res="invalid"
    elif [[ "$got" == "$SD_DISC" ]]; then
        res="same"
    else
        res="diff"
    fi
    assert_eq "3b: discrim $name" "$want" "$res"
done <<'TABLE'
verbatim         | ledger write is not atomic          | same
token-reordered  | atomic not is write ledger          | same
case-folded      | Ledger Write Is Not Atomic          | same
extra-whitespace | ledger<sp><sp>write is not<sp>atomic | same
reworded         | the ledger write lacks atomicity    | diff
TABLE
