# Group I: reset contract — no TRP_CASE_* leak between files (C5) (#2081)
# Tests: bin/lib/test-retire-predicate/case-parser.sh, bin/lib/test-retire-predicate.sh
# Tags: TL2, audit-tests, retire, scope:issue-specific
# Sourced by tests/bin/fix-2081-case-unit-refcount.sh
#
# trp_enumerate_cases resets TRP_CASE_*/TRP_ORPHAN_CASE_IDX/TRP_REFCOUNT/
# TRP_HAS_MARKERS/TRP_UNIT_MODE/_TRP_MARKER_MALFORMED at entry. Processing an
# orphan case-unit and THEN a marker-less alive file in one process must not
# leak the prior file's orphan indices into a spurious partial-orphan.

if ! require_fn trp_case_refcount_verdict "I0"; then return 0; fi

I_REPO="$(make_repo)"
add_src "$I_REPO" "bin/i-live.sh"
# (1) marker file, both cases orphan → orphan, populates TRP_ORPHAN_CASE_IDX.
add_raw "$I_REPO" "i-orphan.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/i-dead1.sh, bin/i-dead2.sh
# Tags: TL2, scope:issue-specific
case_begin "a" "bin/i-dead1.sh"
case_end
case_begin "b" "bin/i-dead2.sh"
case_end
EOF
# (2) marker-less alive file (must stay alive/file, no leaked orphan indices).
add_test_file "$I_REPO" "i-nomarker-alive.sh" "bin/i-live.sh" "TL2, scope:common"
# (3) malformed marker file → file-level fallback.
add_raw "$I_REPO" "i-malformed.sh" <<'EOF'
#!/usr/bin/env bash
# Tests: bin/i-live.sh
# Tags: TL2, scope:issue-specific
  case_begin "n" "bin/i-live.sh"
case_end
EOF
commit_repo "$I_REPO" "group-i alternation fixtures"

# Process the orphan case-unit first — this is what could leak.
run_verdict "$I_REPO" "tests/i-orphan.sh"
assert_eq "I1 orphan case-unit verdict" "orphan" "${TRP_VERDICT:-x}"
assert_eq "I1b orphan indices populated before the next file" \
    "2" "${#TRP_ORPHAN_CASE_IDX[@]}"

# Now the marker-less alive file. A leaked TRP_ORPHAN_CASE_IDX would misclassify
# it as partial-orphan; the reset contract forbids that.
run_verdict "$I_REPO" "tests/i-nomarker-alive.sh"
assert_eq "I2 marker-less file has markers cleared" "0" "${TRP_HAS_MARKERS:-x}"
assert_eq "I2b no leaked orphan indices" "0" "${#TRP_ORPHAN_CASE_IDX[@]}"
assert_eq "I2c verdict is alive, not a leaked partial-orphan" "alive" "${TRP_VERDICT:-x}"
assert_eq "I2d unit mode reset to file" "file" "${TRP_UNIT_MODE:-x}"

# Malformed after alive → fallback, malformed flag must be freshly set (not stale
# clear from the alive file).
run_verdict "$I_REPO" "tests/i-malformed.sh"
assert_eq "I3 malformed flag freshly set" "1" "${_TRP_MARKER_MALFORMED:-x}"
assert_eq "I3b malformed falls back to file unit" "file" "${TRP_UNIT_MODE:-x}"

# Back to a clean marker-less alive file: the malformed flag must clear again.
run_verdict "$I_REPO" "tests/i-nomarker-alive.sh"
assert_eq "I4 malformed flag cleared on the next clean file" "0" "${_TRP_MARKER_MALFORMED:-x}"
assert_eq "I4b verdict alive again" "alive" "${TRP_VERDICT:-x}"
