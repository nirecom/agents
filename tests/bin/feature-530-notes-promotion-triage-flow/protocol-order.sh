#!/usr/bin/env bash
# tests/feature-530-notes-promotion-triage-flow/protocol-order.sh
# Tests: bin/worktree-notes-triage.js, skills/_shared/notes-promotion.md
# Tags: notes-promotion, worktree-notes, triage, issue-create, call-order, prefilter, TL2, scope:issue-specific
#
# O — the ORDER of the protocol's side effects, observed at the process
#     boundary rather than re-simulated: every `worktree-notes-triage.js`
#     invocation and every `/issue-create` invocation is recorded, in real time,
#     into one shared trace by executable wrappers on PATH. The assertions are
#     made against that trace, so a driver that annotated before creating, or
#     that announced after filing, is caught even though it "did all the steps".
#
#     Sibling promotion-loop.sh asserts the CONTENT the loop leaves behind
#     (markers pair with the numbers the stub returned). This file asserts the
#     SEQUENCE the protocol prescribes:
#         NP-4 prefilter → NP-5 list → NP-6 notice → (NP-7 create → NP-8 annotate)*
#
# N — NP-4 says an all-`- (none)` notes file must cost no `worktree-notes-triage.js`
#     call at all. Only a trace taken at the process boundary can show the CLI
#     was never spawned; a test that inspects the CLI's output cannot, because
#     it has already paid for the call it is trying to prove absent.
#
# The driver below (`protocol_pass`) is a reference implementation of
# skills/_shared/notes-promotion.md NP-4..NP-8 — the protocol is prompt text
# executed by the model, so no repo code can be invoked here. Its prefilter reads
# the notes file directly with awk, exactly as NP-4 requires the reader to do
# BEFORE reaching for the CLI. Case O2 is the control that keeps N1 honest: the
# same driver, on notes that do hold findings, does spawn the CLI.
#
# TL3 gap (what this test does NOT catch):
# - Whether the real model-driven callsites (worktree-end WE-11, session-close
#   SC-8, issue-close-finalize residual) issue the calls in this order in a live
#   session, or skip the NP-4 prefilter and call `list` on a clean session.
# - Whether the notice actually reaches the user's chat transcript before the
#   first issue appears on GitHub.
# Closest-to-action mitigation: this gap is checked at WORKFLOW_USER_VERIFIED
# preflight via bin/check-verification-gate.sh category: skill-orchestration.

. "$(dirname "${BASH_SOURCE[0]}")/helpers.sh"

# --------------------------------------------------------------------------
# Traced executables on PATH. Each appends one line to $TRACE before doing its
# real work, so the trace is a faithful, ordered record of the pass's side
# effects — not a log the driver keeps about itself.
# --------------------------------------------------------------------------
TRACE_DIR="$TMPD/trace-bin"
mkdir -p "$TRACE_DIR"
TRACE="$TMPD/protocol.trace"
export TRACE_FILE="$TRACE"
export TRIAGE_BIN_PATH="$TRIAGE_BIN"

cat > "$TRACE_DIR/wnt" <<'WRAP'
#!/usr/bin/env bash
# Traced stand-in for `node bin/worktree-notes-triage.js`.
sub="$1"
case "$sub" in
    list)     printf 'list\n' >> "$TRACE_FILE" ;;
    annotate) printf 'annotate|%s|%s\n' "$3" "$4" >> "$TRACE_FILE" ;;
    *)        printf '%s\n' "$sub" >> "$TRACE_FILE" ;;
esac
exec node "$TRIAGE_BIN_PATH" "$@"
WRAP
chmod +x "$TRACE_DIR/wnt"

cat > "$TRACE_DIR/issue-create" <<'STUB'
#!/usr/bin/env bash
# Traced stand-in for the /issue-create skill: allocates a number and records the
# creation in the SAME trace, so create/annotate interleaving is observable.
n=$(( $(cat "$ISSUE_SEQ_FILE" 2>/dev/null || echo 8000) + 1 ))
printf '%s' "$n" > "$ISSUE_SEQ_FILE"
printf 'create|%s|%s\n' "$n" "$*" >> "$TRACE_FILE"
printf '%s\n' "$n"
STUB
chmod +x "$TRACE_DIR/issue-create"

export PATH="$TRACE_DIR:$PATH"
export ISSUE_SEQ_FILE="$TMPD/protocol.seq"

# --------------------------------------------------------------------------
# NP-4 prefilter, performed the way the protocol requires: by reading the notes
# file, with no CLI call. Exit 0 when all three triage sections hold nothing but
# `- (none)`.
# --------------------------------------------------------------------------
all_sections_none() {
    awk '
        /^## / { sec = substr($0, 4); next }
        /^- / {
            if (sec == "BugsFound" || sec == "RelatedTasks" || sec == "NextTasks") {
                if ($0 != "- (none)") { found = 1 }
            }
        }
        END { exit(found ? 1 : 0) }
    ' "$1"
}

# protocol_pass <os-path-to-notes> <node-path-to-notes>
# Reference driver for NP-4..NP-8. Every observable step goes through PATH.
protocol_pass() {
    local file="$1" notes="$2" out n i raw line num
    if all_sections_none "$file"; then
        return 0                                    # NP-4: nothing further runs
    fi
    out="$(run_with_timeout 30 wnt list "$notes" 2>/dev/null)"   # NP-5
    n="$(json_len "$out")"
    [ "$n" != "ERR" ] && [ "$n" -gt 0 ] 2>/dev/null || return 0
    # NP-6: one line, before anything is created.
    printf 'notice|%s findings will be filed as issues now — the notes are about to become unreachable\n' \
        "$n" >> "$TRACE"
    i=0
    while [ "$i" -lt "$n" ]; do                     # NP-7 / NP-8
        raw="$(json_at "$out" "$i" raw)"
        line="$(json_at "$out" "$i" lineNumber)"
        num="$(issue-create --title "$raw" 2>/dev/null)"
        run_with_timeout 30 wnt annotate "$notes" "$line" "$num" >/dev/null 2>&1
        i=$((i + 1))
    done
    return 0
}

trace_ops() { cut -d'|' -f1 < "$TRACE" 2>/dev/null | tr '\n' ' ' | sed 's/ *$//'; }

# ===========================================================================
# O1 — the real call sequence, observed at the process boundary
# ===========================================================================
o1_call_sequence() {
    local dir="$TMPD/o1" notes missing="" ops
    : > "$TRACE"; : > "$ISSUE_SEQ_FILE"
    notes="$(write_notes "$dir" "sess-o1")"          # 6 entries

    protocol_pass "$dir/WORKTREE_NOTES.md" "$notes"

    ops="$(trace_ops)"
    # list first, notice second, then six create/annotate pairs.
    local want="list notice create annotate create annotate create annotate create annotate create annotate create annotate"
    [ "$ops" = "$want" ] || missing="$missing sequence=[$ops]"

    # Exactly one list: re-listing between entries would mean the queue was
    # re-derived mid-pass, which NP-7 ("walk the listed entries in list order")
    # forbids.
    local lists; lists="$(grep -c '^list$' "$TRACE" 2>/dev/null || echo 0)"
    [ "$lists" = "1" ] || missing="$missing list-count=$lists"

    # Every annotate carries the number emitted by the create IMMEDIATELY before
    # it — the pairing NP-8 ("as soon as its number is known") demands.
    local pair_bad
    pair_bad="$(awk -F'|' '
        $1 == "create"   { last = $2; next }
        $1 == "annotate" { if ($3 != last) { print "annotate-" NR "-used-" $3 "-not-" last }; last = "" }
    ' "$TRACE")"
    [ -z "$pair_bad" ] || missing="$missing $pair_bad"

    # No annotate may precede the first create, at any position.
    local first_create first_annotate
    first_create="$(grep -n '^create|' "$TRACE" | head -1 | cut -d: -f1)"
    first_annotate="$(grep -n '^annotate|' "$TRACE" | head -1 | cut -d: -f1)"
    if [ -n "$first_annotate" ] && [ -n "$first_create" ] \
       && [ "$first_annotate" -lt "$first_create" ]; then
        missing="$missing annotate-before-create"
    fi

    if [ -z "$missing" ]; then
        pass "O1: the traced pass runs list → notice → (create → annotate)×6, each annotate carrying the number its own create returned"
    else
        fail "O1: protocol call order wrong" "$missing (trace=$(tr '\n' ';' < "$TRACE"))"
    fi
}

# ===========================================================================
# O2 — the NP-6 notice precedes the first CLI-observable creation
# ===========================================================================
# The static suite checks that the notice is DOCUMENTED before the /issue-create
# step. This checks the notice is EMITTED before any issue is actually created,
# and that it states the count it is about to file.
o2_notice_before_first_create() {
    local dir="$TMPD/o2" notes missing="" notice_ln create_ln notice_text
    : > "$TRACE"; : > "$ISSUE_SEQ_FILE"
    notes="$(write_notes "$dir" "sess-o2")"

    protocol_pass "$dir/WORKTREE_NOTES.md" "$notes"

    notice_ln="$(grep -n '^notice|' "$TRACE" | head -1 | cut -d: -f1)"
    create_ln="$(grep -n '^create|' "$TRACE" | head -1 | cut -d: -f1)"
    [ -n "$notice_ln" ] || missing="$missing no-notice"
    [ -n "$create_ln" ] || missing="$missing no-create"
    if [ -n "$notice_ln" ] && [ -n "$create_ln" ] && [ "$notice_ln" -ge "$create_ln" ]; then
        missing="$missing notice-line=$notice_ln create-line=$create_ln"
    fi
    notice_text="$(grep '^notice|' "$TRACE" | head -1 | cut -d'|' -f2-)"
    case "$notice_text" in
        6*) ;;                                       # the count it is about to file
        *) missing="$missing notice-omits-count=[$notice_text]" ;;
    esac
    case "$notice_text" in
        *unreachable*) ;;                            # and why, now
        *) missing="$missing notice-omits-reason" ;;
    esac
    # One notice for the pass, not one per issue.
    local notices; notices="$(grep -c '^notice|' "$TRACE" 2>/dev/null || echo 0)"
    [ "$notices" = "1" ] || missing="$missing notice-count=$notices"

    if [ -z "$missing" ]; then
        pass "O2: the one-line notice is emitted once, before the first /issue-create call, naming the count and the reason"
    else
        fail "O2: notice ordering wrong" "$missing (trace=$(tr '\n' ';' < "$TRACE"))"
    fi
}

# ===========================================================================
# N1 — all-'- (none)' notes spawn no CLI at all (NP-4)
# ===========================================================================
n1_prefilter_skips_the_cli() {
    local dir="$TMPD/n1" notes missing="" before_md5
    : > "$TRACE"; : > "$ISSUE_SEQ_FILE"
    notes="$(write_empty_notes "$dir" "sess-n1")"
    before_md5="$(file_md5 "$dir/WORKTREE_NOTES.md")"

    protocol_pass "$dir/WORKTREE_NOTES.md" "$notes"

    # The trace is the whole assertion: not one list, not one create, not one
    # annotate was spawned.
    [ -s "$TRACE" ] && missing="$missing trace-not-empty=[$(tr '\n' ';' < "$TRACE")]"
    [ "$(file_md5 "$dir/WORKTREE_NOTES.md")" = "$before_md5" ] || missing="$missing notes-modified"
    [ "$(tmp_residue "$dir/WORKTREE_NOTES.md")" = "0" ] || missing="$missing tmp-residue"
    [ -s "$ISSUE_SEQ_FILE" ] && missing="$missing issue-number-allocated"

    if [ -z "$missing" ]; then
        pass "N1: notes whose three triage sections are all '- (none)' produce no list, no create and no annotate call (NP-4 prefilter)"
    else
        fail "N1: prefilter did not stop the pass" "$missing"
    fi
}

# N2 — the prefilter is not a blanket "never run": one real entry among the
# placeholders must put the pass back on the CLI. Without this, N1 would pass
# for a driver that never calls anything.
n2_prefilter_control() {
    local dir="$TMPD/n2" notes missing="" ops
    : > "$TRACE"; : > "$ISSUE_SEQ_FILE"
    mkdir -p "$dir"
    cat > "$dir/WORKTREE_NOTES.md" <<'EOF'
# Worktree Notes
Branch: feature/n2
Session-ID: sess-n2

## BugsFound
- (none)

## RelatedTasks
- (none)

## NextTasks
- (none)
- one real finding

## ManualReminders
- (none)

## History Notes
- (none)
EOF
    notes="$(nodepath "$dir/WORKTREE_NOTES.md")"

    protocol_pass "$dir/WORKTREE_NOTES.md" "$notes"

    ops="$(trace_ops)"
    [ "$ops" = "list notice create annotate" ] || missing="$missing sequence=[$ops]"
    grep -q '<!-- promoted: #' "$dir/WORKTREE_NOTES.md" 2>/dev/null || missing="$missing entry-not-marked"

    if [ -z "$missing" ]; then
        pass "N2: control — a single real entry among '- (none)' placeholders puts the pass back on list → notice → create → annotate"
    else
        fail "N2: prefilter over-suppressed a real finding" "$missing (trace=$(tr '\n' ';' < "$TRACE"))"
    fi
}

o1_call_sequence
o2_notice_before_first_create
n1_prefilter_skips_the_cli
n2_prefilter_control

echo ""
echo "Total: PASS=$PASS FAIL=$FAIL SKIP=$SKIP"
exit $((FAIL > 0 ? 1 : 0))
