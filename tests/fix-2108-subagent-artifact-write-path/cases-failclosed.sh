#!/usr/bin/env bash
# Tests: hooks/lib/active-session-ids.js, hooks/lib/protected-basenames.js
# Tags: protected-basename, active-session-ids, fail-closed, cross-session, security, scope:issue-specific, pwsh-not-required
# Part of tests/fix-2108-subagent-artifact-write-path.sh (rules/coding/file-split.md).

# Sections C1c + C1d — the two halves of "what happens when the effective session-id
# set cannot be fully known". C1c: it cannot be observed at all, so the narrowing must
# switch OFF and the old suffix-only breadth must return (a narrowing that fails OPEN
# would be a worse defect than the one #2108 reports). C1d: it IS observable and holds
# OTHER sessions' ids, which stay protected because a reader keyed on that id exists.

_fc_write_probe() {
    cat > "$PROBE_DIR/fc-probe.js" <<'PROBE_EOF'
"use strict";
// argv: <protected-basenames.js> <basename> <spelling> <sid|->
// Prints the classifier verdict for ONE basename under whatever CLAUDE_WORKFLOW_DIR
// and session env the caller established, so fail-closed behaviour is observable.
const p = require(process.argv[2]);
const sid = process.argv[5];
const opts = { spelling: process.argv[4] };
if (sid && sid !== "-") opts.sessionCtx = { sessionId: sid };
process.stdout.write(String(p.classifyProtectedPath(process.argv[3], opts)));
PROBE_EOF
}

# _fc_classify <workflow-dir|-> <sid|-> <basename> <spelling>
_fc_classify() {
    local wf="$1" sid="$2" base="$3" spell="$4"
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        if [ "$wf" = "-" ]; then unset CLAUDE_WORKFLOW_DIR; else export CLAUDE_WORKFLOW_DIR="$wf"; fi
        run_probe "$PROBE_DIR/fc-probe.js" "$PB_NODE" "$base" "$spell" "$sid"
    )
}

run_C1c_fail_closed() {
    local missing_dir missing_node out mod_ok

    _fc_write_probe

    # C1c-0 — the new observation module must exist and answer in the documented shape.
    # Without it there is no `complete` flag and no fail-closed decision to make.
    mod_ok="$(run_probe -e "const m=require(process.argv[1]);const r=m.observeActiveSessionIds({sessionId:'wsid'});process.stdout.write([typeof m.observeActiveSessionIds,r&&r.sids instanceof Set,typeof (r||{}).complete].join(','))" "$ACTIVE_SIDS_NODE")"
    assert_eq "C1c-0 observeActiveSessionIds returns {sids:Set, complete:boolean}" \
        "function,true,boolean" "$mod_ok"

    # C1c-0b — the sid handed in via sessionCtx is always part of the observed set,
    # even when nothing on disk corroborates it. Otherwise the CURRENT session could
    # not write its own marker.
    assert_eq "C1c-0b sessionCtx sid is always in the observed set" "true" \
        "$(run_probe -e "const m=require(process.argv[1]);process.stdout.write(String(m.observeActiveSessionIds({sessionId:'wsid'}).sids.has('wsid')))" "$ACTIVE_SIDS_NODE")"

    # C1c-i — workflow dir does not exist AND no session id is derivable. The set is
    # incomplete, so no stem may be treated as non-clearance-bearing: the false
    # positive that #2108 complains about is CORRECT to block in this state.
    missing_dir="$TMPBASE_SH/no-such-workflow-dir"
    rm -rf "$missing_dir" 2>/dev/null || true
    missing_node="$(node_path "$missing_dir")"
    assert_eq "C1c-i unobservable sid set -> kebab stem still blocks (clean)" "marker" \
        "$(_fc_classify "$missing_node" - "issue-2108-survey.gh-env" clean)"
    assert_eq "C1c-i unobservable sid set -> kebab stem still blocks (bash)" "marker" \
        "$(_fc_classify "$missing_node" - "issue-2108-survey.workflow-off" bash)"
    assert_eq "C1c-i unobservable sid set -> token suffix still blocks" "token" \
        "$(_fc_classify "$missing_node" - "issue-2108-survey.off-clearance" clean)"
    assert_eq "C1c-i incomplete observation is reported as complete:false" "false" \
        "$(cd "$NEUTRAL_CWD" && CLAUDE_WORKFLOW_DIR="$missing_node" run_probe -e "const m=require(process.argv[1]);process.stdout.write(String(m.observeActiveSessionIds({}).complete))" "$ACTIVE_SIDS_NODE")"

    # C1c-i-control — the SAME basename with a readable workflow dir and a known sid
    # is allowed. Without this counterweight C1c-i would also pass on a classifier
    # that simply never narrows anything (Pattern 4: assert both directions).
    assert_eq "C1c-i control: observable set -> same kebab stem is allowed" "null" \
        "$(_fc_classify "$WFDIR" wsid "issue-2108-survey.gh-env" clean)"

    # C1c-ii — readdir denied on an EXISTING dir. Same verdict as C1c-i, reached by a
    # different fault, so an implementation that only checks existsSync is caught.
    local denied denied_node probe
    denied="$TMPBASE_SH/denied-workflow-dir"
    mkdir -p "$denied" 2>/dev/null || true
    chmod 000 "$denied" 2>/dev/null || true
    probe="$(cd "$NEUTRAL_CWD" && CLAUDE_WORKFLOW_DIR="$(node_path "$denied")" run_probe -e "try{require('fs').readdirSync(process.env.CLAUDE_WORKFLOW_DIR);process.stdout.write('readable')}catch(e){process.stdout.write('denied')}")"
    if [ "$probe" = "denied" ]; then
        denied_node="$(node_path "$denied")"
        assert_eq "C1c-ii readdir denied -> kebab stem still blocks" "marker" \
            "$(_fc_classify "$denied_node" - "issue-2108-survey.gh-env" clean)"
        assert_eq "C1c-ii readdir denied -> complete:false" "false" \
            "$(cd "$NEUTRAL_CWD" && CLAUDE_WORKFLOW_DIR="$denied_node" run_probe -e "const m=require(process.argv[1]);process.stdout.write(String(m.observeActiveSessionIds({}).complete))" "$ACTIVE_SIDS_NODE")"
    else
        skip "C1c-ii readdir-permission fault not injectable here (chmod 000 stayed readable) - covered on POSIX CI only"
    fi
    chmod 755 "$denied" 2>/dev/null || true
}

# _c7_complete <workflow-dir> -> the observation's `complete` flag
_c7_complete() {
    (
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID CLAUDE_ENV_FILE
        export CLAUDE_WORKFLOW_DIR="$1"
        run_probe -e "const m=require(process.argv[1]);process.stdout.write(String(m.observeActiveSessionIds({sessionId:'wsid'}).complete))" "$ACTIVE_SIDS_NODE"
    )
}

# Section C7 — MALFORMED STATE STORE (review C3). C1c-ii's permission fault can skip
# (chmod is a no-op on many Windows filesystems), so the "the observer hit an fs error"
# branch had no deterministic case at all. Every fault here is a real on-disk fixture
# driven through the real classifier — no mocks, no monkey-patched fs.
run_C7_state_faults() {
    local notdir notdir_node bad bad_node envfile

    _fc_write_probe

    # C7-1 — the workflow dir IS A FILE. readdirSync throws ENOTDIR on every platform,
    # so this is the portable twin of C1c-ii: observation incomplete -> narrowing OFF
    # -> the #2108 false positive is CORRECT to block in this state.
    notdir="$TMPBASE_SH/c7-wf-is-a-file"
    rm -rf "$notdir" 2>/dev/null || true
    printf 'not a directory' > "$notdir"
    notdir_node="$(node_path "$notdir")"
    assert_eq "C7-1 workflow dir is a file -> complete:false" "false" "$(_c7_complete "$notdir_node")"
    assert_eq "C7-1 workflow dir is a file -> kebab stem still blocks (clean)" "marker" \
        "$(_fc_classify "$notdir_node" - "issue-2108-survey.gh-env" clean)"
    assert_eq "C7-1 workflow dir is a file -> token suffix still blocks" "token" \
        "$(_fc_classify "$notdir_node" - "issue-2108-survey.off-clearance" clean)"
    assert_eq "C7-1 workflow dir is a file -> real marker obviously still blocks" "marker" \
        "$(_fc_classify "$notdir_node" wsid "wsid.workflow-off" clean)"

    # C7-2..C7-4 share one deliberately hostile workflow dir: malformed JSON, a
    # filename/content mismatch, a subdirectory, a dotfile, and a name outside the
    # sid alphabet. The store is READABLE, so the observation must still complete —
    # a classifier that crashed or bailed here would fail closed on every artifact
    # name and silently reinstate #2108.
    bad="$TMPBASE_SH/c7-malformed-wf"
    rm -rf "$bad" 2>/dev/null || true
    mkdir -p "$bad/subdir-sid.json"
    printf '{"version":1,"session_id":"wsid"}' > "$bad/wsid.json"
    printf '{not json at all' > "$bad/othersid.json"
    printf '' > "$bad/emptysid.json"
    printf '{"version":1,"session_id":"beta-sid"}' > "$bad/alpha-sid.json"
    printf 'x' > "$bad/.hidden"
    printf 'x' > "$bad/has space.json"
    bad_node="$(node_path "$bad")"

    assert_eq "C7-2 malformed/odd entries do not break the observation" "true" "$(_c7_complete "$bad_node")"
    assert_eq "C7-2 a state file with malformed JSON still protects its own sid" "marker" \
        "$(_fc_classify "$bad_node" wsid "othersid.workflow-off" clean)"
    assert_eq "C7-2 an empty state file still protects its own sid (token kind)" "token" \
        "$(_fc_classify "$bad_node" wsid "emptysid.off-clearance" clean)"

    # C7-3 — filename/content MISMATCH. Readers open `path.join(dir, sid + ".<kind>")`,
    # so the FILENAME is what confers clearance; the recorded session_id inside is not
    # consulted and must not be needed to keep the on-disk name protected.
    assert_eq "C7-3 filename-derived sid stays protected despite a mismatched body" "marker" \
        "$(_fc_classify "$bad_node" wsid "alpha-sid.workflow-off" clean)"

    # C7-4 — the counterweight (Pattern 4). With the store readable, the artifact name
    # is still ALLOWED, so C7-1..C7-3 are proving the fault path and not a classifier
    # that simply blocks everything once any odd file exists.
    assert_eq "C7-4 control: artifact stem still allowed over a hostile-but-readable store" "null" \
        "$(_fc_classify "$bad_node" wsid "issue-2108-survey.gh-env" clean)"
    assert_eq "C7-4 control: sid-shaped stems in the store are unaffected" "marker" \
        "$(_fc_classify "$bad_node" wsid "wsid.gh-env" clean)"

    # C7-5 — readFileSync fault on the sid-resolution side: CLAUDE_ENV_FILE points at a
    # DIRECTORY, so the SSOT resolver's read throws (EISDIR). Whether that is caught
    # inside resolveSessionId or surfaces as complete:false, the classifier must still
    # answer and must still block a real marker — never crash into an empty verdict.
    envfile="$TMPBASE_SH/c7-env-is-a-dir"
    mkdir -p "$envfile" 2>/dev/null || true
    local v
    v="$(
        cd "$NEUTRAL_CWD" || exit 1
        unset CLAUDE_SESSION_ID CLAUDE_CODE_SESSION_ID
        export CLAUDE_ENV_FILE="$(node_path "$envfile")"
        export CLAUDE_WORKFLOW_DIR="$bad_node"
        run_probe "$PROBE_DIR/fc-probe.js" "$PB_NODE" "wsid.workflow-off" clean wsid
    )"
    assert_eq "C7-5 unreadable CLAUDE_ENV_FILE: real marker still blocks" "marker" "$v"

    # SKIPPED: a state file that becomes unreadable BETWEEN the readdir and the read.
    # Because: the observer never opens the files (the filename is the sid), so there is
    # no read window to race at this layer.
    # L3 gap: a future observer that starts parsing state bodies would need this case.
}

run_C1d_cross_session() {
    local xdir xdir_node docs_hit

    # A dedicated workflow dir so the ids observed here are exactly the ones written.
    xdir="$TMPBASE_SH/cross-session-wf"
    rm -rf "$xdir" 2>/dev/null || true
    mkdir -p "$xdir"
    printf '{"version":1,"session_id":"othersid"}' > "$xdir/othersid.json"
    printf '{"version":1,"session_id":"wsid"}' > "$xdir/wsid.json"
    xdir_node="$(node_path "$xdir")"

    _fc_write_probe

    # C1d-1 — R2b residual risk, protective half: `othersid` is not THIS session's id,
    # but a live reader is keyed on it, so writing its marker is still a forgery.
    assert_eq "C1d other session's marker stays blocked (clean)" "marker" \
        "$(_fc_classify "$xdir_node" wsid "othersid.workflow-off" clean)"
    assert_eq "C1d other session's marker stays blocked (bash)" "marker" \
        "$(_fc_classify "$xdir_node" wsid "othersid.workflow-off" bash)"
    assert_eq "C1d other session's token stays blocked" "token" \
        "$(_fc_classify "$xdir_node" wsid "othersid.off-clearance" clean)"
    assert_eq "C1d own marker stays blocked" "marker" \
        "$(_fc_classify "$xdir_node" wsid "wsid.workflow-off" clean)"

    # C1d-2 — R2b residual risk, accepted half: a name matching NO observed session is
    # allowed. This is the deliberately accepted hole — a session that starts LATER and
    # happens to be assigned this id would find a pre-planted marker. It is accepted
    # because ids are uuid/timestamp-shaped and unguessable; C1d-3 requires it be
    # written down rather than left as tacit knowledge.
    assert_eq "C1d unobserved ghost stem is allowed (accepted R2b hole)" "null" \
        "$(_fc_classify "$xdir_node" wsid "ghost-name.workflow-off" clean)"

    # C1d-2b — and on the bash spelling too. The R2c named exception narrows only
    # TAIL-MATCHING stems (e.g. `report-<uuid>.gh-env`, where the stem ends with a real
    # sid); an entirely-unrelated ghost stem matches neither the canonical tail shape nor
    # the bash residue shape nor any observed sid, so it stays allowed on BOTH spellings
    # per R2b — same shape as fp-kebab-bash in cases-stem-rules.sh.
    assert_eq "C1d ghost stem is allowed on the bash spelling too (R2b, not a tail match)" "null" \
        "$(_fc_classify "$xdir_node" wsid "ghost-name.workflow-off" bash)"

    # C1d-3 — the residual risk must be DOCUMENTED, not just accepted in a plan that
    # disappears when the session ends. Pattern 3: recorded as a skip while the S5
    # doc work is still pending, so the gap is visible instead of silently absent.
    docs_hit="$(grep -rl 'isClearanceBearingStem' "$AGENTS_DIR/docs" 2>/dev/null | head -1)"
    if [ -n "$docs_hit" ]; then
        pass "C1d-3 stem predicate and its residual risk are documented ($docs_hit)"
    else
        skip "C1d-3 R2b residual-risk documentation not written yet (S5 step pending)"
    fi
    # SKIPPED: asserting the exact residual-risk sentence in the S5 doc.
    # Because: the S5 documentation step has not run; asserting wording now would
    # pin prose that the doc author has not written yet.
    # L3 gap: whether a future reader of protected-basenames.js can learn that a
    # non-session-shaped stem is allowed on purpose rather than by oversight.
}
