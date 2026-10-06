# Group O: the marker-state decision extracted from trp_marker_conformance (#2372)
# Tests: bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, case-markers, scope:issue-specific
# Sourced by tests/bin/fix-1833-audit-tests-survival-first.sh

# The state rule (none / conforming / malformed / uncertain) moves into
# trp_marker_state_from_globals so crr_read can reuse it after a registry-routed parse.
# trp_marker_conformance must keep deciding exactly as before: the parse followed by the
# extracted function gives the same state, line and reason, and the pinned states hold.

O_DIR="$TMPDIR_BASE/o-marker-state"
mkdir -p "$O_DIR"

cat > "$O_DIR/none.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh
echo plain
FX
cat > "$O_DIR/conforming.sh" <<'FX'
#!/usr/bin/env bash
# Tests: bin/a.sh, bin/b.sh
case_begin "a" "bin/a.sh"
echo a
case_end
FX
cat > "$O_DIR/malformed.sh" <<'FX'
#!/usr/bin/env bash
  case_begin "a" "bin/a.sh"
echo a
case_end
FX
cat > "$O_DIR/uncertain.sh" <<'FX'
#!/usr/bin/env bash
echo "multi
line"
if true; then
case_begin "a" "bin/a.sh"
echo a
case_end
fi
FX

# o_state <mode> <file> — "state|line|reason"; mode direct = trp_marker_conformance,
# split = trp_parse_case_markers then trp_marker_state_from_globals (globals pre-set to
# x so a function that leaves them stale cannot pass). NO_FN when it does not exist.
o_state() {
    run_with_timeout bash -c '
        . "$1" || exit 95
        if [ "$2" = direct ]; then
            trp_marker_conformance "$3"
        else
            declare -F trp_marker_state_from_globals >/dev/null || { printf NO_FN; exit 0; }
            TRP_MARKER_STATE=x; TRP_MARKER_LINE=x; TRP_MARKER_REASON=x
            trp_parse_case_markers "$3"
            trp_marker_state_from_globals
        fi
        printf "%s|%s|%s" "$TRP_MARKER_STATE" "$TRP_MARKER_LINE" "$TRP_MARKER_REASON"
    ' _ "$RETIRE_LIB" "$1" "$2" 2>/dev/null
}

# name|want "state|line|reason"
while IFS='|' read -r o_name o_state_w o_line_w o_reason_w; do
    [ -n "$o_name" ] || continue
    o_want="$o_state_w|$o_line_w|$o_reason_w"
    assert_eq "O: $o_name trp_marker_conformance state" "$o_want" "$(o_state direct "$O_DIR/$o_name.sh")"
    assert_eq "O: $o_name parse + trp_marker_state_from_globals matches" "$o_want" "$(o_state split "$O_DIR/$o_name.sh")"
done <<'ROWS'
none|none||
conforming|conforming||
malformed|malformed|2|grammar
uncertain|uncertain|5|depth
ROWS
