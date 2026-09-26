# Part of tests/fix-quality-gates-not-found.sh (sourced, not standalone).
# Tests: skills/review-code-security/scripts/run-quality-gates.sh, skills/review-code-security/SKILL.md
# Tags: security-gate, quality-gates, review-code-security, false-green, silent-skip, scope:common, pwsh-not-required, TL2
#
# G7-G9 — what NOT FOUND means, how many of them there were, and who has to read it.
#
# G7. `[ ! -x "$exe" ]` decides absence, and the message it prints ("no executable at
# <path>") asserts absence. Those are two different facts. The Windows shim the installer
# writes reads `exec bash "<agents>/bin/<command>" "$@"` and never depended on the execute
# bit; `core.fileMode=false` under Git Bash, a tree that was COPIED rather than checked out,
# and several mounted filesystems all produce a gate that exists, is readable, and runs
# perfectly while `-x` is false. That gate is then reported NOT FOUND and skipped — the
# silent-skip incident reassembled from different parts, now with a line that actively
# misinforms. rules/coding.md mandating `git update-index --chmod=+x` for every new bin/
# script is the standing evidence that this condition occurs. Every gate carries
# `#!/usr/bin/env bash`, so running one through `bash "$exe"` preserves behaviour exactly.
#
# G8. G3 puts absence on a line. A line is not a consumer: eight gates print eight blocks,
# and one extra line inside them is exactly what a reader skims past — which is what
# happened in the review that found this. A total on the LAST line is the one position that
# survives skimming, and it must be printed when the count is zero too, so its absence is
# itself a signal rather than an ambiguity.
#
# G9. The runner cannot make anyone read it. SKILL.md RCS-2 is the consumer, and the
# obligation has to be written there or the summary line is a message with no addressee.
# This is a static row on purpose: it is the only assertion in this suite that can fail when
# the consumer side is dropped, and it costs nothing.

# The first derived gate that is not the billed one — the gate G7/G8 leave out of the
# fixture. review-code-codex is never a candidate: it must be stubbed in every fixture.
absent_candidate() {
  local g
  while IFS= read -r g; do
    [ -n "$g" ] || continue
    [ "$g" = "review-code-codex" ] && continue
    printf '%s' "$g"
    return 0
  done <<< "$GATES"
}

# ---- G7: present-but-not-executable is not absent ---------------------------

g7_exec_bit_is_not_existence() {
  local cfg repo missing ran
  missing="$(absent_candidate)"
  check "G7a: the fixture has a gate it can leave out" \
    "yes" "$([ -n "$missing" ] && echo yes || echo none)"
  [ -n "$missing" ] || return 0

  cfg="$(make_full_cfg noexec)"
  rm -f "$cfg/bin/$missing"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"

  check "G7b: the runner still exits 0" "0" "$RQG_RC"
  # Direction one: a gate that is genuinely not there is still reported.
  if grep -qE "^##[[:space:]][^:]*${missing}[^:]*:[[:space:]]*NOT FOUND" <<< "$RQG_OUT"; then
    pass "G7c: a gate that does not exist is still reported NOT FOUND"
  else
    fail "G7c: a gate that does not exist is still reported NOT FOUND -- missing in: $RQG_OUT"
  fi
  # Direction two, the regression: everything else exists without the execute bit and must
  # have RUN. The count is the assertion, so a single surviving `-x` test is visible.
  ran="$(grep -cF -- "## STUB " <<< "$RQG_OUT" || true)"
  check "G7d: every gate that exists without the execute bit still ran" \
    "$((GATE_COUNT - 1))" "$ran"
  if grep -qE "^##[[:space:]][^:]*:[[:space:]]*NOT FOUND" <<< "$RQG_OUT" && \
     [ "$(grep -cE "^##[[:space:]][^:]*:[[:space:]]*NOT FOUND" <<< "$RQG_OUT")" != "1" ]; then
    fail "G7e: no gate is accused of absence merely for lacking the execute bit -- in: $RQG_OUT"
  else
    pass "G7e: no gate is accused of absence merely for lacking the execute bit"
  fi
}

# ---- G7f-G7j: present-but-unreadable is not absent either -------------------

# The third state of a gate file, after "absent" and "present without the execute bit". A
# fix that falls back to `bash "$exe"` cannot run this one either: the interpreter has to
# read the script, so a gate with no read permission fails however it is invoked. The
# question the fix has to answer is what the REPORT says about it, and there are only three
# candidates:
#
#   NOT FOUND        — rejected, and for exactly the reason G7 exists. The file is there.
#                      Saying it is not there sends the reader to look for a missing
#                      install when the actual repair is a chmod, and it is the same false
#                      statement the execute-bit case makes.
#   ran, advisory    — rejected. `|| true` would swallow the interpreter's failure, the gate
#                      would be counted among the ones that ran, and the summary would
#                      overstate the sweep. That is the silent-skip incident with extra
#                      steps.
#   its own verdict  — what is asserted below: the gate is NAMED on a `## ` line of its own,
#                      it is NOT called NOT FOUND, it did not run, and the summary does not
#                      count it as having run.
#
# The exact word chosen for the verdict is left to the implementation; pinning it here would
# constrain the fix without protecting anything. What is pinned is that the gate is visible,
# is not misdescribed, and is not counted as work performed.
g7_unreadable_is_not_absent() {
  local cfg repo blind ran ll trip
  blind="$(absent_candidate)"
  [ -n "$blind" ] || return 0

  cfg="$(make_full_cfg exec)"
  repo="$(make_repo)"
  chmod a-r "$cfg/bin/$blind" 2>/dev/null || true
  run_runner "$cfg" "$repo"

  check "G7f: an unreadable gate is a caveat, not a failure — the runner still exits 0" \
    "0" "$RQG_RC"

  if grep -qE "^##[[:space:]][^:]*${blind}[^:]*:[[:space:]]*NOT FOUND" <<< "$RQG_OUT"; then
    fail "G7g: a gate that exists but cannot be read is not called NOT FOUND -- in: $RQG_OUT"
  else
    pass "G7g: a gate that exists but cannot be read is not called NOT FOUND"
  fi

  if grep -qE "^##[[:space:]][^:]*${blind}[^:]*:" <<< "$RQG_OUT"; then
    pass "G7h: and it is named in the report rather than silently skipped"
  else
    fail "G7h: and it is named in the report rather than silently skipped -- in: $RQG_OUT"
  fi

  # It genuinely could not run, so no stub output from it — the other gates are untouched.
  ran="$(grep -cF -- "## STUB " <<< "$RQG_OUT" || true)"
  check "G7i: every readable gate still ran, and the unreadable one did not" \
    "$((GATE_COUNT - 1))" "$ran"

  # And the totals line does not claim it as work performed. Read through the same parser
  # G8 uses, so the two rows cannot disagree about what the summary means.
  ll="$(last_line)"
  trip="$(summary_triple "$ll")"
  check "G7j: the summary does not count the unreadable gate among the gates that ran" \
    "$((GATE_COUNT - 1))" "$(printf '%s' "$trip" | cut -d' ' -f1)"
}

# ---- G8: the totals line ----------------------------------------------------

# Parses the summary into `<ran> <total> <notfound>` so one assertion covers all three
# numbers, and prints the offending line when the shape does not match at all.
summary_triple() { # <last-line>
  printf '%s\n' "$1" | sed -nE \
    's|^##[[:space:]]*gates:[[:space:]]*([0-9]+)/([0-9]+)[[:space:]]+ran,[[:space:]]*([0-9]+)[[:space:]]+NOT FOUND.*|\1 \2 \3|p'
}

g8_summary_is_the_last_line() {
  local cfg repo ll g
  # Direction one: every gate present. The summary must still be printed, reading zero —
  # a summary that only appears when something is wrong cannot be relied on to be there.
  cfg="$(make_full_cfg exec)"
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"
  ll="$(last_line)"
  check "G8a: with every gate present the last line totals them, 0 missing" \
    "$GATE_COUNT $GATE_COUNT 0" "$(summary_triple "$ll")"

  # Direction two: half the gates missing. The counts move, and the NAMES are on the line —
  # a bare count would still leave the reader hunting through eight blocks for which ones.
  split_gates
  if [ -z "$PRESENT" ] || [ -z "$ABSENT" ]; then
    skip_case "G8 partial-fixture rows (the derived gate list does not split into present and absent)"
    return 0
  fi
  cfg="$(mktemp -d "$TMPROOT/cfg.XXXXXX")"
  mkdir -p "$cfg/bin" "$cfg/rules"
  : > "$cfg/rules/core-principles.md"
  for g in $PRESENT; do write_stub "$cfg/bin" "$g" 0; done
  repo="$(make_repo)"
  run_runner "$cfg" "$repo"
  ll="$(last_line)"
  check "G8b: the last line counts what ran, what was expected, and what was missing" \
    "$(printf '%s' "$PRESENT" | wc -w | tr -d '[:space:]') $GATE_COUNT $(printf '%s' "$ABSENT" | wc -w | tr -d '[:space:]')" \
    "$(summary_triple "$ll")"
  for g in $ABSENT; do
    if grep -qF -- "$g" <<< "$ll"; then
      pass "G8c[$g]: the summary line names the missing gate"
    else
      fail "G8c[$g]: the summary line names the missing gate -- last line was: [$ll]"
    fi
  done
  # A summary that names gates which are present would make the list unusable as a to-do.
  for g in $PRESENT; do
    if grep -qF -- "$g" <<< "$ll"; then
      fail "G8d[$g]: the summary line names only the missing gates -- last line was: [$ll]"
    else
      pass "G8d[$g]: the summary line names only the missing gates"
    fi
  done
}

# ---- G9: the consumer side of the NOT FOUND line ----------------------------

# Static, and deliberately tolerant: it pins that RCS-3 carries the obligation and names the
# line the obligation has to surface on, not the wording used to say it. Adopted rather than
# skipped because the runner's whole G8 contract is a message to this reader — with the
# obligation unwritten, every row above can stay green while the report a human sees is
# unchanged, which is precisely the shape of the incident being fixed.
rcs3_block() {
  awk '/^RCS-3\./{f=1} f && /^(RCS-[0-9]|## )/ && !/^RCS-3\./ {exit} f' "$SKILL_MD"
}

g9_skill_consumes_not_found() {
  local block
  if [ ! -f "$SKILL_MD" ]; then
    fail "G9: $SKILL_REL does not exist"
    return 0
  fi
  block="$(rcs3_block)"
  # Guards the vacuous pass: if RCS-3 is ever renumbered the parse would return nothing and
  # both rows below would be asserting against an empty string.
  check "G9a: the RCS-3 section was found in $SKILL_REL" \
    "yes" "$([ -n "$block" ] && echo yes || echo not-found)"
  [ -n "$block" ] || return 0
  if grep -qF -- "NOT FOUND" <<< "$block"; then
    pass "G9b: RCS-3 obliges the consumer to act on a NOT FOUND gate"
  else
    fail "G9b: RCS-3 obliges the consumer to act on a NOT FOUND gate -- no 'NOT FOUND' in RCS-3: [$block]"
  fi
  if grep -qF -- "Security Review" <<< "$block"; then
    pass "G9c: and names the reported line the reader actually sees"
  else
    fail "G9c: and names the reported line the reader actually sees -- no 'Security Review' in RCS-3: [$block]"
  fi
}

# SKIPPED: the review-code-security skill actually reading the summary and surfacing it.
# Because: that requires a real skill invocation through claude -p, which this suite is not
#          gated for (RUN_TL3) and which would reach the billed review-code-codex gate.
# TL3 gap: whether the model honours the RCS-3 obligation in practice. G9 pins that the
#          obligation is written down; nothing here pins that it is obeyed.

if exec_bit_works && no_exec_bit_observable; then
  g7_exec_bit_is_not_existence
else
  skip_case "G7 execute-bit rows (this host does not honour the execute bit in both directions)"
fi
if exec_bit_works && no_read_observable; then
  g7_unreadable_is_not_absent
else
  skip_case "G7 unreadable-gate rows (chmod a-r is advisory on this host, or running as root)"
fi
if exec_bit_works; then
  g8_summary_is_the_last_line
else
  skip_case "G8 summary rows (this host ignores the execute bit, so a stub gate cannot be run)"
fi
g9_skill_consumes_not_found
