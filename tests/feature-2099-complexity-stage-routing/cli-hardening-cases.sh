#!/bin/bash
# tests/feature-2099-complexity-stage-routing/cli-hardening-cases.sh
# Tests: bin/workflow/record-complexity-evaluation, bin/workflow/read-complexity-evaluation, bin/workflow/derive-complexity-level, hooks/workflow-state/state-io.js
# Tags: complexity, routing, cli, read-back, corruption, normalization, security, scope:issue-specific
# Sourced by ../feature-2099-complexity-stage-routing.sh — helpers come from there.

# --- H-RB: read-back invariant, one case per mutated field -------------------
# The invariant is "what the raw event says must agree with what was recorded".
# Mutating only `levels` (as R-24 does) leaves `level` and `signals` untested, so
# a CLI comparing one field passes while the other two go unchecked.
d2099h_rb_shim() {
    case "$1" in
        levels) echo 'levels: { detail: "high", write_tests: "high", write_code: "high" }' ;;
        level) echo 'level: "low"' ;;
        signals) echo 'signals: ["S5-breaking"]' ;;
    esac
}

# Build an isolated hooks+bin tree whose RAW read-back disagrees with what the
# record call actually persisted, in exactly one field. Data-only shim.
d2099h_build_rb_tree() {
    local kind="$1" root="$TMPDIR_BASE/iso-rb-$1" f
    mkdir -p "$root"
    cp -r "$AGENTS_DIR/hooks" "$root/hooks"
    cp -r "$AGENTS_DIR/bin" "$root/bin"
    for f in "$root/hooks/workflow-state.js" "$root/hooks/workflow-state/state-io.js"; do
        [ -f "$f" ] || continue
        cat >> "$f" <<SHIM

/* test shim (#2099 H-RB-$kind): make the RAW read-back disagree in one field. */
if (typeof module.exports.readLastRawComplexityEvent === "function") {
  const __d2099h_orig = module.exports.readLastRawComplexityEvent;
  module.exports.readLastRawComplexityEvent = function () {
    const v = __d2099h_orig.apply(this, arguments);
    if (!v || typeof v !== "object") { return v; }
    return Object.assign({}, v, { $(d2099h_rb_shim "$kind") });
  };
}
SHIM
    done
    if grep -q "d2099h_orig" "$root/hooks/workflow-state.js" 2>/dev/null \
        || grep -q "d2099h_orig" "$root/hooks/workflow-state/state-io.js" 2>/dev/null; then
        echo "SHIMMED"
    else
        echo "NO_SHIM_APPLIED"
    fi
}

# One independent case per field. Each records signals whose honest projection
# contradicts that field's shimmed value, so the CLI can only pass by comparing
# that specific field.
d2099h_read_back_per_field() {
    local kind sid rc out shimmed ctl sid2

    # Control FIRST: an honest record through the intact tree must succeed. If it
    # does not, a rejection under the shim proves nothing (the CLI is refusing
    # every call), so the per-field cases below must go RED rather than green.
    sid2=$(new_session rbctl2)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid2" --signals "S1-multi-file" 2>&1) || rc=$?
    assert_eq "H-RB-ctl control: an honest record through the unshimmed tree exits 0" "0" "$rc"
    assert_contains "H-RB-ctl-b ... with the receipt" "RECORDED_COMPLEXITY" "$out"
    case "$rc$out" in 0*RECORDED_COMPLEXITY*) ctl=yes ;; *) ctl=no ;; esac

    for kind in levels level signals; do
        shimmed=$(d2099h_build_rb_tree "$kind")
        assert_eq "H-RB-$kind-a the fixture carries the $kind-mutating shim" "SHIMMED" "$shimmed"

        # S1-multi-file: levels low/low/high, aggregate level high (signals
        # non-empty), signals ["S1-multi-file"] — each shim contradicts one.
        sid=$(new_session rb$kind)
        rc=0
        out=$(run_with_timeout node "$TMPDIR_BASE/iso-rb-$kind/bin/workflow/record-complexity-evaluation" \
            --session "$sid" --signals "S1-multi-file" 2>&1) || rc=$?
        if [ "$rc" -eq 0 ]; then
            fail "H-RB-$kind a raw read-back disagreeing in '$kind' alone was ACCEPTED (exit 0) — that field is unchecked"
        elif [ "$ctl" != "yes" ]; then
            fail "H-RB-$kind unattributable: the shimmed record failed (exit $rc) but so did the honest control, so nothing here tests the '$kind' comparison"
        else
            pass "H-RB-$kind a raw read-back disagreeing in '$kind' alone fails the record (exit $rc)"
        fi
        assert_not_contains "H-RB-$kind-b ... and prints no success receipt" "RECORDED_COMPLEXITY" "$out"
    done
}

# --- H-ENV: unusable workflow directory --------------------------------------
# A directory that cannot exist: its parent is a regular file, so no mkdir can
# succeed. The write CLI must fail loudly and leave nothing; the read CLI is
# fail-open by contract (detail.md D4) and must answer NONE on exit 0.
d2099h_unusable_workflow_dir() {
    local blocker bad rc out
    blocker="$TMPDIR_BASE/not-a-dir"
    printf 'i am a file\n' > "$blocker"
    # cygpath -m fails once ANY ancestor segment is a regular file (as $blocker
    # is here), so it must run on $blocker alone — converting the already-broken
    # $blocker/inside path silently falls back to the untranslated POSIX form,
    # which native-Windows node resolves relative to the wrong drive root.
    bad="$(to_node_path "$blocker")/inside"

    rc=0
    out=$(CLAUDE_WORKFLOW_DIR="$bad" \
        run_with_timeout node "$BIN_RECORD" --session "h-env-1" --signals "S1-multi-file" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        pass "H-ENV-1 record against an uncreatable workflow dir exits non-zero ($rc)"
    else
        fail "H-ENV-1 record against an uncreatable workflow dir exited 0 — a lost evaluation reported as success"
    fi
    assert_not_contains "H-ENV-2 ... and prints no success receipt" "RECORDED_COMPLEXITY" "$out"
    if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
        pass "H-ENV-3 ... and says something diagnostic rather than failing silently"
    else
        fail "H-ENV-3 ... but produced NO diagnostic output at all"
    fi
    if [ -f "$blocker" ] && [ "$(cat "$blocker")" = "i am a file" ]; then
        pass "H-ENV-4 ... and the blocking file is untouched"
    else
        fail "H-ENV-4 ... but the blocking file was clobbered"
    fi

    rc=0
    out=$(CLAUDE_WORKFLOW_DIR="$bad" \
        run_with_timeout node "$BIN_READ" --session "h-env-1" --stage detail 2>/dev/null) || rc=$?
    assert_eq "H-ENV-5 read stays fail-open on an unusable workflow dir (exit 0)" "0" "$rc"
    assert_eq "H-ENV-6 ... answering NONE rather than inventing a level" "NONE" "$(printf '%s\n' "$out" | head -1)"
}

# --- H-COR: corrupt state file -----------------------------------------------
# Not-JSON and truncated-JSON are separate failure modes: the first fails at
# parse, the second can parse-fail mid-object or yield a shape with no events.
d2099h_corrupt_state_file() {
    local kind sid p raw before rc out
    for kind in garbage truncated; do
        sid=$(new_session corrupt$kind)
        p="$WORKFLOW_DIR/$sid.json"
        case "$kind" in
            garbage) raw='}{ this is not json at all <<<' ;;
            truncated) raw='{"session_id":"x","events":[{"seq":1,"kind":"complexity_' ;;
        esac
        printf '%s' "$raw" > "$p"
        before=$(cksum < "$p")

        rc=0
        out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "S1-multi-file" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            pass "H-COR-$kind record onto a $kind state file exits non-zero ($rc)"
        else
            fail "H-COR-$kind record onto a $kind state file exited 0 — corruption silently accepted or overwritten"
        fi
        assert_not_contains "H-COR-$kind-a ... and prints no success receipt" "RECORDED_COMPLEXITY" "$out"
        if [ -n "$(printf '%s' "$out" | tr -d '[:space:]')" ]; then
            pass "H-COR-$kind-b ... and reports a diagnostic"
        else
            fail "H-COR-$kind-b ... but produced NO diagnostic output"
        fi
        assert_eq "H-COR-$kind-c ... leaving the file byte-identical (no partial write over evidence)" \
            "$before" "$(cksum < "$p")"

        rc=0
        out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null) || rc=$?
        assert_eq "H-COR-$kind-d read stays fail-open over a $kind state file (exit 0)" "0" "$rc"
        assert_eq "H-COR-$kind-e ... answering NONE" "NONE" "$(printf '%s\n' "$out" | head -1)"
        assert_eq "H-COR-$kind-f ... and reading never rewrites the corrupt file" \
            "$before" "$(cksum < "$p")"
    done
}

# --- H-SIG: --signals payload normalization ----------------------------------
# Every variant below is the SAME signal set written untidily. Each must either
# normalize to the canonical outcome or be rejected outright with nothing
# written; "accepted but stored differently" is the defect being hunted.
d2099h_sig_outcome() {
    local sid rc out
    sid=$(new_session sig)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$1" 2>&1) || rc=$?
    if [ "$rc" -eq 0 ]; then
        case "$out" in
            *RECORDED_COMPLEXITY*) ;;
            *) echo "BAD:exit-0-without-receipt"; return ;;
        esac
        echo "ACCEPTED:$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null | tr '\n' ';')"
        return
    fi
    case "$out" in
        *RECORDED_COMPLEXITY*) echo "BAD:receipt-on-failure"; return ;;
    esac
    # A rejection must be clean: nothing appended, no skip annotation.
    if [ "$(d2099_side_effects "$sid")" = "ce=0 skip=0" ]; then
        echo "REJECTED"
    else
        echo "BAD:partial-write-after-rejection"
    fi
}

# A variant is only informative once the reference payload itself records: while
# the CLI refuses everything, "REJECTED" says nothing about normalization.
#
# UNTIDY-BUT-VALID is not an attack (R5-C2). Whitespace padding, a repeated id,
# an empty token and a leading/trailing comma are shapes legitimate producer
# output can plausibly carry, and the contract for them is ACCEPT + canonicalize
# (detail.md D1 step 4 trims and drops empties; round-3 C8 fixed dedup). So these
# variants must land on the reference outcome EXACTLY — accepting "…or REJECTED"
# would let a CLI that refuses every untidy-but-valid payload pass green, and
# would contradict the canonicalization contract asserted by the sibling cases.
d2099h_assert_sig_same() {
    local desc="$1" reference="$2" got="$3"
    case "$reference" in
        ACCEPTED:*) ;;
        *) fail "$desc — unattributable: the reference payload did not record either (baseline [$reference])"; return ;;
    esac
    if [ "$got" = "$reference" ]; then
        pass "$desc"
    elif [ "$got" = "REJECTED" ]; then
        fail "$desc — REJECTED, but this is a normalization form of a VALID payload: the contract is accept + canonicalize (trim, dedup, drop empty tokens), not refuse"
    else
        fail "$desc — want the reference outcome [$reference], got [$got]"
    fi
}

# The other half (test-design.md Pattern 4). An unknown token has ONE documented
# outcome — not "reject or fail-high": detail.md D1 step 5 routes any token outside
# SIGNAL_IDS to the stage's undecidable_level (HIGH), and nothing in D1 items 8/10
# makes an unrecognized token a usage error. Rejection is therefore a contract
# CHANGE, and it is the harmful direction: with no record written every consumer
# falls to the NONE path and re-judges the task from prose. So the row pins the
# accepted-and-undecidable outcome exactly — exit 0, the receipt, the token still
# in the read-back verbatim, level=high, and one event with no skip annotation.
d2099h_assert_sig_invalid() {
    local desc="$1" want_signals="$2" payload="$3" sid rc out
    sid=$(new_session siginv)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$payload" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "$desc — REJECTED (exit $rc): an unrecognized token routes undecidable-high per D1 step 5; refusing writes no record and drops every consumer onto the NONE path. Output: [$out]"
        return
    fi
    assert_contains "$desc — receipt" "RECORDED_COMPLEXITY" "$out"
    assert_eq "$desc — reads back as undecidable-high with the token kept verbatim" \
        "level=high;signals=$want_signals;" \
        "$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null | tr '\n' ';')"
    assert_eq "$desc — one event, no skip annotation" "ce=1 skip=0" "$(d2099_side_effects "$sid")"
}

d2099h_signals_normalization() {
    local canonical zero variant twice
    canonical=$(d2099h_sig_outcome "S1-multi-file,S2-architecture")
    assert_contains "H-SIG-0 the canonical payload records and reads back (baseline for the variants)" \
        "ACCEPTED:level=" "$canonical"

    # (a) untidy renderings of the SAME valid signal set — must be accepted and
    # canonicalized onto the canonical outcome.
    for variant in \
        "S1-multi-file,S1-multi-file,S2-architecture" \
        "S1-multi-file,,S2-architecture" \
        ",S1-multi-file,S2-architecture" \
        "S1-multi-file,S2-architecture," \
        "S1-multi-file, ,S2-architecture" \
        "  S1-multi-file , S2-architecture  " \
        "S1-multi-file,,S1-multi-file, ,S2-architecture,"
    do
        d2099h_assert_sig_same "H-SIG [$variant] is accepted and canonicalized to the canonical outcome" \
            "$canonical" "$(d2099h_sig_outcome "$variant")"
    done

    # (b) payloads made only of separators/whitespace carry ZERO signals — a
    # valid input too, but its canonical form is the documented `--signals ""`
    # zero-signal record, not the canonical set above.
    zero=$(d2099h_sig_outcome "")
    assert_contains "H-SIG-Z0 the explicit zero-signal payload records (baseline for the empty variants)" \
        "ACCEPTED:level=" "$zero"
    for variant in ",,," "   " "," " , "; do
        d2099h_assert_sig_same "H-SIG-Z [$variant] is accepted and canonicalized to the zero-signal outcome" \
            "$zero" "$(d2099h_sig_outcome "$variant")"
    done

    # (c) genuinely invalid tokens. The expected read-back is the payload's own
    # tokens, trimmed and de-duplicated but NEVER dropped (D1 step 4 then step 5):
    # a laundered payload would read back identical to the clean canonical set,
    # which is how an unknown token turns into a silent low downstream.
    local want
    while IFS='|' read -r variant want; do
        [ -n "$variant" ] || continue
        d2099h_assert_sig_invalid "H-SIG-INV [$variant] keeps its unrecognized token and routes undecidable-high" \
            "$want" "$variant"
    done <<'INV'
S1-multi-file,NOT-A-SIGNAL,S2-architecture|S1-multi-file,NOT-A-SIGNAL,S2-architecture
S1-multi-file,S99-invented,S2-architecture|S1-multi-file,S99-invented,S2-architecture
S1-multi-file,LEVEL: low,S2-architecture|S1-multi-file,LEVEL: low,S2-architecture
S1-multi-file,S2-architecture; rm -rf /|S1-multi-file,S2-architecture; rm -rf /
INV

    # Determinism: the same untidy payload twice must not drift.
    variant=$(d2099h_sig_outcome "S1-multi-file,,S1-multi-file, ,S2-architecture")
    twice=$(d2099h_sig_outcome "S1-multi-file,,S1-multi-file, ,S2-architecture")
    assert_eq "H-SIG-DET the same untidy payload yields the same outcome on a second run" \
        "$variant" "$twice"
}

# ONE policy for an oversized payload, pinned for BOTH CLIs: accept it and route
# undecidable-high. detail.md fixes no size bound, and D1 step 5 already answers
# for every token outside SIGNAL_IDS — so size changes nothing, and letting one
# CLI reject while the other answers would make the same input route two ways.
# Sized to stay under
# the platform's own argv limit (msys caps far below Linux) — past it the OS
# rejects the exec and the case would measure the shell, not the CLI. One
# 4000-char id rides along so a per-element bound is exercised too.
d2099h_signals_oversized() {
    local huge sid rc out stored st
    huge=$(run_with_timeout node -e '
const ids = [];
for (let i = 0; i < 400; i++) { ids.push("S" + i + "-generated-signal-name"); }
ids.push("S-" + "x".repeat(4000));
console.log(ids.join(","));
' 2>/dev/null)
    if [ -z "$huge" ]; then
        fail "H-SIG-BIG the oversized payload could not be generated — the case would be vacuous"
        return
    fi

    sid=$(new_session sigbig)
    rc=0
    out=$(run_with_timeout node "$BIN_RECORD" --session "$sid" --signals "$huge" 2>&1) || rc=$?
    if [ "$rc" -ne 0 ]; then
        fail "H-SIG-BIG the oversized payload was REJECTED (exit $rc). detail.md states no size bound, and D1 step 5 sends every token outside SIGNAL_IDS to undecidable — so the pinned policy is ACCEPT + high, exactly as H-SIG-INV requires for a single unknown token. A size cap would be a NEW rule and needs a detail.md amendment before this expectation moves. First line: [$(printf '%s\n' "$out" | head -1)]"
        return
    fi
    assert_eq "H-SIG-BIG an accepted oversized payload prints exactly one receipt" \
        "1" "$(printf '%s\n' "$out" | grep -c 'RECORDED_COMPLEXITY')"
    # Exactly ONE event: a chunked or retried write on a payload this size would
    # append twice, which the receipt and the exit code both look identical for.
    assert_eq "H-SIG-BIG-1 ... appending exactly one evaluation and no skip annotation" \
        "ce=1 skip=0" "$(d2099_side_effects "$sid")"

    # Canonicalized, not truncated: the 401 ids are distinct and already tidy, so
    # the stored list must equal the input verbatim. Compared by count+checksum
    # because the literal is 4000+ chars and a failure message must stay readable.
    stored=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null \
        | grep -m1 '^signals=' | cut -d= -f2-)
    assert_eq "H-SIG-BIG-2 ... keeping every token, in order, neither truncated nor deduplicated away (element count)" \
        "$(printf '%s' "$huge" | tr ',' '\n' | wc -l | tr -d ' ')" \
        "$(printf '%s' "$stored" | tr ',' '\n' | wc -l | tr -d ' ')"
    assert_eq "H-SIG-BIG-3 ... and byte-identical to the payload that was sent (checksum)" \
        "$(printf '%s' "$huge" | cksum)" "$(printf '%s' "$stored" | cksum)"

    # Every token is outside SIGNAL_IDS, so D1 step 5 routes undecidable on ALL
    # THREE stages — the same answer one unknown token produces. A stage that
    # came back low would be a size-dependent silent downgrade.
    for st in detail write_tests write_code; do
        assert_eq "H-SIG-BIG-4 [$st] the stored oversized payload reads back undecidable-high" \
            "level=high" \
            "$(run_with_timeout node "$BIN_READ" --session "$sid" --stage "$st" 2>/dev/null | head -1)"
    done

    # The stateless CLI must reach the SAME policy on the SAME input — the two
    # binaries disagreeing here is the split-brain this case exists to forbid.
    for st in detail write_tests write_code; do
        rc=0
        out=$(run_with_timeout node "$BIN_DERIVE" --stage "$st" --signals "$huge" 2>&1) || rc=$?
        if [ "$rc" -ne 0 ]; then
            fail "H-SIG-BIG-b [$st] derive REJECTED (exit $rc) a payload record accepted — the two CLIs must pin the same accept+high policy. First line: [$(printf '%s\n' "$out" | head -1)]"
            continue
        fi
        assert_eq "H-SIG-BIG-b [$st] derive answers undecidable-high for the same oversized payload" \
            "level=high" "$(printf '%s\n' "$out" | head -1)"
    done
}

# --- H-EMPTY: a zero-byte state file -----------------------------------------
# Distinct from H-COR: there is nothing to fail parsing ON. An empty file is what
# an interrupted or crashed write leaves behind, and the fail-open read must
# answer NONE without repairing it — a read that rewrites the file destroys the
# only evidence that the write was interrupted.
d2099h_empty_state_file() {
    local sid p before rc out
    sid=$(new_session empty)
    p="$WORKFLOW_DIR/$sid.json"
    : > "$p"
    before=$(cksum < "$p")
    assert_eq "H-EMPTY-0 the fixture state file really is zero bytes" "0" "$(wc -c < "$p" | tr -d ' ')"

    rc=0
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" --stage detail 2>/dev/null) || rc=$?
    assert_eq "H-EMPTY-1 read stays fail-open over a zero-byte state file (exit 0)" "0" "$rc"
    assert_eq "H-EMPTY-2 ... answering NONE rather than inventing a level" \
        "NONE" "$(printf '%s\n' "$out" | head -1)"
    assert_eq "H-EMPTY-3 ... and never rewrites the file it read" "$before" "$(cksum < "$p")"

    rc=0
    out=$(run_with_timeout node "$BIN_READ" --session "$sid" 2>/dev/null) || rc=$?
    assert_eq "H-EMPTY-4 the no-stage read is fail-open over the same file (exit 0)" "0" "$rc"
    assert_eq "H-EMPTY-5 ... also answering NONE" "NONE" "$(printf '%s\n' "$out" | head -1)"
}


d2099h_read_back_per_field
d2099h_unusable_workflow_dir
d2099h_corrupt_state_file
d2099h_empty_state_file
d2099h_signals_normalization
d2099h_signals_oversized
