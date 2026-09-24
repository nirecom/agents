# Part of tests/fix-quality-gates-not-found.sh (sourced, not standalone).
# Tests: skills/review-code-security/scripts/run-quality-gates.sh
# Tags: security-gate, quality-gates, review-code-security, false-green, drift-guard, scope:common, pwsh-not-required, TL2
#
# G1-G4 — the original incident: how each gate is NAMED, and what is said when one is not
# there. G1/G2 are static (the script's own text), G3/G4 drive the real script against a
# fake config dir under a PATH from which no bare name can resolve.

# ---- G1: every invocation goes through a full path --------------------------

g1_full_path_invocations() {
  local bad
  # Guards the vacuous pass: if the parse ever stops finding invocations (a rewrite, a
  # renamed variable), G1c would be trivially satisfied by an empty set.
  check "G1a: the parse found at least one gate invocation in $RUNNER_REL" \
    "yes" "$([ "$INVOCATION_COUNT" -gt 0 ] && echo yes || echo none-found)"
  [ "$INVOCATION_COUNT" -gt 0 ] || return 0
  # Cross-check of the two independent derivations. They can only disagree if an
  # invocation drives something that is not a bin/ command, or a gate is invoked twice —
  # either way the per-gate rows below would be reasoning about the wrong set.
  check "G1b: the invocation count matches the derived gate count" \
    "$GATE_COUNT" "$INVOCATION_COUNT"
  # CPR-ORTH: ALL of them, not the ones someone remembered. One surviving bare-name line is
  # one gate that can go on being silently skipped.
  bad="$(printf '%s\n' "$INVOCATIONS" | grep -v '/bin/' | sed 's/:.*//' | tr '\n' ' ' || true)"
  check "G1c: every gate invocation names the executable by full path (offending line numbers)" \
    "" "${bad% }"
}

# ---- G2: no gate is left invoked by bare name -------------------------------

# "Bare name" means command position: line start, or straight after `;`, `&`, `|`, `(`,
# `&&`, `||`. A name preceded by `/` is the full-path form and is what G1 requires.
g2_no_bare_names() {
  local g bare
  if [ "$GATE_COUNT" -eq 0 ]; then
    fail "G2: the parse found no gate name in $RUNNER_REL, so no bare-name row could run"
    return 0
  fi
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    bare="$(grep -cE "(^|[;&|(])[[:space:]]*${g}([[:space:]]|\$)" "$STRIPPED" || true)"
    check "G2[$g]: the gate is not invoked by bare name (PATH-dependent)" "0" "$bare"
  done <<< "$GATES"
}

# ---- G3: an absent gate is reported, a present gate runs --------------------

g3_absent_gate_is_reported() {
  local cfg repo g
  split_gates
  # Without both halves the row would prove only one direction. A gate list of one would
  # make this impossible, which is a reason to say so rather than to assert nothing.
  check "G3a: the fixture has at least one present gate and at least one absent gate" \
    "yes" "$([ -n "$PRESENT" ] && [ -n "$ABSENT" ] && echo yes || echo "present=[$PRESENT] absent=[$ABSENT]")"
  if [ -z "$PRESENT" ] || [ -z "$ABSENT" ]; then return 0; fi

  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  mkdir -p "$cfg/bin" "$cfg/rules"
  : > "$cfg/rules/core-principles.md"
  for g in $PRESENT; do write_stub "$cfg/bin" "$g" 0; done
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"

  check "G3b: the runner still exits 0 with gates missing" "0" "$RQG_RC"

  for g in $ABSENT; do
    # The marker, in the gates' own `## <name>: <verdict>` family. Trailing detail (the
    # path attempted) is free; the heading, the gate name and the verdict are not.
    if grep -qE "^##[[:space:]].*${g}.*:[[:space:]]*NOT FOUND" <<< "$RQG_OUT"; then
      pass "G3c[$g]: the missing gate is reported on stdout as NOT FOUND"
    else
      fail "G3c[$g]: the missing gate is reported on stdout as NOT FOUND -- no '## ... ${g} ...: NOT FOUND' line in: $RQG_OUT"
    fi
  done

  # Direction two. A marker emitted unconditionally would satisfy every G3c row and mean
  # nothing, so the present gates must NOT carry it — and must show they ran.
  for g in $PRESENT; do
    if grep -qE "^##[[:space:]].*${g}.*:[[:space:]]*NOT FOUND" <<< "$RQG_OUT"; then
      fail "G3d[$g]: a gate that exists is not reported NOT FOUND -- unexpected marker in: $RQG_OUT"
    else
      pass "G3d[$g]: a gate that exists is not reported NOT FOUND"
    fi
    if grep -qF -- "## STUB $g: PERFORMED" <<< "$RQG_OUT"; then
      pass "G3e[$g]: the gate under \$AGENTS_CONFIG_DIR/bin actually ran"
    else
      fail "G3e[$g]: the gate under \$AGENTS_CONFIG_DIR/bin actually ran -- no stub output in: $RQG_OUT"
    fi
  done
}

# ---- G4: a gate's own failure stays advisory --------------------------------

# The property that must NOT change. Every gate is present, the FIRST one exits non-zero,
# and the run has to continue to the last one and still exit 0 — otherwise the fix would
# have converted an advisory lint result into a blocker.
g4_failure_stays_advisory() {
  local cfg repo g first="" last=""
  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  mkdir -p "$cfg/bin" "$cfg/rules"
  : > "$cfg/rules/core-principles.md"
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    [ -n "$first" ] || first="$g"
    last="$g"
  done <<< "$GATES"
  if [ -z "$first" ] || [ "$first" = "$last" ]; then
    skip_case "G4 advisory-exit rows (fewer than two gates were derived, so 'the run continued' is not observable)"
    return 0
  fi
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    if [ "$g" = "$first" ]; then write_stub "$cfg/bin" "$g" 3; else write_stub "$cfg/bin" "$g" 0; fi
  done <<< "$GATES"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"

  check "G4a: a gate exiting non-zero does not abort the runner" "0" "$RQG_RC"
  if grep -qF -- "## STUB $first: PERFORMED" <<< "$RQG_OUT"; then
    pass "G4b: the failing gate still reported its own output"
  else
    fail "G4b: the failing gate still reported its own output -- missing in: $RQG_OUT"
  fi
  if grep -qF -- "## STUB $last: PERFORMED" <<< "$RQG_OUT"; then
    pass "G4c: every later gate still ran after the failure"
  else
    fail "G4c: every later gate still ran after the failure -- '$last' missing in: $RQG_OUT"
  fi
  # The per-gate marker only. The G8 summary line also carries the words NOT FOUND, and it
  # is required to be present here reading zero, so the pattern is anchored on the
  # `## <name>: NOT FOUND` shape a gate line has and the summary line does not.
  if grep -qE "^##[[:space:]][^:]*:[[:space:]]*NOT FOUND" <<< "$RQG_OUT"; then
    fail "G4d: no NOT FOUND marker appears when every gate is present -- in: $RQG_OUT"
  else
    pass "G4d: no NOT FOUND marker appears when every gate is present"
  fi
}

g1_full_path_invocations
g2_no_bare_names
if exec_bit_works; then
  g3_absent_gate_is_reported
  g4_failure_stays_advisory
else
  skip_case "G3/G4 integration rows (this host ignores the execute bit, so a stub gate cannot be run)"
fi
