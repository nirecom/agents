# tests/feature-2339-sweep-plan-headings/c8-tests.sh
# Sourced by feature-2339-sweep-plan-headings.sh
# C8: full 7-section canonical outline with unknown section — reorder, preservation, idempotency.

# C8: a full canonical outline with all 7 sections in WRONG order plus one unknown
# custom section. After --fix: (a) the 7 canonical sections are in the approved
# order; (b) the unknown section survives with its body; (c) every section body is
# preserved verbatim; (d) a second --fix is a byte-identical no-op (idempotent).
C8="$TMPDIR_BASE/c8-outline.md"
cat > "$C8" << 'EOF'
# Outline Plan C8

## Reused existing utilities / building blocks

BODY_REUSED

## Confirmed non-goals

BODY_NONGOALS

## Accepted Tradeoffs

BODY_TRADEOFFS

## Custom Notes

BODY_CUSTOM

## Considered alternatives (rejected)

BODY_ALTERNATIVES

## Delivery plan

BODY_DELIVERY

## Adopted approach

BODY_ADOPTED

## Issues

BODY_ISSUES
EOF
C8_RC=0; node "$SWEEP_NODE" --fix "$(to_node "$C8")" >/dev/null 2>&1 || C8_RC=$?

# C8a: canonical sections in the approved order (strictly increasing byte offsets).
C8_ORDER=(
    "## Issues"
    "## Adopted approach"
    "## Delivery plan"
    "## Considered alternatives (rejected)"
    "## Accepted Tradeoffs"
    "## Confirmed non-goals"
    "## Reused existing utilities / building blocks"
)
_c8_order_ok=1
_c8_prev=-1
for _h in "${C8_ORDER[@]}"; do
    _pos="$(grep -boF "$_h" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -z "$_pos" || "$_pos" -le "$_c8_prev" ]]; then _c8_order_ok=0; break; fi
    _c8_prev="$_pos"
done
if [[ $C8_RC -eq 0 && $_c8_order_ok -eq 1 ]]; then
    pass "C8a: --fix reorders all 7 canonical outline sections into the approved order"
else
    fail "C8a: canonical sections not in approved order after --fix (rc=$C8_RC order_ok=$_c8_order_ok)"
fi

# C8b: the unknown 'Custom Notes' section is preserved (heading + body).
if [[ $C8_RC -eq 0 ]] && grep -qF "## Custom Notes" "$C8" 2>/dev/null && grep -qF "BODY_CUSTOM" "$C8" 2>/dev/null; then
    pass "C8b: unknown custom section preserved after --fix"
else
    fail "C8b: unknown custom section dropped by --fix (rc=$C8_RC)"
fi

# C8e: the unknown 'Custom Notes' section keeps its position and is NOT relocated
# to the file tail. In the fixture Custom Notes sits in the interior (before the
# 'Considered alternatives (rejected)' / 'Delivery plan' / 'Issues' blocks). A
# reorder that only sorts the KNOWN canonical sections must leave the unknown
# anchored in the interior — so it must still precede the LAST canonical section
# ('Reused existing utilities / building blocks'). Asserting this catches the
# regression where unknowns are swept to the very end of the document. Content
# preservation is the softer fallback covered by C8b/C8c.
if [[ $C8_RC -eq 0 ]]; then
    _pos_custom8="$(grep -boF "## Custom Notes" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    _pos_reused8="$(grep -boF "## Reused existing utilities / building blocks" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -n "$_pos_custom8" && -n "$_pos_reused8" && "$_pos_custom8" -lt "$_pos_reused8" ]]; then
        pass "C8e: unknown 'Custom Notes' kept in the interior (precedes the last canonical section; not swept to the tail)"
    else
        fail "C8e: unknown section relocated to the file tail after --fix (custom=$_pos_custom8 last-canonical=$_pos_reused8)"
    fi
    # C8e-strong: the unknown section must stay at its ORIGINAL INTERLEAVING position.
    # In the fixture, Custom Notes occupies slot 3 (after Accepted Tradeoffs at
    # slot 2, before Considered alternatives at slot 4 in the input). The reorder
    # algorithm places known sections at known slots and leaves unknown slots
    # unchanged, so Custom Notes must end up between Delivery plan (now at slot 2)
    # and Considered alternatives (now at slot 4). Checking only custom < last-
    # canonical is insufficient — this check also requires custom < Considered.
    _pos_delivery8="$(grep -boF "## Delivery plan" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    _pos_considered8="$(grep -boF "## Considered alternatives (rejected)" "$C8" 2>/dev/null | head -1 | cut -d: -f1)"
    if [[ -n "$_pos_custom8" && -n "$_pos_delivery8" && -n "$_pos_considered8" \
          && "$_pos_delivery8" -lt "$_pos_custom8" && "$_pos_custom8" -lt "$_pos_considered8" ]]; then
        pass "C8e-strong: Custom Notes is between Delivery plan and Considered alternatives (original interleaving preserved, not just pre-tail)"
    else
        fail "C8e-strong: Custom Notes not at its original interleaving position (custom=$_pos_custom8 delivery=$_pos_delivery8 considered=$_pos_considered8)"
    fi
else
    fail "C8e: cannot check unknown-section position — first --fix failed (rc=$C8_RC)"
fi

# C8c: every section body survives the reorder verbatim (no content lost).
_c8_bodies_ok=1
for _m in BODY_REUSED BODY_NONGOALS BODY_TRADEOFFS BODY_CUSTOM BODY_ALTERNATIVES BODY_DELIVERY BODY_ADOPTED BODY_ISSUES; do
    grep -qF "$_m" "$C8" 2>/dev/null || _c8_bodies_ok=0
done
if [[ $C8_RC -eq 0 && $_c8_bodies_ok -eq 1 ]]; then
    pass "C8c: --fix preserves every section body verbatim (8/8 markers present)"
else
    fail "C8c: a section body was lost in the reorder (rc=$C8_RC bodies_ok=$_c8_bodies_ok)"
fi

# C8d: a second --fix over the already-canonical file is a byte-identical no-op.
if [[ $C8_RC -eq 0 ]]; then
    _c8_sha1="$(sha1sum "$C8" 2>/dev/null | cut -d' ' -f1)"
    node "$SWEEP_NODE" --fix "$(to_node "$C8")" >/dev/null 2>&1
    _c8_sha2="$(sha1sum "$C8" 2>/dev/null | cut -d' ' -f1)"
    if [[ -n "$_c8_sha1" && "$_c8_sha1" == "$_c8_sha2" ]]; then
        pass "C8d: --fix is idempotent (second run leaves the file byte-identical)"
    else
        fail "C8d: second --fix changed the file (sha1 before=$_c8_sha1 after=$_c8_sha2)"
    fi
else
    fail "C8d: cannot check idempotency — first --fix failed (rc=$C8_RC)"
fi
