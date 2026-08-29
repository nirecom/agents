#!/bin/bash
# tests/feature-2099-complexity-stage-routing/record-read-readback-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/record-complexity-and-skip, hooks/workflow-state/state-io/session-fields.js
# Tags: complexity, routing, cli, read-back, injection, security, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh AFTER record-read-cases.sh —
# the state probes (d2099_raw_ce_count / d2099_projected_ce) live there.
# Split out of record-read-cases.sh per rules/coding/file-split.md Pattern A.

D2099_ISO_RB="$TMPDIR_BASE/iso-readback"

# R-24: the read-back INVARIANT through the real CLI (detail.md D6). The isolated
# tree makes the RAW read report levels that disagree with the signals while the
# compat read stays valid, so only a CLI using the RAW accessor can notice. What
# the CLI owes: non-zero exit and NO receipt — the append-only store has no
# rollback, so asserting the event vanished would encode a contract D6 rejects.
d2099_build_readback_tree() {
    mkdir -p "$D2099_ISO_RB"
    cp -r "$AGENTS_DIR/hooks" "$D2099_ISO_RB/hooks"
    cp -r "$AGENTS_DIR/bin" "$D2099_ISO_RB/bin"

    # Shim BOTH the barrel and the state-io module: which one the CLI requires is
    # an implementation choice, and the invariant must hold either way. The shim
    # is data-only — it rewrites the returned `levels`, never the module syntax.
    local f
    for f in "$D2099_ISO_RB/hooks/workflow-state.js" "$D2099_ISO_RB/hooks/workflow-state/state-io.js"; do
        [ -f "$f" ] || continue
        cat >> "$f" <<'SHIM'

/* test shim (#2099 R-24): force the RAW read-back to disagree with the signals. */
if (typeof module.exports.readLastRawComplexityEvent === "function") {
  const __d2099_orig = module.exports.readLastRawComplexityEvent;
  module.exports.readLastRawComplexityEvent = function () {
    const v = __d2099_orig.apply(this, arguments);
    if (!v || typeof v !== "object") { return v; }
    return Object.assign({}, v, {
      levels: { detail: "high", write_tests: "high", write_code: "high" },
    });
  };
}
SHIM
    done
    if grep -q "d2099_orig" "$D2099_ISO_RB/hooks/workflow-state.js" 2>/dev/null \
        || grep -q "d2099_orig" "$D2099_ISO_RB/hooks/workflow-state/state-io.js" 2>/dev/null; then
        echo "SHIMMED"
    else
        echo "NO_SHIM_APPLIED"
    fi
}

d2099_cli_read_back_invariant() {
    local shimmed sid rc out
    shimmed=$(d2099_build_readback_tree)
    assert_eq "R-24a the read-back fixture actually carries the mismatching shim" "SHIMMED" "$shimmed"

    # S1-multi-file derives low/low/high; the shim reports high/high/high.
    sid=$(new_session rbcli)
    rc=0
    out=$(run_with_timeout node "$D2099_ISO_RB/bin/workflow/record-complexity-evaluation" \
        --session "$sid" --signals "S1-multi-file" 2>&1) || rc=$?
    assert_eq "R-24 the CLI's own read-back catches raw levels that disagree with the signals (exit 1)" \
        "1" "$rc"
    assert_not_contains "R-25 ... and prints no success receipt" "RECORDED_COMPLEXITY" "$out"

    # No rollback: the append already happened, and D6 does not undo it. Read the
    # RAW log through the INTACT tree — exactly one event, still there.
    assert_eq "R-26 ... while the append-only log keeps the event it already wrote (no rollback, D6)" \
        "1" "$(d2099_raw_ce_count "$sid")"

    # Control: with the shim absent the same call succeeds, proving R-24 failed
    # because of the mismatch and not because the fixture is broken.
    local sid2
    sid2=$(new_session rbctl)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid2" --signals "S1-multi-file" 2>&1) || rc=$?
    assert_eq "R-27 control: the identical call through the unshimmed tree exits 0" "0" "$rc"
    assert_contains "R-28 ... with the receipt" "RECORDED_COMPLEXITY" "$out"
}

# R-29: input injection THROUGH THE BASH WRAPPER. R-21 covers the Node CLI, but
# bin/workflow/record-complexity-and-skip is the file #2099 changes and the only
# layer where an unquoted expansion could execute a payload. A canary file makes
# execution observable: command substitution, backticks, a semicolon command and
# embedded spaces all try to create it.
d2099_wrapper_injection() {
    local sid rc out canary payload
    canary="$TMPDIR_BASE/d2099-wrapper-canary.txt"
    rm -f "$canary"
    payload="S1-multi-file; touch $canary \$(touch $canary) \`touch $canary\` & touch $canary"

    sid=$(new_session wrapinj)
    rc=0
    out=$(run_with_timeout bash "$BIN_RECORD_SKIP" --session "$sid" --signals "$payload" --target outline 2>&1) || rc=$?

    if [ -e "$canary" ]; then
        fail "R-29 the wrapper EXECUTED an embedded payload (canary $canary was created)"
        rm -f "$canary"
    else
        pass "R-29 no part of the --signals payload executes in the wrapper"
    fi

    # Inert-as-data, end to end: whatever survives must come back as signal
    # TOKENS, and an unrecognized token routes undecidable-high — never silently
    # low, and never as an executed side effect.
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage write_code 2>/dev/null | head -1)
    assert_eq "R-30 the payload is stored as data and routes undecidable-high" "level=high" "$out"

    out=$(d2099_projected_ce "$sid")
    assert_contains "R-31 the raw persisted record still holds the payload text verbatim" "touch" "$out"

    if [ -e "$canary" ]; then
        fail "R-32 the read path executed the stored payload (canary appeared after read-back)"
        rm -f "$canary"
    else
        pass "R-32 reading the record back does not execute the stored payload either"
    fi
}

d2099_cli_read_back_invariant
d2099_wrapper_injection
