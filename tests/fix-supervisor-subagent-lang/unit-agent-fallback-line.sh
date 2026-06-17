# unit-agent-fallback-line.sh — Per-agent fallback-line sentinel checks.
# Sourced after helpers.sh; inherits AGENT_FILES, EXPECTED_JA, counters.
#
# For each of the 9 agent files:
#   - If <!-- conv-lang-fallback:v1 --> marker is absent → SKIP (Phase 2a not adopted)
#   - If present: PASS marker exists; PASS line is dynamic (no hardcoded language).

FALLBACK_MARKER='<!-- conv-lang-fallback:v1 -->'

for agent_file in "${AGENT_FILES[@]}"; do
    label_base=$(basename "$agent_file")
    if [ ! -f "$agent_file" ]; then
        skip "fallback($label_base): file missing — cannot check"
        continue
    fi
    # Find marker line(s) — exact substring match.
    marker_lines=$(grep -nF "$FALLBACK_MARKER" "$agent_file" 2>/dev/null || true)
    if [ -z "$marker_lines" ]; then
        skip "fallback($label_base): Phase 2a not yet adopted for $label_base (marker absent)"
        continue
    fi
    pass "fallback($label_base): marker '$FALLBACK_MARKER' present"
    # Verify the marker line does NOT contain a hardcoded language token.
    # We check 'japanese' (case-insensitive) on the marker line itself; the
    # dynamic directive must reference an env var / template rather than naming
    # a specific language inline.
    if echo "$marker_lines" | grep -iqE 'japanese|english|french|german|spanish|chinese|korean'; then
        fail "fallback($label_base): marker line hardcodes a language token (must be dynamic): $marker_lines"
    else
        pass "fallback($label_base): marker line does not hardcode a language token"
    fi
done
